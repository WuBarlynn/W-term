//! No credential is sent during probing. Approval is bound to the exact live
//! transport which supplied the fingerprint (never reconnect between the two).
use anyhow::{anyhow, bail, Context, Result};
use russh::{
    client,
    keys::{HashAlg, PrivateKeyWithHashAlg},
    Channel, ChannelMsg, ChannelOpenFailure, Disconnect,
};
use russh_sftp::client::SftpSession;
use std::{
    collections::HashMap,
    sync::{Arc, OnceLock},
    time::Duration,
};
use tokio::{
    net::TcpStream,
    sync::{mpsc, watch, Mutex, Semaphore},
};
use uuid::Uuid;
use zeroize::{Zeroize, Zeroizing};

pub(crate) mod interactive;

pub type Transport = client::Handle<HostKeyProbe>;
trait RouteStream: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send {}
impl<T: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send> RouteStream for T {}

#[derive(Clone)]
pub(crate) struct RemoteTarget {
    pub target_host: String,
    pub target_port: u16,
    pub slots: Arc<Semaphore>,
    pub error: Arc<std::sync::Mutex<Option<String>>>,
    pub aborts: Arc<std::sync::Mutex<Vec<tokio::task::AbortHandle>>>,
}
pub(crate) type RemoteTargets = Arc<std::sync::Mutex<HashMap<u16, RemoteTarget>>>;
pub(crate) fn remote_targets() -> RemoteTargets {
    Arc::new(std::sync::Mutex::new(HashMap::new()))
}
pub struct HostKeyProbe {
    pub fingerprint: Arc<std::sync::Mutex<Option<String>>>,
    pub remote_targets: RemoteTargets,
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
    async fn server_channel_open_forwarded_tcpip(
        &mut self,
        channel: Channel<client::Msg>,
        _connected_address: &str,
        connected_port: u32,
        _originator_address: &str,
        _originator_port: u32,
        reply: client::ChannelOpenHandle,
        _session: &mut client::Session,
    ) -> Result<()> {
        let port = u16::try_from(connected_port).ok();
        let target = port.and_then(|port| {
            self.remote_targets
                .lock()
                .ok()
                .and_then(|map| map.get(&port).cloned())
        });
        let Some(target) = target else {
            reply
                .reject(ChannelOpenFailure::AdministrativelyProhibited)
                .await;
            return Ok(());
        };
        let permit = match target.slots.clone().try_acquire_owned() {
            Ok(permit) => permit,
            Err(_) => {
                reply.reject(ChannelOpenFailure::ResourceShortage).await;
                return Ok(());
            }
        };
        reply.accept().await;
        let target_host = target.target_host.clone();
        let target_port = target.target_port;
        let target_error = target.error.clone();
        let aborts = target.aborts.clone();
        let task = tokio::spawn(async move {
            let _permit = permit;
            let result: Result<()> = async {
                let mut socket = TcpStream::connect((target_host.as_str(), target_port))
                    .await
                    .context("远端转发目标连接失败")?;
                let mut stream = channel.into_stream();
                tokio::io::copy_bidirectional(&mut socket, &mut stream).await?;
                Ok(())
            }
            .await;
            if let Err(failure) = result {
                if let Ok(mut slot) = target_error.lock() {
                    *slot = Some(failure.to_string());
                }
            }
        });
        if let Ok(mut handles) = aborts.lock() {
            handles.retain(|handle| !handle.is_finished());
            handles.push(task.abort_handle());
        }
        Ok(())
    }
}
struct Pending {
    handle: Transport,
    fingerprint: String,
    parent: Option<String>,
    remote_targets: RemoteTargets,
}
pub enum Input {
    Data(Vec<u8>),
    Resize(u32, u32),
}
pub(crate) struct ForwardTask {
    pub info: crate::api::forward::ForwardInfo,
    pub error: Arc<std::sync::Mutex<Option<String>>>,
    pub task: tokio::task::JoinHandle<()>,
    pub remote: Option<(String, u16)>,
}
pub struct Live {
    pub handle: Transport,
    pub forwards: Mutex<HashMap<String, ForwardTask>>,
    pub input: mpsc::Sender<Input>,
    pub output: Mutex<Option<mpsc::Receiver<Vec<u8>>>>,
    pub ack: Semaphore,
    pub stop: watch::Sender<bool>,
    pub sftp: Mutex<Option<Arc<SftpSession>>>,
    pub remote_targets: RemoteTargets,
    parent: Option<String>,
}
#[derive(Default)]
struct Registry {
    pending: HashMap<String, Pending>,
    live: HashMap<String, Arc<Live>>,
    authenticating: HashMap<String, watch::Sender<bool>>,
    probes: HashMap<String, watch::Sender<bool>>,
    cancelled_probes: std::collections::HashSet<String>,
}
fn registry() -> &'static Mutex<Registry> {
    static REG: OnceLock<Mutex<Registry>> = OnceLock::new();
    REG.get_or_init(Default::default)
}

