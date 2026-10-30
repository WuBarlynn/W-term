//! HTTP CONNECT (RFC 9110) and SOCKS5 CONNECT (RFC 1928/1929).
//! The caller bounds the entire TCP/proxy/SSH handshake with one deadline.
use crate::api::proxy::{ProxyProfile, ProxySettings};
use anyhow::{bail, ensure, Context, Result};
use base64ct::{Base64, Encoding};
use rusqlite::{Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashSet},
    net::IpAddr,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
};
use zeroize::{Zeroize, Zeroizing};

const KEY: &str = "connection_proxy_v1";
const PROFILES_KEY: &str = "connection_proxies_v1";
const BINDINGS_KEY: &str = "host_proxy_bindings_v1";
const MAX_PROFILES: usize = 32;
const MAX_BINDINGS: usize = 10000;

// Intentionally no Debug: a settings error must never print the password.
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Config {
    mode: String,
    host: String,
    port: u16,
    authenticate: bool,
    username: String,
    password: String,
}
impl Drop for Config {
    fn drop(&mut self) {
        self.password.zeroize();
        self.username.zeroize();
    }
}

fn valid_host(host: &str) -> Result<()> {
    // Accept raw IPv4/IPv6 and ASCII DNS names; never a URL, header, or authority.
    ensure!(
        !host.is_empty() && host.len() <= 253,
        "代理或目标主机地址长度无效"
    );
    ensure!(
        host.parse::<IpAddr>().is_ok()
            || host
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_')),
        "地址只能填写域名或 IP，不含协议、端口或路径；IPv6 不加方括号"
    );
    Ok(())
}
impl Config {
    fn validate(&self) -> Result<()> {
        ensure!(
            matches!(self.mode.as_str(), "http" | "socks5"),
            "不支持的连接代理类型"
        );
        valid_host(&self.host)?;
        ensure!(self.port > 0, "代理端口必须在 1–65535 之间");
        if self.authenticate {
            ensure!(
                !self.username.is_empty()
                    && self.username.len() <= 255
                    && !self.password.is_empty()
                    && self.password.len() <= 255,
                "代理用户名和密码须为 1–255 字节"
            );
            ensure!(
                !self.username.chars().any(char::is_control)
                    && !self.password.chars().any(char::is_control),
                "代理凭证不能包含控制字符"
            );
            ensure!(
                self.mode != "http" || !self.username.contains(':'),
                "HTTP 代理用户名不能包含冒号"
            );
        } else {
            ensure!(
                self.username.is_empty() && self.password.is_empty(),
                "无认证代理不能留存凭证"
            );
        }
        Ok(())
    }
    fn view(&self) -> ProxySettings {
        ProxySettings {
            mode: self.mode.clone(),
            host: self.host.clone(),
            port: self.port,
            authenticate: self.authenticate,
            username: self.username.clone(),
            password_saved: !self.password.is_empty(),
        }
    }
}

