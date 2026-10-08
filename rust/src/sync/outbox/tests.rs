use super::*;
use crate::api::vault::{open_database, put_record, read_record};
use serde_json::json;
const SPACE: &str = "10000000-0000-4000-8000-000000000001";
const PASSWORD: &str = "outbox fixture password";
fn fixture() -> &'static (crypto::SyncKey, crypto::KeyEnvelope, crypto::RecoveryCode) {
    static KEY: std::sync::OnceLock<(crypto::SyncKey, crypto::KeyEnvelope, crypto::RecoveryCode)> =
        std::sync::OnceLock::new();
    KEY.get_or_init(|| crypto::create(SPACE.into(), PASSWORD).unwrap())
}
fn db(dir: &tempfile::TempDir) -> Connection {
    let mut db = open_database(&dir.path().join("outbox.db"), PASSWORD, true).unwrap();
    state::initialize(&mut db, SPACE.into()).unwrap();
    let (key, envelope, _) = fixture();
    crypto::install(&mut db, key, envelope).unwrap();
    snippet(&db, "echo unique-outbox-secret");
    db
}
fn snippet(db: &Connection, command: &str) {
    put_record(
        db,
        "snippets",
        &json!([{"id":"snippet","name":"Fixture","command":command}]).to_string(),
    )
    .unwrap();
}
fn generation(db: &Connection) -> u64 {
    state::load(db).unwrap().unwrap().generation()
}
fn prepare(db: &mut Connection) {
    let g = generation(db);
    let result = state::prepare(db, g, &Snapshot::empty(SPACE.into()).unwrap(), None).unwrap();
    assert!(matches!(result, state::Preparation::Ready(_)));
}
fn staged(db: &mut Connection) -> Upload {
    let g = generation(db);
    stage(db, g).unwrap()
}
fn ack(db: &mut Connection, upload: &Upload) -> Result<state::State> {
    acknowledge_published(
        db,
        upload.generation(),
        upload.batch_id(),
        None,
        "a".repeat(40),
        upload.packet(),
        upload.envelope(),
    )
}
fn exists(db: &Connection) -> bool {
    db.query_row(
        "SELECT EXISTS(SELECT 1 FROM metadata WHERE key=?1)",
        [OUTBOX],
        |r| r.get(0),
    )
    .unwrap()
}
#[test]
fn retries_and_reopen_return_identical_bytes_without_losing_later_edits() {
    let dir = tempfile::tempdir().unwrap();
    let mut db = db(&dir);
    prepare(&mut db);
    let first = staged(&mut db);
    snippet(&db, "echo later-edit");
    let second = staged(&mut db);
    assert!(first.packet() == second.packet() && first.envelope() == second.envelope());
    drop(db);
    let mut db = open_database(&dir.path().join("outbox.db"), PASSWORD, false).unwrap();
    let reopened = staged(&mut db);
    assert!(first.packet() == reopened.packet());
    let s = ack(&mut db, &first).unwrap();
    assert!(!s.has_pending() && !exists(&db));
    assert!(read_record(&db, "snippets").unwrap().contains("later-edit"));
    drop(db);
    let mut db = open_database(&dir.path().join("outbox.db"), PASSWORD, false).unwrap();
    let duplicate = ack(&mut db, &first).unwrap();
    assert_eq!(duplicate.generation(), s.generation());
    drop(db);
    let raw = std::fs::read(dir.path().join("outbox.db")).unwrap();
    assert!(!raw
        .windows(b"unique-outbox-secret".len())
        .any(|w| w == b"unique-outbox-secret"));
}
#[test]
fn mismatched_remote_content_parent_and_revision_preserve_pending() {
    let dir = tempfile::tempdir().unwrap();
    let mut db = db(&dir);
    prepare(&mut db);
    let u = staged(&mut db);
    assert!(
        state::acknowledge(&mut db, u.generation(), u.batch_id(), None, "a".repeat(40)).is_err()
    );
    let (key, _, _) = fixture();
    let opened = crypto::decrypt(u.packet(), key).unwrap();
    // Even equivalent freshly encrypted content must not confirm these exact staged bytes.
    let equivalent = crypto::encrypt(&opened.snapshot, key, u.batch_id().into(), None).unwrap();
    assert!(acknowledge_published(
        &mut db,
        u.generation(),
        u.batch_id(),
        None,
        "a".repeat(40),
        &equivalent,
        u.envelope()
    )
    .is_err());
    for (id, parent, revision, packet, envelope) in [
        ("wrong", None, "a".repeat(40), u.packet(), u.envelope()),
        (
            u.batch_id(),
            Some("b".repeat(40)),
            "a".repeat(40),
            u.packet(),
            u.envelope(),
        ),
        (
            u.batch_id(),
            None,
            "invalid".into(),
            u.packet(),
            u.envelope(),
        ),
        (
            u.batch_id(),
            None,
            "a".repeat(40),
            b"damaged".as_slice(),
            u.envelope(),
        ),
        (
            u.batch_id(),
            None,
            "a".repeat(40),
            u.packet(),
            b"damaged".as_slice(),
        ),
    ] {
        assert!(acknowledge_published(
            &mut db,
            u.generation(),
            id,
            parent,
            revision,
            packet,
            envelope
        )
        .is_err());
        assert!(state::load(&db).unwrap().unwrap().has_pending() && exists(&db));
    }
    ack(&mut db, &u).unwrap();
    assert!(acknowledge_published(
        &mut db,
        u.generation(),
        u.batch_id(),
        None,
        "b".repeat(40),
        u.packet(),
        u.envelope()
    )
    .is_err());
}
#[test]
fn corrupted_or_stale_outbox_is_not_silently_replaced() {
    let dir = tempfile::tempdir().unwrap();
    let mut db = db(&dir);
    prepare(&mut db);
    let u = staged(&mut db);
    let original = serde_json::to_value(&u).unwrap();
    let other = crypto::encrypt(
        &Snapshot::empty(SPACE.into()).unwrap(),
        &fixture().0,
        u.batch_id().into(),
        None,
    )
    .unwrap();
    let mut replaced = original.clone();
    replaced["packet"] = json!(String::from_utf8(other).unwrap());
    write(&db, OUTBOX, &replaced, LIMIT).unwrap();
    assert!(stage(&mut db, u.generation()).is_err());

    for (field, value) in [
        ("version", json!(2)),
        ("generation", json!(u.generation() + 1)),
        ("batch_id", json!(uuid::Uuid::new_v4().to_string())),
        ("packet", json!("broken")),
        ("envelope", json!("broken")),
    ] {
        let mut broken = original.clone();
        broken[field] = value;
        write(&db, OUTBOX, &broken, LIMIT).unwrap();
        assert!(stage(&mut db, u.generation()).is_err());
        assert!(ack(&mut db, &u).is_err());
        assert!(read::<Value>(&db, OUTBOX, LIMIT).unwrap().unwrap() == broken);
    }
    write(&db, OUTBOX, &u, LIMIT).unwrap();
    assert!(staged(&mut db).packet() == u.packet());
}
#[test]
fn outbox_and_receipt_failures_roll_back_without_losing_retry() {
    let dir = tempfile::tempdir().unwrap();
    let mut db = db(&dir);
    prepare(&mut db);
    db.execute_batch("CREATE TRIGGER fail_outbox BEFORE INSERT ON metadata WHEN NEW.key='sync_outbox_v1' BEGIN SELECT RAISE(ABORT,'fixture failure'); END;").unwrap();
    let g = generation(&db);
    assert!(stage(&mut db, g).is_err());
    assert!(!exists(&db));
    assert_eq!(generation(&db), g);
    db.execute_batch("DROP TRIGGER fail_outbox").unwrap();
    let u = staged(&mut db);
    db.execute_batch("CREATE TRIGGER fail_receipt BEFORE INSERT ON metadata WHEN NEW.key='sync_delivery_receipt_v1' BEGIN SELECT RAISE(ABORT,'fixture failure'); END;").unwrap();
    assert!(ack(&mut db, &u).is_err());
    assert_eq!(generation(&db), g);
    assert!(exists(&db));
    assert!(state::load(&db)
        .unwrap()
        .unwrap()
        .remote_revision()
        .is_none());
    db.execute_batch("DROP TRIGGER fail_receipt").unwrap();
    ack(&mut db, &u).unwrap();
}
#[test]
fn cancellation_clears_ciphertext_atomically_and_next_batch_gets_new_bytes() {
    let dir = tempfile::tempdir().unwrap();
    let mut db = db(&dir);
    prepare(&mut db);
    let u = staged(&mut db);
    db.execute_batch("CREATE TRIGGER fail_clear BEFORE DELETE ON metadata WHEN OLD.key='sync_outbox_v1' BEGIN SELECT RAISE(ABORT,'fixture failure'); END;").unwrap();
    assert!(state::discard_pending(&mut db, u.generation(), u.batch_id()).is_err());
    assert!(exists(&db) && state::load(&db).unwrap().unwrap().has_pending());
    db.execute_batch("DROP TRIGGER fail_clear").unwrap();
    state::discard_pending(&mut db, u.generation(), u.batch_id()).unwrap();
    assert!(!exists(&db));
    prepare(&mut db);
    assert!(stage(&mut db, u.generation()).is_err());
    let next = staged(&mut db);
    assert_ne!(u.batch_id(), next.batch_id());
    assert!(u.packet() != next.packet());
    assert!(ack(&mut db, &u).is_err());
}
#[test]
fn changed_private_dependencies_block_retry_but_allow_recording_accepted_upload() {
    let dir = tempfile::tempdir().unwrap();
    let mut db = db(&dir);
    db.execute("INSERT INTO identities VALUES ('shared','Fixture','tester','password','synthetic-secret','','')",[]).unwrap();
    let host = |identity: &str| {
        json!([{"id":"private","name":"Private","host":"localhost","username":"tester","port":22,"group":"","tags":[],"favorite":false,"identityId":identity}]).to_string()
    };
    put_record(&db, "hosts", &host("")).unwrap();
    let g = generation(&db);
    state::set_policy(
        &mut db,
        g,
        state::Policy::new(BTreeSet::from([Key {
            kind: Kind::Host,
            id: "private".into(),
        }]))
        .unwrap(),
    )
    .unwrap();
    prepare(&mut db);
    let u = staged(&mut db);
    put_record(&db, "hosts", &host("shared")).unwrap();
    assert!(stage(&mut db, u.generation()).is_err());
    // Remote already accepted the in-flight upload; checkpoint must tell the truth.
    ack(&mut db, &u).unwrap();
    assert!(read_record(&db, "hosts").unwrap().contains("shared"));
}
#[test]
fn pull_only_batches_do_not_create_outbox_and_old_receipt_cannot_ack_next_batch() {
    let dir = tempfile::tempdir().unwrap();
    let mut db = db(&dir);
    prepare(&mut db);
    let u = staged(&mut db);
    let opened = crypto::decrypt(u.packet(), &fixture().0).unwrap();
    let s = ack(&mut db, &u).unwrap();
    state::prepare(
        &mut db,
        s.generation(),
        &opened.snapshot,
        Some("a".repeat(40)),
    )
    .unwrap();
    let g = generation(&db);
    assert!(stage(&mut db, g).is_err());
    assert!(!exists(&db));
    let after_duplicate = ack(&mut db, &u).unwrap();
    assert_eq!(after_duplicate.generation(), g);
    assert!(after_duplicate.has_pending());
    let p = state::pending_upload(&db).unwrap().unwrap();
    state::acknowledge(&mut db, g, p.id(), Some("a".repeat(40)), "a".repeat(40)).unwrap();
}
#[test]
fn malformed_and_oversized_records_fail_closed() {
    let dir = tempfile::tempdir().unwrap();
    let mut db = db(&dir);
    prepare(&mut db);
    let u = staged(&mut db);
    db.execute(
        "UPDATE metadata SET value=zeroblob(?1) WHERE key=?2",
        params![(LIMIT + 1) as i64, OUTBOX],
    )
    .unwrap();
    assert!(stage(&mut db, u.generation()).is_err());
    db.execute("UPDATE metadata SET value='{}' WHERE key=?1", [OUTBOX])
        .unwrap();
    assert!(stage(&mut db, u.generation()).is_err());
    write(&db, OUTBOX, &u, LIMIT).unwrap();
    db.execute("INSERT INTO metadata VALUES (?1,'{}')", [RECEIPT])
        .unwrap();
    assert!(ack(&mut db, &u).is_err());
    assert!(exists(&db));
}
