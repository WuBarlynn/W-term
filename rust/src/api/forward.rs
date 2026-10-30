//! Session-scoped local (-L), remote (-R) and dynamic SOCKS5 (-D) forwarding.
use crate::session;
use anyhow::{bail, ensure, Context, Result};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    net::{Ipv4Addr, Ipv6Addr},
    sync::{Arc, Mutex},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::Semaphore,
    task::JoinSet,
};
use uuid::Uuid;

const MAX_FORWARDS: usize = 8;
const MAX_CLIENTS: usize = 32;
const CONNECT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(15);

#[derive(Clone, Debug)]
pub struct ForwardInfo {
    pub id: String,
    /// local, remote, or dynamic
    pub kind: String,
    pub listen_host: String,
    pub listen_port: u16,
    pub target_host: String,
    pub target_port: u16,
    pub last_error: Option<String>,
    /// True when the listening socket is on the SSH server.
    pub listen_remote: bool,
}

#[derive(Clone, Debug)]
pub struct LocalForward {
    pub id: String,
    pub local_port: u16,
    pub target_host: String,
    pub target_port: u16,
    pub last_error: Option<String>,
}
impl LocalForward {
    fn from_info(info: &ForwardInfo) -> Self {
        Self {
            id: info.id.clone(),
            local_port: info.listen_port,
            target_host: info.target_host.clone(),
            target_port: info.target_port,
            last_error: info.last_error.clone(),
        }
    }
}