pub(crate) fn load(db: &Connection) -> Result<Option<Config>> {
    let raw: Option<String> = db
        .query_row("SELECT value FROM metadata WHERE key=?1", [KEY], |r| {
            r.get(0)
        })
        .optional()?;
    raw.map(|raw| {
        let raw = Zeroizing::new(raw);
        ensure!(raw.len() <= 8192, "代理设置过大");
        let config: Config =
            serde_json::from_str(&raw).map_err(|_| anyhow::anyhow!("代理设置损坏，请重新保存"))?;
        config.validate()?;
        Ok(config)
    })
    .transpose()
}
pub(crate) fn settings(db: &Connection) -> Result<ProxySettings> {
    Ok(load(db)?.map(|c| c.view()).unwrap_or(ProxySettings {
        mode: "direct".into(),
        host: String::new(),
        port: 1080,
        authenticate: false,
        username: String::new(),
        password_saved: false,
    }))
}
pub(crate) fn save(
    db: &mut Connection,
    view: ProxySettings,
    password: Zeroizing<String>,
) -> Result<()> {
    let tx = db.transaction()?;
    if view.mode == "direct" {
        tx.execute("DELETE FROM metadata WHERE key=?1", [KEY])?;
    } else {
        let mut config = Config {
            mode: view.mode,
            host: view.host.trim().to_string(),
            port: view.port,
            authenticate: view.authenticate,
            username: view.username,
            password: password.to_string(),
        };
        if !config.authenticate {
            config.username.zeroize();
            config.password.zeroize();
        } else if config.password.is_empty() {
            let old = load(&tx)?.context("请输入代理密码")?;
            ensure!(
                old.mode == config.mode
                    && old.host == config.host
                    && old.port == config.port
                    && old.authenticate
                    && old.username == config.username,
                "代理地址、类型或用户名已更改，请重新输入代理密码"
            );
            config.password = old.password.clone();
        }
        config.validate()?;
        let raw = Zeroizing::new(serde_json::to_string(&config)?);
        tx.execute(
            "INSERT OR REPLACE INTO metadata(key,value) VALUES (?1,?2)",
            [KEY, raw.as_str()],
        )?;
    }
    tx.commit()?;
    Ok(())
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct StoredProfile {
    id: String,
    name: String,
    mode: String,
    host: String,
    port: u16,
    authenticate: bool,
    username: String,
    password: String,
}
impl Drop for StoredProfile {
    fn drop(&mut self) {
        self.password.zeroize();
        self.username.zeroize();
    }
}
impl StoredProfile {
    fn config(&self) -> Config {
        Config {
            mode: self.mode.clone(),
            host: self.host.clone(),
            port: self.port,
            authenticate: self.authenticate,
            username: self.username.clone(),
            password: self.password.clone(),
        }
    }
    fn view(&self) -> ProxyProfile {
        ProxyProfile {
            id: self.id.clone(),
            name: self.name.clone(),
            mode: self.mode.clone(),
            host: self.host.clone(),
            port: self.port,
            authenticate: self.authenticate,
            username: self.username.clone(),
            password_saved: !self.password.is_empty(),
        }
    }
    fn validate(&self) -> Result<()> {
        ensure!(
            !self.id.is_empty() && self.id.len() <= 128,
            "命名代理标识无效"
        );
        ensure!(
            !self.name.trim().is_empty()
                && self.name.len() <= 64
                && !self.name.chars().any(char::is_control),
            "代理名称须为 1–64 字节且不含控制字符"
        );
        ensure!(
            matches!(self.mode.as_str(), "http" | "socks5"),
            "命名代理仅支持 HTTP CONNECT 或 SOCKS5"
        );
        self.config().validate()
    }
}
fn stored_profiles(db: &Connection) -> Result<Vec<StoredProfile>> {
    let raw: Option<String> = db
        .query_row(
            "SELECT value FROM metadata WHERE key=?1",
            [PROFILES_KEY],
            |r| r.get(0),
        )
        .optional()?;
    let Some(raw) = raw else {
        return Ok(vec![]);
    };
    let raw = Zeroizing::new(raw);
    ensure!(raw.len() <= 256 * 1024, "命名代理配置过大");
    let items: Vec<StoredProfile> =
        serde_json::from_str(&raw).map_err(|_| anyhow::anyhow!("命名代理配置损坏，请重新保存"))?;
    ensure!(items.len() <= MAX_PROFILES, "命名代理数量过多");
    let mut names = HashSet::new();
    let mut ids = HashSet::new();
    for profile in &items {
        profile.validate()?;
        ensure!(
            names.insert(profile.name.to_lowercase()),
            "命名代理名称重复，请重命名"
        );
        ensure!(ids.insert(profile.id.clone()), "命名代理 ID 重复");
    }
    Ok(items)
}
fn write_profiles(db: &Connection, items: &[StoredProfile]) -> Result<()> {
    let raw = Zeroizing::new(serde_json::to_string(items)?);
    db.execute(
        "INSERT OR REPLACE INTO metadata(key,value) VALUES (?1,?2)",
        [PROFILES_KEY, raw.as_str()],
    )?;
    Ok(())
}
pub(crate) fn profiles(db: &Connection) -> Result<Vec<ProxyProfile>> {
    Ok(stored_profiles(db)?
        .iter()
        .map(StoredProfile::view)
        .collect())
}
pub(crate) fn save_profile(
    db: &mut Connection,
    view: crate::api::proxy::ProxyProfileInput,
    password: Zeroizing<String>,
) -> Result<String> {
    let tx = db.transaction()?;
    let mut items = stored_profiles(&tx)?;
    let name = view.name.trim().to_string();
    ensure!(
        matches!(view.mode.as_str(), "http" | "socks5"),
        "命名代理仅支持 HTTP CONNECT 或 SOCKS5"
    );
    let id = if view.id.is_empty() {
        ensure!(items.len() < MAX_PROFILES, "命名代理最多 32 个");
        uuid::Uuid::new_v4().to_string()
    } else {
        ensure!(
            items.iter().any(|p| p.id == view.id),
            "代理配置已被删除，请刷新列表"
        );
        view.id.clone()
    };
    ensure!(
        !items
            .iter()
            .any(|p| p.id != id && p.name.eq_ignore_ascii_case(&name)),
        "代理名称已存在"
    );
    let mut config = Config {
        mode: view.mode,
        host: view.host.trim().to_string(),
        port: view.port,
        authenticate: view.authenticate,
        username: if view.authenticate {
            view.username
        } else {
            String::new()
        },
        password: password.to_string(),
    };
    if !config.authenticate {
        config.username.zeroize();
        config.password.zeroize();
    } else if config.password.is_empty() {
        let old = items
            .iter()
            .find(|p| p.id == id)
            .context("请输入代理密码")?;
        ensure!(
            old.mode == config.mode
                && old.host == config.host
                && old.port == config.port
                && old.authenticate
                && old.username == config.username,
            "代理地址、类型或用户名已更改，请重新输入代理密码"
        );
        config.password = old.password.clone();
    }
    config.validate()?;
    let stored = StoredProfile {
        id: id.clone(),
        name,
        mode: config.mode.clone(),
        host: config.host.clone(),
        port: config.port,
        authenticate: config.authenticate,
        username: config.username.clone(),
        password: config.password.clone(),
    };
    items.retain(|p| p.id != id);
    items.push(stored);
    items.sort_by_key(|a| a.name.to_lowercase());
    write_profiles(&tx, &items)?;
    tx.commit()?;
    Ok(id)
}
fn host_ids(db: &Connection) -> Result<HashSet<String>> {
    let raw: Option<String> = db
        .query_row("SELECT value FROM records WHERE kind='hosts'", [], |r| {
            r.get(0)
        })
        .optional()?;
    let Some(raw) = raw else {
        return Ok(HashSet::new());
    };
    let value: serde_json::Value =
        serde_json::from_str(&raw).map_err(|_| anyhow::anyhow!("主机数据格式无效"))?;
    let items = value.as_array().context("主机数据格式无效")?;
    ensure!(items.len() <= 10000, "主机数量过多");
    items
        .iter()
        .map(|item| {
            item.get("id")
                .and_then(serde_json::Value::as_str)
                .filter(|id| !id.is_empty() && id.len() <= 4096)
                .map(str::to_string)
                .context("主机数据格式无效")
        })
        .collect()
}
fn read_bindings(db: &Connection) -> Result<BTreeMap<String, String>> {
    let raw: Option<String> = db
        .query_row(
            "SELECT value FROM metadata WHERE key=?1",
            [BINDINGS_KEY],
            |r| r.get(0),
        )
        .optional()?;
    let Some(raw) = raw else {
        return Ok(BTreeMap::new());
    };
    let raw = Zeroizing::new(raw);
    ensure!(raw.len() <= 1024 * 1024, "主机代理设置过大");
    let map: BTreeMap<String, String> =
        serde_json::from_str(&raw).map_err(|_| anyhow::anyhow!("主机代理设置损坏"))?;
    ensure!(map.len() <= MAX_BINDINGS, "主机代理设置过多");
    for (host, binding) in &map {
        ensure!(
            !host.is_empty() && host.len() <= 4096 && binding.len() <= 128,
            "主机代理设置无效"
        );
    }
    Ok(map)
}
fn write_bindings(db: &Connection, bindings: &BTreeMap<String, String>) -> Result<()> {
    if bindings.is_empty() {
        db.execute("DELETE FROM metadata WHERE key=?1", [BINDINGS_KEY])?;
    } else {
        let raw = Zeroizing::new(serde_json::to_string(bindings)?);
        db.execute(
            "INSERT OR REPLACE INTO metadata(key,value) VALUES (?1,?2)",
            [BINDINGS_KEY, raw.as_str()],
        )?;
    }
    Ok(())
}
fn prune_bindings(bindings: &mut BTreeMap<String, String>, hosts: &HashSet<String>) {
    bindings.retain(|host, _| hosts.contains(host));
}
pub(crate) fn delete_profile(db: &mut Connection, id: &str) -> Result<()> {
    let tx = db.transaction()?;
    let mut items = stored_profiles(&tx)?;
    ensure!(
        items.iter().any(|p| p.id == id),
        "代理配置已被删除，请刷新列表"
    );
    let hosts = host_ids(&tx)?;
    let mut bindings = read_bindings(&tx)?;
    prune_bindings(&mut bindings, &hosts);
    let used = bindings.values().filter(|binding| *binding == id).count();
    ensure!(
        used == 0,
        "仍有 {used} 台主机使用此代理，请先修改这些主机的代理设置"
    );
    items.retain(|p| p.id != id);
    write_profiles(&tx, &items)?;
    write_bindings(&tx, &bindings)?;
    tx.commit()?;
    Ok(())
}
pub(crate) fn host_binding(db: &Connection, host_id: &str) -> Result<String> {
    ensure!(!host_id.is_empty(), "主机标识无效");
    Ok(read_bindings(db)?.remove(host_id).unwrap_or_default())
}
pub(crate) fn set_host_binding(db: &mut Connection, host_id: &str, binding: &str) -> Result<()> {
    ensure!(!host_id.is_empty(), "主机标识无效");
    let tx = db.transaction()?;
    let hosts = host_ids(&tx)?;
    ensure!(hosts.contains(host_id), "主机不存在，请刷新后重试");
    ensure!(
        binding.is_empty() || binding == "direct" || binding.len() <= 128,
        "主机代理设置无效"
    );
    if !binding.is_empty() && binding != "direct" {
        let items = stored_profiles(&tx)?;
        ensure!(
            items.iter().any(|p| p.id == binding),
            "所选代理不存在，请刷新列表"
        );
    }
    let mut bindings = read_bindings(&tx)?;
    prune_bindings(&mut bindings, &hosts);
    if binding.is_empty() {
        bindings.remove(host_id);
    } else {
        bindings.insert(host_id.to_string(), binding.to_string());
    }
    write_bindings(&tx, &bindings)?;
    tx.commit()?;
    Ok(())
}
pub(crate) fn profile_config(db: &Connection, id: &str) -> Result<Config> {
    stored_profiles(db)?
        .into_iter()
        .find(|p| p.id == id)
        .map(|p| p.config())
        .context("代理配置已被删除，请刷新列表")
}
pub(crate) fn draft_config(
    draft: crate::api::proxy::ProxyDraft,
    password: Zeroizing<String>,
) -> Result<Config> {
    let mut config = Config {
        mode: draft.mode,
        host: draft.host.trim().to_string(),
        port: draft.port,
        authenticate: draft.authenticate,
        username: if draft.authenticate {
            draft.username
        } else {
            String::new()
        },
        password: password.to_string(),
    };
    if !config.authenticate {
        config.username.zeroize();
        config.password.zeroize();
    } else {
        ensure!(!config.password.is_empty(), "请输入代理密码");
    }
    config.validate()?;
    Ok(config)
}
/// Resolves a host's first-hop proxy. An explicit named binding that no longer
/// exists fails closed; it never falls back to the inherited default or direct.
pub(crate) fn config_for_host(db: &Connection, host_id: Option<&str>) -> Result<Option<Config>> {
    let Some(host_id) = host_id.filter(|id| !id.is_empty()) else {
        return load(db);
    };
    let binding = read_bindings(db)?.remove(host_id).unwrap_or_default();
    if binding.is_empty() {
        return load(db);
    }
    if binding == "direct" {
        return Ok(None);
    }
    stored_profiles(db)?
        .into_iter()
        .find(|p| p.id == binding)
        .map(|p| p.config())
        .map(Some)
        .context("此设备缺少主机指定的代理配置，请重新选择代理")
}
#[derive(Clone, Debug)]
pub(crate) struct TestOutcome {
    pub tcp_ok: bool,
    pub authenticated: Option<bool>,
    pub target_ok: Option<bool>,
    pub message: String,
}
fn outcome(tcp_ok: bool, message: impl Into<String>) -> TestOutcome {
    TestOutcome {
        tcp_ok,
        authenticated: None,
        target_ok: None,
        message: message.into(),
    }
}
/// Tests TCP reachability, proxy authentication and target TCP reachability
/// separately. It never performs SSH authentication or sends SSH credentials.
pub(crate) async fn test(config: &Config, target: Option<(&str, u16)>) -> TestOutcome {
    if let Err(error) = config.validate() {
        return outcome(false, error.to_string());
    }
    let mut stream = match tokio::time::timeout(
        std::time::Duration::from_secs(8),
        TcpStream::connect((config.host.as_str(), config.port)),
    )
    .await
    {
        Ok(Ok(stream)) => stream,
        Ok(Err(_)) => return outcome(false, "无法连接代理服务器（TCP 不可达）"),
        Err(_) => return outcome(false, "连接代理服务器超时"),
    };
    let Some((host, port)) = target else {
        return TestOutcome {
            tcp_ok: true,
            authenticated: if config.authenticate {
                None
            } else {
                Some(true)
            },
            target_ok: None,
            message: if config.authenticate {
                "代理 TCP 可达；填写目标后可测试认证与目标连通".into()
            } else {
                "代理 TCP 可达；填写目标后可测试目标连通".into()
            },
        };
    };
    if let Err(error) = valid_host(host) {
        return outcome(true, error.to_string());
    }
    if port == 0 {
        return outcome(true, "目标端口必须在 1–65535 之间");
    }
    let result = tokio::time::timeout(std::time::Duration::from_secs(10), async {
        match config.mode.as_str() {
            "http" => http(&mut stream, host, port, config).await,
            "socks5" => socks5(&mut stream, host, port, config).await,
            _ => Err(anyhow::anyhow!("不支持的连接代理类型")),
        }
    })
    .await;
    match result {
        Ok(Ok(())) => TestOutcome {
            tcp_ok: true,
            authenticated: Some(true),
            target_ok: Some(true),
            message: "代理认证通过，目标 TCP 可以连接（未进行 SSH 认证）".into(),
        },
        Ok(Err(error)) => {
            let text = error.to_string();
            // Only an explicit proxy status proves authentication succeeded;
            // timeouts and malformed replies stay unconfirmed.
            let authenticated =
                !config.authenticate || (text.contains("拒绝连接") && !text.contains("认证失败"));
            TestOutcome {
                tcp_ok: true,
                authenticated: Some(authenticated),
                target_ok: Some(false),
                message: format!("目标不可达或代理拒绝连接：{text}"),
            }
        }
        Err(_) => TestOutcome {
            tcp_ok: true,
            authenticated: None,
            target_ok: None,
            message: "代理握手超时，未确认认证或目标连通".into(),
        },
    }
}

pub(crate) async fn connect(host: &str, port: u16, proxy: Option<&Config>) -> Result<TcpStream> {
    if let Some(config) = proxy {
        config.validate()?;
        valid_host(host)?;
        ensure!(port > 0, "目标端口无效");
        let mut stream = TcpStream::connect((config.host.as_str(), config.port))
            .await
            .context("无法连接代理服务器")?;
        match config.mode.as_str() {
            "http" => http(&mut stream, host, port, config).await?,
            "socks5" => socks5(&mut stream, host, port, config).await?,
            _ => bail!("不支持的连接代理类型"),
        }
        Ok(stream)
    } else {
        Ok(TcpStream::connect((host, port)).await?)
    }
}

async fn http(stream: &mut TcpStream, host: &str, port: u16, config: &Config) -> Result<()> {
    let authority = if matches!(host.parse::<IpAddr>(), Ok(IpAddr::V6(_))) {
        format!("[{host}]:{port}")
    } else {
        format!("{host}:{port}")
    };
    let mut request = Zeroizing::new(format!(
        "CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\n"
    ));
    if config.authenticate {
        let credentials = Zeroizing::new(format!("{}:{}", config.username, config.password));
        let encoded = Zeroizing::new(Base64::encode_string(credentials.as_bytes()));
        request.push_str("Proxy-Authorization: Basic ");
        request.push_str(&encoded);
        request.push_str("\r\n");
    }
    request.push_str("\r\n");
    stream
        .write_all(request.as_bytes())
        .await
        .context("发送 HTTP 代理请求失败")?;
    request.zeroize();
    // Read exactly to CRLFCRLF. A coalesced SSH banner must remain in the socket.
    // Cap the total response (including informational responses) at 16 KiB.
    let mut total = 0;
    loop {
        let mut header = Vec::new();
        while !header.ends_with(b"\r\n\r\n") {
            ensure!(total < 16384, "HTTP 代理响应头过大");
            header.push(stream.read_u8().await.context("HTTP 代理提前关闭连接")?);
            total += 1;
        }
        let end = header
            .windows(2)
            .position(|w| w == b"\r\n")
            .context("HTTP 代理状态行无效")?;
        let line = &header[..end];
        ensure!(
            line.len() >= 13
                && (line.starts_with(b"HTTP/1.1 ") || line.starts_with(b"HTTP/1.0 "))
                && line[9..12].iter().all(u8::is_ascii_digit)
                && line[12] == b' ',
            "HTTP 代理状态行无效"
        );
        let code = (line[9] - b'0') as u16 * 100
            + (line[10] - b'0') as u16 * 10
            + (line[11] - b'0') as u16;
        if (100..200).contains(&code) && code != 101 {
            continue;
        }
        if code == 407 {
            bail!("HTTP 代理认证失败，请检查用户名、密码及 Basic 认证支持");
        }
        ensure!(
            (200..300).contains(&code),
            "HTTP 代理拒绝连接（状态 {code}）"
        );
        return Ok(());
    }
}

async fn socks5(stream: &mut TcpStream, host: &str, port: u16, config: &Config) -> Result<()> {
    let method = if config.authenticate { 2 } else { 0 };
    // Offer only the configured method; never silently downgrade authentication.
    stream.write_all(&[5, 1, method]).await?;
    let mut selected = [0; 2];
    stream
        .read_exact(&mut selected)
        .await
        .context("SOCKS5 代理协商中断")?;
    ensure!(selected == [5, method], "SOCKS5 代理不支持所选认证方式");
    if config.authenticate {
        let mut auth = Zeroizing::new(vec![1, config.username.len() as u8]);
        auth.extend_from_slice(config.username.as_bytes());
        auth.push(config.password.len() as u8);
        auth.extend_from_slice(config.password.as_bytes());
        stream.write_all(&auth).await?;
        auth.zeroize();
        stream
            .read_exact(&mut selected)
            .await
            .context("SOCKS5 代理认证中断")?;
        ensure!(selected == [1, 0], "SOCKS5 代理认证失败");
    }
    let mut request = vec![5, 1, 0];
    match host.parse::<IpAddr>() {
        Ok(IpAddr::V4(ip)) => {
            request.push(1);
            request.extend_from_slice(&ip.octets());
        }
        Ok(IpAddr::V6(ip)) => {
            request.push(4);
            request.extend_from_slice(&ip.octets());
        }
        Err(_) => {
            request.extend_from_slice(&[3, host.len() as u8]);
            request.extend_from_slice(host.as_bytes());
        }
    }
    request.extend_from_slice(&port.to_be_bytes());
    stream.write_all(&request).await?;
    let mut reply = [0; 4];
    stream
        .read_exact(&mut reply)
        .await
        .context("SOCKS5 代理连接响应中断")?;
    ensure!(reply[0] == 5 && reply[2] == 0, "SOCKS5 代理连接响应无效");
    ensure!(reply[1] == 0, "SOCKS5 代理拒绝连接（状态 {}）", reply[1]);
    let len = match reply[3] {
        1 => 4,
        4 => 16,
        3 => {
            let len = stream.read_u8().await? as usize;
            ensure!(len > 0, "SOCKS5 代理返回空地址");
            len
        }
        _ => bail!("SOCKS5 代理返回未知地址类型"),
    };
    let mut discard = vec![0; len + 2];
    stream
        .read_exact(&mut discard)
        .await
        .context("SOCKS5 代理连接响应不完整")?;
    Ok(())
}

#[cfg(test)]
mod tests;
