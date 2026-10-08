//! User-facing manual sync orchestration. No plaintext credential read API.
use super::{crypto, github, state, *};
use crate::api::sync::SyncSettings;
use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};
const CONFIG: &str = "sync_account_v1";
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Config {
    version: u32,
    owner: String,
    repository: String,
    branch: String,
    access_token: String,
    recovery_confirmed: bool,
    repo_id: u64,
}
impl Drop for Config {
    fn drop(&mut self) {
        self.access_token.zeroize();
    }
}
impl Config {
    fn target(&self) -> Result<github::Target> {
        github::Target::new(
            self.owner.clone(),
            self.repository.clone(),
            self.branch.clone(),
        )
    }
    fn client(&self) -> Result<github::GitHub> {
        github::GitHub::new(self.target()?, &self.access_token)
    }
}
fn config(db: &Connection) -> Result<Option<Config>> {
    let size: Option<i64> = db
        .query_row(
            "SELECT length(CAST(value AS BLOB)) FROM metadata WHERE key=?1",
            [CONFIG],
            |r| r.get(0),
        )
        .optional()?;
    let Some(size) = size else { return Ok(None) };
    ensure!((0..=16384).contains(&size), "同步设置过大");
    let json = Zeroizing::new(db.query_row::<String, _, _>(
        "SELECT value FROM metadata WHERE key=?1",
        [CONFIG],
        |r| r.get(0),
    )?);
    ensure!(json.len() <= 16384, "同步设置过大");
    let c: Config = serde_json::from_str(&json).map_err(|_| anyhow::anyhow!("同步设置已损坏"))?;
    ensure!(c.version == 1, "不支持的同步设置版本");
    c.target()?;
    validate_token(&c.access_token)?;
    Ok(Some(c))
}
fn validate_token(token: &str) -> Result<()> {
    ensure!(
        !token.is_empty() && token.len() <= 4096 && token.bytes().all(|b| b.is_ascii_graphic()),
        "请输入有效的 GitHub 令牌"
    );
    Ok(())
}
fn save(db: &Connection, c: &Config) -> Result<()> {
    let json = Zeroizing::new(serde_json::to_string(c)?);
    db.execute("INSERT INTO metadata(key,value) VALUES (?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value",params![CONFIG,json.as_str()])?;
    Ok(())
}
pub fn settings(db: &mut Connection) -> Result<SyncSettings> {
    let c = config(db)?;
    let s = state::load(db)?;
    Ok(SyncSettings {
        configured: c.is_some(),
        owner: c.as_ref().map(|c| c.owner.clone()).unwrap_or_default(),
        repository: c.as_ref().map(|c| c.repository.clone()).unwrap_or_default(),
        branch: c
            .as_ref()
            .map(|c| c.branch.clone())
            .unwrap_or_else(|| "main".into()),
        token_saved: c.is_some(),
        initialized: s.is_some(),
        recovery_confirmed: c.as_ref().is_some_and(|c| c.recovery_confirmed),
        pending: s.as_ref().is_some_and(|s| s.has_pending()),
        revision: s
            .as_ref()
            .and_then(|s| s.remote_revision())
            .unwrap_or_default()
            .into(),
    })
}
pub fn save_config(
    db: &mut Connection,
    owner: String,
    repository: String,
    branch: String,
    access_token: &str,
) -> Result<()> {
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let old = config(&tx)?;
    let next = Config {
        version: 1,
        owner: owner.trim().to_ascii_lowercase(),
        repository: repository.trim().to_ascii_lowercase(),
        branch: branch.trim().into(),
        access_token: if access_token.is_empty() {
            old.as_ref()
                .context("首次设置需要 GitHub 令牌")?
                .access_token
                .clone()
        } else {
            access_token.into()
        },
        recovery_confirmed: old.as_ref().is_some_and(|c| c.recovery_confirmed),
        repo_id: old.as_ref().map(|c| c.repo_id).unwrap_or(0),
    };
    next.target()?;
    validate_token(&next.access_token)?;
    if state::load(&tx)?.is_some() {
        ensure!(
            old.as_ref().context("同步设置不存在")?.target()? == next.target()?,
            "同步空间已初始化，不能直接更换仓库或分支"
        );
    }
    save(&tx, &next)?;
    tx.commit()?;
    Ok(())
}
pub async fn check(db: &mut Connection) -> Result<String> {
    let c = config(db)?.context("请先保存仓库设置")?;
    c.client()?.check().await
}
pub async fn initialize(db: &mut Connection, mode: &str, secret: &str) -> Result<String> {
    let c = config(db)?.context("请先保存仓库设置")?;
    let client = c.client()?;
    initialize_with(db, mode, secret, &client).await
}
pub(super) async fn initialize_with(
    db: &mut Connection,
    mode: &str,
    secret: &str,
    client: &github::GitHub,
) -> Result<String> {
    ensure!(
        matches!(mode, "create" | "password" | "recovery"),
        "同步初始化方式无效"
    );
    let mut c = config(db)?.context("请先保存仓库设置")?;
    let id = client.repository(true).await?;
    let files = client.fetch(None).await?;
    ensure!(client.repository(true).await? == id, "仓库身份已变化");
    let (key, envelope, code) = if mode == "create" {
        ensure!(
            files.packet.is_none(),
            "仓库已有同步空间，请使用口令或恢复码接入"
        );
        let (key, envelope, code) = crypto::create(uuid::Uuid::new_v4().to_string(), secret)?;
        (key, envelope, Some(code))
    } else {
        let envelope =
            crypto::KeyEnvelope::decode(files.envelope.as_deref().context("仓库没有同步空间")?)?;
        let key = if mode == "password" {
            crypto::unlock_password(&envelope, envelope.space(), secret)?
        } else {
            crypto::unlock_recovery(&envelope, envelope.space(), secret)?
        };
        crypto::decrypt(files.packet.as_deref().context("仓库同步文件不完整")?, &key)?;
        (key, envelope, None)
    };
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    if let Some(s) = state::load(&tx)? {
        ensure!(
            mode == "create"
                && !c.recovery_confirmed
                && !s.has_pending()
                && s.remote_revision().is_none(),
            "同步空间已经初始化"
        );
        // Only an unpublished, unconfirmed setup may replace its lost recovery code.
        ensure!(
            !github::journal::exists(&tx)? && !super::outbox::exists_in_transaction(&tx)?,
            "存在待处理发布"
        );
        tx.execute(
            "DELETE FROM metadata WHERE key IN ('sync_state_v1','sync_key_v1')",
            [],
        )?;
    }
    state::initialize_in_transaction(&tx, key.space().into())?;
    crypto::install_in_transaction(&tx, &key, &envelope)?;
    github::journal::bind_in_transaction(&tx, c.target()?, id)?;
    c.repo_id = id;
    c.recovery_confirmed = mode != "create";
    save(&tx, &c)?;
    tx.commit()?;
    Ok(code
        .map(|code| code.expose().to_string())
        .unwrap_or_default())
}
pub fn confirm(db: &mut Connection, code: &str) -> Result<()> {
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let mut c = config(&tx)?.context("同步设置不存在")?;
    let (key, envelope) = crypto::load(&tx)?.context("请先创建同步空间")?;
    let restored = crypto::unlock_recovery(&envelope, key.space(), code)?;
    ensure!(restored.id() == key.id(), "恢复码与同步空间不一致");
    c.recovery_confirmed = true;
    save(&tx, &c)?;
    tx.commit()?;
    Ok(())
}
pub async fn run(db: &mut Connection) -> Result<String> {
    let c = config(db)?.context("请先保存仓库设置")?;
    let client = c.client()?;
    run_with(db, &client).await
}
pub(super) async fn run_with(db: &mut Connection, client: &github::GitHub) -> Result<String> {
    let c = config(db)?.context("请先保存仓库设置")?;
    ensure!(
        c.recovery_confirmed && c.repo_id > 0,
        "请先完成同步空间设置并核验恢复码"
    );
    let mut s = state::load(db)?.context("请先创建或接入同步空间")?;
    ensure!(
        client.repository(true).await? == c.repo_id,
        "GitHub 仓库身份已变化，已停止同步"
    );
    let recovered = s.has_pending()
        && client
            .recover_competition(db, s.generation(), c.repo_id)
            .await?;
    if recovered {
        s = state::load(db)?.context("同步状态不存在")?;
    }
    if s.has_pending() {
        let pending = s.pending().context("同步批次不存在")?;
        if pending.needs_upload() {
            client.publish(db, s.generation()).await?;
        } else {
            let rev = pending
                .expected_revision()
                .context("拉取批次缺少版本")?
                .to_owned();
            state::acknowledge(db, s.generation(), pending.id(), Some(rev.clone()), rev)?;
        }
        return Ok("已恢复并完成待处理同步；如有后续编辑，请再同步一次".into());
    }
    let remote = client.fetch(s.fetch_revision()).await?;
    ensure!(
        client.repository(true).await? == c.repo_id,
        "GitHub 仓库身份已变化，已停止同步"
    );
    let (key, envelope) = crypto::load(db)?.context("同步密钥不存在")?;
    let (snapshot, revision) = if let Some(packet) = remote.packet {
        let remote_envelope =
            crypto::KeyEnvelope::decode(remote.envelope.as_deref().context("远端密钥文件不存在")?)?;
        ensure!(
            remote_envelope.encode()? == envelope.encode()?,
            "远端同步密钥已变化，已保留本机数据；需完成换钥接入后同步"
        );
        (
            crypto::decrypt(&packet, &key)?.snapshot,
            Some(remote.revision),
        )
    } else {
        (Snapshot::empty(key.space().into())?, None)
    };
    let result = match state::prepare(db, s.generation(), &snapshot, revision)? {
        state::Preparation::Conflicts(plan) => Ok(format!(
            "发现 {} 项待选择记录、{} 项身份引用问题。双方数据已保留，请打开冲突处理选择保留版本。",
            plan.conflicts().len(),
            plan.missing_identities().len()
        )),
        state::Preparation::Ready(p) => finish(db, &p, client).await,
    }?;
    Ok(if recovered {
        format!("已核实旧批次未发布，保留本机修改并重新合并。{result}")
    } else {
        result
    })
}
async fn finish(
    db: &mut Connection,
    p: &state::PendingUpload,
    client: &github::GitHub,
) -> Result<String> {
    let g = state::load(db)?.context("同步状态不存在")?.generation();
    if p.needs_upload() {
        client.publish(db, g).await?;
    } else {
        let rev = p.expected_revision().context("远端版本不存在")?.to_owned();
        state::acknowledge(db, g, p.id(), Some(rev.clone()), rev)?;
    }
    Ok("同步完成，主机、文件夹、身份和命令片段已更新".into())
}
pub async fn resolve(
    db: &mut Connection,
    review_id: &str,
    choices: &[crate::api::sync::SyncConflictChoice],
) -> Result<String> {
    let c = config(db)?.context("请先保存仓库设置")?;
    resolve_with(db, review_id, choices, &c.client()?).await
}
pub(super) async fn resolve_with(
    db: &mut Connection,
    review_id: &str,
    choices: &[crate::api::sync::SyncConflictChoice],
    client: &github::GitHub,
) -> Result<String> {
    let c = config(db)?.context("请先保存仓库设置")?;
    ensure!(c.recovery_confirmed && c.repo_id > 0, "请先完成同步设置");
    let r = review::load(db)?.context("没有待处理冲突，请重新同步")?;
    ensure!(r.id == review_id, "冲突列表已更新，请重新打开");
    // Reject stale local data before network access, and again in the write transaction.
    state::conflict_review(db)?.context("冲突记录已失效")?;
    ensure!(
        client.repository(true).await? == c.repo_id,
        "GitHub 仓库身份已变化"
    );
    let remote = client.fetch(Some(&r.revision)).await?;
    ensure!(
        client.repository(true).await? == c.repo_id,
        "GitHub 仓库身份已变化"
    );
    ensure!(
        remote.revision == r.revision,
        "远端已变化，请关闭冲突窗口并重新同步后选择"
    );
    let (key, envelope) = crypto::load(db)?.context("同步密钥不存在")?;
    let remote_envelope =
        crypto::KeyEnvelope::decode(remote.envelope.as_deref().context("远端密钥文件不存在")?)?;
    ensure!(
        remote_envelope.encode()? == envelope.encode()?,
        "远端同步密钥已变化，请先完成换钥接入"
    );
    let snapshot = crypto::decrypt(
        remote.packet.as_deref().context("远端同步文件不存在")?,
        &key,
    )?
    .snapshot;
    ensure!(snapshot == r.remote, "远端冲突数据不一致，已停止写入");
    match state::prepare_resolved(db, review_id, choices)? {
        state::Preparation::Ready(p) => finish(db, &p, client).await,
        state::Preparation::Conflicts(_) => anyhow::bail!("仍有未解决冲突，已停止写入"),
    }
}

