//! Durable encrypted delivery. Remote provenance/ancestry belongs to transport;
//! these APIs only verify that read-back bytes match the staged publication.
use super::{crypto, state, *};
use base64ct::{Base64, Encoding};
use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};

const OUTBOX: &str = "sync_outbox_v1";
const RECEIPT: &str = "sync_delivery_receipt_v1";
const LIMIT: usize = 32 * 1024 * 1024;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Upload {
    version: u32,
    generation: u64,
    batch_id: String,
    packet: String,
    envelope: String,
}
impl Upload {
    pub fn generation(&self) -> u64 {
        self.generation
    }
    pub fn batch_id(&self) -> &str {
        &self.batch_id
    }
    pub fn packet(&self) -> &[u8] {
        self.packet.as_bytes()
    }
    pub fn envelope(&self) -> &[u8] {
        self.envelope.as_bytes()
    }
}
#[derive(PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Receipt {
    version: u32,
    generation: u64,
    batch_id: String,
    // JSON null must be explicit, never silently interpret missing as initial upload.
    #[serde(deserialize_with = "required_parent")]
    parent: Option<String>,
    revision: String,
    packet_digest: String,
    envelope_digest: String,
}
fn required_parent<'de, D: serde::Deserializer<'de>>(
    d: D,
) -> std::result::Result<Option<String>, D::Error> {
    Option::deserialize(d)
}
fn read<T: serde::de::DeserializeOwned>(
    db: &Connection,
    key: &str,
    limit: usize,
) -> Result<Option<T>> {
    let length: Option<i64> = db
        .query_row(
            "SELECT length(CAST(value AS BLOB)) FROM metadata WHERE key=?1",
            [key],
            |r| r.get(0),
        )
        .optional()?;
    let Some(length) = length else {
        return Ok(None);
    };
    ensure!(
        length >= 0 && length as usize <= limit,
        "同步发件箱记录过大"
    );
    let bytes: String = db.query_row("SELECT value FROM metadata WHERE key=?1", [key], |r| {
        r.get(0)
    })?;
    ensure!(bytes.len() <= limit, "同步发件箱记录过大");
    Ok(Some(
        serde_json::from_str(&bytes).map_err(|_| anyhow::anyhow!("同步发件箱记录损坏"))?,
    ))
}
fn write(db: &Connection, key: &str, value: &impl Serialize, limit: usize) -> Result<()> {
    let bytes = serde_json::to_string(value)?;
    ensure!(bytes.len() <= limit, "同步发件箱记录过大");
    db.execute("INSERT INTO metadata(key,value) VALUES (?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value", params![key,bytes])?;
    Ok(())
}
pub(super) fn exists_in_transaction(db: &Connection) -> Result<bool> {
    Ok(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM metadata WHERE key=?1)",
        [OUTBOX],
        |r| r.get(0),
    )?)
}
pub(super) fn clear_in_transaction(db: &Connection) -> Result<()> {
    db.execute("DELETE FROM metadata WHERE key=?1", [OUTBOX])?;
    Ok(())
}
fn validate(db: &Connection, upload: &Upload, s: &state::State) -> Result<()> {
    ensure!(
        upload.version == 1 && upload.generation == s.generation(),
        "同步发件箱版本已变化"
    );
    let pending = s.pending().context("发件箱没有对应待处理批次")?;
    ensure!(
        pending.needs_upload() && upload.batch_id == pending.id(),
        "发件箱与待上传批次不一致"
    );
    let (key, envelope) = crypto::rotation::publication_key(db)?;
    ensure!(
        upload.envelope() == envelope.encode()?,
        "发件箱密钥信封已变化"
    );
    let opened = crypto::decrypt(upload.packet(), &key)?;
    ensure!(
        opened.batch_id == pending.id()
            && opened.parent.as_deref() == pending.expected_revision()
            && opened.snapshot == *pending.snapshot(),
        "发件箱密文与待上传批次不一致"
    );
    Ok(())
}
/// Creates once and returns the same bytes after retries/reopen. A failure does
/// not emit upload bytes or replace a damaged/stale entry. Current privacy rules
/// are checked even when returning existing ciphertext.
pub fn stage(db: &mut Connection, generation: u64) -> Result<Upload> {
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let s = state::load(&tx)?.context("请先初始化同步状态")?;
    ensure!(s.generation() == generation, "同步状态已变化，请重新读取");
    let pending = state::pending_in_transaction(&tx)?.context("没有待上传批次")?;
    ensure!(pending.needs_upload(), "该批次只需确认拉取，无需上传");
    let upload = if let Some(upload) = read::<Upload>(&tx, OUTBOX, LIMIT)? {
        validate(&tx, &upload, &s)?;
        upload
    } else {
        let (key, envelope) = crypto::rotation::publication_key(&tx)?;
        let packet = crypto::encrypt(
            pending.snapshot(),
            &key,
            pending.id().into(),
            pending.expected_revision().map(str::to_owned),
        )?;
        let upload = Upload {
            version: 1,
            generation,
            batch_id: pending.id().into(),
            packet: String::from_utf8(packet)?,
            envelope: String::from_utf8(envelope.encode()?)?,
        };
        write(&tx, OUTBOX, &upload, LIMIT)?;
        upload
    };
    tx.commit()?;
    Ok(upload)
}
/// Read for remote-result verification only; must not send these bytes without
/// stage() rechecking current privacy rules.
pub(super) fn restore_for_confirmation(db: &Connection, generation: u64) -> Result<Upload> {
    let tx = db.unchecked_transaction()?;
    let s = state::load(&tx)?.context("同步状态不存在")?;
    ensure!(s.generation() == generation, "同步状态已变化");
    let upload = read::<Upload>(&tx, OUTBOX, LIMIT)?.context("发件箱不存在")?;
    validate(&tx, &upload, &s)?;
    tx.commit()?;
    Ok(upload)
}
fn digest(bytes: &[u8]) -> String {
    Base64::encode_string(ring::digest::digest(&ring::digest::SHA256, bytes).as_ref())
}
/// Transport must fetch both files from the SAME verified commit, check its
/// parent/branch, and pass that commit's revision. Matching bytes alone are NOT
/// proof of publication. Does not overwrite user edits made after staging.
/// Do not recheck privacy here: a remotely accepted batch must be recorded even
/// if local dependencies changed while the request was in flight.
pub fn acknowledge_published(
    db: &mut Connection,
    generation: u64,
    batch_id: &str,
    parent: Option<String>,
    revision: String,
    packet: &[u8],
    envelope: &[u8],
) -> Result<state::State> {
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    ensure!(
        !super::github::journal::exists(&tx)?,
        "请通过 GitHub 发布结果核对入口确认"
    );
    let s = acknowledge_in_transaction(
        &tx, generation, batch_id, parent, revision, packet, envelope,
    )?;
    tx.commit()?;
    Ok(s)
}
pub(super) fn acknowledge_in_transaction(
    db: &Connection,
    generation: u64,
    batch_id: &str,
    parent: Option<String>,
    revision: String,
    packet: &[u8],
    envelope: &[u8],
) -> Result<state::State> {
    ensure!(
        packet.len() <= LIMIT && envelope.len() <= 16 * 1024,
        "远端同步内容过大"
    );
    let receipt = Receipt {
        version: 1,
        generation,
        batch_id: batch_id.into(),
        parent,
        revision,
        packet_digest: digest(packet),
        envelope_digest: digest(envelope),
    };
    if read::<Receipt>(db, RECEIPT, 4096)?.as_ref() == Some(&receipt) {
        let s = state::acknowledge_in_transaction(
            db,
            generation,
            batch_id,
            receipt.parent,
            receipt.revision,
        )?;
        return Ok(s);
    }
    let s = state::load(db)?.context("请先初始化同步状态")?;
    ensure!(s.generation() == generation, "同步状态已变化，请重新读取");
    let upload = read::<Upload>(db, OUTBOX, LIMIT)?.context("没有已持久化的上传密文")?;
    validate(db, &upload, &s)?;
    ensure!(
        upload.batch_id == batch_id && upload.packet() == packet && upload.envelope() == envelope,
        "远端内容与发件箱不一致，已保留待处理批次"
    );
    crypto::rotation::activate_in_transaction(db, batch_id)?;
    let s = state::acknowledge_in_transaction(
        db,
        generation,
        batch_id,
        receipt.parent.clone(),
        receipt.revision.clone(),
    )?;
    write(db, RECEIPT, &receipt, 4096)?;
    Ok(s)
}

#[cfg(test)]
mod tests;
