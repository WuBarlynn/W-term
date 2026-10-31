//! Durable conflict review. Full alternatives stay in SQLCipher; FFI gets summaries only.
use super::*;
use crate::api::sync::{SyncConflictChoice, SyncConflictItem, SyncConflictReview};
use rusqlite::{params, Connection, OptionalExtension};
const KEY: &str = "sync_conflict_review_v1";
const LIMIT: usize = 34 * 1024 * 1024;
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Review {
    version: u32,
    pub id: String,
    pub generation: u64,
    pub local: Snapshot,
    pub remote: Snapshot,
    pub revision: String,
}
pub(super) fn load(db: &Connection) -> Result<Option<Review>> {
    let size: Option<i64> = db
        .query_row(
            "SELECT length(CAST(value AS BLOB)) FROM metadata WHERE key=?1",
            [KEY],
            |r| r.get(0),
        )
        .optional()?;
    let Some(size) = size else { return Ok(None) };
    ensure!(size >= 0 && size as usize <= LIMIT, "冲突记录超过容量限制");
    let text = Zeroizing::new(db.query_row::<String, _, _>(
        "SELECT value FROM metadata WHERE key=?1",
        [KEY],
        |r| r.get(0),
    )?);
    ensure!(text.len() <= LIMIT, "冲突记录超过容量限制");
    let r: Review = serde_json::from_str(&text).map_err(|_| anyhow::anyhow!("冲突记录已损坏"))?;
    ensure!(r.version == 1, "不支持的冲突记录版本");
    uuid::Uuid::parse_str(&r.id).context("冲突记录编号无效")?;
    ensure!(
        r.revision.len() == 40 && r.revision.bytes().all(|b| b.is_ascii_hexdigit()),
        "冲突记录远端版本无效"
    );
    r.local.validate()?;
    r.remote.validate()?;
    ensure!(r.local.space == r.remote.space, "冲突记录空间不一致");
    Ok(Some(r))
}
pub(super) fn save(
    db: &Connection,
    generation: u64,
    local: &Snapshot,
    remote: &Snapshot,
    revision: &str,
) -> Result<()> {
    let r = Review {
        version: 1,
        id: uuid::Uuid::new_v4().to_string(),
        generation,
        local: local.clone(),
        remote: remote.clone(),
        revision: revision.into(),
    };
    let json = Zeroizing::new(serde_json::to_string(&r)?);
    ensure!(json.len() <= LIMIT, "冲突记录超过容量限制");
    db.execute("INSERT INTO metadata(key,value) VALUES (?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value",params![KEY,json.as_str()])?;
    Ok(())
}
pub(super) fn clear(db: &Connection) -> Result<()> {
    db.execute("DELETE FROM metadata WHERE key=?1", [KEY])?;
    Ok(())
}

