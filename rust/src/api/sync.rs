use super::vault;
use crate::sync::service;
use anyhow::{Context, Result};

pub struct SyncSettings {
    pub configured: bool,
    pub owner: String,
    pub repository: String,
    pub branch: String,
    pub token_saved: bool,
    pub initialized: bool,
    pub recovery_confirmed: bool,
    pub pending: bool,
    pub revision: String,
}
pub fn sync_settings(token: String) -> Result<SyncSettings> {
    vault::with_vault(&token, service::settings)
}
pub fn sync_save_settings(
    token: String,
    owner: String,
    repository: String,
    branch: String,
    access_token: String,
) -> Result<()> {
    let secret = zeroize::Zeroizing::new(access_token);
    vault::with_vault(&token, |db| {
        service::save_config(db, owner, repository, branch, &secret)
    })
}
pub async fn sync_check(token: String) -> Result<String> {
    let mut lease = vault::lease(&token)?;
    let cancel = lease.cancelled.clone();
    let db = lease.db.as_mut().context("保险库连接不可用")?;
    tokio::select! { biased;
        _ = cancel.notified() => anyhow::bail!("仓库检查已取消"),
        result = service::check(db) => result,
    }
}
pub async fn sync_initialize(token: String, mode: String, secret: String) -> Result<String> {
    let secret = zeroize::Zeroizing::new(secret);
    let mut lease = vault::lease(&token)?;
    let cancel = lease.cancelled.clone();
    let db = lease.db.as_mut().context("保险库连接不可用")?;
    tokio::select! { biased;
        _ = cancel.notified() => anyhow::bail!("同步设置已取消"),
        result = service::initialize(db,&mode,&secret) => result,
    }
}
pub fn sync_confirm_recovery(token: String, code: String) -> Result<()> {
    let code = zeroize::Zeroizing::new(code);
    vault::with_vault(&token, |db| service::confirm(db, &code))
}
pub async fn sync_run(token: String) -> Result<String> {
    let mut lease = vault::lease(&token)?;
    let cancel = lease.cancelled.clone();
    let db = lease.db.as_mut().context("保险库连接不可用")?;
    tokio::select! { biased;
        _ = cancel.notified() => anyhow::bail!("同步已取消；待处理数据保留，下次同步会核对发布结果"),
        result = service::run(db) => result,
    }
}
pub fn sync_cancel(token: String) -> Result<()> {
    vault::cancel_sync(&token)
}

pub struct SyncConflictItem {
    pub kind: String,
    pub id: String,
    pub local_summary: String,
    pub remote_summary: String,
    pub local_deleted: bool,
    pub remote_deleted: bool,
    pub changed_fields: Vec<String>,
}
pub struct SyncConflictReview {
    pub id: String,
    pub items: Vec<SyncConflictItem>,
}
pub struct SyncConflictChoice {
    pub kind: String,
    pub id: String,
    pub side: String,
}
pub fn sync_conflicts(token: String) -> Result<Option<SyncConflictReview>> {
    vault::with_vault(&token, |db| crate::sync::state::conflict_review(db))
}
pub async fn sync_resolve(
    token: String,
    review_id: String,
    choices: Vec<SyncConflictChoice>,
) -> Result<String> {
    let mut lease = vault::lease(&token)?;
    let cancel = lease.cancelled.clone();
    let db = lease.db.as_mut().context("保险库连接不可用")?;
    tokio::select! { biased;
        _ = cancel.notified() => anyhow::bail!("冲突处理已取消；请检查同步状态后继续"),
        result = service::resolve(db,&review_id,&choices) => result,
    }
}

pub async fn sync_adopt_key(token: String, mode: String, secret: String) -> Result<String> {
    let secret = zeroize::Zeroizing::new(secret);
    let mut lease = vault::lease(&token)?;
    let cancel = lease.cancelled.clone();
    let db = lease.db.as_mut().context("保险库连接不可用")?;
    tokio::select! { biased;
        _ = cancel.notified() => anyhow::bail!("密钥接入已取消，请检查同步状态后重试"),
        result = service::adopt_key(db, &mode, &secret) => result,
    }
}

pub struct SyncRotationStatus {
    pub can_begin: bool,
    pub batch_id: String,
    pub recovery_confirmed: bool,
    pub can_discard: bool,
}
pub fn sync_rotation_status(token: String) -> Result<SyncRotationStatus> {
    vault::with_vault(&token, service::rotation_status)
}
pub async fn sync_begin_rotation(token: String, password: String) -> Result<String> {
    let secret = zeroize::Zeroizing::new(password);
    let mut lease = vault::lease(&token)?;
    let cancel = lease.cancelled.clone();
    let db = lease.db.as_mut().context("保险库连接不可用")?;
    tokio::select! { biased;
        _ = cancel.notified() => anyhow::bail!("轮换准备已中断，请重新打开检查状态"),
        result = service::begin_rotation(db, &secret) => result,
    }
}
pub fn sync_confirm_rotation(token: String, batch_id: String, code: String) -> Result<()> {
    let secret = zeroize::Zeroizing::new(code);
    vault::with_vault(&token, |db| {
        service::confirm_rotation(db, &batch_id, &secret)
    })
}
pub fn sync_discard_rotation(token: String, batch_id: String) -> Result<()> {
    vault::with_vault(&token, |db| service::discard_rotation(db, &batch_id))
}
pub async fn sync_publish_rotation(token: String, batch_id: String) -> Result<String> {
    let mut lease = vault::lease(&token)?;
    let cancel = lease.cancelled.clone();
    let db = lease.db.as_mut().context("保险库连接不可用")?;
    tokio::select! { biased;
        _ = cancel.notified() => anyhow::bail!("轮换发布已中断；批次保留，请恢复核对结果"),
        result = service::publish_rotation(db, &batch_id) => result,
    }
}

pub struct SyncScopeKey {
    pub kind: String,
    pub id: String,
}
pub struct SyncScopeItem {
    pub kind: String,
    pub id: String,
    pub summary: String,
    pub selected: bool,
    pub excluded: bool,
    pub published: bool,
}
pub struct SyncScopeView {
    pub revision: String,
    pub items: Vec<SyncScopeItem>,
    pub blocked_reason: String,
}
pub fn sync_scope(token: String, selection: Option<Vec<SyncScopeKey>>) -> Result<SyncScopeView> {
    vault::with_vault(&token, |db| crate::sync::scope::preview(db, selection))
}
pub fn sync_save_scope(
    token: String,
    revision: String,
    selection: Vec<SyncScopeKey>,
) -> Result<()> {
    vault::with_vault(&token, |db| {
        crate::sync::scope::save(db, &revision, selection)
    })
}

pub struct SyncDisconnectInfo {
    pub revision: String,
    pub target: String,
    pub initialized: bool,
    pub blocked_reason: String,
}
pub fn sync_disconnect_preview(token: String) -> Result<SyncDisconnectInfo> {
    vault::with_vault(&token, crate::sync::disconnect::preview)
}
pub fn sync_disconnect(token: String, revision: String, confirmation: String) -> Result<()> {
    vault::with_vault(&token, |db| {
        crate::sync::disconnect::disconnect(db, &revision, &confirmation)
    })
}