pub async fn probe(host: String, port: u16) -> Result<(String, String)> {
    probe_with_proxy(host, port, None).await
}

pub(crate) async fn probe_with_proxy(
    host: String,
    port: u16,
    proxy: Option<crate::proxy::Config>,
) -> Result<(String, String)> {
    probe_hop(None, None, host, port, proxy).await
}

/// Opens one route hop. A non-empty parent must already be authenticated and is
/// the only path to the target; failures never fall back to a direct socket.
/// `operation_id` allows cancelling the handshake before a connection id exists.
pub(crate) async fn probe_hop(
    operation_id: Option<String>,
    parent: Option<String>,
    host: String,
    port: u16,
    proxy: Option<crate::proxy::Config>,
) -> Result<(String, String)> {
    if host.trim().is_empty() || port == 0 {
        bail!("Host and a valid port are required");
    }
    let parent = parent.filter(|id| !id.is_empty());
    let probe_id = operation_id.filter(|id| !id.is_empty());
    if let Some(id) = &probe_id {
        if registry().lock().await.cancelled_probes.remove(id) {
            bail!("Connection cancelled");
        }
    }
    {
        let r = registry().lock().await;
        if r.pending.len() + r.live.len() + r.authenticating.len() >= 16 {
            bail!("At most 16 connections may be open");
        }
        if r.probes.len() >= 16 {
            bail!("Too many connection attempts are open");
        }
    }
    let fingerprint = Arc::new(std::sync::Mutex::new(None));
    let targets = remote_targets();
    let handler = HostKeyProbe {
        fingerprint: fingerprint.clone(),
        remote_targets: targets.clone(),
    };
    let config = client::Config {
        keepalive_interval: Some(Duration::from_secs(20)),
        keepalive_max: 3,
        ..Default::default()
    };
    let mut cancel_rx = None;
    if let Some(id) = &probe_id {
        let (cancel, rx) = watch::channel(false);
        registry().lock().await.probes.insert(id.clone(), cancel);
        cancel_rx = Some(rx);
    }
    let target = host.clone();
    let connect_parent = parent.clone();
    let connect = async move {
        let stream: Box<dyn RouteStream> = if let Some(parent_id) = connect_parent {
            let upstream = live(&parent_id)
                .await
                .context("上游跳板连接已断开，请重新连接")?;
            let channel = tokio::time::timeout(
                Duration::from_secs(20),
                upstream.handle.channel_open_direct_tcpip(
                    target.clone(),
                    port as u32,
                    "127.0.0.1",
                    0,
                ),
            )
            .await
            .context("跳板转发通道建立超时")??;
            Box::new(channel.into_stream())
        } else {
            let stream = crate::proxy::connect(&target, port, proxy.as_ref()).await?;
            if config.nodelay {
                let _ = stream.set_nodelay(true);
            }
            Box::new(stream)
        };
        client::connect_stream(Arc::new(config), stream, handler).await
    };
    let result = if let Some(rx) = cancel_rx.as_mut() {
        tokio::select! {
            biased;
            _ = rx.changed() => Err(anyhow!("Connection cancelled")),
            result = tokio::time::timeout(Duration::from_secs(20), connect) =>
                result.map_err(|_| anyhow!("SSH connection timed out")).and_then(|r| r),
        }
    } else {
        tokio::time::timeout(Duration::from_secs(20), connect)
            .await
            .map_err(|_| anyhow!("SSH connection timed out"))?
    };
    if let Some(id) = &probe_id {
        registry().lock().await.probes.remove(id);
    }
    let handle = result?;
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
            parent,
            remote_targets: targets,
        },
    );
    let expiry_id = id.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(120)).await;
        let expired = registry().lock().await.pending.contains_key(&expiry_id);
        if expired {
            // Cascade so an abandoned route does not keep authenticated parents.
            let _ = disconnect(&expiry_id).await;
        }
    });
    Ok((id, key))
}

