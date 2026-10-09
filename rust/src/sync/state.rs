//! Durable local orchestration inside SQLCipher. No network or plaintext export API.
use super::*;
use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};

const STATE_KEY: &str = "sync_state_v1";
const RETAINED_POLICY: &str = "sync_local_policy_v1";
const STATE_LIMIT: usize = 64 * 1024 * 1024;

fn required_option<'de, D, T>(deserializer: D) -> std::result::Result<Option<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de>,
{
    Option::<T>::deserialize(deserializer)
}

#[derive(Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Policy {
    local_only: BTreeSet<Key>,
}
impl Policy {
    pub fn new(local_only: BTreeSet<Key>) -> Result<Self> {
        let policy = Self { local_only };
        policy.validate()?;
        Ok(policy)
    }
    pub fn local_only(&self) -> &BTreeSet<Key> {
        &self.local_only
    }
    fn validate(&self) -> Result<()> {
        ensure!(self.local_only.len() <= MAX_RECORDS, "仅本机规则过多");
        for key in &self.local_only {
            ensure!(key.kind != Kind::Folders, "暂不支持单独排除文件夹树");
            ensure!(
                !key.id.is_empty() && key.id.len() <= 4096,
                "仅本机记录 ID 无效"
            );
        }
        Ok(())
    }
    pub(super) fn excluded(&self, snapshots: &[&Snapshot]) -> BTreeSet<Key> {
        let mut edges = BTreeMap::<Key, BTreeSet<Key>>::new();
        for record in snapshots.iter().flat_map(|s| &s.records) {
            if record.key.kind != Kind::Host {
                continue;
            }
            let Some(id) = record
                .value
                .as_ref()
                .and_then(|v| v.get("identityId"))
                .and_then(Value::as_str)
                .filter(|id| !id.is_empty())
            else {
                continue;
            };
            let identity = Key {
                kind: Kind::Identity,
                id: id.into(),
            };
            edges
                .entry(record.key.clone())
                .or_default()
                .insert(identity.clone());
            edges
                .entry(identity)
                .or_default()
                .insert(record.key.clone());
        }
        let mut excluded = self.local_only.clone();
        let mut queue: std::collections::VecDeque<_> = excluded.iter().cloned().collect();
        while let Some(key) = queue.pop_front() {
            if let Some(neighbors) = edges.get(&key) {
                for neighbor in neighbors {
                    if excluded.insert(neighbor.clone()) {
                        queue.push_back(neighbor.clone());
                    }
                }
            }
        }
        excluded
    }
}