fn valid_host(host: &str) -> bool {
    !host.is_empty()
        && host.len() <= 253
        && !host.chars().any(|c| c.is_whitespace() || c.is_control())
}
fn validate_listen(host: &str, port: u16) -> Result<()> {
    ensure!(valid_host(host), "请输入有效的监听地址");
    let _ = port;
    Ok(())
}
fn validate_target(host: &str, port: u16) -> Result<()> {
    ensure!(valid_host(host) && port > 0, "请输入有效的目标主机和端口");
    Ok(())
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ForwardRule {
    pub id: String,
    pub host_id: String,
    pub name: String,
    /// local, remote, or dynamic
    pub kind: String,
    pub listen_host: String,
    pub listen_port: u16,
    pub target_host: String,
    pub target_port: u16,
}

pub fn forward_rules(token: String, host_id: String) -> Result<Vec<ForwardRule>> {
    crate::api::vault::with_vault(&token, |db| crate::forward_rules::rules(db, &host_id))
}

pub fn forward_save_rule(token: String, rule: ForwardRule) -> Result<ForwardRule> {
    crate::api::vault::with_vault(&token, |db| crate::forward_rules::save(db, rule))
}

pub fn forward_delete_rule(token: String, id: String) -> Result<()> {
    crate::api::vault::with_vault(&token, |db| crate::forward_rules::delete(db, &id))
}

pub async fn start_forward(
    connection_id: String,
    kind: String,
    listen_host: String,
    listen_port: u16,
    target_host: String,
    target_port: u16,
) -> Result<ForwardInfo> {
    ensure!(
        matches!(kind.as_str(), "local" | "remote" | "dynamic"),
        "不支持的转发类型"
    );
    let listen_host = listen_host.trim().to_string();
    validate_listen(&listen_host, listen_port)?;
    let target_host = target_host.trim().to_string();
    if kind == "dynamic" {
        ensure!(
            target_host.is_empty() && target_port == 0,
            "动态转发不指定固定目标"
        );
    } else {
        validate_target(&target_host, target_port)?;
    }
    let live = session::live(&connection_id).await?;
    let mut forwards = live.forwards.lock().await;
    forwards.retain(|_, task| !task.task.is_finished());
    if *live.stop.borrow() {
        bail!("SSH 会话已断开");
    }
    ensure!(
        forwards.len() < MAX_FORWARDS,
        "每个会话最多 {MAX_FORWARDS} 条转发"
    );
    if kind == "remote" {
        start_remote(
            &live,
            &mut forwards,
            listen_host,
            listen_port,
            target_host,
            target_port,
        )
        .await
    } else {
        start_listener(
            &live,
            &mut forwards,
            kind,
            listen_host,
            listen_port,
            target_host,
            target_port,
        )
        .await
    }
}

async fn start_listener(
    live: &Arc<session::Live>,
    forwards: &mut HashMap<String, session::ForwardTask>,
    kind: String,
    listen_host: String,
    listen_port: u16,
    target_host: String,
    target_port: u16,
) -> Result<ForwardInfo> {
    let listener = TcpListener::bind((listen_host.as_str(), listen_port))
        .await
        .context("监听失败，端口可能已被占用或地址不可用")?;
    let id = Uuid::new_v4().to_string();
    let info = ForwardInfo {
        id: id.clone(),
        kind: kind.clone(),
        listen_host,
        listen_port: listener.local_addr()?.port(),
        target_host: target_host.clone(),
        target_port,
        last_error: None,
        listen_remote: false,
    };
    let error = Arc::new(Mutex::new(None));
    let report = error.clone();
    let transport = live.clone();
    let dynamic = kind == "dynamic";
    let task = tokio::spawn(async move {
        let mut stop = transport.stop.subscribe();
        let mut clients = JoinSet::new();
        let slots = Arc::new(Semaphore::new(MAX_CLIENTS));
        loop {
            if *stop.borrow() {
                break;
            }
            tokio::select! {
                biased;
                _ = stop.changed() => break,
                _ = clients.join_next(), if !clients.is_empty() => {},
                accepted = listener.accept() => {
                    let (mut socket, peer) = match accepted {
                        Ok(value) => value,
                        Err(error) => {
                            *report.lock().unwrap() = Some(error.to_string());
                            break;
                        }
                    };
                    let permit = match slots.clone().try_acquire_owned() {
                        Ok(permit) => permit,
                        Err(_) => {
                            *report.lock().unwrap() = Some(format!("并发连接达到 {MAX_CLIENTS} 个上限"));
                            continue;
                        }
                    };
                    let transport = transport.clone();
                    let host = target_host.clone();
                    let report = report.clone();
                    let dynamic = dynamic;
                    clients.spawn(async move {
                        let _permit = permit;
                        if dynamic {
                            let result: Result<()> = async {
                                let channel = socks5_connect(&mut socket, &transport.handle).await?;
                                let mut stream = channel.into_stream();
                                tokio::io::copy_bidirectional(&mut socket, &mut stream).await?;
                                Ok(())
                            }.await;
                            if let Err(error) = result {
                                *report.lock().unwrap() = Some(error.to_string());
                            }
                        } else {
                            let result: Result<russh::Channel<russh::client::Msg>> = async {
                                Ok(tokio::time::timeout(
                                    CONNECT_TIMEOUT,
                                    transport.handle.channel_open_direct_tcpip(
                                        host,
                                        u32::from(target_port),
                                        peer.ip().to_string(),
                                        u32::from(peer.port()),
                                    ),
                                )
                                .await
                                .context("目标连接超时")??)
                            }.await;
                            match result {
                                Ok(channel) => {
                                    let mut stream = channel.into_stream();
                                    if tokio::io::copy_bidirectional(&mut socket, &mut stream)
                                        .await
                                        .is_err()
                                    {
                                        // Client disconnects are not rule errors.
                                    }
                                }
                                Err(error) => *report.lock().unwrap() = Some(error.to_string()),
                            }
                        }
                    });
                }
            }
        }
        clients.abort_all();
        while clients.join_next().await.is_some() {}
    });
    forwards.insert(
        id.clone(),
        session::ForwardTask {
            info: info.clone(),
            error,
            task,
            remote: None,
        },
    );
    Ok(info)
}

async fn start_remote(
    live: &Arc<session::Live>,
    forwards: &mut HashMap<String, session::ForwardTask>,
    listen_host: String,
    listen_port: u16,
    target_host: String,
    target_port: u16,
) -> Result<ForwardInfo> {
    let assigned = tokio::time::timeout(
        CONNECT_TIMEOUT,
        live.handle
            .tcpip_forward(listen_host.clone(), u32::from(listen_port)),
    )
    .await
    .context("远端监听请求超时")??;
    let assigned = u16::try_from(assigned).context("服务器返回的监听端口无效")?;
    // A server accepting a fixed-port request replies without a port value.
    let assigned = if assigned == 0 { listen_port } else { assigned };
    ensure!(assigned > 0, "服务器未返回有效的监听端口");
    let error = Arc::new(Mutex::new(None));
    let conflict = {
        let targets = live
            .remote_targets
            .lock()
            .map_err(|_| anyhow::anyhow!("远端转发状态不可用"))?;
        targets.contains_key(&assigned)
    };
    if conflict {
        let _ = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            live.handle
                .cancel_tcpip_forward(listen_host.clone(), u32::from(assigned)),
        )
        .await;
        bail!("远端端口已被此会话的另一条规则使用");
    }
    {
        let mut targets = live
            .remote_targets
            .lock()
            .map_err(|_| anyhow::anyhow!("远端转发状态不可用"))?;
        targets.insert(
            assigned,
            session::RemoteTarget {
                target_host: target_host.clone(),
                target_port,
                slots: Arc::new(Semaphore::new(MAX_CLIENTS)),
                error: error.clone(),
                aborts: Arc::new(Mutex::new(Vec::new())),
            },
        );
    }
    let id = Uuid::new_v4().to_string();
    let info = ForwardInfo {
        id: id.clone(),
        kind: "remote".into(),
        listen_host: listen_host.clone(),
        listen_port: assigned,
        target_host,
        target_port,
        last_error: None,
        listen_remote: true,
    };
    let transport = live.clone();
    let host = listen_host.clone();
    let task = tokio::spawn(async move {
        let mut stop = transport.stop.subscribe();
        let _ = stop.changed().await;
        remove_remote_target(&transport, assigned);
        let _ = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            transport
                .handle
                .cancel_tcpip_forward(host, u32::from(assigned)),
        )
        .await;
    });
    forwards.insert(
        id.clone(),
        session::ForwardTask {
            info: info.clone(),
            error,
            task,
            remote: Some((listen_host, assigned)),
        },
    );
    Ok(info)
}

