use super::*;
use crate::api::vault::{open_database, put_record, read_record};
use serde_json::json;
const SPACE: &str = "10000000-0000-4000-8000-000000000001";
const PASSWORD: &str = "sync state fixture password";
fn revision(c: char) -> String {
    c.to_string().repeat(40)
}
fn key(kind: Kind, id: &str) -> Key {
    Key {
        kind,
        id: id.into(),
    }
}
fn host(id: &str, identity: &str) -> Value {
    json!({"id":id,"name":id,"host":"127.0.0.1","username":"tester","port":22,"group":"","tags":[],"favorite":false,"identityId":identity})
}
fn db(dir: &tempfile::TempDir, name: &str) -> Connection {
    open_database(&dir.path().join(name), PASSWORD, true).unwrap()
}
fn seed(db: &Connection) {
    put_record(
        db,
        "hosts",
        &json!([
            host("private-host", "private-id"),
            host("shared-login-host", "private-id"),
            host("public-host", "public-id")
        ])
        .to_string(),
    )
    .unwrap();
    put_record(db, "snippets", &json!([{"id":"private-command","name":"Private","command":"echo private-command-secret"}, {"id":"public-command","name":"Public","command":"pwd"}]).to_string()).unwrap();
    for (id, secret) in [
        ("private-id", "unique-local-only-secret"),
        ("public-id", "unique-pending-secret"),
    ] {
        db.execute(
            "INSERT INTO identities VALUES (?1,?1,'tester','password',?2,'','')",
            params![id, secret],
        )
        .unwrap();
    }
}
fn ready(result: Preparation) -> PendingUpload {
    match result {
        Preparation::Ready(p) => p,
        Preparation::Conflicts(_) => panic!("unexpected fixture conflict"),
    }
}
fn generation(db: &Connection) -> u64 {
    load(db).unwrap().unwrap().generation()
}
fn empty() -> Snapshot {
    Snapshot::empty(SPACE.into()).unwrap()
}
fn policy() -> Policy {
    Policy::new(BTreeSet::from([
        key(Kind::Host, "private-host"),
        key(Kind::Snippet, "private-command"),
    ]))
    .unwrap()
}
fn confirm(db: &mut Connection, pending: &PendingUpload, c: char) -> State {
    acknowledge(
        db,
        generation(db),
        pending.id(),
        pending.expected_revision.clone(),
        revision(c),
    )
    .unwrap()
}

