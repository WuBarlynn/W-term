//! Local forwards are scoped to an authenticated SSH session and loopback only.
use crate::session;
use anyhow::{bail, Context, Result};
use std::sync::{Arc, Mutex};
use tokio::{net::TcpListener, sync::Semaphore, task::JoinSet};
use uuid::Uuid;

#[derive(Clone)]
pub struct LocalForward {
    pub id: String,
    pub local_port: u16,
    pub target_host: String,
    pub target_port: u16,
    pub last_error: Option<String>,
}

pub async fn start_local_forward(
    connection_id: String,
    local_port: u16,
    target_host: String,
    target_port: u16,
) -> Result<LocalForward> {
    let host = target_host.trim().to_string();
    if host.is_empty()
        || host.len() > 253
        || host.chars().any(|c| c.is_whitespace() || c.is_control())
        || target_port == 0
    {
        bail!("请输入有效的目标主机和端口");
    }
    let live = session::live(&connection_id).await?;
    let mut forwards = live.forwards.lock().await;
    forwards.retain(|_, f| !f.task.is_finished());
    if *live.stop.borrow() {
        bail!("SSH 会话已断开");
    }
    if forwards.len() >= 8 {
        bail!("每个会话最多 8 个本地转发");
    }
    let listener = TcpListener::bind(("127.0.0.1", local_port))
        .await
        .context("本地端口无法监听，可能已被占用")?;
    let info = LocalForward {
        id: Uuid::new_v4().to_string(),
        local_port: listener.local_addr()?.port(),
        target_host: host.clone(),
        target_port,
        last_error: None,
    };
    let mut stop = live.stop.subscribe();
    let error = Arc::new(Mutex::new(None));
    let report = error.clone();
    let transport = live.clone();
    let task = tokio::spawn(async move {
        let mut clients = JoinSet::new();
        let slots = Arc::new(Semaphore::new(32));
        loop {
            if *stop.borrow() {
                break;
            }
            tokio::select! {
                biased;
                _ = stop.changed() => break,
                _ = clients.join_next(), if !clients.is_empty() => {},
                accepted = listener.accept() => {
                    let (mut socket, peer) = match accepted { Ok(value) => value, Err(e) => {
                        *report.lock().unwrap() = Some(e.to_string()); break;
                    }};
                    let permit = match slots.clone().try_acquire_owned() { Ok(p) => p, Err(_) => {
                        *report.lock().unwrap() = Some("并发连接达到 32 个上限".into()); continue;
                    }};
                    let transport = transport.clone();
                    let host = host.clone();
                    let report = report.clone();
                    clients.spawn(async move {
                        let _permit = permit;
                        let result: Result<()> = async {
                            let channel = tokio::time::timeout(std::time::Duration::from_secs(15),
                                transport.handle.channel_open_direct_tcpip(host, u32::from(target_port), peer.ip().to_string(), u32::from(peer.port())))
                                .await.context("目标连接超时")??;
                            let mut stream = channel.into_stream();
                            tokio::io::copy_bidirectional(&mut socket, &mut stream).await?;
                            Ok(())
                        }.await;
                        if let Err(e) = result { *report.lock().unwrap() = Some(e.to_string()); }
                    });
                }
            }
        }
        clients.abort_all();
        while clients.join_next().await.is_some() {}
    });
    forwards.insert(
        info.id.clone(),
        session::ForwardTask {
            info: info.clone(),
            error,
            task,
        },
    );
    Ok(info)
}

pub async fn list_local_forwards(connection_id: String) -> Result<Vec<LocalForward>> {
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
    result.sort_by_key(|f| f.local_port);
    Ok(result)
}

pub async fn stop_local_forward(connection_id: String, forward_id: String) -> Result<()> {
    let live = session::live(&connection_id).await?;
    let task = live.forwards.lock().await.remove(&forward_id);
    if let Some(task) = task {
        task.task.abort();
        let _ = task.task.await;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[tokio::test]
    async fn rejects_invalid_forward_destination() {
        for host in ["", "bad host", "host\n"] {
            assert!(start_local_forward("unknown".into(), 0, host.into(), 22)
                .await
                .is_err());
        }
        assert!(
            start_local_forward("unknown".into(), 0, "localhost".into(), 0)
                .await
                .is_err()
        );
    }

    #[tokio::test]
    #[ignore = "Run scripts/test-core.sh for the loopback SSH fixture"]
    async fn fixture_local_forward_roundtrip_stop_and_disconnect() {
        let port = std::env::var("WTERM_TEST_PORT").unwrap().parse().unwrap();
        let identity = crate::api::client::probe_server("127.0.0.1".into(), port)
            .await
            .unwrap();
        let id = identity.connection_id;
        crate::api::client::authenticate(
            id.clone(),
            identity.fingerprint,
            "wterm".into(),
            "wterm-test-only".into(),
            "".into(),
            "".into(),
        )
        .await
        .unwrap();
        let echo = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let target = echo.local_addr().unwrap().port();
        let echo_task = tokio::spawn(async move {
            let (mut socket, _) = echo.accept().await.unwrap();
            let mut data = [0; 5];
            socket.read_exact(&mut data).await.unwrap();
            socket.write_all(&data).await.unwrap();
            let mut tail = [0; 1];
            assert_eq!(socket.read(&mut tail).await.unwrap(), 0);
        });
        let occupied = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        assert!(start_local_forward(
            id.clone(),
            occupied.local_addr().unwrap().port(),
            "127.0.0.1".into(),
            target
        )
        .await
        .is_err());
        let forward = start_local_forward(id.clone(), 0, "127.0.0.1".into(), target)
            .await
            .unwrap();
        assert_eq!(list_local_forwards(id.clone()).await.unwrap().len(), 1);
        let mut socket = tokio::net::TcpStream::connect(("127.0.0.1", forward.local_port))
            .await
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
        stop_local_forward(id.clone(), forward.id).await.unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(5), echo_task)
            .await
            .unwrap()
            .unwrap();
        assert!(list_local_forwards(id.clone()).await.unwrap().is_empty());
        let rebound = TcpListener::bind(("127.0.0.1", forward.local_port))
            .await
            .unwrap();
        drop(rebound);
        // The fixture refuses destinations other than 127.0.0.1.
        let rejected = start_local_forward(id.clone(), 0, "localhost".into(), target)
            .await
            .unwrap();
        let mut rejected_socket =
            tokio::net::TcpStream::connect(("127.0.0.1", rejected.local_port))
                .await
                .unwrap();
        let mut byte = [0; 1];
        assert_eq!(
            tokio::time::timeout(
                std::time::Duration::from_secs(5),
                rejected_socket.read(&mut byte)
            )
            .await
            .unwrap()
            .unwrap(),
            0
        );
        let listed = list_local_forwards(id.clone()).await.unwrap();
        assert!(listed
            .iter()
            .find(|f| f.id == rejected.id)
            .unwrap()
            .last_error
            .is_some());
        stop_local_forward(id.clone(), rejected.id).await.unwrap();
        let forward = start_local_forward(id.clone(), 0, "127.0.0.1".into(), target)
            .await
            .unwrap();
        crate::api::client::disconnect(id).await.unwrap();
        TcpListener::bind(("127.0.0.1", forward.local_port))
            .await
            .unwrap();
    }
}
