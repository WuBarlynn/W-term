//! Local-only policy UI. Only safe summaries and a stale-data fence cross FFI.
use super::*;
use crate::api::sync::{SyncScopeItem, SyncScopeKey, SyncScopeView};
use rusqlite::{Connection, TransactionBehavior};

fn kind_name(kind: &Kind) -> &'static str {
    match kind {
        Kind::Host => "host",
        Kind::Identity => "identity",
        Kind::Snippet => "snippet",
        Kind::Folders => "folders",
        Kind::Settings => "settings",
    }
}
fn selected(keys: Vec<SyncScopeKey>) -> Result<BTreeSet<Key>> {
    ensure!(keys.len() <= MAX_RECORDS, "仅本机规则过多");
    let mut result = BTreeSet::new();
    for key in keys {
        let kind = match key.kind.as_str() {
            "host" => Kind::Host,
            "identity" => Kind::Identity,
            "snippet" => Kind::Snippet,
            _ => anyhow::bail!("不支持的仅本机记录类型"),
        };
        ensure!(result.insert(Key { kind, id: key.id }), "仅本机规则重复");
    }
    Ok(result)
}
pub fn preview(db: &mut Connection, selection: Option<Vec<SyncScopeKey>>) -> Result<SyncScopeView> {
    // One read transaction gives a consistent state, business data and dependencies.
    let tx = db.transaction()?;
    let view = view(&tx, selection)?;
    tx.commit()?;
    Ok(view)
}
fn view(db: &Connection, selection: Option<Vec<SyncScopeKey>>) -> Result<SyncScopeView> {
    let s = state::load(db)?.context("请先创建或接入同步空间，再选择仅本机范围")?;
    let full = vault::capture_in_transaction(db, s.local_snapshot(), s.device())?;
    let keys = match selection {
        Some(keys) => selected(keys)?,
        None => s.policy().local_only().clone(),
    };
    let mut known: BTreeSet<Key> = full
        .records
        .iter()
        .filter(|r| r.value.is_some() && !matches!(r.key.kind, Kind::Folders | Kind::Settings))
        .map(|r| r.key.clone())
        .collect();
    // Keep rules for removed records visible and removable; never silently drop them.
    known.extend(s.policy().local_only().iter().cloned());
    ensure!(
        keys.iter().all(|k| known.contains(k)),
        "列表已变化，请刷新后重新选择"
    );
    let policy = state::Policy::new(keys)?;
    let excluded = policy.excluded(&[&full, s.base_snapshot(), s.local_snapshot()]);
    let blocked_reason = if s.has_pending()
        || github::journal::exists(db)?
        || outbox::exists_in_transaction(db)?
        || crypto::rotation::exists_in_transaction(db)?
    {
        "请先完成待处理同步或轮换，再修改仅本机规则".into()
    } else if review::load(db)?.is_some() {
        "请先完成同步冲突处理，再修改仅本机规则".into()
    } else {
        state::validate_policy_change(&s, &full, &policy)
            .err()
            .map(|e| e.to_string())
            .unwrap_or_default()
    };
    // Includes business values and proposed policy, so renamed or re-linked hosts
    // and changed secrets cannot silently alter a reviewed selection at save time.
    let bytes = Zeroizing::new(serde_json::to_vec(&(&s, &full, &policy))?);
    let digest = ring::digest::digest(&ring::digest::SHA256, &bytes);
    let revision = digest.as_ref().iter().map(|v| format!("{v:02x}")).collect();
    let values: BTreeMap<_, _> = full
        .records
        .iter()
        .map(|r| (&r.key, r.value.as_ref()))
        .collect();
    let published_keys: BTreeSet<_> = s
        .base_snapshot()
        .records
        .iter()
        .filter(|r| r.value.is_some())
        .map(|r| &r.key)
        .collect();
    let items = known
        .into_iter()
        .map(|key| {
            let value = values.get(&key).copied().flatten();
            let published = published_keys.contains(&key);
            SyncScopeItem {
                kind: kind_name(&key.kind).into(),
                id: key.id.clone(),
                summary: review::summary(&key.kind, value),
                selected: policy.local_only().contains(&key),
                excluded: excluded.contains(&key),
                published,
            }
        })
        .collect();
    Ok(SyncScopeView {
        revision,
        items,
        blocked_reason,
    })
}
pub fn save(db: &mut Connection, revision: &str, selection: Vec<SyncScopeKey>) -> Result<()> {
    let keys = selected(selection)?;
    let selection = keys
        .iter()
        .map(|k| SyncScopeKey {
            kind: kind_name(&k.kind).into(),
            id: k.id.clone(),
        })
        .collect();
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let current = view(&tx, Some(selection))?;
    ensure!(
        current.revision == revision,
        "数据或同步状态已变化，请刷新范围并重新确认"
    );
    ensure!(
        current.blocked_reason.is_empty(),
        "{}",
        current.blocked_reason
    );
    let s = state::load(&tx)?.context("同步状态不存在")?;
    state::set_policy_in_transaction(&tx, s.generation(), state::Policy::new(keys)?)?;
    tx.commit()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::vault::{open_database, put_record, read_record};
    use serde_json::json;
    const SPACE: &str = "10000000-0000-4000-8000-000000000001";
    fn key(kind: &str, id: &str) -> SyncScopeKey {
        SyncScopeKey {
            kind: kind.into(),
            id: id.into(),
        }
    }
    fn setup(dir: &tempfile::TempDir) -> Connection {
        let mut db =
            open_database(&dir.path().join("scope.db"), "fixture scope password", true).unwrap();
        let hosts = json!([{"id":"one","name":"One","host":"localhost","port":22,"username":"tester","identityId":"login","group":"","tags":[],"favorite":false},
            {"id":"two","name":"Two","host":"localhost","port":22,"username":"tester","identityId":"login","group":"","tags":[],"favorite":false}]);
        put_record(&db, "hosts", &hosts.to_string()).unwrap();
        put_record(
            &db,
            "snippets",
            r#"[{"id":"cmd","name":"Command","command":"echo never-expose-command"}]"#,
        )
        .unwrap();
        db.execute("INSERT INTO identities VALUES ('login','Login','tester','password','never-expose-password','','')", []).unwrap();
        state::initialize(&mut db, SPACE.into()).unwrap();
        db
    }
    #[test]
    fn preview_explains_dependencies_without_secrets_and_survives_reopen() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let mut db = setup(&dir);
        let view = preview(&mut db, Some(vec![key("host", "one")]))?;
        assert_eq!(view.items.iter().filter(|i| i.excluded).count(), 3);
        assert_eq!(view.items.iter().filter(|i| i.selected).count(), 1);
        for i in &view.items {
            assert!(!i.summary.contains("never-expose"));
        }
        assert!(state::load(&db)?.unwrap().policy().local_only().is_empty());
        save(&mut db, &view.revision, vec![key("host", "one")])?;
        drop(db);
        let mut db = open_database(
            &dir.path().join("scope.db"),
            "fixture scope password",
            false,
        )?;
        assert_eq!(
            preview(&mut db, None)?
                .items
                .iter()
                .filter(|i| i.excluded)
                .count(),
            3
        );
        let s = state::load(&db)?.unwrap();
        let state::Preparation::Ready(batch) = state::prepare(
            &mut db,
            s.generation(),
            &Snapshot::empty(SPACE.into())?,
            None,
        )?
        else {
            panic!("unexpected conflict")
        };
        let bytes = batch.snapshot().encode()?;
        assert!(!String::from_utf8_lossy(&bytes).contains("never-expose-password"));
        assert!(read_record(&db, "hosts")?.contains("One"));
        Ok(())
    }
    #[test]
    fn local_only_jump_host_excludes_dependent_hosts() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let mut db = open_database(&dir.path().join("scope.db"), "fixture scope password", true)?;
        let hosts = json!([
            {"id":"jump","name":"Jump","host":"jump.example","port":22,"username":"tester","group":"","tags":[],"favorite":false},
            {"id":"target","name":"Target","host":"target.example","port":22,"username":"tester","group":"","tags":[],"favorite":false,"jumpHostIds":["jump"]},
            {"id":"direct","name":"Direct","host":"direct.example","port":22,"username":"tester","group":"","tags":[],"favorite":false}
        ]);
        put_record(&db, "hosts", &hosts.to_string())?;
        put_record(&db, "snippets", "[]")?;
        state::initialize(&mut db, SPACE.into())?;
        let view = preview(&mut db, Some(vec![key("host", "jump")]))?;
        let item = |id: &str| view.items.iter().find(|i| i.id == id).unwrap();
        assert!(item("jump").selected && item("jump").excluded);
        assert!(item("target").excluded);
        assert!(!item("direct").excluded);
        save(&mut db, &view.revision, vec![key("host", "jump")])?;
        let s = state::load(&db)?.unwrap();
        let full = vault::capture_in_transaction(&db, s.local_snapshot(), s.device())?;
        let excluded = s.policy().excluded(&[&full]);
        let host_key = |id: &str| Key {
            kind: Kind::Host,
            id: id.into(),
        };
        assert!(excluded.contains(&host_key("jump")));
        assert!(excluded.contains(&host_key("target")));
        assert!(!excluded.contains(&host_key("direct")));
        Ok(())
    }
    #[test]
    fn stale_edits_and_failed_transaction_never_install_unreviewed_rules() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let mut db = setup(&dir);
        let v = preview(&mut db, Some(vec![key("host", "one")]))?;
        db.execute(
            "UPDATE identities SET password='changed-secret' WHERE id='login'",
            [],
        )?;
        assert!(save(&mut db, &v.revision, vec![key("host", "one")]).is_err());
        let v = preview(&mut db, Some(vec![key("host", "one")]))?;
        assert!(save(&mut db, &v.revision, vec![key("snippet", "cmd")]).is_err());
        db.execute_batch("CREATE TRIGGER fail_scope BEFORE UPDATE ON metadata WHEN NEW.key='sync_state_v1' BEGIN SELECT RAISE(ABORT,'fixture'); END;")?;
        assert!(save(&mut db, &v.revision, vec![key("host", "one")]).is_err());
        assert!(state::load(&db)?.unwrap().policy().local_only().is_empty());
        db.execute_batch("DROP TRIGGER fail_scope")?;
        save(&mut db, &v.revision, vec![key("host", "one")])?;
        assert!(save(&mut db, &v.revision, vec![key("host", "one")]).is_err());
        Ok(())
    }
    #[test]
    fn pending_and_published_dependencies_block_scope_changes() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let mut db = setup(&dir);
        let s = state::load(&db)?.unwrap();
        let state::Preparation::Ready(p) = state::prepare(
            &mut db,
            s.generation(),
            &Snapshot::empty(SPACE.into())?,
            None,
        )?
        else {
            panic!()
        };
        let v = preview(&mut db, Some(vec![key("host", "one")]))?;
        assert!(v.blocked_reason.contains("待处理"));
        assert!(save(&mut db, &v.revision, vec![key("host", "one")]).is_err());
        let g = state::load(&db)?.unwrap().generation();
        state::acknowledge(&mut db, g, p.id(), None, "a".repeat(40))?;
        let v = preview(&mut db, Some(vec![key("host", "one")]))?;
        assert!(v.blocked_reason.contains("已有同步数据"));
        assert!(v.items.iter().any(|i| i.published));
        assert!(save(&mut db, &v.revision, vec![key("host", "one")]).is_err());
        Ok(())
    }
    #[test]
    fn removed_rules_remain_visible_and_can_be_removed_without_restoring_records() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let mut db = setup(&dir);
        let v = preview(&mut db, Some(vec![key("snippet", "cmd")]))?;
        save(&mut db, &v.revision, vec![key("snippet", "cmd")])?;
        put_record(&db, "snippets", "[]")?;
        let v = preview(&mut db, None)?;
        let item = v.items.iter().find(|i| i.id == "cmd").unwrap();
        assert!(item.selected && item.excluded);
        assert!(item.summary.contains("不存在"));
        assert!(preview(&mut db, Some(vec![key("host", "missing")])).is_err());
        assert!(preview(&mut db, Some(vec![key("folders", "tree")])).is_err());
        let v = preview(&mut db, Some(vec![]))?;
        save(&mut db, &v.revision, vec![])?;
        assert!(preview(&mut db, None)?.items.iter().all(|i| i.id != "cmd"));
        assert_eq!(read_record(&db, "snippets")?, "[]");
        Ok(())
    }
}
