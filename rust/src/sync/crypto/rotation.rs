//! Staged local key rotation. Transport must verify publication before activation.
use super::*;
use crate::sync::{outbox, state};
use rusqlite::TransactionBehavior;

const CANDIDATE: &str = "sync_key_rotation_v1";
const HISTORY: &str = "sync_key_history_v1";
const HISTORY_LIMIT: usize = 256 * 1024;
const MAX_HISTORY: usize = 16;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Candidate {
    version: u32,
    generation: u64,
    batch_id: String,
    previous_key_id: String,
    recovery_confirmed: bool,
    key: StoredKey,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct History {
    version: u32,
    keys: Vec<StoredKey>,
}
fn read<T: serde::de::DeserializeOwned>(
    db: &Connection,
    name: &str,
    limit: usize,
) -> Result<Option<T>> {
    let length: Option<i64> = db
        .query_row(
            "SELECT length(CAST(value AS BLOB)) FROM metadata WHERE key=?1",
            [name],
            |r| r.get(0),
        )
        .optional()?;
    let Some(length) = length else {
        return Ok(None);
    };
    ensure!(length >= 0 && length as usize <= limit, "密钥轮换记录过大");
    let json = Zeroizing::new(db.query_row::<String, _, _>(
        "SELECT value FROM metadata WHERE key=?1",
        [name],
        |r| r.get(0),
    )?);
    ensure!(json.len() <= limit, "密钥轮换记录过大");
    Ok(Some(
        serde_json::from_str(&json).map_err(|_| anyhow::anyhow!("密钥轮换记录损坏"))?,
    ))
}
fn write(db: &Connection, name: &str, value: &impl Serialize, limit: usize) -> Result<()> {
    let json = Zeroizing::new(serde_json::to_string(value)?);
    ensure!(json.len() <= limit, "密钥轮换记录过大");
    db.execute("INSERT INTO metadata(key,value) VALUES (?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value", params![name,json.as_str()])?;
    Ok(())
}
pub(in crate::sync) fn exists_in_transaction(db: &Connection) -> Result<bool> {
    Ok(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM metadata WHERE key=?1)",
        [CANDIDATE],
        |r| r.get(0),
    )?)
}
pub(in crate::sync) fn cancel_in_transaction(db: &Connection) -> Result<()> {
    db.execute("DELETE FROM metadata WHERE key=?1", [CANDIDATE])?;
    Ok(())
}
fn history(db: &Connection, active: &SyncKey) -> Result<History> {
    let h = read::<History>(db, HISTORY, HISTORY_LIMIT)?.unwrap_or(History {
        version: 1,
        keys: vec![],
    });
    ensure!(
        h.version == 1 && h.keys.len() <= MAX_HISTORY,
        "历史同步密钥版本或数量无效"
    );
    let mut ids = BTreeSet::from([active.id.clone()]);
    for saved in &h.keys {
        let key = saved.open()?;
        ensure!(
            key.space == active.space && ids.insert(key.id.clone()),
            "历史同步密钥空间或编号无效"
        );
    }
    Ok(h)
}
fn candidate_key(db: &Connection, c: &Candidate, active: &SyncKey) -> Result<SyncKey> {
    let s = state::load(db)?.context("同步状态不存在")?;
    let pending = s.pending().context("轮换记录缺少待处理批次")?;
    ensure!(
        c.version == 1
            && c.generation == s.generation()
            && c.batch_id == pending.id()
            && pending.needs_upload()
            && pending.is_key_rotation()
            && c.previous_key_id == active.id,
        "密钥轮换批次已变化"
    );
    let key = c.key.open()?;
    ensure!(
        key.space == active.space && key.id != active.id,
        "候选密钥空间或编号无效"
    );
    let h = history(db, active)?;
    ensure!(
        h.keys.len() < MAX_HISTORY && !h.keys.iter().any(|old| old.id == key.id),
        "历史密钥已满或候选编号重复"
    );
    Ok(key)
}
/// Returns the new recovery code once; caller must persist it offline and call
/// confirm_recovery before upload. Active key stays unchanged until read-back.
pub fn begin(db: &mut Connection, generation: u64, new_password: &str) -> Result<RecoveryCode> {
    let s = state::load(db)?.context("请先初始化同步状态")?;
    ensure!(
        s.generation() == generation && !s.has_pending(),
        "同步状态已变化或存在待处理批次"
    );
    let (active, _) = load(db)?.context("请先配置同步密钥")?;
    ensure!(
        !exists_in_transaction(db)? && !outbox::exists_in_transaction(db)?,
        "已有待处理轮换或发件箱"
    );
    ensure!(
        history(db, &active)?.keys.len() < MAX_HISTORY,
        "历史密钥已满，暂不允许继续轮换"
    );
    // Expensive KDF outside the write transaction; recheck all state afterwards.
    let (next, envelope, code) = create(active.space.clone(), new_password)?;
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let (current, _) = load(&tx)?.context("同步密钥不存在")?;
    ensure!(
        current.id == active.id
            && !exists_in_transaction(&tx)?
            && !outbox::exists_in_transaction(&tx)?,
        "同步密钥状态已变化"
    );
    ensure!(
        history(&tx, &current)?.keys.len() < MAX_HISTORY,
        "历史密钥已满"
    );
    let s = state::prepare_rotation_in_transaction(&tx, generation)?;
    let c = Candidate {
        version: 1,
        generation: s.generation(),
        batch_id: s.pending().context("轮换批次不存在")?.id().into(),
        previous_key_id: current.id.clone(),
        recovery_confirmed: false,
        key: StoredKey::from_key(&next, &envelope),
    };
    write(&tx, CANDIDATE, &c, KEY_LIMIT)?;
    tx.commit()?;
    Ok(code)
}
pub fn confirm_recovery(db: &mut Connection, generation: u64, recovery_code: &str) -> Result<()> {
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let (active, _) = load(&tx)?.context("同步密钥不存在")?;
    let mut c = read::<Candidate>(&tx, CANDIDATE, KEY_LIMIT)?.context("没有待处理轮换")?;
    ensure!(c.generation == generation, "密钥轮换状态已变化");
    let next = candidate_key(&tx, &c, &active)?;
    let recovered = unlock_recovery(&c.key.envelope, &active.space, recovery_code)?;
    ensure!(
        recovered.secret.as_ref() == next.secret.as_ref(),
        "恢复码与候选密钥不一致"
    );
    c.recovery_confirmed = true;
    write(&tx, CANDIDATE, &c, KEY_LIMIT)?;
    tx.commit()?;
    Ok(())
}
pub(in crate::sync) fn publication_key(db: &Connection) -> Result<(SyncKey, KeyEnvelope)> {
    let (active, envelope) = load(db)?.context("请先配置同步密钥")?;
    let Some(c) = read::<Candidate>(db, CANDIDATE, KEY_LIMIT)? else {
        ensure!(
            !state::load(db)?
                .context("同步状态不存在")?
                .pending()
                .is_some_and(|p| p.is_key_rotation()),
            "轮换候选密钥丢失，已阻止上传"
        );
        return Ok((active, envelope));
    };
    let key = candidate_key(db, &c, &active)?;
    ensure!(c.recovery_confirmed, "请先核验并保存新恢复码");
    Ok((key, c.key.envelope.clone()))
}
/// Must share the outbox acknowledgement transaction, after exact-byte validation.
pub(in crate::sync) fn activate_in_transaction(db: &Connection, batch_id: &str) -> Result<()> {
    let Some(c) = read::<Candidate>(db, CANDIDATE, KEY_LIMIT)? else {
        ensure!(
            !state::load(db)?
                .context("同步状态不存在")?
                .pending()
                .is_some_and(|p| p.is_key_rotation()),
            "轮换候选密钥丢失，已阻止确认"
        );
        return Ok(());
    };
    let (active, envelope) = load(db)?.context("同步密钥不存在")?;
    candidate_key(db, &c, &active)?;
    ensure!(
        c.batch_id == batch_id && c.recovery_confirmed,
        "轮换批次或恢复码状态不一致"
    );
    let mut h = history(db, &active)?;
    h.keys.push(StoredKey::from_key(&active, &envelope));
    write(db, HISTORY, &h, HISTORY_LIMIT)?;
    write(db, LOCAL_KEY, &c.key, KEY_LIMIT)?;
    cancel_in_transaction(db)?;
    Ok(())
}
/// Local historical reading only. Successful decryption is NOT authorization to
/// apply an older snapshot or accept a rollback from the network.
pub fn decrypt_retained(db: &Connection, bytes: &[u8]) -> Result<OpenedPacket> {
    ensure!(bytes.len() <= PACKET_LIMIT, "同步密文过大");
    let packet: Packet =
        serde_json::from_slice(bytes).map_err(|_| anyhow::anyhow!("同步密文格式无效"))?;
    let tx = db.unchecked_transaction()?;
    let (active, _) = load(&tx)?.context("同步密钥不存在")?;
    let opened = if packet.header.key_id == active.id {
        decrypt(bytes, &active)?
    } else {
        let h = history(&tx, &active)?;
        let old = h
            .keys
            .iter()
            .find(|key| key.id == packet.header.key_id)
            .context("没有对应历史密钥")?
            .open()?;
        decrypt(bytes, &old)?
    };
    tx.commit()?;
    Ok(opened)
}