pub async fn adopt_key(db: &mut Connection, mode: &str, secret: &str) -> Result<String> {
    let c = config(db)?.context("请先保存仓库设置")?;
    adopt_key_with(db, mode, secret, &c.client()?).await
}
pub(super) async fn adopt_key_with(
    db: &mut Connection,
    mode: &str,
    secret: &str,
    client: &github::GitHub,
) -> Result<String> {
    ensure!(matches!(mode, "password" | "recovery"), "密钥接入方式无效");
    let c = config(db)?.context("同步设置不存在")?;
    ensure!(
        c.recovery_confirmed && c.repo_id > 0,
        "请先完成同步空间设置"
    );
    let s = state::load(db)?.context("请先接入同步空间")?;
    ensure!(
        !s.has_pending()
            && !github::journal::exists(db)?
            && !super::outbox::exists_in_transaction(db)?
            && !crypto::rotation::exists_in_transaction(db)?,
        "存在待处理发布或轮换，请先恢复原批次；不会丢弃结果未知的数据"
    );
    let (active, old_envelope) = crypto::load(db)?.context("同步密钥不存在")?;
    ensure!(
        client.repository(true).await? == c.repo_id,
        "GitHub 仓库身份已变化"
    );
    let remote = client.fetch(s.fetch_revision()).await?;
    let envelope =
        crypto::KeyEnvelope::decode(remote.envelope.as_deref().context("远端密钥文件不存在")?)?;
    let key = if mode == "password" {
        crypto::unlock_password(&envelope, s.space(), secret)?
    } else {
        crypto::unlock_recovery(&envelope, s.space(), secret)?
    };
    crypto::decrypt(
        remote.packet.as_deref().context("远端同步文件不存在")?,
        &key,
    )?;
    // Re-read after the KDF: never knowingly accept a superseded key or packet.
    let latest = client.fetch(Some(&remote.revision)).await?;
    ensure!(
        latest.revision == remote.revision
            && latest.packet == remote.packet
            && latest.envelope == remote.envelope,
        "远端在验证期间已变化，请重新接入新密钥"
    );
    ensure!(
        client.repository(true).await? == c.repo_id,
        "GitHub 仓库身份已变化"
    );
    if key.id() == active.id() {
        ensure!(
            envelope.encode()? == old_envelope.encode()?,
            "相同密钥编号对应不同信封，已停止接入"
        );
        return Ok("本机已使用当前同步密钥，可以点击立即同步".into());
    }
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let current = config(&tx)?.context("同步设置不存在")?;
    ensure!(
        current.repo_id == c.repo_id
            && current.target()? == c.target()?
            && current.recovery_confirmed,
        "同步设置已变化"
    );
    crypto::rotation::adopt_in_transaction(&tx, active.id(), &key, &envelope)?;
    state::adopt_key_revision_in_transaction(&tx, s.generation(), remote.revision)?;
    tx.commit()?;
    Ok("已接入新的同步密钥，本机数据已保留。点击立即同步以合并；原冲突列表将重新核对。".into())
}