fn remove_remote_target(live: &session::Live, port: u16) {
    if let Ok(mut targets) = live.remote_targets.lock() {
        if let Some(target) = targets.remove(&port) {
            if let Ok(mut handles) = target.aborts.lock() {
                for handle in handles.drain(..) {
                    handle.abort();
                }
            }
        }
    }
}

pub async fn list_forwards(connection_id: String) -> Result<Vec<ForwardInfo>> {
    let live = session::live(&connection_id).await?;
    let mut tasks = live.forwards.lock().await;
    tasks.retain(|_, task| !task.task.is_finished());
    let mut result: Vec<_> = tasks
        .values()
        .map(|task| {
            let mut info = task.info.clone();
            info.last_error = task.error.lock().unwrap().clone();
            info
        })
        .collect();
    result.sort_by(|a, b| a.kind.cmp(&b.kind).then(a.listen_port.cmp(&b.listen_port)));
    Ok(result)
}

pub async fn stop_forward(connection_id: String, forward_id: String) -> Result<()> {
    let live = session::live(&connection_id).await?;
    let task = live.forwards.lock().await.remove(&forward_id);
    if let Some(task) = task {
        if let Some((host, port)) = &task.remote {
            remove_remote_target(&live, *port);
            let _ = tokio::time::timeout(
                std::time::Duration::from_secs(5),
                live.handle
                    .cancel_tcpip_forward(host.clone(), u32::from(*port)),
            )
            .await;
        }
        task.task.abort();
        let _ = task.task.await;
    }
    Ok(())
}

pub async fn start_local_forward(
    connection_id: String,
    local_port: u16,
    target_host: String,
    target_port: u16,
) -> Result<LocalForward> {
    let info = start_forward(
        connection_id,
        "local".into(),
        "127.0.0.1".into(),
        local_port,
        target_host,
        target_port,
    )
    .await?;
    Ok(LocalForward::from_info(&info))
}

pub async fn list_local_forwards(connection_id: String) -> Result<Vec<LocalForward>> {
    Ok(list_forwards(connection_id)
        .await?
        .iter()
        .filter(|info| info.kind == "local")
        .map(LocalForward::from_info)
        .collect())
}

pub async fn stop_local_forward(connection_id: String, forward_id: String) -> Result<()> {
    stop_forward(connection_id, forward_id).await
}

async fn socks5_reply(socket: &mut TcpStream, code: u8) {
    let _ = socket.write_all(&[5, code, 0, 1, 0, 0, 0, 0, 0, 0]).await;
}

