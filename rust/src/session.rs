//! No credential is sent during probing. Approval is bound to the exact live
//! transport which supplied the fingerprint (never reconnect between the two).
use anyhow::{anyhow, bail, Context, Result};
use russh::{
    client,
    keys::{HashAlg, PrivateKeyWithHashAlg},
    Channel, ChannelMsg, Disconnect,
};
use russh_sftp::client::SftpSession;
use std::{
    collections::HashMap,
    sync::{Arc, OnceLock},
    time::Duration,
};
use tokio::sync::{mpsc, watch, Mutex, Semaphore};
use uuid::Uuid;
use zeroize::Zeroizing;

pub type Transport = client::Handle<HostKeyProbe>;
pub struct HostKeyProbe {
    pub fingerprint: Arc<std::sync::Mutex<Option<String>>>,
}
impl client::Handler for HostKeyProbe {
    type Error = anyhow::Error;
    async fn check_server_key(
        &mut self,
        key: &russh::keys::PublicKeyOrCertificate,
    ) -> Result<bool> {
        if key.certificate().is_some() {
            bail!("SSH host certificates are not supported in this preview");
        }
        let value = key.public_key().fingerprint(HashAlg::Sha256).to_string();
        let mut slot = self
            .fingerprint
            .lock()
            .map_err(|_| anyhow!("Host key state unavailable"))?;
        if let Some(previous) = slot.as_ref() {
            return Ok(previous == &value);
        }
        *slot = Some(value);
        // Handshake only. Authentication separately requires explicit approval.
        Ok(true)
    }
}
struct Pending {
    handle: Transport,
    fingerprint: String,
}
pub enum Input {
    Data(Vec<u8>),
    Resize(u32, u32),
}
pub(crate) struct ForwardTask {
    pub info: crate::api::forward::LocalForward,
    pub error: Arc<std::sync::Mutex<Option<String>>>,
    pub task: tokio::task::JoinHandle<()>,
}
pub struct Live {
    pub handle: Transport,
    pub forwards: Mutex<HashMap<String, ForwardTask>>,
    pub input: mpsc::Sender<Input>,
    pub output: Mutex<Option<mpsc::Receiver<Vec<u8>>>>,
    pub ack: Semaphore,
    pub stop: watch::Sender<bool>,
    pub sftp: Mutex<Option<Arc<SftpSession>>>,
}
#[derive(Default)]
struct Registry {
    pending: HashMap<String, Pending>,
    live: HashMap<String, Arc<Live>>,
    authenticating: HashMap<String, watch::Sender<bool>>,
}
fn registry() -> &'static Mutex<Registry> {
    static REG: OnceLock<Mutex<Registry>> = OnceLock::new();
    REG.get_or_init(Default::default)
}

pub async fn probe(host: String, port: u16) -> Result<(String, String)> {
    if host.trim().is_empty() || port == 0 {
        bail!("Host and a valid port are required");
    }
    {
        let r = registry().lock().await;
        if r.pending.len() + r.live.len() + r.authenticating.len() >= 16 {
            bail!("At most 16 connections may be open");
        }
    }
    let fingerprint = Arc::new(std::sync::Mutex::new(None));
    let handler = HostKeyProbe {
        fingerprint: fingerprint.clone(),
    };
    let config = client::Config {
        keepalive_interval: Some(Duration::from_secs(20)),
        keepalive_max: 3,
        ..Default::default()
    };
    let handle = tokio::time::timeout(
        Duration::from_secs(20),
        client::connect(Arc::new(config), (host.as_str(), port), handler),
    )
    .await
    .context("SSH connection timed out")??;
    let key = fingerprint
        .lock()
        .map_err(|_| anyhow!("Host key unavailable"))?
        .clone()
        .context("Server did not provide a host key")?;
    let id = Uuid::new_v4().to_string();
    registry().lock().await.pending.insert(
        id.clone(),
        Pending {
            handle,
            fingerprint: key.clone(),
        },
    );
    let expiry_id = id.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(120)).await;
        let expired = registry().lock().await.pending.remove(&expiry_id);
        if let Some(p) = expired {
            let _ = p
                .handle
                .disconnect(Disconnect::ByApplication, "Approval expired", "en")
                .await;
        }
    });
    Ok((id, key))
}

