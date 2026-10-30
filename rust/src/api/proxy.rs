//! Device-local proxy settings; credentials never leave the vault as readback.
use super::{client::ServerIdentity, vault::with_vault};
use crate::{proxy, session};
use anyhow::{ensure, Result};
use zeroize::Zeroizing;

#[derive(Clone, Debug)]
pub struct ProxySettings {
    /// direct, http, or socks5
    pub mode: String,
    pub host: String,
    pub port: u16,
    pub authenticate: bool,
    pub username: String,
    pub password_saved: bool,
}

#[derive(Clone, Debug)]
pub struct ProxyProfile {
    pub id: String,
    pub name: String,
    pub mode: String,
    pub host: String,
    pub port: u16,
    pub authenticate: bool,
    pub username: String,
    pub password_saved: bool,
}

#[derive(Clone, Debug)]
pub struct ProxyProfileInput {
    pub id: String,
    pub name: String,
    pub mode: String,
    pub host: String,
    pub port: u16,
    pub authenticate: bool,
    pub username: String,
}

#[derive(Clone, Debug)]
pub struct ProxyDraft {
    pub mode: String,
    pub host: String,
    pub port: u16,
    pub authenticate: bool,
    pub username: String,
}

#[derive(Clone, Debug)]
pub struct ProxyTestResult {
    pub tcp_ok: bool,
    pub authenticated: Option<bool>,
    pub target_ok: Option<bool>,
    pub message: String,
}

pub fn proxy_settings(token: String) -> Result<ProxySettings> {
    with_vault(&token, |db| proxy::settings(db))
}

pub fn proxy_save_settings(token: String, settings: ProxySettings, password: String) -> Result<()> {
    let password = Zeroizing::new(password);
    with_vault(&token, |db| proxy::save(db, settings, password))
}

pub fn proxy_profiles(token: String) -> Result<Vec<ProxyProfile>> {
    with_vault(&token, |db| proxy::profiles(db))
}

pub fn proxy_save_profile(
    token: String,
    profile: ProxyProfileInput,
    password: String,
) -> Result<String> {
    let password = Zeroizing::new(password);
    with_vault(&token, |db| proxy::save_profile(db, profile, password))
}

pub fn proxy_delete_profile(token: String, id: String) -> Result<()> {
    with_vault(&token, |db| proxy::delete_profile(db, &id))
}

pub fn proxy_host_binding(token: String, host_id: String) -> Result<String> {
    with_vault(&token, |db| proxy::host_binding(db, &host_id))
}

pub fn proxy_set_host_binding(token: String, host_id: String, binding: String) -> Result<()> {
    with_vault(&token, |db| proxy::set_host_binding(db, &host_id, &binding))
}

fn test_target(host: String, port: u16) -> Result<Option<(String, u16)>> {
    if host.trim().is_empty() && port == 0 {
        return Ok(None);
    }
    ensure!(
        !host.trim().is_empty() && port > 0,
        "目标地址和端口需同时填写"
    );
    Ok(Some((host.trim().to_string(), port)))
}

pub async fn proxy_test_global(
    token: String,
    target_host: String,
    target_port: u16,
) -> Result<ProxyTestResult> {
    let target = test_target(target_host, target_port)?;
    let config = with_vault(&token, |db| proxy::load(db))?
        .ok_or_else(|| anyhow::anyhow!("当前默认代理为直接连接"))?;
    let target_ref = target.as_ref().map(|(h, p)| (h.as_str(), *p));
    Ok(map_test(proxy::test(&config, target_ref).await))
}

pub async fn proxy_test_profile(
    token: String,
    id: String,
    target_host: String,
    target_port: u16,
) -> Result<ProxyTestResult> {
    let target = test_target(target_host, target_port)?;
    let config = with_vault(&token, |db| proxy::profile_config(db, &id))?;
    let target_ref = target.as_ref().map(|(h, p)| (h.as_str(), *p));
    Ok(map_test(proxy::test(&config, target_ref).await))
}

pub async fn proxy_test_draft(
    draft: ProxyDraft,
    password: String,
    target_host: String,
    target_port: u16,
) -> Result<ProxyTestResult> {
    let password = Zeroizing::new(password);
    let target = test_target(target_host, target_port)?;
    let config = proxy::draft_config(draft, password)?;
    let target_ref = target.as_ref().map(|(h, p)| (h.as_str(), *p));
    Ok(map_test(proxy::test(&config, target_ref).await))
}

fn map_test(value: proxy::TestOutcome) -> ProxyTestResult {
    ProxyTestResult {
        tcp_ok: value.tcp_ok,
        authenticated: value.authenticated,
        target_ok: value.target_ok,
        message: value.message,
    }
}

pub async fn probe_server_with_proxy(
    token: String,
    operation_id: String,
    host: String,
    port: u16,
) -> Result<ServerIdentity> {
    let config = with_vault(&token, |db| proxy::load(db))?;
    let (connection_id, fingerprint) =
        session::probe_hop(Some(operation_id), None, host, port, config).await?;
    if let Err(error) = with_vault(&token, |_| Ok(())) {
        session::disconnect(&connection_id).await?;
        return Err(error);
    }
    Ok(ServerIdentity {
        connection_id,
        fingerprint,
    })
}

/// The first hop of a saved route uses that hop's binding; an explicit named
/// binding that is missing on this device fails closed instead of connecting direct.
pub async fn probe_server_with_host_proxy(
    token: String,
    operation_id: String,
    host_id: String,
    host: String,
    port: u16,
) -> Result<ServerIdentity> {
    let config = with_vault(&token, |db| proxy::config_for_host(db, Some(&host_id)))?;
    let (connection_id, fingerprint) =
        session::probe_hop(Some(operation_id), None, host, port, config).await?;
    if let Err(error) = with_vault(&token, |_| Ok(())) {
        session::disconnect(&connection_id).await?;
        return Err(error);
    }
    Ok(ServerIdentity {
        connection_id,
        fingerprint,
    })
}

/// Every hop after the first is reached only through the previous transport.
/// A failed channel open never falls back to a direct socket.
pub async fn probe_server_through(
    token: String,
    operation_id: String,
    parent_connection_id: String,
    host: String,
    port: u16,
) -> Result<ServerIdentity> {
    with_vault(&token, |_| Ok(()))?;
    let (connection_id, fingerprint) = session::probe_hop(
        Some(operation_id),
        Some(parent_connection_id),
        host,
        port,
        None,
    )
    .await?;
    if let Err(error) = with_vault(&token, |_| Ok(())) {
        session::disconnect(&connection_id).await?;
        return Err(error);
    }
    Ok(ServerIdentity {
        connection_id,
        fingerprint,
    })
}

pub async fn cancel_probe(operation_id: String) {
    session::cancel_probe(&operation_id).await;
}