/// Cancellation may arrive before the probe registers; remember it briefly so
/// an early tap cannot be lost, then bound the set.
pub(crate) async fn cancel_probe(operation_id: &str) {
    let mut r = registry().lock().await;
    if let Some(cancel) = r.probes.remove(operation_id) {
        cancel.send_replace(true);
    } else if r.cancelled_probes.len() < 32 {
        r.cancelled_probes.insert(operation_id.to_string());
    }
}

pub async fn authenticate(
    id: &str,
    approved: &str,
    username: String,
    password: String,
    private_key: String,
    passphrase: String,
) -> Result<()> {
    authenticate_inner(
        id,
        approved,
        username,
        password,
        private_key,
        passphrase,
        true,
    )
    .await
}

/// A jump hop keeps its authenticated transport for the next hop but must not
/// open a PTY or shell: only the final target owns a terminal.
pub(crate) async fn authenticate_jump(
    id: &str,
    approved: &str,
    username: String,
    password: String,
    private_key: String,
    passphrase: String,
) -> Result<()> {
    authenticate_inner(
        id,
        approved,
        username,
        password,
        private_key,
        passphrase,
        false,
    )
    .await
}

async fn authenticate_inner(
    id: &str,
    approved: &str,
    username: String,
    password: String,
    private_key: String,
    passphrase: String,
    open_terminal: bool,
) -> Result<()> {
    let mut password = Zeroizing::new(password);
    let mut private_key = Zeroizing::new(private_key);
    let mut passphrase = Zeroizing::new(passphrase);
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
    let parent = pending.parent.clone();
    let mut handle = pending.handle;
    let initialize = async {
        if pending.fingerprint != approved {
            bail!("HOST_KEY_MISMATCH: authentication blocked");
        }
        if username.trim().is_empty() {
            bail!("Username is required");
        }
        let auth = tokio::time::timeout(Duration::from_secs(20), async {
            if private_key.is_empty() && password.is_empty() {
                handle
                    .authenticate_none(&username)
                    .await
                    .map_err(anyhow::Error::from)
            } else if private_key.is_empty() {
                handle
                    .authenticate_password(&username, password.as_str())
                    .await
                    .map_err(anyhow::Error::from)
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
                    .authenticate_publickey(
                        &username,
                        PrivateKeyWithHashAlg::new(Arc::new(key), hash),
                    )
                    .await
                    .map_err(anyhow::Error::from)
            }
        })
        .await
        .context("Authentication timed out")??;
        password.zeroize();
        private_key.zeroize();
        passphrase.zeroize();
        if !auth.success() {
            if matches!(&auth, client::AuthResult::Failure { remaining_methods, .. } if remaining_methods.contains(&russh::MethodKind::KeyboardInteractive))
            {
                interactive::authenticate(id, &mut handle, &username).await?;
            } else {
                bail!("Authentication rejected. Check username and credentials.");
            }
        }
        if !open_terminal {
            return Ok(None);
        }
        tokio::time::timeout(Duration::from_secs(30), async {
            let mut channel = handle.channel_open_session().await?;
            channel
                .request_pty(true, "xterm-256color", 100, 30, 0, 0, &[])
                .await?;
            await_success(&mut channel).await?;
            channel.request_shell(true).await?;
            await_success(&mut channel).await?;
            Ok::<_, anyhow::Error>(Some(channel))
        })
        .await
        .context("Terminal startup timed out")?
    };
    let result = tokio::select! {
        biased;
        _ = cancelled.changed() => Err(anyhow!("Connection cancelled")),
        result = tokio::time::timeout(Duration::from_secs(300), initialize) =>
            result.context("Authentication timed out").and_then(|result| result),
    };
    interactive::clear(id).await;
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
    let remote_targets = pending.remote_targets.clone();
    let live = Arc::new(Live {
        handle,
        input,
        output: Mutex::new(if channel.is_some() {
            Some(output_rx)
        } else {
            drop(output_rx);
            None
        }),
        ack: Semaphore::new(0),
        stop,
        sftp: Mutex::new(None),
        forwards: Mutex::new(HashMap::new()),
        remote_targets,
        parent,
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
    if let Some(channel) = channel {
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
    }
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
/// Disconnecting any hop owns its whole chain: descendants are torn down first
/// so no child transport is left running over a closed parent.
pub async fn disconnect(id: &str) -> Result<()> {
    let (pending, lives, cancel) = {
        let mut r = registry().lock().await;
        let mut ids = std::collections::HashSet::new();
        let mut queue = std::collections::VecDeque::from([id.to_string()]);
        while let Some(current) = queue.pop_front() {
            if !ids.insert(current.clone()) {
                continue;
            }
            for (child, p) in &r.pending {
                if p.parent.as_deref() == Some(current.as_str()) {
                    queue.push_back(child.clone());
                }
                if child == &current {
                    if let Some(parent) = &p.parent {
                        queue.push_back(parent.clone());
                    }
                }
            }
            for (child, l) in &r.live {
                if l.parent.as_deref() == Some(current.as_str()) {
                    queue.push_back(child.clone());
                }
                if child == &current {
                    if let Some(parent) = &l.parent {
                        queue.push_back(parent.clone());
                    }
                }
            }
        }
        let mut pending = Vec::new();
        let mut lives = Vec::new();
        let mut cancels = Vec::new();
        for chain_id in ids {
            if let Some(p) = r.pending.remove(&chain_id) {
                pending.push((chain_id.clone(), p));
            }
            if let Some(l) = r.live.remove(&chain_id) {
                lives.push((chain_id.clone(), l));
            }
            if let Some(c) = r.authenticating.remove(&chain_id) {
                cancels.push(c);
            }
        }
        (pending, lives, cancels)
    };
    for chain_id in pending.iter().map(|(id, _)| id) {
        interactive::clear(chain_id).await;
    }
    for chain_id in lives.iter().map(|(id, _)| id) {
        interactive::clear(chain_id).await;
    }
    for cancel in cancel {
        cancel.send_replace(true);
    }
    for (_, p) in pending {
        let _ = p
            .handle
            .disconnect(Disconnect::ByApplication, "Cancelled", "en")
            .await;
    }
    for (_, s) in lives {
        s.stop.send_replace(true);
        s.ack.close();
        let forwards: Vec<_> = s.forwards.lock().await.drain().map(|(_, f)| f).collect();
        if let Ok(mut targets) = s.remote_targets.lock() {
            for (_, target) in targets.drain() {
                if let Ok(mut handles) = target.aborts.lock() {
                    for handle in handles.drain(..) {
                        handle.abort();
                    }
                }
            }
        }
        for forward in forwards {
            forward.task.abort();
            let _ = forward.task.await;
        }
        let _ = s
            .handle
            .disconnect(Disconnect::ByApplication, "Disconnected", "en")
            .await;
    }
    interactive::clear(id).await;
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
    async fn fixture_closing_one_session_keeps_other_terminals() {
        let first = password_session().await;
        let second = password_session().await;
        disconnect(&first).await.unwrap();
        assert!(live(&first).await.is_err());
        let state = live(&second).await.unwrap();
        let mut output = state.output.lock().await.take().unwrap();
        client::write_terminal(second.clone(), b"survives\n".to_vec())
            .await
            .unwrap();
        let mut received = Vec::new();
        tokio::time::timeout(Duration::from_secs(10), async {
            while let Some(bytes) = output.recv().await {
                received.extend(bytes);
                if String::from_utf8_lossy(&received).contains("ECHO:survives") {
                    break;
                }
            }
        })
        .await
        .unwrap();
        assert!(String::from_utf8_lossy(&received).contains("WTERM_FIXTURE_READY"));
        disconnect(&second).await.unwrap();
    }
    #[tokio::test]
    #[ignore = "Run scripts/test-core.sh to start the loopback fixture"]
    async fn fixture_two_hop_route_rejects_wrong_key_and_cleans_chain() {
        let root = std::env::var("WTERM_FIXTURE_ROOT").unwrap();
        let jump_port: u16 = tokio::fs::read_to_string(format!("{root}/jump_port"))
            .await
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        let (hop, hop_fp) = probe("127.0.0.1".into(), port()).await.unwrap();
        authenticate_jump(
            &hop,
            &hop_fp,
            "wterm".into(),
            "wterm-test-only".into(),
            "".into(),
            "".into(),
        )
        .await
        .unwrap();
        assert!(live(&hop).await.unwrap().output.lock().await.is_none());
        let (child, _) = probe_hop(None, Some(hop.clone()), "127.0.0.1".into(), jump_port, None)
            .await
            .unwrap();
        assert!(authenticate(
            &child,
            "SHA256:wrong",
            "wterm".into(),
            "wterm-test-only".into(),
            "".into(),
            "".into(),
        )
        .await
        .is_err());
        assert!(live(&child).await.is_err());
        let (child, child_fp) =
            probe_hop(None, Some(hop.clone()), "127.0.0.1".into(), jump_port, None)
                .await
                .unwrap();
        authenticate(
            &child,
            &child_fp,
            "wterm".into(),
            "wterm-test-only".into(),
            "".into(),
            "".into(),
        )
        .await
        .unwrap();
        let state = live(&child).await.unwrap();
        let mut output = state.output.lock().await.take().unwrap();
        client::write_terminal(child.clone(), b"two-hop\n".to_vec())
            .await
            .unwrap();
        let mut received = Vec::new();
        tokio::time::timeout(Duration::from_secs(10), async {
            while let Some(bytes) = output.recv().await {
                received.extend(bytes);
                let text = String::from_utf8_lossy(&received);
                if text.contains("WTERM_FIXTURE_READY:JUMP") && text.contains("ECHO:two-hop") {
                    break;
                }
            }
        })
        .await
        .unwrap();
        assert!(probe_hop(
            None,
            Some("missing-parent".into()),
            "127.0.0.1".into(),
            jump_port,
            None
        )
        .await
        .is_err());
        disconnect(&hop).await.unwrap();
        assert!(live(&hop).await.is_err());
        assert!(live(&child).await.is_err());
    }
    #[tokio::test]
    #[ignore = "Run scripts/test-core.sh to start the loopback fixture"]
    async fn fixture_rejected_jump_channel_never_falls_back_to_direct() {
        let (hop, hop_fp) = probe("127.0.0.1".into(), port()).await.unwrap();
        authenticate_jump(
            &hop,
            &hop_fp,
            "wterm".into(),
            "wterm-test-only".into(),
            "".into(),
            "".into(),
        )
        .await
        .unwrap();
        // The fixture refuses opening its own port through itself, while a
        // direct connection to the same endpoint would succeed.
        assert!(
            probe_hop(None, Some(hop.clone()), "127.0.0.1".into(), port(), None)
                .await
                .is_err()
        );
        let (direct, _) = probe("127.0.0.1".into(), port()).await.unwrap();
        disconnect(&direct).await.unwrap();
        disconnect(&hop).await.unwrap();
    }
    #[tokio::test]
    #[ignore = "Run scripts/test-core.sh to start the loopback fixture"]
    async fn fixture_probe_cancellation_is_immediate() {
        let root = std::env::var("WTERM_FIXTURE_ROOT").unwrap();
        let stall: u16 = tokio::fs::read_to_string(format!("{root}/stall_port"))
            .await
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        let operation = format!("cancel-{}", Uuid::new_v4());
        let task_operation = operation.clone();
        let task = tokio::spawn(async move {
            probe_hop(Some(task_operation), None, "127.0.0.1".into(), stall, None).await
        });
        tokio::time::sleep(Duration::from_millis(300)).await;
        let started = std::time::Instant::now();
        cancel_probe(&operation).await;
        let result = tokio::time::timeout(Duration::from_secs(5), task)
            .await
            .unwrap()
            .unwrap();
        assert!(result.is_err());
        assert!(started.elapsed() < Duration::from_secs(2));
        let early = format!("early-{}", Uuid::new_v4());
        cancel_probe(&early).await;
        assert!(
            probe_hop(Some(early), None, "127.0.0.1".into(), stall, None)
                .await
                .is_err()
        );
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
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink("中文新名", fixture.join(link.trim_start_matches('/')))
                .unwrap();
            assert!(client::remote_permissions(id.clone(), link.clone())
                .await
                .is_err());
            assert!(
                client::change_remote_permissions(id.clone(), link.clone(), 0o640, 0o777)
                    .await
                    .is_err()
            );
            client::delete_remote_entry(id.clone(), link).await.unwrap();
        }
        #[cfg(not(unix))]
        {
            let _ = (fixture, link);
        }
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

#[cfg(test)]
mod interactive_tests;
