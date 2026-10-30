use super::*;
use crate::api::proxy::ProxyProfileInput;
use tokio::net::TcpListener;

fn profile_input(
    id: &str,
    name: &str,
    mode: &str,
    host: &str,
    port: u16,
    authenticate: bool,
) -> ProxyProfileInput {
    ProxyProfileInput {
        id: id.into(),
        name: name.into(),
        mode: mode.into(),
        host: host.into(),
        port,
        authenticate,
        username: if authenticate { "proxy-user" } else { "" }.into(),
    }
}
fn seed_hosts(db: &Connection) -> Result<()> {
    crate::api::vault::put_record(
        db,
        "hosts",
        r#"[{"id":"h1","name":"One","host":"one.example","username":"u","port":22,"group":"","tags":[],"favorite":false},
            {"id":"h2","name":"Two","host":"two.example","username":"u","port":22,"group":"","tags":[],"favorite":false}]"#,
    )
}
#[test]
fn named_profiles_reuse_credentials_and_validate_names() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("profiles.db");
    let mut db = crate::api::vault::open_database(&path, "named profile vault", true)?;
    assert!(profiles(&db)?.is_empty());
    let id = save_profile(
        &mut db,
        profile_input("", "Corp", "http", "proxy.example", 3128, true),
        Zeroizing::new("profile-secret".into()),
    )?;
    let items = profiles(&db)?;
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].name, "Corp");
    assert!(items[0].password_saved);
    save_profile(
        &mut db,
        profile_input(&id, "Corp renamed", "http", "proxy.example", 3128, true),
        Zeroizing::new(String::new()),
    )?;
    assert_eq!(profiles(&db)?[0].name, "Corp renamed");
    assert!(save_profile(
        &mut db,
        profile_input(&id, "Corp", "http", "other.example", 3128, true),
        Zeroizing::new(String::new()),
    )
    .is_err());
    assert!(save_profile(
        &mut db,
        profile_input("", "CORP RENAMED", "socks5", "proxy.example", 1080, false),
        Zeroizing::new(String::new()),
    )
    .is_err());
    assert!(save_profile(
        &mut db,
        profile_input("", "Direct", "direct", "", 1080, false),
        Zeroizing::new(String::new()),
    )
    .is_err());
    drop(db);
    assert!(!std::fs::read(&path)?
        .windows(14)
        .any(|w| w == b"profile-secret"));
    let db = crate::api::vault::open_database(&path, "named profile vault", false)?;
    assert!(profiles(&db)?[0].password_saved);
    Ok(())
}
#[test]
fn host_bindings_inherit_direct_named_and_block_delete() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("bindings.db");
    let mut db = crate::api::vault::open_database(&path, "binding fixture vault", true)?;
    seed_hosts(&db)?;
    let id = save_profile(
        &mut db,
        profile_input("", "Bound", "socks5", "127.0.0.1", 1080, true),
        Zeroizing::new("binding-secret".into()),
    )?;
    assert_eq!(host_binding(&db, "h1")?, "");
    set_host_binding(&mut db, "h1", &id)?;
    assert_eq!(host_binding(&db, "h1")?, id);
    assert_eq!(
        config_for_host(&db, Some("h1"))?.unwrap().password,
        "binding-secret"
    );
    set_host_binding(&mut db, "h1", "direct")?;
    assert_eq!(host_binding(&db, "h1")?, "direct");
    assert!(config_for_host(&db, Some("h1"))?.is_none());
    // An explicit direct binding must not inherit the global default.
    let mut inherited = config("http", 3128, false);
    inherited.password.clear();
    save(&mut db, inherited.view(), Zeroizing::new(String::new()))?;
    assert!(config_for_host(&db, Some("h1"))?.is_none());
    assert!(config_for_host(&db, Some("h2"))?.is_some());
    set_host_binding(&mut db, "h1", "")?;
    assert_eq!(host_binding(&db, "h1")?, "");
    set_host_binding(&mut db, "h1", &id)?;
    assert!(delete_profile(&mut db, &id).is_err());
    set_host_binding(&mut db, "h1", "")?;
    delete_profile(&mut db, &id)?;
    assert!(profiles(&db)?.is_empty());
    assert!(set_host_binding(&mut db, "missing-host", "").is_err());
    assert!(set_host_binding(&mut db, "h2", "does-not-exist").is_err());
    db.execute(
        "INSERT OR REPLACE INTO metadata(key,value) VALUES (?1,?2)",
        [BINDINGS_KEY, r#"{"h2":"deleted-proxy"}"#],
    )?;
    assert!(config_for_host(&db, Some("h2")).is_err());
    Ok(())
}
async fn mock_http(response: &'static [u8]) -> Result<(u16, tokio::task::JoinHandle<()>)> {
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let port = listener.local_addr()?.port();
    let task = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        header(&mut stream).await;
        let _ = stream.write_all(response).await;
    });
    Ok((port, task))
}
#[tokio::test]
async fn layered_test_reports_tcp_auth_and_target_stages() -> Result<()> {
    for (response, authenticated, target_ok) in [
        (&b"HTTP/1.1 200 Connected\r\n\r\n"[..], true, true),
        (&b"HTTP/1.1 407 Secret\r\n\r\n"[..], false, false),
        (&b"HTTP/1.1 502 Bad\r\n\r\n"[..], true, false),
        (&b"HTTP/1.1"[..], false, false),
    ] {
        let (port, task) = mock_http(response).await?;
        let c = config("http", port, true);
        let result = test(&c, Some(("target.invalid", 22u16))).await;
        assert!(result.tcp_ok);
        assert_eq!(result.authenticated, Some(authenticated));
        assert_eq!(result.target_ok, Some(target_ok));
        assert!(!result.message.contains("Secret"));
        task.await?;
    }
    let (port, task) = mock_http(b"HTTP/1.1 200 Connected\r\n\r\n").await?;
    let c = config("http", port, false);
    let result = test(&c, None).await;
    assert!(result.tcp_ok);
    assert_eq!(result.authenticated, Some(true));
    assert_eq!(result.target_ok, None);
    task.abort();
    let _ = task.await;
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let unused = listener.local_addr()?.port();
    drop(listener);
    let result = test(
        &config("http", unused, false),
        Some(("target.invalid", 22u16)),
    )
    .await;
    assert!(!result.tcp_ok);
    assert!(result.authenticated.is_none());
    Ok(())
}
#[tokio::test]
async fn socks5_layered_test_distinguishes_auth_from_target() -> Result<()> {
    for (auth_ok, authenticated) in [(false, false), (true, true)] {
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let port = listener.local_addr()?.port();
        let task = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut greeting = [0; 3];
            stream.read_exact(&mut greeting).await.unwrap();
            assert_eq!(greeting, [5, 1, 2]);
            stream.write_all(&[5, 2]).await.unwrap();
            let mut credentials = [0; 25];
            stream.read_exact(&mut credentials).await.unwrap();
            if !auth_ok {
                stream.write_all(&[1, 1]).await.unwrap();
                return;
            }
            stream.write_all(&[1, 0]).await.unwrap();
            let mut target = [0; 21];
            stream.read_exact(&mut target).await.unwrap();
            stream
                .write_all(&[5, 5, 0, 1, 0, 0, 0, 0, 0, 0])
                .await
                .unwrap();
        });
        let c = config("socks5", port, true);
        let result = test(&c, Some(("target.invalid", 22u16))).await;
        assert!(result.tcp_ok);
        assert_eq!(result.authenticated, Some(authenticated));
        assert_eq!(
            result.target_ok,
            Some(false),
            "SOCKS rejection is never target success"
        );
        task.await?;
    }
    Ok(())
}

