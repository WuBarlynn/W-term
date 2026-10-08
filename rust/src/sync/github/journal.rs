use super::*;
use rusqlite::{params, OptionalExtension, TransactionBehavior};
const ATTEMPT: &str = "sync_github_attempt_v1";
const BINDING: &str = "sync_github_target_v1";
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Binding {
    version: u32,
    target: Target,
    repo_id: u64,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Attempt {
    version: u32,
    binding: Binding,
    generation: u64,
    batch_id: String,
    pub(super) base_head: String,
    #[serde(deserialize_with = "required_commit")]
    pub(super) commit: Option<String>,
    // Older records may already have sent PATCH. Never infer non-publication.
    #[serde(default = "possibly_published")]
    pub(super) ref_update_started: bool,
}
fn possibly_published() -> bool {
    true
}
fn required_commit<'de, D: serde::Deserializer<'de>>(
    d: D,
) -> std::result::Result<Option<String>, D::Error> {
    Option::deserialize(d)
}
fn read<T: serde::de::DeserializeOwned>(db: &Connection, name: &str) -> Result<Option<T>> {
    let len: Option<i64> = db
        .query_row(
            "SELECT length(CAST(value AS BLOB)) FROM metadata WHERE key=?1",
            [name],
            |r| r.get(0),
        )
        .optional()?;
    let Some(len) = len else { return Ok(None) };
    ensure!((0..=8192).contains(&len), "GitHub 发布记录过大");
    let value: String = db.query_row("SELECT value FROM metadata WHERE key=?1", [name], |r| {
        r.get(0)
    })?;
    ensure!(value.len() <= 8192, "GitHub 发布记录过大");
    Ok(Some(
        serde_json::from_str(&value).map_err(|_| anyhow::anyhow!("GitHub 发布记录损坏"))?,
    ))
}
fn save(db: &Connection, name: &str, value: &impl Serialize) -> Result<()> {
    let value = serde_json::to_string(value)?;
    ensure!(value.len() <= 8192, "GitHub 发布记录过大");
    db.execute("INSERT INTO metadata(key,value) VALUES (?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value",params![name,value])?;
    Ok(())
}
pub(in crate::sync) fn exists(db: &Connection) -> Result<bool> {
    Ok(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM metadata WHERE key=?1)",
        [ATTEMPT],
        |r| r.get(0),
    )?)
}
pub(super) fn load(db: &Connection) -> Result<Option<Attempt>> {
    let a = read::<Attempt>(db, ATTEMPT)?;
    if let Some(a) = &a {
        ensure!(
            a.version == 1 && a.binding.version == 1 && a.binding.repo_id > 0,
            "GitHub 发布记录版本无效"
        );
        sha(&a.base_head)?;
        if let Some(commit) = &a.commit {
            sha(commit)?;
        }
        uuid::Uuid::parse_str(&a.batch_id).context("GitHub 发布批次无效")?;
    }
    Ok(a)
}
fn state_matches(db: &Connection, a: &Attempt) -> Result<()> {
    let s = state::load(db)?.context("同步状态不存在")?;
    ensure!(
        s.generation() == a.generation && s.pending().is_some_and(|p| p.id() == a.batch_id),
        "GitHub 发布批次已变化"
    );
    Ok(())
}
pub(super) fn check(
    db: &Connection,
    a: &Attempt,
    target: &Target,
    id: u64,
    u: &outbox::Upload,
) -> Result<()> {
    ensure!(
        a.binding.target == *target
            && a.binding.repo_id == id
            && a.generation == u.generation()
            && a.batch_id == u.batch_id(),
        "GitHub 发布目标或批次不一致"
    );
    ensure!(
        read::<Binding>(db, BINDING)?.as_ref() == Some(&a.binding),
        "GitHub 仓库绑定已变化"
    );
    state_matches(db, a)
}
pub(super) fn start(
    db: &mut Connection,
    target: &Target,
    id: u64,
    u: &outbox::Upload,
    head: String,
) -> Result<Attempt> {
    let a = Attempt {
        version: 1,
        binding: Binding {
            version: 1,
            target: target.clone(),
            repo_id: id,
        },
        generation: u.generation(),
        batch_id: u.batch_id().into(),
        base_head: head,
        commit: None,
        ref_update_started: false,
    };
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    state_matches(&tx, &a)?;
    if let Some(existing) = load(&tx)? {
        check(&tx, &existing, target, id, u)?;
        return Ok(existing);
    }
    if let Some(binding) = read::<Binding>(&tx, BINDING)? {
        ensure!(binding == a.binding, "此保险库已绑定其他 GitHub 仓库或分支");
    }
    save(&tx, BINDING, &a.binding)?;
    save(&tx, ATTEMPT, &a)?;
    tx.commit()?;
    Ok(a)
}
pub(super) fn set_commit(db: &mut Connection, a: &Attempt, commit: String) -> Result<Attempt> {
    sha(&commit)?;
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    ensure!(
        load(&tx)?.as_ref() == Some(a),
        "GitHub 发布记录已变化，请重新读取"
    );
    state_matches(&tx, a)?;
    let mut next = a.clone();
    next.commit = Some(commit);
    save(&tx, ATTEMPT, &next)?;
    tx.commit()?;
    Ok(next)
}
pub(super) fn acknowledge(
    db: &mut Connection,
    a: &Attempt,
    u: &outbox::Upload,
    files: &RemoteFiles,
) -> Result<state::State> {
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    ensure!(load(&tx)?.as_ref() == Some(a), "GitHub 发布记录已变化");
    check(&tx, a, &a.binding.target, a.binding.repo_id, u)?;
    let s = state::load(&tx)?.context("同步状态不存在")?;
    let parent = s
        .pending()
        .context("同步批次不存在")?
        .expected_revision()
        .map(str::to_owned);
    let s = outbox::acknowledge_in_transaction(
        &tx,
        u.generation(),
        u.batch_id(),
        parent,
        files.revision.clone(),
        files.packet.as_deref().context("发布密文不存在")?,
        files.envelope.as_deref().context("发布信封不存在")?,
    )?;
    tx.execute("DELETE FROM metadata WHERE key=?1", [ATTEMPT])?;
    tx.commit()?;
    Ok(s)
}