async fn read_timeout(socket: &mut TcpStream, buffer: &mut [u8]) -> Result<()> {
    tokio::time::timeout(
        std::time::Duration::from_secs(10),
        socket.read_exact(buffer),
    )
    .await
    .context("SOCKS5 握手超时")??;
    Ok(())
}

async fn socks5_handshake(socket: &mut TcpStream) -> Result<(String, u16)> {
    let mut header = [0u8; 2];
    read_timeout(socket, &mut header).await?;
    ensure!(header[0] == 5, "只支持 SOCKS5");
    ensure!((1..=8).contains(&header[1]), "SOCKS5 方法数量无效");
    let mut methods = vec![0u8; header[1] as usize];
    read_timeout(socket, &mut methods).await?;
    if !methods.contains(&0) {
        let _ = socket.write_all(&[5, 0xff]).await;
        bail!("客户端未提供无认证 SOCKS5 方式");
    }
    socket.write_all(&[5, 0]).await?;
    let mut request = [0u8; 4];
    read_timeout(socket, &mut request).await?;
    ensure!(request[0] == 5 && request[2] == 0, "SOCKS5 请求无效");
    if request[1] != 1 {
        socks5_reply(socket, 7).await;
        bail!("动态转发只支持 SOCKS5 CONNECT");
    }
    let host = match request[3] {
        1 => {
            let mut bytes = [0u8; 4];
            read_timeout(socket, &mut bytes).await?;
            Ipv4Addr::from(bytes).to_string()
        }
        3 => {
            let mut length = [0u8; 1];
            read_timeout(socket, &mut length).await?;
            ensure!(length[0] > 0, "SOCKS5 目标域名为空");
            let mut bytes = vec![0u8; length[0] as usize];
            read_timeout(socket, &mut bytes).await?;
            let value =
                String::from_utf8(bytes).map_err(|_| anyhow::anyhow!("SOCKS5 目标域名无效"))?;
            ensure!(valid_host(&value), "SOCKS5 目标域名无效");
            value
        }
        4 => {
            let mut bytes = [0u8; 16];
            read_timeout(socket, &mut bytes).await?;
            Ipv6Addr::from(bytes).to_string()
        }
        _ => {
            socks5_reply(socket, 8).await;
            bail!("不支持的 SOCKS5 地址类型");
        }
    };
    let mut port = [0u8; 2];
    read_timeout(socket, &mut port).await?;
    let port = u16::from_be_bytes(port);
    ensure!(port > 0, "SOCKS5 目标端口无效");
    Ok((host, port))
}