fn config(mode: &str, port: u16, authenticate: bool) -> Config {
    Config {
        mode: mode.into(),
        host: "127.0.0.1".into(),
        port,
        authenticate,
        username: if authenticate { "proxy-user" } else { "" }.into(),
        password: if authenticate { "proxy-secret" } else { "" }.into(),
    }
}
async fn header(stream: &mut TcpStream) -> Vec<u8> {
    let mut bytes = Vec::new();
    while !bytes.ends_with(b"\r\n\r\n") {
        bytes.push(stream.read_u8().await.unwrap());
        assert!(bytes.len() < 4096);
    }
    bytes
}

#[test]
fn encrypted_settings_reuse_clear_and_reject_credential_redirect() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("proxy.db");
    let mut db = crate::api::vault::open_database(&path, "proxy fixture vault", true)?;
    assert_eq!(settings(&db)?.mode, "direct");
    let c = config("socks5", 1080, true);
    save(&mut db, c.view(), Zeroizing::new(c.password.clone()))?;
    assert!(settings(&db)?.password_saved);
    save(&mut db, c.view(), Zeroizing::new(String::new()))?;
    assert_eq!(load(&db)?.unwrap().password, "proxy-secret");
    for change in 0..4 {
        let mut v = c.view();
        match change {
            0 => v.host = "other.invalid".into(),
            1 => v.port += 1,
            2 => v.mode = "http".into(),
            _ => v.username = "other".into(),
        }
        assert!(save(&mut db, v, Zeroizing::new(String::new())).is_err());
        assert_eq!(load(&db)?.unwrap().password, "proxy-secret");
    }
    drop(db);
    assert!(!std::fs::read(&path)?
        .windows(12)
        .any(|w| w == b"proxy-secret"));
    let mut db = crate::api::vault::open_database(&path, "proxy fixture vault", false)?;
    assert!(settings(&db)?.password_saved);
    let mut v = c.view();
    v.authenticate = false;
    save(&mut db, v, Zeroizing::new("discard-this".into()))?;
    assert!(!settings(&db)?.password_saved);
    assert!(load(&db)?.unwrap().username.is_empty());
    let mut v = c.view();
    v.mode = "direct".into();
    save(&mut db, v, Zeroizing::new(String::new()))?;
    assert!(load(&db)?.is_none());
    Ok(())
}