pub async fn authenticate(
    id: &str,
    approved: &str,
    username: String,
    password: String,
    private_key: String,
    passphrase: String,
) -> Result<()> {
    let (cancel, mut cancelled) = watch::channel(false);
    let pending = {
        let mut r = registry().lock().await;
        let pending = r
            .pending
            .remove(id)
            .context("Connection expired; connect again")?;
        r.authenticating.insert(id.to_string(), cancel);
        pending
    };
    let mut handle = pending.handle;
    let password = Zeroizing::new(password);
    let private_key = Zeroizing::new(private_key);
    let passphrase = Zeroizing::new(passphrase);
    let initialize = async {
        if pending.fingerprint != approved {
            bail!("HOST_KEY_MISMATCH: authentication blocked");
        }
        if username.trim().is_empty() {
            bail!("Username is required");
        }
        let auth = if private_key.is_empty() {
            handle
                .authenticate_password(&username, password.as_str())
                .await?
        } else {
            let key = russh::keys::decode_secret_key(
                private_key.as_str(),
                if passphrase.is_empty() {
                    None
                } else {
                    Some(passphrase.as_str())
                },
            )
            .context("Cannot decrypt or parse private key")?;
            let hash = handle.best_supported_rsa_hash().await?.flatten();
            handle
                .authenticate_publickey(&username, PrivateKeyWithHashAlg::new(Arc::new(key), hash))
                .await?
        };
        if !auth.success() {
            bail!("Authentication rejected. Check username and credentials.");
        }
        let mut channel = handle.channel_open_session().await?;
        channel
            .request_pty(true, "xterm-256color", 100, 30, 0, 0, &[])
            .await?;
        await_success(&mut channel).await?;
        channel.request_shell(true).await?;
        await_success(&mut channel).await?;
        Ok::<_, anyhow::Error>(channel)
    };
    let result = tokio::select! {
        biased;
        _ = cancelled.changed() => Err(anyhow!("Connection cancelled")),
        result = tokio::time::timeout(Duration::from_secs(30), initialize) =>
            result.context("Authentication timed out").and_then(|result| result),
    };
    let channel = match result {
        Ok(channel) => channel,
        Err(error) => {
            registry().lock().await.authenticating.remove(id);
            let _ = handle
                .disconnect(Disconnect::ByApplication, "Authentication ended", "en")
                .await;
            return Err(error);
        }
    };
    let (input, input_rx) = mpsc::channel(64);
    let (output, output_rx) = mpsc::channel(32);
    let (stop, stop_rx) = watch::channel(false);
    let live = Arc::new(Live {
        handle,
        input,
        output: Mutex::new(Some(output_rx)),
        ack: Semaphore::new(0),
        stop,
        sftp: Mutex::new(None),
        forwards: Mutex::new(HashMap::new()),
    });
    {
        let mut r = registry().lock().await;
        r.authenticating.remove(id);
        if *cancelled.borrow() {
            bail!("Connection cancelled");
        }
        r.live.insert(id.to_string(), live.clone());
    }
    let actor_id = id.to_string();
    tokio::spawn(async move {
        let _ = terminal_actor(channel, input_rx, output, stop_rx).await;
        live.stop.send_replace(true);
        // Keep the registry entry while Dart drains and ACKs the final output.
        let _ = live
            .handle
            .disconnect(Disconnect::ByApplication, "Session ended", "en")
            .await;
        tokio::time::sleep(Duration::from_secs(65)).await;
        let _ = disconnect(&actor_id).await;
    });
    Ok(())
}
async fn await_success(channel: &mut Channel<client::Msg>) -> Result<()> {
    tokio::time::timeout(Duration::from_secs(15), async {
        loop {
            match channel.wait().await {
                Some(ChannelMsg::Success) => return Ok(()),
                Some(ChannelMsg::Failure) | Some(ChannelMsg::Close) | None => {
                    bail!("Server rejected terminal request")
                }
                _ => {}
            }
        }
    })
    .await
    .context("Terminal request timed out")?
}
async fn terminal_actor(
    mut channel: Channel<client::Msg>,
    mut input: mpsc::Receiver<Input>,
    output: mpsc::Sender<Vec<u8>>,
    mut stop: watch::Receiver<bool>,
) -> Result<()> {
    loop {
        tokio::select! {
            biased;
            _ = stop.changed() => break,
            cmd = input.recv() => match cmd {
                Some(Input::Data(data)) => channel.data(&data[..]).await?,
                Some(Input::Resize(cols, rows)) => channel.window_change(cols.clamp(1, 1000), rows.clamp(1, 1000), 0, 0).await?,
                None => break,
            },
            msg = channel.wait() => match msg {
                Some(ChannelMsg::Data { data }) | Some(ChannelMsg::ExtendedData { data, .. }) => {
                    // Bounded output; cancellation remains responsive while consumer is paused.
                    tokio::select! { _ = stop.changed() => break, r = output.send(data.to_vec()) => { if r.is_err() { break; } } }
                }
                Some(ChannelMsg::Close) | Some(ChannelMsg::Eof) | None => break,
                _ => {}
            }
        }
    }
    let _ = channel.close().await;
    Ok(())
}
pub async fn live(id: &str) -> Result<Arc<Live>> {
    registry()
        .lock()
        .await
        .live
        .get(id)
        .cloned()
        .context("Session is disconnected")
}
pub async fn sftp(id: &str) -> Result<Arc<SftpSession>> {
    let live = live(id).await?;
    let mut slot = live.sftp.lock().await;
    if let Some(s) = &*slot {
        return Ok(s.clone());
    }
    let channel = live.handle.channel_open_session().await?;
    channel.request_subsystem(true, "sftp").await?;
    let s = Arc::new(
        tokio::time::timeout(
            Duration::from_secs(15),
            SftpSession::new(channel.into_stream()),
        )
        .await
        .context("SFTP startup timed out")??,
    );
    s.set_timeout(20);
    *slot = Some(s.clone());
    Ok(s)
}
pub async fn disconnect(id: &str) -> Result<()> {
    let (pending, live, authenticating) = {
        let mut r = registry().lock().await;
        (
            r.pending.remove(id),
            r.live.remove(id),
            r.authenticating.remove(id),
        )
    };
    if let Some(cancel) = authenticating {
        cancel.send_replace(true);
    }
    if let Some(p) = pending {
        let _ = p
            .handle
            .disconnect(Disconnect::ByApplication, "Cancelled", "en")
            .await;
    }
    if let Some(s) = live {
        s.stop.send_replace(true);
        s.ack.close();
        let forwards: Vec<_> = s.forwards.lock().await.drain().map(|(_, f)| f).collect();
        for forward in forwards {
            forward.task.abort();
            let _ = forward.task.await;
        }
        let _ = s
            .handle
            .disconnect(Disconnect::ByApplication, "Disconnected", "en")
            .await;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::client;

    fn port() -> u16 {
        std::env::var("WTERM_TEST_PORT")
            .unwrap_or_else(|_| "22222".into())
            .parse()
            .unwrap()
    }
    async fn password_session() -> String {
        let identity = client::probe_server("127.0.0.1".into(), port())
            .await
            .unwrap();
        client::authenticate(
            identity.connection_id.clone(),
            identity.fingerprint,
            "wterm".into(),
            "wterm-test-only".into(),
            "".into(),
            "".into(),
        )
        .await
        .unwrap();
        identity.connection_id
    }
    #[tokio::test]
    async fn invalid_inputs_and_unknown_sessions_fail() {
        assert!(probe("".into(), 22).await.is_err());
        assert!(probe("localhost".into(), 0).await.is_err());
        assert!(live("does-not-exist").await.is_err());
        assert!(client::list_directory("does-not-exist".into(), ".".into())
            .await
            .is_err());
        assert!(disconnect("does-not-exist").await.is_ok());
    }
    #[tokio::test]
    #[ignore = "Run scripts/test-core.sh to start the loopback fixture"]
    async fn fixture_wrong_fingerprint_cannot_authenticate() {
        let (id, _) = probe("127.0.0.1".into(), port()).await.unwrap();
        let error = authenticate(
            &id,
            "SHA256:wrong",
            "wterm".into(),
            "wterm-test-only".into(),
            "".into(),
            "".into(),
        )
        .await
        .unwrap_err();
        assert!(error.to_string().contains("HOST_KEY_MISMATCH"));
        assert!(live(&id).await.is_err());
    }
    #[tokio::test]
    #[ignore = "Run scripts/test-core.sh to start the loopback fixture"]
    async fn fixture_wrong_password_and_cancel() {
        let (id, fingerprint) = probe("127.0.0.1".into(), port()).await.unwrap();
        assert!(authenticate(
            &id,
            &fingerprint,
            "wterm".into(),
            "wrong".into(),
            "".into(),
            "".into()
        )
        .await
        .is_err());
        assert!(live(&id).await.is_err());
        let (id, fingerprint) = probe("127.0.0.1".into(), port()).await.unwrap();
        disconnect(&id).await.unwrap();
        assert!(authenticate(
            &id,
            &fingerprint,
            "wterm".into(),
            "wterm-test-only".into(),
            "".into(),
            "".into()
        )
        .await
        .is_err());
    }
    #[tokio::test]
    #[ignore = "Run scripts/test-core.sh to start the loopback fixture"]
    async fn fixture_encrypted_private_key_and_terminal() {
        let root = std::env::var("WTERM_FIXTURE_ROOT").unwrap();
        let key = tokio::fs::read_to_string(format!("{root}/client_key"))
            .await
            .unwrap();
        let (id, fingerprint) = probe("127.0.0.1".into(), port()).await.unwrap();
        authenticate(
            &id,
            &fingerprint,
            "wterm".into(),
            "".into(),
            key,
            "fixture-passphrase".into(),
        )
        .await
        .unwrap();
        let state = live(&id).await.unwrap();
        let mut output = state.output.lock().await.take().unwrap();
        client::write_terminal(id.clone(), "你好 SSH\n".as_bytes().to_vec())
            .await
            .unwrap();
        let mut received = Vec::new();
        tokio::time::timeout(Duration::from_secs(10), async {
            while let Some(bytes) = output.recv().await {
                received.extend(bytes);
                if String::from_utf8_lossy(&received).contains("ECHO:你好 SSH") {
                    break;
                }
            }
        })
        .await
        .unwrap();
        assert!(String::from_utf8_lossy(&received).contains("WTERM_FIXTURE_READY"));
        client::resize_terminal(id.clone(), 120, 40).await.unwrap();
        disconnect(&id).await.unwrap();
        assert!(live(&id).await.is_err());
    }
    #[tokio::test]
    #[ignore = "Run scripts/test-core.sh to start the loopback fixture"]
    async fn fixture_sftp_rename_delete_preserves_conflicts_and_link_targets() {
        let id = password_session().await;
        let dir = tempfile::tempdir().unwrap();
        let local = dir.path().join("source");
        tokio::fs::write(&local, b"preserved content")
            .await
            .unwrap();
        let root = format!("/actions-{}", Uuid::new_v4());
        client::create_directory(id.clone(), root.clone())
            .await
            .unwrap();
        let a = format!("{root}/original");
        let b = format!("{root}/existing");
        for path in [&a, &b] {
            client::upload_file(id.clone(), local.to_string_lossy().into(), path.clone())
                .await
                .unwrap();
        }
        assert!(
            client::rename_remote_entry(id.clone(), a.clone(), "existing".into())
                .await
                .is_err()
        );
        assert_eq!(
            client::preview_text(id.clone(), b.clone()).await.unwrap(),
            "preserved content"
        );
        let mode = client::remote_permissions(id.clone(), a.clone())
            .await
            .unwrap();
        client::change_remote_permissions(id.clone(), a.clone(), mode, 0o640)
            .await
            .unwrap();
        assert_eq!(
            client::remote_permissions(id.clone(), a.clone())
                .await
                .unwrap()
                & 0o777,
            0o640
        );
        assert!(
            client::change_remote_permissions(id.clone(), a.clone(), 0o777, 0o600)
                .await
                .is_err()
        );
        assert!(
            client::change_remote_permissions(id.clone(), a.clone(), 0o640, 0o1777)
                .await
                .is_err()
        );
        assert_eq!(
            client::remote_permissions(id.clone(), a.clone())
                .await
                .unwrap()
                & 0o777,
            0o640
        );
        assert!(client::delete_remote_entry(id.clone(), root.clone())
            .await
            .is_err());
        for invalid in ["/", "/..", "/x/../", "."] {
            assert!(client::delete_remote_entry(id.clone(), invalid.into())
                .await
                .is_err());
        }
        assert!(
            client::rename_remote_entry(id.clone(), a.clone(), "../bad".into())
                .await
                .is_err()
        );
        client::rename_remote_entry(id.clone(), a, "中文新名".into())
            .await
            .unwrap();
        let renamed = format!("{root}/中文新名");
        assert_eq!(
            client::preview_text(id.clone(), renamed.clone())
                .await
                .unwrap(),
            "preserved content"
        );
        // Place synthetic links inside the fixture root, not in user directories.
        let fixture = std::path::PathBuf::from(std::env::var("WTERM_FIXTURE_ROOT").unwrap());
        let link = format!("{root}/link");
        std::os::unix::fs::symlink("中文新名", fixture.join(link.trim_start_matches('/'))).unwrap();
        assert!(client::remote_permissions(id.clone(), link.clone())
            .await
            .is_err());
        assert!(
            client::change_remote_permissions(id.clone(), link.clone(), 0o640, 0o777)
                .await
                .is_err()
        );
        client::delete_remote_entry(id.clone(), link).await.unwrap();
        assert_eq!(
            client::preview_text(id.clone(), renamed.clone())
                .await
                .unwrap(),
            "preserved content"
        );
        client::delete_remote_entry(id.clone(), renamed)
            .await
            .unwrap();
        client::delete_remote_entry(id.clone(), b).await.unwrap();
        client::rename_remote_entry(id.clone(), root.clone(), "renamed-empty-folder".into())
            .await
            .unwrap();
        client::delete_remote_entry(id.clone(), "/renamed-empty-folder".into())
            .await
            .unwrap();
        disconnect(&id).await.unwrap();
    }
    #[tokio::test]
    #[ignore = "Run scripts/test-core.sh to start the loopback fixture"]
    async fn fixture_remote_text_edit_and_conflicts() {
        let id = password_session().await;
        let dir = tempfile::tempdir().unwrap();
        let local = dir.path().join("text");
        let path = format!("/editor-{}.txt", Uuid::new_v4());
        tokio::fs::write(&local, "原内容\r\n").await.unwrap();
        client::upload_file(id.clone(), local.to_string_lossy().into(), path.clone())
            .await
            .unwrap();
        let snapshot = client::read_remote_text(id.clone(), path.clone())
            .await
            .unwrap();
        client::save_remote_text(
            id.clone(),
            path.clone(),
            snapshot.clone(),
            "编辑后\r\n".into(),
        )
        .await
        .unwrap();
        let updated = client::read_remote_text(id.clone(), path.clone())
            .await
            .unwrap();
        assert_eq!(updated.text, "编辑后\r\n");
        assert_eq!(updated.permissions, snapshot.permissions);
        assert_eq!((updated.uid, updated.gid), (snapshot.uid, snapshot.gid));
        assert!(
            client::save_remote_text(id.clone(), path.clone(), snapshot, "stale".into())
                .await
                .is_err()
        );
        assert!(client::save_remote_text(
            id.clone(),
            path.clone(),
            updated.clone(),
            "x".repeat(256 * 1024 + 1)
        )
        .await
        .is_err());
        assert_eq!(
            client::preview_text(id.clone(), path).await.unwrap(),
            "编辑后\r\n"
        );
        let denied = "/denied-rename.bin".to_string();
        // Other fixture tests may have created this file; use its current snapshot.
        if client::read_remote_text(id.clone(), denied.clone())
            .await
            .is_err()
        {
            client::upload_file(id.clone(), local.to_string_lossy().into(), denied.clone())
                .await
                .unwrap();
        }
        let original = client::read_remote_text(id.clone(), denied.clone())
            .await
            .unwrap();
        assert!(client::save_remote_text(
            id.clone(),
            denied.clone(),
            original.clone(),
            "reject save".into()
        )
        .await
        .is_err());
        assert_eq!(
            client::preview_text(id.clone(), denied.clone())
                .await
                .unwrap(),
            original.text
        );
        client::delete_remote_entry(id.clone(), denied)
            .await
            .unwrap();
        let listing = client::list_directory(id.clone(), "/".into())
            .await
            .unwrap();
        assert!(!listing.entries.iter().any(|e| e.name.ends_with(".part")));
        disconnect(&id).await.unwrap();
    }
    #[tokio::test]
    #[ignore = "Run scripts/test-core.sh to start the loopback fixture"]
    async fn fixture_sftp_roundtrip_and_no_overwrite() {
        let id = password_session().await;
        let listing = client::list_directory(id.clone(), ".".into())
            .await
            .unwrap();
        assert!(listing
            .entries
            .iter()
            .any(|e| e.name == "fixture.txt" && e.modified_at.is_some()));
        assert!(client::preview_text(id.clone(), "/fixture.txt".into())
            .await
            .unwrap()
            .contains("你好"));
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("source.bin");
        let target = dir.path().join("target.bin");
        let data: Vec<u8> = (0..1_048_577).map(|i| (i % 251) as u8).collect();
        tokio::fs::write(&source, &data).await.unwrap();
        let remote = format!("/roundtrip-{}.bin", Uuid::new_v4());
        assert_eq!(
            client::upload_file(id.clone(), source.to_str().unwrap().into(), remote.clone())
                .await
                .unwrap(),
            data.len() as u64
        );
        assert!(
            client::upload_file(id.clone(), source.to_str().unwrap().into(), remote.clone())
                .await
                .is_err()
        );
        assert_eq!(
            client::download_file(id.clone(), remote.clone(), target.to_str().unwrap().into())
                .await
                .unwrap(),
            data.len() as u64
        );
        assert_eq!(tokio::fs::read(&target).await.unwrap(), data);
        assert!(
            client::download_file(id.clone(), remote.clone(), target.to_str().unwrap().into())
                .await
                .is_err()
        );
        tokio::fs::write(&source, b"replacement content")
            .await
            .unwrap();
        let kept = client::upload_file_with_policy(
            id.clone(),
            source.to_str().unwrap().into(),
            remote.clone(),
            "keepBoth".into(),
        )
        .await
        .unwrap();
        assert_ne!(kept.remote_path, remote);
        assert!(kept.remote_path.ends_with(" (1).bin"));
        let original_copy = dir.path().join("original.bin");
        client::download_file(
            id.clone(),
            remote.clone(),
            original_copy.to_str().unwrap().into(),
        )
        .await
        .unwrap();
        assert_eq!(tokio::fs::read(&original_copy).await.unwrap(), data);
        let kept_again = client::upload_file_with_policy(
            id.clone(),
            source.to_str().unwrap().into(),
            remote.clone(),
            "keepBoth".into(),
        )
        .await
        .unwrap();
        assert!(kept_again.remote_path.ends_with(" (2).bin"));
        client::upload_file_with_policy(
            id.clone(),
            source.to_str().unwrap().into(),
            remote.clone(),
            "replace".into(),
        )
        .await
        .unwrap();
        assert_eq!(
            client::preview_text(id.clone(), remote.clone())
                .await
                .unwrap(),
            "replacement content"
        );
        let folder = format!("/upload-dir-{}", Uuid::new_v4());
        client::create_directory(id.clone(), folder.clone())
            .await
            .unwrap();
        assert!(client::upload_file_with_policy(
            id.clone(),
            source.to_str().unwrap().into(),
            folder,
            "replace".into()
        )
        .await
        .is_err());
        assert!(client::upload_file_with_policy(
            id.clone(),
            "missing-source-file".into(),
            remote.clone(),
            "replace".into()
        )
        .await
        .is_err());
        assert_eq!(
            client::preview_text(id.clone(), remote).await.unwrap(),
            "replacement content"
        );
        let denied = "/denied-rename.bin".to_string();
        tokio::fs::write(&source, b"keep this original")
            .await
            .unwrap();
        client::upload_file(id.clone(), source.to_str().unwrap().into(), denied.clone())
            .await
            .unwrap();
        tokio::fs::write(&source, b"must not replace original")
            .await
            .unwrap();
        assert!(client::upload_file_with_policy(
            id.clone(),
            source.to_str().unwrap().into(),
            denied.clone(),
            "replace".into()
        )
        .await
        .is_err());
        assert_eq!(
            client::preview_text(id.clone(), denied).await.unwrap(),
            "keep this original"
        );
        let listing = client::list_directory(id.clone(), "/".into())
            .await
            .unwrap();
        assert!(!listing.entries.iter().any(|e| e.name.ends_with(".part")));
        disconnect(&id).await.unwrap();
        assert!(client::list_directory(id, "/".into()).await.is_err());
    }
}