pub(in crate::sync) fn bind_in_transaction(
    db: &Connection,
    target: Target,
    repo_id: u64,
) -> Result<()> {
    let desired = Binding {
        version: 1,
        target,
        repo_id,
    };
    if let Some(current) = read::<Binding>(db, BINDING)? {
        ensure!(current == desired, "此保险库已绑定其他仓库或分支");
    }
    save(db, BINDING, &desired)
}

/// Persist before sending PATCH; once ambiguous, a later rejection cannot erase
/// the possibility that an earlier request was accepted or is still in flight.
pub(super) fn mark_ref_update(db: &mut Connection, a: &Attempt, started: bool) -> Result<Attempt> {
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    ensure!(load(&tx)?.as_ref() == Some(a), "GitHub 发布记录已变化");
    state_matches(&tx, a)?;
    ensure!(a.commit.is_some(), "发布提交不存在");
    let mut next = a.clone();
    next.ref_update_started = started;
    save(&tx, ATTEMPT, &next)?;
    tx.commit()?;
    Ok(next)
}

pub(super) fn discard_unpublished(
    db: &mut Connection,
    generation: u64,
    pending_id: &str,
    attempt: Option<&Attempt>,
) -> Result<()> {
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    ensure!(load(&tx)?.as_ref() == attempt, "GitHub 发布记录已变化");
    if let Some(a) = attempt {
        ensure!(!a.ref_update_started, "发布结果未知，不能丢弃批次");
        state_matches(&tx, a)?;
        tx.execute("DELETE FROM metadata WHERE key=?1", [ATTEMPT])?;
    }
    state::discard_pending_in_transaction(&tx, generation, pending_id)?;
    tx.commit()?;
    Ok(())
}

pub(in crate::sync) fn can_discard_unpublished(db: &Connection) -> Result<bool> {
    if let Some(a) = load(db)? {
        state_matches(db, &a)?;
        return Ok(!a.ref_update_started);
    }
    Ok(true)
}
pub(in crate::sync) fn discard_rotation(db: &mut Connection, batch_id: &str) -> Result<()> {
    let s = state::load(db)?.context("同步状态不存在")?;
    ensure!(
        s.pending()
            .is_some_and(|p| p.is_key_rotation() && p.id() == batch_id),
        "轮换批次已变化，请重新打开"
    );
    let attempt = load(db)?;
    discard_unpublished(db, s.generation(), batch_id, attempt.as_ref())
}