#[test]
fn validation_blocks_header_injection_and_invalid_credentials() {
    for host in [
        "proxy\r\nInjected: yes",
        "http://proxy",
        "proxy:1080",
        "[::1]",
        "",
        "a b",
        "é.example",
    ] {
        assert!(valid_host(host).is_err());
    }
    for host in ["proxy.example", "127.0.0.1", "::1", "2001:db8::2"] {
        assert!(valid_host(host).is_ok());
    }
    let mut c = config("http", 3128, true);
    c.username = "user:other".into();
    assert!(c.validate().is_err());
    c.mode = "socks5".into();
    assert!(c.validate().is_ok());
    c.password = "a".repeat(256);
    assert!(c.validate().is_err());
}

#[tokio::test]
async fn http_remote_dns_basic_ipv6_and_coalesced_banner() -> Result<()> {
    for target in ["only-at-proxy.invalid", "2001:db8::1"] {
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let c = config("http", listener.local_addr()?.port(), true);
        let target_owned = target.to_string();
        let task = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let request = String::from_utf8(header(&mut stream).await).unwrap();
            let authority = if target_owned.contains(':') {
                format!("[{target_owned}]:22")
            } else {
                format!("{target_owned}:22")
            };
            assert!(request.starts_with(&format!(
                "CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\n"
            )));
            assert!(request.contains(&format!(
                "Proxy-Authorization: Basic {}\r\n",
                Base64::encode_string(b"proxy-user:proxy-secret")
            )));
            stream.write_all(b"HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 Connected\r\n\r\nSSH-2.0-fixture\r\n").await.unwrap();
        });
        let mut stream = connect(target, 22, Some(&c)).await?;
        let mut banner = String::new();
        stream.read_to_string(&mut banner).await?;
        assert_eq!(banner, "SSH-2.0-fixture\r\n");
        task.await?;
    }
    Ok(())
}

#[tokio::test]
async fn http_rejections_never_fallback_or_reflect_proxy_text() -> Result<()> {
    for response in [
        b"HTTP/1.1 407 secret\r\n\r\n".to_vec(),
        b"HTTP/1.1 502 secret\r\n\r\n".to_vec(),
        b"HTTP/1.1 2000 secret\r\n\r\n".to_vec(),
        b"HTTP/1.1 101 secret\r\n\r\n".to_vec(),
        vec![b'a'; 16385],
        b"HTTP/1.1".to_vec(),
    ] {
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let c = config("http", listener.local_addr()?.port(), false);
        let task = tokio::spawn(async move {
            let (mut s, _) = listener.accept().await.unwrap();
            header(&mut s).await;
            let _ = s.write_all(&response).await;
        });
        let error = connect("unresolved.invalid", 22, Some(&c))
            .await
            .unwrap_err()
            .to_string();
        assert!(!error.contains("secret"));
        assert!(!error.contains("lookup"));
        task.await?;
    }
    Ok(())
}

