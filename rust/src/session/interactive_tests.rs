use super::*;
use russh::server::{self, Server as _};
use std::borrow::Cow;
#[derive(Clone, Default)]
struct TestServer {
    first: bool,
    round: u8,
}
fn next_factor() -> server::Auth {
    server::Auth::Reject {
        proceed_with_methods: Some((&[russh::MethodKind::KeyboardInteractive][..]).into()),
        partial_success: true,
    }
}
impl server::Server for TestServer {
    type Handler = Self;
    fn new_client(&mut self, _: Option<std::net::SocketAddr>) -> Self {
        Self::default()
    }
}
impl server::Handler for TestServer {
    type Error = anyhow::Error;
    async fn auth_password(&mut self, _: &str, password: &str) -> Result<server::Auth> {
        self.first = password == "fixture-password";
        Ok(if self.first {
            next_factor()
        } else {
            server::Auth::reject()
        })
    }
    async fn auth_publickey(
        &mut self,
        _: &str,
        _: &russh::keys::PublicKey,
    ) -> Result<server::Auth> {
        self.first = true;
        Ok(next_factor())
    }
    async fn auth_keyboard_interactive<'a>(
        &'a mut self,
        user: &str,
        _: &str,
        response: Option<server::Response<'a>>,
    ) -> Result<server::Auth> {
        if !self.first && user != "interactive-only" {
            return Ok(server::Auth::reject());
        }
        if let Some(response) = response {
            let values: Vec<_> = response.collect();
            if self.round == 1
                && (values.len() != 2
                    || values[0].as_ref() != b"654321"
                    || values[1].as_ref() != b"visible")
            {
                return Ok(server::Auth::reject());
            }
            if self.round == 2 {
                return Ok(server::Auth::Accept);
            }
        }
        self.round += 1;
        Ok(server::Auth::Partial {
            name: Cow::Borrowed("Fixture MFA"),
            instructions: Cow::Borrowed("Synthetic challenge"),
            prompts: Cow::Owned(if self.round == 1 {
                vec![
                    (Cow::Borrowed("One-time code"), false),
                    (Cow::Borrowed("Label"), true),
                ]
            } else {
                vec![]
            }),
        })
    }
    async fn channel_open_session(
        &mut self,
        _: Channel<server::Msg>,
        reply: server::ChannelOpenHandle,
        _: &mut server::Session,
    ) -> Result<()> {
        reply.accept().await;
        Ok(())
    }
    async fn pty_request(
        &mut self,
        id: russh::ChannelId,
        _: &str,
        _: u32,
        _: u32,
        _: u32,
        _: u32,
        _: &[(russh::Pty, u32)],
        s: &mut server::Session,
    ) -> Result<()> {
        s.channel_success(id)?;
        Ok(())
    }
    async fn shell_request(&mut self, id: russh::ChannelId, s: &mut server::Session) -> Result<()> {
        s.channel_success(id)?;
        s.data(id, b"MFA_READY".to_vec())?;
        Ok(())
    }
}
async fn next(id: &str) -> Result<crate::api::client::AuthChallenge> {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if let Some(v) = interactive::challenge(id).await {
                return v;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .context("fixture challenge timeout")
}
#[tokio::test]
#[ignore = "Run scripts/test-core.sh for loopback protocol tests"]
async fn fixture_jump_authentication_supports_mfa_without_terminal() -> Result<()> {
    let config = Arc::new(server::Config {
        auth_rejection_time: Duration::ZERO,
        auth_rejection_time_initial: Some(Duration::ZERO),
        keys: vec![russh::keys::PrivateKey::random(
            &mut rand::rng(),
            russh::keys::Algorithm::Ed25519,
        )?],
        ..Default::default()
    });
    let socket = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let port = socket.local_addr()?.port();
    let task =
        tokio::spawn(async move { TestServer::default().run_on_socket(config, &socket).await });
    let (id, fp) = probe("127.0.0.1".into(), port).await?;
    let task_id = id.clone();
    let auth = tokio::spawn(async move {
        authenticate_jump(
            &task_id,
            &fp,
            "tester".into(),
            "fixture-password".into(),
            String::new(),
            String::new(),
        )
        .await
    });
    let first = next(&id).await?;
    interactive::respond(&id, &first.id, vec!["654321".into(), "visible".into()]).await?;
    let second = next(&id).await?;
    interactive::respond(&id, &second.id, vec![]).await?;
    tokio::time::timeout(Duration::from_secs(5), auth).await???;
    assert!(live(&id).await?.output.lock().await.is_none());
    disconnect(&id).await?;
    task.abort();
    let _ = task.await;
    Ok(())
}
#[tokio::test]
#[ignore = "Run scripts/test-core.sh for loopback protocol tests"]
async fn fixture_mfa_password_key_rounds_cancel_and_reject() -> Result<()> {
    let config = Arc::new(server::Config {
        auth_rejection_time: Duration::ZERO,
        auth_rejection_time_initial: Some(Duration::ZERO),
        keys: vec![russh::keys::PrivateKey::random(
            &mut rand::rng(),
            russh::keys::Algorithm::Ed25519,
        )?],
        ..Default::default()
    });
    let socket = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let port = socket.local_addr()?.port();
    let task =
        tokio::spawn(async move { TestServer::default().run_on_socket(config, &socket).await });
    for mode in [
        "password",
        "key",
        "interactive-only",
        "cancel",
        "reject",
        "wrong-fingerprint",
    ] {
        let (id, fp) = probe("127.0.0.1".into(), port).await?;
        let key = if mode == "key" {
            russh::keys::PrivateKey::random(&mut rand::rng(), russh::keys::Algorithm::Ed25519)?
                .to_openssh(russh::keys::ssh_key::LineEnding::LF)?
                .to_string()
        } else {
            String::new()
        };
        let user = if mode == "interactive-only" {
            "interactive-only"
        } else {
            "tester"
        };
        let password = if mode == "interactive-only" {
            ""
        } else {
            "fixture-password"
        };
        let task_id = id.clone();
        let approved = if mode == "wrong-fingerprint" {
            "wrong".into()
        } else {
            fp
        };
        let auth = tokio::spawn(async move {
            authenticate(
                &task_id,
                &approved,
                user.into(),
                password.into(),
                key,
                String::new(),
            )
            .await
        });
        if mode == "wrong-fingerprint" {
            assert!(auth.await?.is_err());
            assert!(interactive::challenge(&id).await.is_none());
            continue;
        }
        let first = next(&id).await?;
        assert!(!first.prompts[0].echo && first.prompts[1].echo);
        assert!(live(&id).await.is_err());
        if mode == "cancel" {
            disconnect(&id).await?;
            assert!(auth.await?.is_err());
            assert!(interactive::challenge(&id).await.is_none());
            continue;
        }
        interactive::respond(
            &id,
            &first.id,
            vec![
                if mode == "reject" { "wrong" } else { "654321" }.into(),
                "visible".into(),
            ],
        )
        .await?;
        if mode == "reject" {
            assert!(auth.await?.is_err());
            assert!(live(&id).await.is_err());
            continue;
        }
        let second = next(&id).await?;
        assert!(second.prompts.is_empty());
        assert_ne!(first.id, second.id);
        assert!(interactive::respond(&id, &first.id, vec![]).await.is_err());
        interactive::respond(&id, &second.id, vec![]).await?;
        tokio::time::timeout(Duration::from_secs(5), auth).await???;
        let live = live(&id).await?;
        let mut rx = live.output.lock().await.take().unwrap();
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(5), rx.recv())
                .await?
                .unwrap(),
            b"MFA_READY"
        );
        disconnect(&id).await?;
    }
    task.abort();
    let _ = task.await;
    Ok(())
}