// A concurrently deleted identity and changed host must be decided together.
// Include those rows in the review instead of silently dropping the host/reference.
pub(super) fn include_dependencies(
    plan: &mut MergePlan,
    base: &Snapshot,
    local: &Snapshot,
    remote: &Snapshot,
) {
    let (b, l, r) = (base.map(), local.map(), remote.map());
    let live: BTreeSet<_> = plan
        .merged
        .records
        .iter()
        .filter(|r| r.key.kind == Kind::Identity && r.value.is_some())
        .map(|r| r.key.clone())
        .collect();
    let live_hosts: BTreeSet<_> = plan
        .merged
        .records
        .iter()
        .filter(|r| r.key.kind == Kind::Host && r.value.is_some())
        .map(|r| r.key.clone())
        .collect();
    let identity_ref = |row: &Record| {
        row.value
            .as_ref()
            .and_then(|v| v.get("identityId"))
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
            .map(|id| Key {
                kind: Kind::Identity,
                id: id.into(),
            })
    };
    let jump_refs = |row: &Record| -> Vec<Key> {
        row.value
            .as_ref()
            .and_then(|v| v.get("jumpHostIds"))
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .filter(|id| !id.is_empty())
            .map(|id| Key {
                kind: Kind::Host,
                id: id.into(),
            })
            .collect()
    };
    let mut dependents = BTreeMap::<Key, BTreeSet<Key>>::new();
    let mut host_dependents = BTreeMap::<Key, BTreeSet<Key>>::new();
    for row in plan
        .merged
        .records
        .iter()
        .filter(|r| r.key.kind == Kind::Host)
    {
        if let Some(id) = identity_ref(row) {
            dependents.entry(id).or_default().insert(row.key.clone());
        }
        for jump in jump_refs(row) {
            host_dependents
                .entry(jump)
                .or_default()
                .insert(row.key.clone());
        }
    }
    let mut known: BTreeSet<_> = plan.conflicts.iter().map(|c| c.key.clone()).collect();
    let mut queue: std::collections::VecDeque<_> = known.iter().cloned().collect();
    for missing in &plan.missing_identities {
        let id = Key {
            kind: Kind::Identity,
            id: missing.identity_id.clone(),
        };
        // Both live alternatives will repair an omitted conflicting identity.
        if known.contains(&id)
            && payload(l.get(&id).copied()).is_some()
            && payload(r.get(&id).copied()).is_some()
        {
            continue;
        }
        queue.push_back(id);
        queue.push_back(Key {
            kind: Kind::Host,
            id: missing.host_id.clone(),
        });
    }
    for missing in &plan.missing_jump_hosts {
        let id = Key {
            kind: Kind::Host,
            id: missing.jump_host_id.clone(),
        };
        if known.contains(&id)
            && payload(l.get(&id).copied()).is_some()
            && payload(r.get(&id).copied()).is_some()
        {
            continue;
        }
        queue.push_back(id);
        queue.push_back(Key {
            kind: Kind::Host,
            id: missing.host_id.clone(),
        });
    }
    let mut processed = BTreeSet::new();
    while let Some(key) = queue.pop_front() {
        if !processed.insert(key.clone()) {
            continue;
        }
        if known.insert(key.clone()) {
            plan.conflicts.push(Conflict {
                key: key.clone(),
                base: b.get(&key).map(|r| (*r).clone()),
                local: l.get(&key).map(|r| (*r).clone()),
                remote: r.get(&key).map(|r| (*r).clone()),
            });
        }
        if key.kind == Kind::Host {
            for row in [l.get(&key), r.get(&key)].into_iter().flatten() {
                if let Some(id) = identity_ref(row) {
                    if !live.contains(&id) {
                        queue.push_back(id);
                    }
                }
                for jump in jump_refs(row) {
                    if !live_hosts.contains(&jump) {
                        queue.push_back(jump);
                    }
                }
            }
        }
        if key.kind == Kind::Identity
            && (payload(l.get(&key).copied()).is_none() || payload(r.get(&key).copied()).is_none())
        {
            if let Some(hosts) = dependents.get(&key) {
                queue.extend(hosts.iter().cloned());
            }
        }
        if key.kind == Kind::Host
            && (payload(l.get(&key).copied()).is_none() || payload(r.get(&key).copied()).is_none())
        {
            if let Some(hosts) = host_dependents.get(&key) {
                queue.extend(hosts.iter().cloned());
            }
        }
    }
    plan.merged.records.retain(|r| !known.contains(&r.key));
    plan.conflicts.sort_by(|a, b| a.key.cmp(&b.key));
    plan.missing_identities = vault::missing_identities(&plan.merged);
    plan.missing_jump_hosts = vault::missing_jump_hosts(&plan.merged);
}