async fn socks5_connect(
    socket: &mut TcpStream,
    handle: &session::Transport,
) -> Result<russh::Channel<russh::client::Msg>> {
    let (host, port) = socks5_handshake(socket).await?;
    let channel = match tokio::time::timeout(
        CONNECT_TIMEOUT,
        handle.channel_open_direct_tcpip(host, u32::from(port), "127.0.0.1", 0),
    )
    .await
    {
        Ok(Ok(channel)) => channel,
        Ok(Err(_)) => {
            socks5_reply(socket, 5).await;
            bail!("SOCKS5 目标连接被拒绝");
        }
        Err(_) => {
            socks5_reply(socket, 4).await;
            bail!("SOCKS5 目标连接超时");
        }
    };
    socket.write_all(&[5, 0, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
    Ok(channel)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    fn rule(host: &str, name: &str, kind: &str) -> ForwardRule {
        ForwardRule {
            id: String::new(),
            host_id: host.into(),
            name: name.into(),
            kind: kind.into(),
            listen_host: "127.0.0.1".into(),
            listen_port: 0,
            target_host: if kind == "dynamic" {
                String::new()
            } else {
                "127.0.0.1".into()
            },
            target_port: if kind == "dynamic" { 0 } else { 22 },
        }
    }

    #[test]
    fn saved_rules_validate_hosts_names_and_persist() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("rules.db");
        let mut db = crate::api::vault::open_database(&path, "forward rules vault", true)?;
        crate::api::vault::put_record(
            &db,
            "hosts",
            r#"[{"id":"h1","name":"One","host":"127.0.0.1","username":"u","port":22,"group":"","tags":[],"favorite":false}]"#,
        )?;
        let saved = crate::forward_rules::save(&mut db, rule("h1", "Web", "local"))?;
        assert_eq!(saved.listen_host, "127.0.0.1");
        assert_eq!(crate::forward_rules::rules(&db, "h1")?.len(), 1);
        assert!(crate::forward_rules::rules(&db, "missing")?.is_empty());
        assert!(crate::forward_rules::save(&mut db, rule("h1", "web", "remote")).is_err());
        assert!(crate::forward_rules::save(&mut db, rule("missing", "X", "local")).is_err());
        let mut bad = rule("h1", "Bad kind", "local");
        bad.kind = "tunnel".into();
        assert!(crate::forward_rules::save(&mut db, bad).is_err());
        let mut bad = rule("h1", "Bad host", "local");
        bad.listen_host = "bad host".into();
        assert!(crate::forward_rules::save(&mut db, bad).is_err());
        let mut bad = rule("h1", "Bad target", "remote");
        bad.target_port = 0;
        assert!(crate::forward_rules::save(&mut db, bad).is_err());
        let mut update = saved.clone();
        update.name = "Web 2".into();
        update.listen_port = 8081;
        let updated = crate::forward_rules::save(&mut db, update)?;
        assert_eq!(updated.id, saved.id);
        assert_eq!(updated.listen_port, 8081);
        let socks = crate::forward_rules::save(&mut db, rule("h1", "Socks", "dynamic"))?;
        assert!(socks.target_host.is_empty() && socks.target_port == 0);
        crate::forward_rules::delete(&mut db, &updated.id)?;
        assert_eq!(crate::forward_rules::rules(&db, "h1")?.len(), 1);
        drop(db);
        let db = crate::api::vault::open_database(&path, "forward rules vault", false)?;
        assert_eq!(crate::forward_rules::rules(&db, "h1")?.len(), 1);
        Ok(())
    }

    async fn session() -> String {
        let port = std::env::var("WTERM_TEST_PORT").unwrap().parse().unwrap();
        let identity = crate::api::client::probe_server("127.0.0.1".into(), port)
            .await
            .unwrap();
        crate::api::client::authenticate(
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

    async fn echo_once() -> (u16, tokio::task::JoinHandle<()>) {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let task = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut data = [0; 5];
            socket.read_exact(&mut data).await.unwrap();
            socket.write_all(&data).await.unwrap();
            socket.shutdown().await.unwrap();
            let mut tail = [0; 1];
            assert_eq!(socket.read(&mut tail).await.unwrap(), 0);
        });
        (port, task)
    }

    async fn echo_roundtrip(port: u16) {
        let mut socket = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            TcpStream::connect(("127.0.0.1", port)),
        )
        .await
        .unwrap()
        .unwrap();
        socket.write_all(b"hello").await.unwrap();
        let mut result = [0; 5];
        tokio::time::timeout(
            std::time::Duration::from_secs(5),
            socket.read_exact(&mut result),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(&result, b"hello");
    }

    async fn assert_rebindable(port: u16) {
        for _ in 0..60 {
            if let Ok(listener) = TcpListener::bind(("127.0.0.1", port)).await {
                drop(listener);
                return;
            }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
        panic!("port {port} was not released");
    }

    #[tokio::test]
    #[ignore = "Run scripts/test-core.sh for the loopback SSH fixture"]
    async fn fixture_local_forward_roundtrip_stop_and_occupied_port() {
        let id = session().await;
        let (target, echo) = echo_once().await;
        let occupied = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        assert!(start_forward(
            id.clone(),
            "local".into(),
            "127.0.0.1".into(),
            occupied.local_addr().unwrap().port(),
            "127.0.0.1".into(),
            target
        )
        .await
        .is_err());
        let info = start_local_forward(id.clone(), 0, "127.0.0.1".into(), target)
            .await
            .unwrap();
        assert!(!info.id.is_empty());
        assert_eq!(list_local_forwards(id.clone()).await.unwrap().len(), 1);
        echo_roundtrip(info.local_port).await;
        tokio::time::timeout(std::time::Duration::from_secs(5), echo)
            .await
            .unwrap()
            .unwrap();
        stop_local_forward(id.clone(), info.id).await.unwrap();
        assert_rebindable(info.local_port).await;
        assert!(list_local_forwards(id.clone()).await.unwrap().is_empty());
        crate::api::client::disconnect(id).await.unwrap();
    }

    #[tokio::test]
    #[ignore = "Run scripts/test-core.sh for the loopback SSH fixture"]
    async fn fixture_remote_forward_roundtrip_conflict_and_stop() {
        let id = session().await;
        let (target, echo) = echo_once().await;
        let info = start_forward(
            id.clone(),
            "remote".into(),
            "127.0.0.1".into(),
            0,
            "127.0.0.1".into(),
            target,
        )
        .await
        .unwrap();
        assert!(info.listen_remote);
        assert!(info.listen_port > 0);
        let listed = list_forwards(id.clone()).await.unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].kind, "remote");
        echo_roundtrip(info.listen_port).await;
        tokio::time::timeout(std::time::Duration::from_secs(5), echo)
            .await
            .unwrap()
            .unwrap();
        let occupied = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let fixed = occupied.local_addr().unwrap().port();
        drop(occupied);
        let first = start_forward(
            id.clone(),
            "remote".into(),
            "127.0.0.1".into(),
            fixed,
            "127.0.0.1".into(),
            target,
        )
        .await
        .unwrap();
        assert!(start_forward(
            id.clone(),
            "remote".into(),
            "127.0.0.1".into(),
            fixed,
            "127.0.0.1".into(),
            target
        )
        .await
        .is_err());
        stop_forward(id.clone(), first.id).await.unwrap();
        stop_forward(id.clone(), info.id).await.unwrap();
        assert_rebindable(fixed).await;
        assert_rebindable(info.listen_port).await;
        crate::api::client::disconnect(id).await.unwrap();
    }

    #[tokio::test]
    #[ignore = "Run scripts/test-core.sh for the loopback SSH fixture"]
    async fn fixture_dynamic_socks5_roundtrip_and_stop() {
        let id = session().await;
        let (target, echo) = echo_once().await;
        let info = start_forward(
            id.clone(),
            "dynamic".into(),
            "127.0.0.1".into(),
            0,
            String::new(),
            0,
        )
        .await
        .unwrap();
        assert!(info.target_host.is_empty());
        let mut socket = TcpStream::connect(("127.0.0.1", info.listen_port))
            .await
            .unwrap();
        socket.write_all(&[5, 1, 0]).await.unwrap();
        let mut greeting = [0; 2];
        socket.read_exact(&mut greeting).await.unwrap();
        assert_eq!(greeting, [5, 0]);
        let port = target.to_be_bytes();
        socket
            .write_all(&[5, 1, 0, 1, 127, 0, 0, 1, port[0], port[1]])
            .await
            .unwrap();
        let mut reply = [0; 10];
        socket.read_exact(&mut reply).await.unwrap();
        assert_eq!(&reply[..2], &[5, 0]);
        socket.write_all(b"hello").await.unwrap();
        let mut result = [0; 5];
        socket.read_exact(&mut result).await.unwrap();
        assert_eq!(&result, b"hello");
        socket.shutdown().await.unwrap();
        drop(socket);
        tokio::time::timeout(std::time::Duration::from_secs(5), echo)
            .await
            .unwrap()
            .unwrap();
        stop_forward(id.clone(), info.id).await.unwrap();
        assert_rebindable(info.listen_port).await;
        assert!(list_forwards(id.clone()).await.unwrap().is_empty());
        crate::api::client::disconnect(id).await.unwrap();
    }

    #[tokio::test]
    #[ignore = "Run scripts/test-core.sh for the loopback SSH fixture"]
    async fn fixture_disconnect_stops_all_forwarding() {
        let id = session().await;
        let (target, _echo) = echo_once().await;
        let local = start_forward(
            id.clone(),
            "local".into(),
            "127.0.0.1".into(),
            0,
            "127.0.0.1".into(),
            target,
        )
        .await
        .unwrap();
        let dynamic = start_forward(
            id.clone(),
            "dynamic".into(),
            "127.0.0.1".into(),
            0,
            String::new(),
            0,
        )
        .await
        .unwrap();
        crate::api::client::disconnect(id.clone()).await.unwrap();
        assert!(list_forwards(id.clone()).await.is_err());
        assert_rebindable(local.listen_port).await;
        assert_rebindable(dynamic.listen_port).await;
    }
}