pub(super) fn retained_policy(db: &Connection) -> Result<Policy> {
    let len: Option<i64> = db
        .query_row(
            "SELECT length(CAST(value AS BLOB)) FROM metadata WHERE key=?1",
            [RETAINED_POLICY],
            |r| r.get(0),
        )
        .optional()?;
    let Some(len) = len else {
        return Ok(Policy::default());
    };
    ensure!((0..=MAX_BYTES as i64).contains(&len), "仅本机规则过大");
    let value: String = db.query_row(
        "SELECT value FROM metadata WHERE key=?1",
        [RETAINED_POLICY],
        |r| r.get(0),
    )?;
    let policy: Policy =
        serde_json::from_str(&value).map_err(|_| anyhow::anyhow!("仅本机规则已损坏"))?;
    policy.validate()?;
    Ok(policy)
}
pub(super) fn retain_policy(db: &Connection, policy: &Policy) -> Result<()> {
    policy.validate()?;
    let value = serde_json::to_string(policy)?;
    ensure!(value.len() <= MAX_BYTES, "仅本机规则过大");
    db.execute("INSERT INTO metadata(key,value) VALUES (?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value", params![RETAINED_POLICY,value])?;
    Ok(())
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PendingUpload {
    id: String,
    #[serde(deserialize_with = "required_option")]
    expected_revision: Option<String>,
    needs_upload: bool,
    #[serde(default)] // Existing v1 batches predate rotation and are ordinary uploads.
    key_rotation: bool,
    snapshot: Snapshot,
}
impl PendingUpload {
    pub fn id(&self) -> &str {
        &self.id
    }
    pub fn expected_revision(&self) -> Option<&str> {
        self.expected_revision.as_deref()
    }
    pub(super) fn is_key_rotation(&self) -> bool {
        self.key_rotation
    }
    pub fn needs_upload(&self) -> bool {
        self.needs_upload
    }
    /// Plaintext memory. Transport must use the encrypted outbox before upload.
    pub fn snapshot(&self) -> &Snapshot {
        &self.snapshot
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Receipt {
    pending_id: String,
    #[serde(deserialize_with = "required_option")]
    parent: Option<String>,
    revision: String,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct State {
    version: u32,
    device: String,
    generation: u64,
    base: Snapshot,
    local: Snapshot,
    #[serde(deserialize_with = "required_option")]
    remote_revision: Option<String>,
    // A newly adopted key is pinned before its snapshot has been merged. Keep
    // the old baseline intact, but never fetch history older than this commit.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    key_revision: Option<String>,
    policy: Policy,
    #[serde(deserialize_with = "required_option")]
    pending: Option<PendingUpload>,
    #[serde(deserialize_with = "required_option")]
    last_receipt: Option<Receipt>,
}
impl State {
    pub fn generation(&self) -> u64 {
        self.generation
    }
    pub(in crate::sync) fn base_snapshot(&self) -> &Snapshot {
        &self.base
    }
    pub(super) fn local_snapshot(&self) -> &Snapshot {
        &self.local
    }
    pub fn device(&self) -> &str {
        &self.device
    }
    pub fn space(&self) -> &str {
        &self.base.space
    }
    pub fn remote_revision(&self) -> Option<&str> {
        self.remote_revision.as_deref()
    }
    pub(in crate::sync) fn fetch_revision(&self) -> Option<&str> {
        self.key_revision.as_deref().or(self.remote_revision())
    }
    pub(super) fn pending(&self) -> Option<&PendingUpload> {
        self.pending.as_ref()
    }
    pub fn has_pending(&self) -> bool {
        self.pending.is_some()
    }
    pub fn policy(&self) -> &Policy {
        &self.policy
    }
    fn validate(&self) -> Result<()> {
        ensure!(self.version == 1, "不支持的同步状态版本");
        uuid::Uuid::parse_str(&self.device).context("同步设备 ID 无效")?;
        self.policy.validate()?;
        self.base.validate()?;
        self.local.validate()?;
        ensure!(self.base.space == self.local.space, "同步状态空间不一致");
        check_revision(self.remote_revision.as_deref())?;
        check_revision(self.key_revision.as_deref())?;
        if let Some(p) = &self.pending {
            uuid::Uuid::parse_str(&p.id).context("待上传批次无效")?;
            check_revision(p.expected_revision.as_deref())?;
            ensure!(
                p.needs_upload || p.expected_revision.is_some(),
                "拉取检查点缺少远端版本"
            );
            ensure!(
                !p.key_rotation
                    || (p.needs_upload && p.expected_revision.is_some() && p.snapshot == self.base),
                "轮换快照与已确认基线不一致"
            );
            p.snapshot.validate()?;
            ensure!(p.snapshot == self.local, "待上传批次与本机检查点不一致");
            ensure!(
                p.expected_revision == self.remote_revision,
                "待上传批次的远端基线不一致"
            );
            ensure!(
                p.needs_upload || p.snapshot == self.base,
                "拉取批次与远端快照不一致"
            );
        }
        if let Some(r) = &self.last_receipt {
            uuid::Uuid::parse_str(&r.pending_id).context("同步回执无效")?;
            check_revision(r.parent.as_deref())?;
            check_revision(Some(&r.revision))?;
        }
        Ok(())
    }
    fn advance(&mut self) -> Result<()> {
        self.generation = self
            .generation
            .checked_add(1)
            .context("同步状态版本已耗尽")?;
        Ok(())
    }
}
fn check_revision(revision: Option<&str>) -> Result<()> {
    if let Some(id) = revision {
        ensure!(
            [40, 64].contains(&id.len()) && id.bytes().all(|c| c.is_ascii_hexdigit()),
            "远端提交版本无效"
        );
    }
    Ok(())
}
/// Read only, including across lock/reopen. Secrets remain in encrypted metadata.
pub fn load(db: &Connection) -> Result<Option<State>> {
    let length: Option<i64> = db
        .query_row(
            "SELECT length(CAST(value AS BLOB)) FROM metadata WHERE key=?1",
            [STATE_KEY],
            |r| r.get(0),
        )
        .optional()?;
    let Some(length) = length else {
        return Ok(None);
    };
    ensure!(
        length >= 0 && length as usize <= STATE_LIMIT,
        "同步状态超过容量限制"
    );
    let json = Zeroizing::new(db.query_row::<String, _, _>(
        "SELECT value FROM metadata WHERE key=?1",
        [STATE_KEY],
        |r| r.get(0),
    )?);
    ensure!(json.len() <= STATE_LIMIT, "同步状态超过容量限制");
    let state: State =
        serde_json::from_str(&json).map_err(|_| anyhow::anyhow!("同步状态损坏或格式无效"))?;
    state.validate()?;
    Ok(Some(state))
}
fn save(db: &Connection, state: &State) -> Result<()> {
    state.validate()?;
    let json = Zeroizing::new(serde_json::to_string(state)?);
    ensure!(json.len() <= STATE_LIMIT, "同步状态超过容量限制");
    db.execute("INSERT INTO metadata(key,value) VALUES (?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value", params![STATE_KEY, json.as_str()])?;
    Ok(())
}
fn checked(db: &Connection, generation: u64) -> Result<State> {
    let state = load(db)?.context("请先初始化同步状态")?;
    ensure!(state.generation == generation, "同步状态已变化，请重新读取");
    Ok(state)
}
pub fn initialize(db: &mut Connection, space: String) -> Result<State> {
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let state = initialize_in_transaction(&tx, space)?;
    tx.commit()?;
    Ok(state)
}
pub(super) fn initialize_in_transaction(db: &Connection, space: String) -> Result<State> {
    let base = Snapshot::empty(space)?;
    if let Some(state) = load(db)? {
        ensure!(
            state.base.space == base.space,
            "当前保险库已绑定其他同步空间"
        );
        return Ok(state);
    }
    let state = State {
        version: 1,
        device: uuid::Uuid::new_v4().to_string(),
        generation: 0,
        local: base.clone(),
        base,
        remote_revision: None,
        key_revision: None,
        policy: retained_policy(db)?,
        pending: None,
        last_receipt: None,
    };
    save(db, &state)?;
    Ok(state)
}
pub fn set_policy(db: &mut Connection, generation: u64, policy: Policy) -> Result<State> {
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let state = set_policy_in_transaction(&tx, generation, policy)?;
    tx.commit()?;
    Ok(state)
}
pub(super) fn validate_policy_change(
    state: &State,
    full: &Snapshot,
    policy: &Policy,
) -> Result<BTreeSet<Key>> {
    policy.validate()?;
    ensure!(
        !state.has_pending(),
        "请先完成待处理同步或轮换，再修改仅本机规则"
    );
    let excluded = policy.excluded(&[full, &state.base, &state.local]);
    ensure!(
        !state
            .base
            .records
            .iter()
            .any(|r| r.value.is_some() && excluded.contains(&r.key)),
        "已有同步数据不能直接改为仅本机；需要先完成远端撤回流程"
    );
    Ok(excluded)
}
pub(super) fn set_policy_in_transaction(
    db: &Connection,
    generation: u64,
    policy: Policy,
) -> Result<State> {
    let mut state = checked(db, generation)?;
    let full = vault::capture_in_transaction(db, &state.local, &state.device)?;
    validate_policy_change(&state, &full, &policy)?;
    retain_policy(db, &policy)?;
    state.policy = policy;
    state.advance()?;
    save(db, &state)?;
    Ok(state)
}

pub enum Preparation {
    Ready(PendingUpload),
    Conflicts(MergePlan),
}
/// Applies incoming data and persists the exact outgoing batch in ONE transaction.
/// The baseline advances only to the verified remote input, not the outgoing
/// candidate. acknowledge() accepts the candidate after a verified publication.
pub fn prepare(
    db: &mut Connection,
    generation: u64,
    remote: &Snapshot,
    remote_revision: Option<String>,
) -> Result<Preparation> {
    prepare_inner(db, generation, remote, remote_revision, None)
}
pub(super) fn prepare_resolved(
    db: &mut Connection,
    review_id: &str,
    choices: &[crate::api::sync::SyncConflictChoice],
) -> Result<Preparation> {
    let r = review::load(db)?.context("没有待处理冲突，请重新同步")?;
    ensure!(r.id == review_id, "冲突列表已更新，请重新打开");
    prepare_inner(
        db,
        r.generation,
        &r.remote,
        Some(r.revision.clone()),
        Some((&r, choices)),
    )
}
pub(crate) fn conflict_review(
    db: &Connection,
) -> Result<Option<crate::api::sync::SyncConflictReview>> {
    let Some(r) = review::load(db)? else {
        return Ok(None);
    };
    let s = checked(db, r.generation)?;
    ensure!(!s.has_pending(), "冲突已处理，请继续同步待处理批次");
    let local = vault::capture_in_transaction(db, &s.local, &s.device)?;
    ensure!(local == r.local, "本机数据已变化，请重新同步以更新冲突列表");
    let excluded = s.policy.excluded(&[&local, &s.base, &s.local, &r.remote]);
    let mut shared = local;
    let baseline_keys: BTreeSet<_> = s.base.records.iter().map(|r| &r.key).collect();
    shared.records.retain(|r| {
        !excluded.contains(&r.key) || (r.value.is_none() && baseline_keys.contains(&r.key))
    });
    let mut plan = merge(&s.base, &shared, &r.remote)?;
    review::include_dependencies(&mut plan, &s.base, &shared, &r.remote);
    Ok(Some(review::describe(&r, &plan)))
}
fn prepare_inner(
    db: &mut Connection,
    generation: u64,
    remote: &Snapshot,
    remote_revision: Option<String>,
    resolution: Option<(&review::Review, &[crate::api::sync::SyncConflictChoice])>,
) -> Result<Preparation> {
    remote.validate()?;
    check_revision(remote_revision.as_deref())?;
    ensure!(
        remote_revision.is_some() || remote.records.is_empty(),
        "远端数据缺少提交版本"
    );
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let mut state = checked(&tx, generation)?;
    ensure!(
        state.pending.is_none(),
        "已有待上传批次，请恢复该批次或确认取消"
    );
    ensure!(
        remote_revision.is_some() || state.remote_revision.is_none(),
        "远端同步数据已丢失，已阻止重新初始化"
    );
    if state.remote_revision.is_some() && state.remote_revision == remote_revision {
        ensure!(state.base == *remote, "相同远端提交对应的数据不一致");
    }
    let full = vault::capture_in_transaction(&tx, &state.local, &state.device)?;
    if let Some((r, _)) = resolution {
        let stored = review::load(&tx)?.context("冲突记录已失效")?;
        ensure!(
            stored.id == r.id && r.local == full,
            "本机数据或冲突列表已变化，请重新同步"
        );
    }
    let excluded = state
        .policy
        .excluded(&[&full, &state.base, &state.local, remote]);
    ensure!(
        !remote
            .records
            .iter()
            .any(|r| r.value.is_some() && excluded.contains(&r.key)),
        "远端记录与仅本机规则冲突，已阻止写入"
    );
    // Newly private dependencies must never turn a previous publication into an implicit deletion.
    ensure!(
        !state
            .base
            .records
            .iter()
            .any(|r| r.value.is_some() && excluded.contains(&r.key)),
        "已同步记录与仅本机依赖冲突，请先处理远端撤回"
    );
    let baseline_keys: BTreeSet<_> = state.base.records.iter().map(|r| &r.key).collect();
    let mut shared = full.clone();
    shared.records.retain(|r| {
        !excluded.contains(&r.key) || (r.value.is_none() && baseline_keys.contains(&r.key))
    });
    let mut plan = merge(&state.base, &shared, remote)?;
    review::include_dependencies(&mut plan, &state.base, &shared, remote);
    if let Some((_, choices)) = resolution {
        review::resolve(&mut plan, choices, &state.device)?;
    }
    if !plan.is_resolved() {
        review::save(
            &tx,
            generation,
            &full,
            remote,
            remote_revision.as_deref().context("冲突缺少远端版本")?,
        )?;
        tx.commit()?;
        return Ok(Preparation::Conflicts(plan));
    }
    let outgoing = plan.snapshot()?.clone();
    // Preserve excluded local rows, even if the peer has a tombstone for that ID.
    let mut combined = outgoing.clone();
    combined.records.retain(|r| !excluded.contains(&r.key));
    combined.records.extend(
        full.records
            .iter()
            .filter(|r| excluded.contains(&r.key))
            .cloned(),
    );
    combined.records.sort_by(|a, b| a.key.cmp(&b.key));
    let missing_identities = vault::missing_identities(&combined);
    let local_plan = MergePlan {
        merged: combined,
        expected_local: full,
        conflicts: vec![],
        missing_identities,
    };
    vault::apply_in_transaction(&tx, &local_plan)?;
    let pending = PendingUpload {
        id: uuid::Uuid::new_v4().to_string(),
        needs_upload: remote_revision.is_none() || outgoing != *remote,
        key_rotation: false,
        expected_revision: remote_revision,
        snapshot: outgoing.clone(),
    };
    // These bytes are already committed remotely and have just been applied locally.
    // On CAS failure, the next merge must compare against this remote snapshot,
    // otherwise previously received edits would masquerade as local edits.
    state.base = remote.clone();
    state.remote_revision = pending.expected_revision.clone();
    state.local = outgoing;
    state.pending = Some(pending.clone());
    state.advance()?;
    save(&tx, &state)?;
    review::clear(&tx)?;
    tx.commit()?;
    Ok(Preparation::Ready(pending))
}
/// Re-encrypts the last confirmed snapshot; uncommitted business edits remain
/// local and will be captured by the next ordinary sync.
pub(super) fn prepare_rotation_in_transaction(db: &Connection, generation: u64) -> Result<State> {
    ensure!(
        checked(db, generation)?.key_revision.is_none(),
        "请先完成新密钥接入后的普通同步再轮换"
    );
    let mut s = checked(db, generation)?;
    ensure!(!s.has_pending(), "请先处理待同步批次");
    ensure!(
        s.remote_revision.is_some() && s.local == s.base,
        "请先完成普通同步再轮换密钥"
    );
    s.pending = Some(PendingUpload {
        id: uuid::Uuid::new_v4().to_string(),
        expected_revision: s.remote_revision.clone(),
        needs_upload: true,
        key_rotation: true,
        snapshot: s.base.clone(),
    });
    s.advance()?;
    save(db, &s)?;
    pending_in_transaction(db)?;
    Ok(s)
}
/// Resuming a saved batch rechecks current local-only dependencies.
pub fn pending_upload(db: &Connection) -> Result<Option<PendingUpload>> {
    let tx = db.unchecked_transaction()?;
    let pending = pending_in_transaction(&tx)?;
    tx.commit()?;
    Ok(pending)
}
pub(super) fn pending_in_transaction(db: &Connection) -> Result<Option<PendingUpload>> {
    let state = load(db)?.context("请先初始化同步状态")?;
    let Some(pending) = state.pending else {
        return Ok(None);
    };
    let full = vault::capture_in_transaction(db, &state.local, &state.device)?;
    let excluded = state
        .policy
        .excluded(&[&full, &state.base, &pending.snapshot]);
    ensure!(
        !pending
            .snapshot
            .records
            .iter()
            .any(|r| r.value.is_some() && excluded.contains(&r.key)),
        "仅本机依赖已变化，请核对远端结果后重新准备批次"
    );
    Ok(Some(pending))
}
/// Caller must verify that the remote commit contains this EXACT pending batch.
/// This updates checkpoints only; edits made after prepare() are never overwritten.
pub fn acknowledge(
    db: &mut Connection,
    generation: u64,
    pending_id: &str,
    parent: Option<String>,
    revision: String,
) -> Result<State> {
    check_revision(Some(&revision))?;
    check_revision(parent.as_deref())?;
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    ensure!(
        !super::outbox::exists_in_transaction(&tx)?
            && !super::crypto::rotation::exists_in_transaction(&tx)?,
        "请通过发件箱核对远端密文后确认上传"
    );
    ensure!(
        !load(&tx)?
            .context("同步状态不存在")?
            .pending()
            .is_some_and(|p| p.is_key_rotation()),
        "密钥轮换必须核对发件箱后确认"
    );
    let state = acknowledge_in_transaction(&tx, generation, pending_id, parent, revision)?;
    tx.commit()?;
    Ok(state)
}
pub(super) fn acknowledge_in_transaction(
    db: &Connection,
    generation: u64,
    pending_id: &str,
    parent: Option<String>,
    revision: String,
) -> Result<State> {
    check_revision(Some(&revision))?;
    check_revision(parent.as_deref())?;
    let mut state = load(db)?.context("请先初始化同步状态")?;
    if state
        .last_receipt
        .as_ref()
        .is_some_and(|r| r.pending_id == pending_id && r.parent == parent && r.revision == revision)
    {
        return Ok(state);
    }
    ensure!(state.generation == generation, "同步状态已变化，请重新读取");
    let pending = state.pending.as_ref().context("没有待确认的同步批次")?;
    ensure!(
        pending.id == pending_id && pending.expected_revision == parent,
        "远端回执与待上传批次不一致"
    );
    if pending.needs_upload {
        ensure!(parent.as_ref() != Some(&revision), "远端提交未更新");
    } else {
        ensure!(
            parent.as_ref() == Some(&revision),
            "拉取确认必须对应已读取的远端版本"
        );
    }
    state.base = pending.snapshot.clone();
    state.remote_revision = Some(revision.clone());
    state.key_revision = None;
    state.last_receipt = Some(Receipt {
        pending_id: pending_id.into(),
        parent,
        revision,
    });
    state.pending = None;
    state.advance()?;
    save(db, &state)?;
    super::outbox::clear_in_transaction(db)?;
    Ok(state)
}
/// Only call after confirming the remote did NOT accept the batch. Local merged
/// data is retained for re-merging, not rolled back over subsequent user edits.
pub fn discard_pending(db: &mut Connection, generation: u64, pending_id: &str) -> Result<State> {
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let state = discard_pending_in_transaction(&tx, generation, pending_id)?;
    tx.commit()?;
    Ok(state)
}
pub(in crate::sync) fn discard_pending_in_transaction(
    db: &Connection,
    generation: u64,
    pending_id: &str,
) -> Result<State> {
    ensure!(
        !super::github::journal::exists(db)?,
        "GitHub 发布结果未解除，不能直接取消批次"
    );
    let mut state = checked(db, generation)?;
    ensure!(
        state.pending.as_ref().is_some_and(|p| p.id == pending_id),
        "待上传批次已变化"
    );
    state.pending = None;
    state.advance()?;
    save(db, &state)?;
    super::outbox::clear_in_transaction(db)?;
    super::crypto::rotation::cancel_in_transaction(db)?;
    Ok(state)
}

#[cfg(test)]
mod tests;

/// Advances only the read fence, not the merge baseline or user records.
pub(in crate::sync) fn adopt_key_revision_in_transaction(
    db: &Connection,
    generation: u64,
    revision: String,
) -> Result<()> {
    check_revision(Some(&revision))?;
    let mut state = checked(db, generation)?;
    ensure!(!state.has_pending(), "请先处理待同步批次再接入新密钥");
    state.key_revision = Some(revision);
    state.advance()?;
    save(db, &state)?;
    review::clear(db)?;
    Ok(())
}