pub fn rotation_status(db: &mut Connection) -> Result<crate::api::sync::SyncRotationStatus> {
    let candidate = crypto::rotation::status(db)?;
    let s = state::load(db)?;
    let c = config(db)?;
    Ok(crate::api::sync::SyncRotationStatus {
        can_begin: candidate.is_none()
            && c.as_ref().is_some_and(|c| c.recovery_confirmed)
            && s.as_ref().is_some_and(|s| {
                !s.has_pending()
                    && s.remote_revision().is_some()
                    && s.fetch_revision() == s.remote_revision()
            })
            && !github::journal::exists(db)?
            && !super::outbox::exists_in_transaction(db)?
            && review::load(db)?.is_none(),
        batch_id: candidate.as_ref().map(|c| c.0.clone()).unwrap_or_default(),
        recovery_confirmed: candidate.as_ref().is_some_and(|c| c.1),
        can_discard: candidate.is_some() && github::journal::can_discard_unpublished(db)?,
    })
}
pub async fn begin_rotation(db: &mut Connection, password: &str) -> Result<String> {
    let c = config(db)?.context("同步设置不存在")?;
    begin_rotation_with(db, password, &c.client()?).await
}
pub(super) async fn begin_rotation_with(
    db: &mut Connection,
    password: &str,
    client: &github::GitHub,
) -> Result<String> {
    ensure!(
        rotation_status(db)?.can_begin,
        "请先完成普通同步、冲突处理或现有轮换"
    );
    let c = config(db)?.context("同步设置不存在")?;
    let s = state::load(db)?.context("同步状态不存在")?;
    ensure!(
        client.repository(true).await? == c.repo_id,
        "GitHub 仓库身份已变化"
    );
    let remote = client.fetch(s.fetch_revision()).await?;
    ensure!(
        Some(remote.revision.as_str()) == s.remote_revision(),
        "远端已更新，请先完成普通同步再轮换"
    );
    let (key, envelope) = crypto::load(db)?.context("同步密钥不存在")?;
    ensure!(
        remote.envelope.as_deref() == Some(envelope.encode()?.as_slice()),
        "远端密钥已变化，请先接入新密钥"
    );
    let opened = crypto::decrypt(
        remote.packet.as_deref().context("远端同步文件不存在")?,
        &key,
    )?;
    ensure!(
        &opened.snapshot == s.base_snapshot(),
        "远端快照与已确认基线不一致，已阻止轮换"
    );
    ensure!(
        client.repository(true).await? == c.repo_id,
        "GitHub 仓库身份已变化"
    );
    Ok(crypto::rotation::begin(db, s.generation(), password)?
        .expose()
        .into())
}
fn rotation_batch(db: &Connection, batch_id: &str) -> Result<u64> {
    let status = crypto::rotation::status(db)?.context("没有待处理轮换")?;
    ensure!(status.0 == batch_id, "轮换批次已变化，请重新打开");
    Ok(state::load(db)?.context("同步状态不存在")?.generation())
}
pub fn confirm_rotation(db: &mut Connection, batch_id: &str, code: &str) -> Result<()> {
    let g = rotation_batch(db, batch_id)?;
    crypto::rotation::confirm_recovery(db, g, code)
}
pub fn discard_rotation(db: &mut Connection, batch_id: &str) -> Result<()> {
    rotation_batch(db, batch_id)?;
    github::journal::discard_rotation(db, batch_id)
}
pub async fn publish_rotation(db: &mut Connection, batch_id: &str) -> Result<String> {
    let c = config(db)?.context("同步设置不存在")?;
    publish_rotation_with(db, batch_id, &c.client()?).await
}
pub(super) async fn publish_rotation_with(
    db: &mut Connection,
    batch_id: &str,
    client: &github::GitHub,
) -> Result<String> {
    rotation_batch(db, batch_id)?;
    ensure!(
        crypto::rotation::status(db)?.is_some_and(|c| c.1),
        "请先核验新恢复码"
    );
    run_with(db, client).await?;
    Ok("密钥轮换已发布并确认。其他设备需用新口令或恢复码接入；本机后续修改请继续普通同步。".into())
}
