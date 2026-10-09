//! Explicit local unlink; never contacts or deletes the remote repository.
use super::*;
use crate::api::sync::SyncDisconnectInfo;
use rusqlite::{Connection, TransactionBehavior};
const REMOVE: &[&str] = &[
    "sync_account_v1",
    "sync_state_v1",
    "sync_key_v1",
    "sync_key_history_v1",
    "sync_github_target_v1",
    "sync_delivery_receipt_v1",
];
const BLOCKERS: &[&str] = &[
    "sync_outbox_v1",
    "sync_github_attempt_v1",
    "sync_key_rotation_v1",
    "sync_conflict_review_v1",
];
fn view(db: &Connection) -> Result<(SyncDisconnectInfo, state::Policy)> {
    let config = service::read_settings(db)?;
    ensure!(config.configured, "没有可断开的同步仓库");
    let s = state::load(db)?;
    let full = s
        .as_ref()
        .map(|s| vault::capture_in_transaction(db, s.local_snapshot(), s.device()))
        .transpose()?;
    let policy = if let (Some(s), Some(full)) = (&s, &full) {
        state::Policy::new(
            s.policy()
                .excluded(&[full, s.local_snapshot(), s.base_snapshot()]),
        )?
    } else {
        state::retained_policy(db)?
    };
    let mut stmt = db.prepare("SELECT key, length(CAST(value AS BLOB)) FROM metadata WHERE key GLOB 'sync_*' ORDER BY key")?;
    let rows = stmt
        .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let mut digest = ring::digest::Context::new(&ring::digest::SHA256);
    let mut blocked = s.as_ref().is_some_and(|s| s.has_pending());
    for (key, len) in rows {
        ensure!(
            REMOVE.contains(&key.as_str())
                || BLOCKERS.contains(&key.as_str())
                || key == "sync_local_policy_v1",
            "存在未知同步记录，请升级应用后再断开"
        );
        ensure!(
            (0..=64 * 1024 * 1024).contains(&len),
            "同步记录过大，不能断开"
        );
        blocked |= BLOCKERS.contains(&key.as_str());
        let value = Zeroizing::new(db.query_row::<String, _, _>(
            "SELECT value FROM metadata WHERE key=?1",
            [&key],
            |r| r.get(0),
        )?);
        digest.update(&(key.len() as u64).to_be_bytes());
        digest.update(key.as_bytes());
        digest.update(&(value.len() as u64).to_be_bytes());
        digest.update(value.as_bytes());
    }
    if let Some(full) = full {
        digest.update(&full.encode()?);
    }
    let revision = digest
        .finish()
        .as_ref()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    Ok((
        SyncDisconnectInfo {
            revision,
            target: format!("{}/{} · {}", config.owner, config.repository, config.branch),
            initialized: config.initialized,
            blocked_reason: if blocked {
                "请先完成待处理同步、轮换或冲突处理；断开不会丢弃恢复记录".into()
            } else {
                String::new()
            },
        },
        policy,
    ))
}
pub fn preview(db: &mut Connection) -> Result<SyncDisconnectInfo> {
    let tx = db.transaction()?;
    let (info, _) = view(&tx)?;
    tx.commit()?;
    Ok(info)
}
pub fn disconnect(db: &mut Connection, revision: &str, confirmation: &str) -> Result<()> {
    ensure!(confirmation == "断开", "请输入“断开”确认操作");
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let (info, policy) = view(&tx)?;
    ensure!(
        info.revision == revision,
        "仓库或本机数据已变化，请重新检查断开信息"
    );
    ensure!(info.blocked_reason.is_empty(), "{}", info.blocked_reason);
    state::retain_policy(&tx, &policy)?;
    for key in REMOVE {
        tx.execute("DELETE FROM metadata WHERE key=?1", [key])?;
    }
    tx.commit()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::vault::{open_database, put_record, read_record};
    fn setup(dir: &tempfile::TempDir) -> Connection {
        let mut db = open_database(
            &dir.path().join("unlink.db"),
            "fixture disconnect password",
            true,
        )
        .unwrap();
        service::save_config(
            &mut db,
            "fixture".into(),
            "vault".into(),
            "main".into(),
            "synthetic-token",
        )
        .unwrap();
        put_record(
            &db,
            "snippets",
            r#"[{"id":"local","name":"Local","command":"echo retained"}]"#,
        )
        .unwrap();
        db.execute("INSERT INTO metadata VALUES ('unrelated','keep')", [])
            .unwrap();
        db
    }
    fn metadata(db: &Connection) -> Vec<(String, String)> {
        db.prepare("SELECT key,value FROM metadata ORDER BY key")
            .unwrap()
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .map(Result::unwrap)
            .collect()
    }
    #[test]
    fn detach_keeps_business_and_policy_across_reopen_and_new_space() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let mut db = setup(&dir);
        let s = state::initialize(&mut db, uuid::Uuid::new_v4().to_string())?;
        state::set_policy(
            &mut db,
            s.generation(),
            state::Policy::new(BTreeSet::from([Key {
                kind: Kind::Snippet,
                id: "local".into(),
            }]))?,
        )?;
        let before = read_record(&db, "snippets")?;
        let v = preview(&mut db)?;
        assert!(disconnect(&mut db, &v.revision, "wrong").is_err());
        disconnect(&mut db, &v.revision, "断开")?;
        assert_eq!(before, read_record(&db, "snippets")?);
        assert!(state::load(&db)?.is_none());
        assert!(!service::settings(&mut db)?.configured);
        assert_eq!(
            db.query_row::<String, _, _>(
                "SELECT value FROM metadata WHERE key='unrelated'",
                [],
                |r| r.get(0)
            )?,
            "keep"
        );
        assert!(disconnect(&mut db, &v.revision, "断开").is_err());
        drop(db);
        let mut db = open_database(
            &dir.path().join("unlink.db"),
            "fixture disconnect password",
            false,
        )?;
        service::save_config(
            &mut db,
            "another".into(),
            "repo".into(),
            "main".into(),
            "new-token",
        )?;
        let s = state::initialize(&mut db, uuid::Uuid::new_v4().to_string())?;
        assert_eq!(s.policy().local_only().len(), 1);
        Ok(())
    }
    #[test]
    fn failed_delete_and_changed_config_leave_all_metadata_intact() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let mut db = setup(&dir);
        let v = preview(&mut db)?;
        service::save_config(
            &mut db,
            "fixture".into(),
            "new".into(),
            "main".into(),
            "replacement-token",
        )?;
        let before = metadata(&db);
        assert!(disconnect(&mut db, &v.revision, "断开").is_err());
        assert_eq!(metadata(&db), before);
        let v = preview(&mut db)?;
        db.execute_batch("CREATE TRIGGER fail_unlink BEFORE DELETE ON metadata WHEN OLD.key='sync_account_v1' BEGIN SELECT RAISE(ABORT,'fixture'); END;")?;
        assert!(disconnect(&mut db, &v.revision, "断开").is_err());
        assert_eq!(metadata(&db), before);
        Ok(())
    }
    #[test]
    fn every_pending_record_blocks_even_without_state_and_unknown_versions_fail_closed(
    ) -> Result<()> {
        let dir = tempfile::tempdir()?;
        let mut db = setup(&dir);
        for key in BLOCKERS {
            db.execute("INSERT INTO metadata VALUES (?1,'{}')", [key])?;
            let v = preview(&mut db)?;
            assert!(!v.blocked_reason.is_empty());
            let before = metadata(&db);
            assert!(disconnect(&mut db, &v.revision, "断开").is_err());
            assert_eq!(metadata(&db), before);
            db.execute("DELETE FROM metadata WHERE key=?1", [key])?;
        }
        db.execute("INSERT INTO metadata VALUES ('sync_future_v2','{}')", [])?;
        assert!(preview(&mut db).is_err());
        Ok(())
    }
    #[test]
    fn dependency_closure_is_preserved_and_later_edits_invalidate_preview() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let mut db = setup(&dir);
        db.execute(
            "INSERT INTO identities VALUES ('login','Login','tester','password','secret','','')",
            [],
        )?;
        put_record(
            &db,
            "hosts",
            r#"[{"id":"h","name":"Host","host":"localhost","port":22,"username":"tester","group":"","tags":[],"favorite":false,"identityId":"login"}]"#,
        )?;
        let s = state::initialize(&mut db, uuid::Uuid::new_v4().to_string())?;
        state::set_policy(
            &mut db,
            s.generation(),
            state::Policy::new(BTreeSet::from([Key {
                kind: Kind::Host,
                id: "h".into(),
            }]))?,
        )?;
        let v = preview(&mut db)?;
        db.execute("UPDATE identities SET password='changed'", [])?;
        assert!(disconnect(&mut db, &v.revision, "断开").is_err());
        let v = preview(&mut db)?;
        disconnect(&mut db, &v.revision, "断开")?;
        let p = state::retained_policy(&db)?;
        assert!(p.local_only().contains(&Key {
            kind: Kind::Identity,
            id: "login".into()
        }));
        assert!(p.local_only().contains(&Key {
            kind: Kind::Host,
            id: "h".into()
        }));
        Ok(())
    }
}