#[cfg(test)]
mod tests;

/// The caller must authenticate the remote envelope/packet and verify repository
/// identity, ancestry and the latest revision before entering this transaction.
pub(in crate::sync) fn adopt_in_transaction(
    db: &Connection,
    previous_key_id: &str,
    next: &SyncKey,
    envelope: &KeyEnvelope,
) -> Result<()> {
    let (active, old_envelope) = load(db)?.context("同步密钥不存在")?;
    ensure!(active.id == previous_key_id, "本机同步密钥已变化，请重试");
    ensure!(
        next.space == active.space && next.id != active.id,
        "新密钥空间或编号无效"
    );
    verify_envelope(next, envelope)?;
    ensure!(
        !state::load(db)?.context("同步状态不存在")?.has_pending()
            && !exists_in_transaction(db)?
            && !outbox::exists_in_transaction(db)?
            && !crate::sync::github::journal::exists(db)?,
        "存在待处理发布或轮换，请先恢复原批次"
    );
    let mut h = history(db, &active)?;
    ensure!(
        h.keys.len() < MAX_HISTORY,
        "历史同步密钥已满，暂不能接入新密钥"
    );
    ensure!(
        !h.keys.iter().any(|k| k.id == next.id),
        "拒绝重新接入已淘汰的历史同步密钥"
    );
    h.keys.push(StoredKey::from_key(&active, &old_envelope));
    write(db, HISTORY, &h, HISTORY_LIMIT)?;
    write(
        db,
        LOCAL_KEY,
        &StoredKey::from_key(next, envelope),
        KEY_LIMIT,
    )?;
    Ok(())
}

/// Safe metadata for UI resumption; never returns the recovery code or keys.
pub(in crate::sync) fn status(db: &Connection) -> Result<Option<(String, bool)>> {
    let candidate = read::<Candidate>(db, CANDIDATE, KEY_LIMIT)?;
    let pending_rotation =
        state::load(db)?.is_some_and(|s| s.pending().is_some_and(|p| p.is_key_rotation()));
    let Some(c) = candidate else {
        ensure!(
            !pending_rotation,
            "轮换候选密钥丢失，请保留当前数据并检查备份"
        );
        return Ok(None);
    };
    let (active, _) = load(db)?.context("同步密钥不存在")?;
    candidate_key(db, &c, &active)?;
    Ok(Some((c.batch_id.clone(), c.recovery_confirmed)))
}