#[tokio::test]
async fn socks5_address_forms_auth_and_reply_consumption() -> Result<()> {
    for (target, address) in [
        (
            "remote.invalid",
            [vec![3, 14], b"remote.invalid".to_vec()].concat(),
        ),
        ("127.0.0.1", vec![1, 127, 0, 0, 1]),
        (
            "::1",
            [vec![4], std::net::Ipv6Addr::LOCALHOST.octets().to_vec()].concat(),
        ),
    ] {
        for auth in [false, true] {
            let listener = TcpListener::bind("127.0.0.1:0").await?;
            let c = config("socks5", listener.local_addr()?.port(), auth);
            let address = address.clone();
            let task = tokio::spawn(async move {
                let (mut s, _) = listener.accept().await.unwrap();
                let mut greeting = [0; 3];
                s.read_exact(&mut greeting).await.unwrap();
                assert_eq!(greeting, [5, 1, if auth { 2 } else { 0 }]);
                s.write_all(&[5, greeting[2]]).await.unwrap();
                if auth {
                    let mut request = vec![0; 2 + 10 + 1 + 12];
                    s.read_exact(&mut request).await.unwrap();
                    assert_eq!(
                        request,
                        [
                            vec![1, 10],
                            b"proxy-user".to_vec(),
                            vec![12],
                            b"proxy-secret".to_vec()
                        ]
                        .concat()
                    );
                    s.write_all(&[1, 0]).await.unwrap();
                }
                let mut request = vec![0; 3 + address.len() + 2];
                s.read_exact(&mut request).await.unwrap();
                assert_eq!(
                    request,
                    [vec![5, 1, 0], address.clone(), vec![0, 22]].concat()
                );
                s.write_all(&[vec![5, 0, 0], address, vec![0, 22], b"banner".to_vec()].concat())
                    .await
                    .unwrap();
            });
            let mut s = connect(target, 22, Some(&c)).await?;
            let mut banner = String::new();
            s.read_to_string(&mut banner).await?;
            assert_eq!(banner, "banner");
            task.await?;
        }
    }
    Ok(())
}

#[tokio::test]
async fn socks5_rejects_downgrade_auth_failure_and_invalid_reply() -> Result<()> {
    // Failed method/auth replies must not receive an SSH target request.
    for reply in [vec![5, 0], vec![5, 255], vec![4, 2], vec![5, 2, 1, 1]] {
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let c = config("socks5", listener.local_addr()?.port(), true);
        let task = tokio::spawn(async move {
            let (mut s, _) = listener.accept().await.unwrap();
            let mut greeting = [0; 3];
            s.read_exact(&mut greeting).await.unwrap();
            s.write_all(&reply[..2]).await.unwrap();
            if reply.len() > 2 {
                let mut credentials = [0; 25];
                s.read_exact(&mut credentials).await.unwrap();
                s.write_all(&reply[2..]).await.unwrap();
            }
            let mut remainder = Vec::new();
            s.read_to_end(&mut remainder).await.unwrap();
            assert!(remainder.is_empty());
        });
        assert!(connect("unresolved.invalid", 22, Some(&c)).await.is_err());
        task.await?;
    }
    for reply in [
        vec![5, 5, 0, 1],
        vec![5, 0, 1, 1],
        vec![4, 0, 0, 1],
        vec![5, 0, 0, 7],
        vec![5, 0, 0, 3, 0],
    ] {
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let c = config("socks5", listener.local_addr()?.port(), false);
        let task = tokio::spawn(async move {
            let (mut s, _) = listener.accept().await.unwrap();
            let mut greeting = [0; 3];
            s.read_exact(&mut greeting).await.unwrap();
            s.write_all(&[5, 0]).await.unwrap();
            let mut target = [0; 10];
            s.read_exact(&mut target).await.unwrap();
            s.write_all(&reply).await.unwrap();
        });
        assert!(connect("127.0.0.1", 22, Some(&c)).await.is_err());
        task.await?;
    }
    Ok(())
}

#[tokio::test]
async fn cancelled_proxy_handshake_drops_socket() -> Result<()> {
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let c = config("http", listener.local_addr()?.port(), false);
    let task = tokio::spawn(async move {
        let (mut s, _) = listener.accept().await.unwrap();
        header(&mut s).await;
        // Never answer CONNECT. Cancelling its future must close this transport.
        let mut remainder = Vec::new();
        s.read_to_end(&mut remainder).await.unwrap();
        assert!(remainder.is_empty());
    });
    assert!(tokio::time::timeout(
        std::time::Duration::from_millis(100),
        connect("remote.invalid", 22, Some(&c))
    )
    .await
    .is_err());
    tokio::time::timeout(std::time::Duration::from_secs(2), task).await??;
    Ok(())
}