#[test]
fn durable_pending_survives_reopen_and_excludes_private_credentials() {
    let dir = tempfile::tempdir().unwrap();
    let mut a = db(&dir, "a.db");
    seed(&a);
    let state = initialize(&mut a, SPACE.into()).unwrap();
    let device = state.device().to_string();
    let state = set_policy(&mut a, state.generation(), policy()).unwrap();
    let pending = ready(prepare(&mut a, state.generation(), &empty(), None).unwrap());
    let bytes = pending.snapshot().encode().unwrap();
    for text in [
        "private-host",
        "shared-login-host",
        "private-id",
        "unique-local-only-secret",
        "private-command-secret",
    ] {
        assert!(!bytes.windows(text.len()).any(|w| w == text.as_bytes()));
    }
    let state = load(&a).unwrap().unwrap();
    assert!(state.base.records.is_empty());
    assert_eq!(state.remote_revision(), None);
    drop(a);
    let mut a = open_database(&dir.path().join("a.db"), PASSWORD, false).unwrap();
    let state = load(&a).unwrap().unwrap();
    assert_eq!(state.device(), device);
    assert!(state.has_pending());
    let resumed = pending_upload(&a).unwrap().unwrap();
    assert_eq!(resumed.id(), pending.id());
    assert!(resumed.snapshot().encode().unwrap() == bytes);
    // No local-only row was removed during the projected merge.
    assert!(read_record(&a, "hosts").unwrap().contains("private-host"));
    let secret: String = a
        .query_row(
            "SELECT password FROM identities WHERE id='private-id'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(secret, "unique-local-only-secret");
    let acknowledged = confirm(&mut a, &pending, 'a');
    assert!(!acknowledged.has_pending());
    assert_eq!(acknowledged.remote_revision(), Some(revision('a').as_str()));
    drop(a);
    let file = std::fs::read(dir.path().join("a.db")).unwrap();
    assert!(!file
        .windows(b"unique-pending-secret".len())
        .any(|w| w == b"unique-pending-secret"));
}
#[test]
fn local_identity_also_excludes_every_referencing_host() {
    let dir = tempfile::tempdir().unwrap();
    let mut a = db(&dir, "a");
    seed(&a);
    let s = initialize(&mut a, SPACE.into()).unwrap();
    let s = set_policy(
        &mut a,
        s.generation(),
        Policy::new(BTreeSet::from([key(Kind::Identity, "private-id")])).unwrap(),
    )
    .unwrap();
    let p = ready(prepare(&mut a, s.generation(), &empty(), None).unwrap());
    assert!(!p.snapshot.records.iter().any(|r| [
        "private-id",
        "private-host",
        "shared-login-host"
    ]
    .contains(&r.key.id.as_str())));
    assert!(p.snapshot.records.iter().any(|r| r.key.id == "public-host"));
}
#[test]
fn acknowledgment_is_bound_idempotent_and_preserves_later_local_edits() {
    let dir = tempfile::tempdir().unwrap();
    let mut a = db(&dir, "a");
    seed(&a);
    let s = initialize(&mut a, SPACE.into()).unwrap();
    let p = ready(prepare(&mut a, s.generation(), &empty(), None).unwrap());
    let g = generation(&a);
    assert!(acknowledge(&mut a, g, "wrong-batch", None, revision('a')).is_err());
    assert!(acknowledge(&mut a, g, p.id(), Some(revision('b')), revision('a')).is_err());
    assert!(load(&a).unwrap().unwrap().base.records.is_empty());
    a.execute(
        "UPDATE identities SET password='edited-after-prepare' WHERE id='public-id'",
        [],
    )
    .unwrap();
    let s = acknowledge(&mut a, g, p.id(), None, revision('a')).unwrap();
    let repeated = acknowledge(&mut a, g, p.id(), None, revision('a')).unwrap();
    assert_eq!(repeated.generation(), s.generation());
    let next = ready(prepare(&mut a, s.generation(), p.snapshot(), Some(revision('a'))).unwrap());
    let record = next
        .snapshot
        .records
        .iter()
        .find(|r| r.key.id == "public-id")
        .unwrap();
    assert!(record.value.as_ref().unwrap()["password"] == "edited-after-prepare");
    assert!(
        record.revision.counter
            > p.snapshot
                .records
                .iter()
                .find(|r| r.key.id == "public-id")
                .unwrap()
                .revision
                .counter
    );
}
#[test]
fn policy_edits_and_stale_handles_cannot_replace_an_inflight_batch() {
    let dir = tempfile::tempdir().unwrap();
    let mut a = db(&dir, "a");
    seed(&a);
    let s = initialize(&mut a, SPACE.into()).unwrap();
    let p = ready(prepare(&mut a, s.generation(), &empty(), None).unwrap());
    assert!(prepare(&mut a, s.generation(), &empty(), None).is_err());
    let g = generation(&a);
    assert!(set_policy(&mut a, g, policy()).is_err());
    assert!(discard_pending(&mut a, g, "wrong-batch").is_err());
    assert_eq!(pending_upload(&a).unwrap().unwrap().id(), p.id());
    confirm(&mut a, &p, 'a');
    let g = generation(&a);
    assert!(set_policy(&mut a, g, policy()).is_err());
    assert!(load(&a).unwrap().unwrap().policy().local_only().is_empty());
}
#[test]
fn checkpoint_failure_rolls_back_remote_data_and_state_together() {
    let dir = tempfile::tempdir().unwrap();
    let mut a = db(&dir, "a");
    let b = db(&dir, "b");
    seed(&b);
    let s = initialize(&mut a, SPACE.into()).unwrap();
    let remote = capture(&b, &empty(), "20000000-0000-4000-8000-000000000002").unwrap();
    a.execute_batch("CREATE TRIGGER fail_checkpoint BEFORE UPDATE ON metadata WHEN NEW.key='sync_state_v1' BEGIN SELECT RAISE(FAIL,'fixture checkpoint failure'); END;").unwrap();
    assert!(prepare(&mut a, s.generation(), &remote, Some(revision('a'))).is_err());
    assert_eq!(read_record(&a, "hosts").unwrap(), "[]");
    let count: i64 = a
        .query_row("SELECT count(*) FROM identities", [], |r| r.get(0))
        .unwrap();
    assert_eq!(count, 0);
    let unchanged = load(&a).unwrap().unwrap();
    assert_eq!(unchanged.generation(), s.generation());
    assert!(!unchanged.has_pending());
}
#[test]
fn discard_keeps_received_data_and_allows_remerge() {
    let dir = tempfile::tempdir().unwrap();
    let mut a = db(&dir, "a");
    let b = db(&dir, "b");
    seed(&b);
    let s = initialize(&mut a, SPACE.into()).unwrap();
    let remote = capture(&b, &empty(), "20000000-0000-4000-8000-000000000002").unwrap();
    let p = ready(prepare(&mut a, s.generation(), &remote, Some(revision('a'))).unwrap());
    let g = generation(&a);
    let s = discard_pending(&mut a, g, p.id()).unwrap();
    assert!(s.base == remote);
    assert!(!s.has_pending());
    assert!(read_record(&a, "hosts").unwrap().contains("public-host"));
    let retried = ready(prepare(&mut a, s.generation(), &remote, Some(revision('a'))).unwrap());
    assert!(retried.snapshot == p.snapshot);
    assert_ne!(retried.id(), p.id());
}
#[test]
fn peer_cannot_overwrite_an_excluded_local_identity() {
    let dir = tempfile::tempdir().unwrap();
    let mut a = db(&dir, "a");
    let b = db(&dir, "b");
    seed(&a);
    seed(&b);
    b.execute(
        "UPDATE identities SET password='remote-password' WHERE id='private-id'",
        [],
    )
    .unwrap();
    let s = initialize(&mut a, SPACE.into()).unwrap();
    let s = set_policy(&mut a, s.generation(), policy()).unwrap();
    let remote = capture(&b, &empty(), "20000000-0000-4000-8000-000000000002").unwrap();
    assert!(prepare(&mut a, s.generation(), &remote, Some(revision('a'))).is_err());
    let value: String = a
        .query_row(
            "SELECT password FROM identities WHERE id='private-id'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(value, "unique-local-only-secret");
    assert!(!load(&a).unwrap().unwrap().has_pending());
}
#[test]
fn changed_private_dependency_blocks_resuming_old_payload() {
    let dir = tempfile::tempdir().unwrap();
    let mut a = db(&dir, "a");
    seed(&a);
    let s = initialize(&mut a, SPACE.into()).unwrap();
    let s = set_policy(&mut a, s.generation(), policy()).unwrap();
    let p = ready(prepare(&mut a, s.generation(), &empty(), None).unwrap());
    put_record(
        &a,
        "hosts",
        &json!([
            host("private-host", "public-id"),
            host("public-host", "public-id")
        ])
        .to_string(),
    )
    .unwrap();
    assert!(pending_upload(&a).is_err());
    let g = generation(&a);
    let s = discard_pending(&mut a, g, p.id()).unwrap();
    let next = ready(prepare(&mut a, s.generation(), &empty(), None).unwrap());
    assert!(!next
        .snapshot
        .records
        .iter()
        .any(|r| r.key.id == "public-id" && r.value.is_some()));
}
#[test]
fn conflicts_leave_durable_state_and_local_content_unchanged() {
    let dir = tempfile::tempdir().unwrap();
    let mut a = db(&dir, "a");
    let b = db(&dir, "b");
    seed(&a);
    seed(&b);
    b.execute(
        "UPDATE identities SET password='different' WHERE id='public-id'",
        [],
    )
    .unwrap();
    let s = initialize(&mut a, SPACE.into()).unwrap();
    let remote = capture(&b, &empty(), "20000000-0000-4000-8000-000000000002").unwrap();
    match prepare(&mut a, s.generation(), &remote, Some(revision('a'))).unwrap() {
        Preparation::Conflicts(plan) => assert_eq!(plan.conflicts().len(), 1),
        _ => panic!("conflict expected"),
    }
    let review = conflict_review(&a).unwrap().unwrap();
    assert_eq!(review.items.len(), 1);
    assert!(review.items[0]
        .changed_fields
        .iter()
        .any(|s| s.contains("密码")));
    assert!(!review.items[0]
        .local_summary
        .contains("unique-pending-secret"));
    assert!(!review.items[0].remote_summary.contains("different"));
    assert_eq!(generation(&a), s.generation());
    assert!(!load(&a).unwrap().unwrap().has_pending());
}
#[test]
fn initialize_is_idempotent_and_corrupt_state_is_never_reset() {
    let dir = tempfile::tempdir().unwrap();
    let mut a = db(&dir, "a");
    let s = initialize(&mut a, SPACE.into()).unwrap();
    assert_eq!(
        initialize(&mut a, SPACE.into()).unwrap().device(),
        s.device()
    );
    assert!(initialize(&mut a, uuid::Uuid::new_v4().to_string()).is_err());
    a.execute(
        "UPDATE metadata SET value=?1 WHERE key='sync_state_v1'",
        ["invalid-private-value"],
    )
    .unwrap();
    assert!(load(&a).is_err());
    assert!(initialize(&mut a, SPACE.into()).is_err());
    let saved: String = a
        .query_row(
            "SELECT value FROM metadata WHERE key='sync_state_v1'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(saved, "invalid-private-value");
}

#[test]
fn remote_tombstones_never_delete_private_rows() {
    let dir = tempfile::tempdir().unwrap();
    let mut a = db(&dir, "a");
    seed(&a);
    let s = initialize(&mut a, SPACE.into()).unwrap();
    let s = set_policy(&mut a, s.generation(), policy()).unwrap();
    let mut remote = empty();
    for k in [
        key(Kind::Host, "private-host"),
        key(Kind::Identity, "private-id"),
    ] {
        remote.records.push(Record {
            key: k,
            revision: Revision {
                counter: 2,
                device: uuid::Uuid::new_v4().to_string(),
            },
            value: None,
        });
    }
    let p = ready(prepare(&mut a, s.generation(), &remote, Some(revision('a'))).unwrap());
    assert!(read_record(&a, "hosts").unwrap().contains("private-host"));
    let secret: String = a
        .query_row(
            "SELECT password FROM identities WHERE id='private-id'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(secret, "unique-local-only-secret");
    assert!(p
        .snapshot
        .records
        .iter()
        .filter(|r| r.key.id == "private-id")
        .all(|r| r.value.is_none()));
}
#[test]
fn durable_two_device_pull_only_flow_can_confirm_existing_remote_commit() {
    let dir = tempfile::tempdir().unwrap();
    let mut a = db(&dir, "a");
    let mut b = db(&dir, "b");
    seed(&a);
    let s = initialize(&mut a, SPACE.into()).unwrap();
    let s = set_policy(&mut a, s.generation(), policy()).unwrap();
    let upload = ready(prepare(&mut a, s.generation(), &empty(), None).unwrap());
    assert!(upload.needs_upload());
    confirm(&mut a, &upload, 'a');
    let s = initialize(&mut b, SPACE.into()).unwrap();
    let pull = ready(
        prepare(
            &mut b,
            s.generation(),
            upload.snapshot(),
            Some(revision('a')),
        )
        .unwrap(),
    );
    assert!(!pull.needs_upload());
    assert!(!read_record(&b, "hosts").unwrap().contains("private-host"));
    let g = generation(&b);
    assert!(acknowledge(&mut b, g, pull.id(), Some(revision('a')), revision('b')).is_err());
    let s = acknowledge(&mut b, g, pull.id(), Some(revision('a')), revision('a')).unwrap();
    assert!(!s.has_pending());
    assert_eq!(s.remote_revision(), Some(revision('a').as_str()));
    assert!(s.base == upload.snapshot);
}
#[test]
fn opting_back_into_sync_publishes_records_with_their_existing_ids() {
    let dir = tempfile::tempdir().unwrap();
    let mut a = db(&dir, "a");
    seed(&a);
    let s = initialize(&mut a, SPACE.into()).unwrap();
    let s = set_policy(&mut a, s.generation(), policy()).unwrap();
    let p = ready(prepare(&mut a, s.generation(), &empty(), None).unwrap());
    let s = confirm(&mut a, &p, 'a');
    let s = set_policy(&mut a, s.generation(), Policy::default()).unwrap();
    let next = ready(prepare(&mut a, s.generation(), p.snapshot(), Some(revision('a'))).unwrap());
    assert!(next.needs_upload());
    assert!(next
        .snapshot
        .records
        .iter()
        .any(|r| r.key == key(Kind::Identity, "private-id") && r.value.is_some()));
    assert!(next
        .snapshot
        .records
        .iter()
        .any(|r| r.key == key(Kind::Host, "private-host") && r.value.is_some()));
}

#[test]
fn failed_publish_remerges_from_received_remote_without_false_conflicts() {
    let dir = tempfile::tempdir().unwrap();
    let mut a = db(&dir, "a");
    let b = db(&dir, "b");
    seed(&b);
    put_record(
        &a,
        "snippets",
        &json!([{"id":"local-addition","name":"Local","command":"hostname"}]).to_string(),
    )
    .unwrap();
    let s = initialize(&mut a, SPACE.into()).unwrap();
    let r1 = capture(&b, &empty(), "20000000-0000-4000-8000-000000000002").unwrap();
    let p = ready(prepare(&mut a, s.generation(), &r1, Some(revision('a'))).unwrap());
    assert!(p.needs_upload());
    let g = generation(&a);
    let s = discard_pending(&mut a, g, p.id()).unwrap();
    b.execute(
        "UPDATE identities SET password='newer-remote-secret' WHERE id='public-id'",
        [],
    )
    .unwrap();
    let r2 = capture(&b, &r1, "20000000-0000-4000-8000-000000000002").unwrap();
    let retry = ready(prepare(&mut a, s.generation(), &r2, Some(revision('b'))).unwrap());
    assert!(retry
        .snapshot
        .records
        .iter()
        .any(|r| r.key.id == "local-addition"));
    let identity = retry
        .snapshot
        .records
        .iter()
        .find(|r| r.key.id == "public-id")
        .unwrap();
    assert!(identity.value.as_ref().unwrap()["password"] == "newer-remote-secret");
}
#[test]
fn missing_or_inconsistent_remote_revision_never_reinitializes_state() {
    let dir = tempfile::tempdir().unwrap();
    let mut a = db(&dir, "a");
    seed(&a);
    let s = initialize(&mut a, SPACE.into()).unwrap();
    let p = ready(prepare(&mut a, s.generation(), &empty(), None).unwrap());
    let s = confirm(&mut a, &p, 'a');
    assert!(prepare(&mut a, s.generation(), &empty(), None).is_err());
    let mut wrong = p.snapshot.clone();
    wrong
        .records
        .iter_mut()
        .find(|r| r.key.id == "public-id")
        .unwrap()
        .value
        .as_mut()
        .unwrap()["password"] = json!("changed");
    assert!(prepare(&mut a, s.generation(), &wrong, Some(revision('a'))).is_err());
    assert_eq!(generation(&a), s.generation());
}

#[test]
fn omitted_optional_state_fields_are_corruption_not_silent_batch_cancellation() {
    let dir = tempfile::tempdir().unwrap();
    let mut a = db(&dir, "a");
    seed(&a);
    let s = initialize(&mut a, SPACE.into()).unwrap();
    ready(prepare(&mut a, s.generation(), &empty(), None).unwrap());
    let original: String = a
        .query_row(
            "SELECT value FROM metadata WHERE key='sync_state_v1'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    for field in ["pending", "remote_revision", "last_receipt"] {
        let mut value: Value = serde_json::from_str(&original).unwrap();
        value.as_object_mut().unwrap().remove(field);
        let malformed = serde_json::to_string(&value).unwrap();
        a.execute(
            "UPDATE metadata SET value=?1 WHERE key='sync_state_v1'",
            [&malformed],
        )
        .unwrap();
        assert!(load(&a).is_err());
        assert!(initialize(&mut a, SPACE.into()).is_err());
        let saved: String = a
            .query_row(
                "SELECT value FROM metadata WHERE key='sync_state_v1'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert!(saved == malformed);
    }
}