pub(super) fn resolve(
    plan: &mut MergePlan,
    choices: &[SyncConflictChoice],
    device: &str,
) -> Result<()> {
    ensure!(
        choices.len() == plan.conflicts.len(),
        "请为每项冲突选择保留版本"
    );
    let mut selected_choices = BTreeMap::new();
    for c in choices {
        ensure!(
            matches!(c.side.as_str(), "local" | "remote"),
            "冲突选择无效"
        );
        ensure!(
            selected_choices
                .insert((c.kind.as_str(), c.id.as_str()), c.side.as_str())
                .is_none(),
            "冲突选择重复"
        );
    }
    for conflict in &plan.conflicts {
        let side = selected_choices
            .remove(&(kind(&conflict.key.kind), conflict.key.id.as_str()))
            .context("冲突条目已变化，请重新同步")?;
        let selected = if side == "local" {
            &conflict.local
        } else {
            &conflict.remote
        };
        let counter = [&conflict.base, &conflict.local, &conflict.remote]
            .into_iter()
            .flatten()
            .map(|r| r.revision.counter)
            .max()
            .unwrap_or(0)
            .checked_add(1)
            .context("同步版本计数已耗尽")?;
        plan.merged.records.push(Record {
            key: conflict.key.clone(),
            revision: Revision {
                counter,
                device: device.into(),
            },
            value: selected.as_ref().and_then(|r| r.value.clone()),
        });
    }
    plan.merged.records.sort_by(|a, b| a.key.cmp(&b.key));
    plan.merged.validate()?;
    plan.missing_identities = vault::missing_identities(&plan.merged);
    plan.missing_jump_hosts = vault::missing_jump_hosts(&plan.merged);
    ensure!(
        plan.missing_identities.is_empty(),
        "所选主机引用了已删除的身份。请同时保留该身份，或选择不引用它的主机版本"
    );
    ensure!(
        plan.missing_jump_hosts.is_empty(),
        "所选主机引用了已删除或未同步的跳板主机。请同时保留该跳板主机，或选择不使用它的主机版本"
    );
    plan.conflicts.clear();
    Ok(())
}
fn kind(k: &Kind) -> &'static str {
    match k {
        Kind::Host => "host",
        Kind::Identity => "identity",
        Kind::Snippet => "snippet",
        Kind::Folders => "folders",
        Kind::Settings => "settings",
    }
}
fn short(s: &str) -> String {
    let mut text: String = s.chars().filter(|c| !c.is_control()).take(180).collect();
    if s.chars().count() > 180 {
        text.push('…');
    }
    text
}
fn text(v: &Value, key: &str) -> String {
    short(v.get(key).and_then(Value::as_str).unwrap_or_default())
}
pub(super) fn summary(k: &Kind, value: Option<&Value>) -> String {
    let Some(v) = value else {
        return "已删除 / 不存在".into();
    };
    match k {
        Kind::Host => format!(
            "{}\n{}@{}:{}\n文件夹：{}",
            text(v, "name"),
            text(v, "username"),
            text(v, "host"),
            v["port"],
            text(v, "group")
        ),
        Kind::Identity => format!(
            "{}\n用户名：{}\n认证：{}",
            text(v, "name"),
            text(v, "username"),
            if v["kind"] == "key" {
                "私钥"
            } else {
                "密码"
            }
        ),
        Kind::Snippet => format!(
            "{}\n命令长度：{} 字符",
            text(v, "name"),
            v["command"].as_str().unwrap_or_default().chars().count()
        ),
        Kind::Settings => "W Term 设置\n外观、插件与命令偏好".into(),
        Kind::Folders => {
            let a = v.as_array().expect("validated folders");
            format!(
                "{} 个文件夹\n{}",
                a.len(),
                a.iter()
                    .take(8)
                    .filter_map(Value::as_str)
                    .map(short)
                    .collect::<Vec<_>>()
                    .join("\n")
            )
        }
    }
}
fn differences(c: &Conflict) -> Vec<String> {
    let (l, r) = (payload(c.local.as_ref()), payload(c.remote.as_ref()));
    if l.is_none() || r.is_none() {
        return vec!["存在 / 删除状态".into()];
    }
    if c.key.kind == Kind::Folders {
        return vec!["文件夹树".into()];
    }
    if c.key.kind == Kind::Settings {
        return vec!["应用设置".into()];
    }
    let fields: &[(&str, &str)] = match c.key.kind {
        Kind::Host => &[
            ("name", "名称"),
            ("host", "地址"),
            ("port", "端口"),
            ("username", "用户名"),
            ("group", "文件夹"),
            ("tags", "标签"),
            ("favorite", "收藏"),
            ("identityId", "关联身份"),
        ],
        Kind::Identity => &[
            ("name", "名称"),
            ("username", "用户名"),
            ("kind", "认证方式"),
            ("password", "密码（内容隐藏）"),
            ("private_key", "私钥（内容隐藏）"),
            ("passphrase", "私钥口令（内容隐藏）"),
        ],
        Kind::Snippet => &[("name", "名称"), ("command", "命令（内容隐藏）")],
        Kind::Folders | Kind::Settings => unreachable!(),
    };
    fields
        .iter()
        .filter(|(key, _)| l.and_then(|v| v.get(*key)) != r.and_then(|v| v.get(*key)))
        .map(|(_, label)| (*label).into())
        .collect()
}
pub(super) fn describe(r: &Review, plan: &MergePlan) -> SyncConflictReview {
    SyncConflictReview {
        id: r.id.clone(),
        items: plan
            .conflicts
            .iter()
            .map(|c| SyncConflictItem {
                kind: kind(&c.key.kind).into(),
                id: c.key.id.clone(),
                local_summary: summary(&c.key.kind, payload(c.local.as_ref())),
                remote_summary: summary(&c.key.kind, payload(c.remote.as_ref())),
                local_deleted: c.local_deleted(),
                remote_deleted: c.remote_deleted(),
                changed_fields: differences(c),
            })
            .collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::vault::{open_database, put_record, read_record};
    use serde_json::json;
    const PASSWORD: &str = "conflict review test password";
    const SPACE: &str = "10000000-0000-4000-8000-000000000001";
    const PEER: &str = "00000000-0000-4000-8000-000000000002";
    fn command(db: &Connection, text: &str) {
        put_record(
            db,
            "snippets",
            &json!([{"id":"one","name":"Command","command":text}]).to_string(),
        )
        .unwrap();
    }
    fn ready(p: state::Preparation) -> state::PendingUpload {
        match p {
            state::Preparation::Ready(p) => p,
            _ => panic!("expected ready"),
        }
    }
    fn pair() -> (tempfile::TempDir, Connection, Connection, Snapshot) {
        let dir = tempfile::tempdir().unwrap();
        let mut a = open_database(&dir.path().join("a.db"), PASSWORD, true).unwrap();
        let mut b = open_database(&dir.path().join("b.db"), PASSWORD, true).unwrap();
        command(&a, "echo original");
        let state = state::initialize(&mut a, SPACE.into()).unwrap();
        let p = ready(
            state::prepare(
                &mut a,
                state.generation(),
                &Snapshot::empty(SPACE.into()).unwrap(),
                None,
            )
            .unwrap(),
        );
        let base = p.snapshot().clone();
        let g = state::load(&a).unwrap().unwrap().generation();
        state::acknowledge(&mut a, g, p.id(), None, "a".repeat(40)).unwrap();
        let local = capture(&b, &Snapshot::empty(SPACE.into()).unwrap(), PEER).unwrap();
        apply_merge(
            &mut b,
            &merge(&Snapshot::empty(SPACE.into()).unwrap(), &local, &base).unwrap(),
        )
        .unwrap();
        (dir, a, b, base)
    }
    fn prepare(a: &mut Connection, b: &Connection, base: &Snapshot) -> Snapshot {
        let remote = capture(b, base, PEER).unwrap();
        let g = state::load(a).unwrap().unwrap().generation();
        assert!(matches!(
            state::prepare(a, g, &remote, Some("b".repeat(40))).unwrap(),
            state::Preparation::Conflicts(_)
        ));
        remote
    }
    fn choice(side: &str) -> SyncConflictChoice {
        SyncConflictChoice {
            kind: "snippet".into(),
            id: "one".into(),
            side: side.into(),
        }
    }
    #[test]
    fn durable_review_masks_commands_resolves_and_rejects_replay() -> Result<()> {
        let (dir, mut a, b, base) = pair();
        command(&a, "echo local-secret");
        command(&b, "echo remote-secret");
        let remote = prepare(&mut a, &b, &base);
        let r = state::conflict_review(&a)?.unwrap();
        assert_eq!(r.items.len(), 1);
        assert!(!r.items[0].local_summary.contains("local-secret"));
        assert!(!r.items[0].remote_summary.contains("remote-secret"));
        assert!(r.items[0].changed_fields.iter().any(|s| s.contains("命令")));
        drop(a);
        let mut a = open_database(&dir.path().join("a.db"), PASSWORD, false)?;
        assert_eq!(state::conflict_review(&a)?.unwrap().id, r.id);
        let p = ready(state::prepare_resolved(&mut a, &r.id, &[choice("local")])?);
        assert!(read_record(&a, "snippets")?.contains("local-secret"));
        assert!(load(&a)?.is_none());
        assert!(p.snapshot().records[0].revision.counter > remote.records[0].revision.counter);
        assert!(state::prepare_resolved(&mut a, &r.id, &[choice("remote")]).is_err());
        let file = std::fs::read(dir.path().join("a.db"))?;
        for secret in ["local-secret", "remote-secret"] {
            assert!(!file.windows(secret.len()).any(|w| w == secret.as_bytes()));
        }
        Ok(())
    }
    #[test]
    fn stale_local_duplicate_choices_and_write_failure_preserve_both() -> Result<()> {
        let (_dir, mut a, b, base) = pair();
        command(&a, "echo local");
        command(&b, "echo remote");
        prepare(&mut a, &b, &base);
        let r = state::conflict_review(&a)?.unwrap();
        assert!(state::prepare_resolved(&mut a, &r.id, &[]).is_err());
        assert!(
            state::prepare_resolved(&mut a, &r.id, &[choice("local"), choice("remote")]).is_err()
        );
        assert!(state::prepare_resolved(&mut a, &r.id, &[choice("invalid")]).is_err());
        a.execute_batch("CREATE TRIGGER fail_review_clear BEFORE DELETE ON metadata WHEN OLD.key='sync_conflict_review_v1' BEGIN SELECT RAISE(ABORT,'fixture'); END;")?;
        assert!(state::prepare_resolved(&mut a, &r.id, &[choice("remote")]).is_err());
        assert!(read_record(&a, "snippets")?.contains("echo local"));
        assert_eq!(load(&a)?.unwrap().id, r.id);
        assert!(!state::load(&a)?.unwrap().has_pending());
        a.execute_batch("DROP TRIGGER fail_review_clear;")?;
        command(&a, "echo later");
        assert!(state::conflict_review(&a).is_err());
        assert!(state::prepare_resolved(&mut a, &r.id, &[choice("remote")]).is_err());
        prepare(&mut a, &b, &base);
        let next = state::conflict_review(&a)?.unwrap();
        assert_ne!(r.id, next.id);
        assert!(state::prepare_resolved(&mut a, &r.id, &[choice("remote")]).is_err());
        ready(state::prepare_resolved(
            &mut a,
            &next.id,
            &[choice("remote")],
        )?);
        assert!(read_record(&a, "snippets")?.contains("echo remote"));
        Ok(())
    }
    #[test]
    fn edit_delete_and_folder_tree_choices_are_explicit() -> Result<()> {
        let (_dir, mut a, b, base) = pair();
        command(&a, "echo changed");
        put_record(&b, "snippets", "[]")?;
        prepare(&mut a, &b, &base);
        let r = state::conflict_review(&a)?.unwrap();
        assert!(r.items[0].remote_deleted);
        ready(state::prepare_resolved(&mut a, &r.id, &[choice("remote")])?);
        assert_eq!(read_record(&a, "snippets")?, "[]");
        // First-sync folder additions conflict as a whole tree, no path loss by union.
        let dir = tempfile::tempdir()?;
        let mut a = open_database(&dir.path().join("a.db"), PASSWORD, true)?;
        let b = open_database(&dir.path().join("b.db"), PASSWORD, true)?;
        state::initialize(&mut a, SPACE.into())?;
        put_record(&a, "folders", r#"["Local","Local/Child"]"#)?;
        put_record(&b, "folders", r#"["Remote"]"#)?;
        prepare(&mut a, &b, &Snapshot::empty(SPACE.into())?);
        let r = state::conflict_review(&a)?.unwrap();
        assert_eq!(r.items[0].kind, "folders");
        ready(state::prepare_resolved(
            &mut a,
            &r.id,
            &[SyncConflictChoice {
                kind: "folders".into(),
                id: "tree".into(),
                side: "local".into(),
            }],
        )?);
        assert_eq!(read_record(&a, "folders")?, r#"["Local","Local/Child"]"#);
        Ok(())
    }
    #[test]
    fn identity_dependency_choices_cannot_leave_dangling_hosts_or_expose_passwords() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let mut a = open_database(&dir.path().join("a.db"), PASSWORD, true)?;
        let mut b = open_database(&dir.path().join("b.db"), PASSWORD, true)?;
        let host = json!({"id":"h","name":"Host","host":"localhost","port":22,"username":"tester","group":"","tags":[],"favorite":false,"identityId":"login"});
        put_record(&a, "hosts", &json!([host]).to_string())?;
        a.execute("INSERT INTO identities VALUES ('login','Login','tester','password','original-secret','','')",[])?;
        state::initialize(&mut a, SPACE.into())?;
        let p = ready(state::prepare(
            &mut a,
            0,
            &Snapshot::empty(SPACE.into())?,
            None,
        )?);
        let base = p.snapshot().clone();
        let g = state::load(&a)?.unwrap().generation();
        state::acknowledge(&mut a, g, p.id(), None, "a".repeat(40))?;
        let empty = Snapshot::empty(SPACE.into())?;
        let initial = merge(&empty, &capture(&b, &empty, PEER)?, &base)?;
        apply_merge(&mut b, &initial)?;
        // Remote deletes host + credential; local changes both.
        let mut local_host = host;
        local_host["name"] = json!("Edited");
        put_record(&a, "hosts", &json!([local_host]).to_string())?;
        // Identity itself is unchanged locally: the host choice must promote
        // its automatically deleted credential into the review.

        put_record(&b, "hosts", "[]")?;
        b.execute("DELETE FROM identities", [])?;
        prepare(&mut a, &b, &base);
        let r = state::conflict_review(&a)?.unwrap();
        assert_eq!(r.items.len(), 2);
        for item in &r.items {
            assert!(!item.local_summary.contains("secret"));
            assert!(!item.remote_summary.contains("secret"));
        }
        let choices = |identity: &str| {
            vec![
                SyncConflictChoice {
                    kind: "host".into(),
                    id: "h".into(),
                    side: "local".into(),
                },
                SyncConflictChoice {
                    kind: "identity".into(),
                    id: "login".into(),
                    side: identity.into(),
                },
            ]
        };
        assert!(state::prepare_resolved(&mut a, &r.id, &choices("remote")).is_err());
        assert!(!state::load(&a)?.unwrap().has_pending());
        ready(state::prepare_resolved(&mut a, &r.id, &choices("local"))?);
        assert!(read_record(&a, "hosts")?.contains("Edited"));
        Ok(())
    }
}
