use super::*;
use crate::api::vault::{open_database, put_record, read_record};
use serde_json::json;
const SPACE: &str = "10000000-0000-4000-8000-000000000001";
const LOCAL_PASSWORD: &str = "local rotation fixture password";
const OLD_PASSWORD: &str = "old sync fixture password";
const NEW_PASSWORD: &str = "new sync fixture password";
fn initial() -> &'static (SyncKey, KeyEnvelope, RecoveryCode) {
    static KEYS: std::sync::OnceLock<(SyncKey, KeyEnvelope, RecoveryCode)> =
        std::sync::OnceLock::new();
    KEYS.get_or_init(|| create(SPACE.into(), OLD_PASSWORD).unwrap())
}
fn generation(db: &Connection) -> u64 {
    state::load(db).unwrap().unwrap().generation()
}
fn make_db(dir: &tempfile::TempDir) -> (Connection, outbox::Upload) {
    let mut db = open_database(&dir.path().join("rotation.db"), LOCAL_PASSWORD, true).unwrap();
    let s = state::initialize(&mut db, SPACE.into()).unwrap();
    install(&mut db, &initial().0, &initial().1).unwrap();
    put_record(
        &db,
        "snippets",
        r#"[{"id":"command","name":"Fixture","command":"echo historical-secret"}]"#,
    )
    .unwrap();
    state::prepare(
        &mut db,
        s.generation(),
        &Snapshot::empty(SPACE.into()).unwrap(),
        None,
    )
    .unwrap();
    let g = generation(&db);
    let u = outbox::stage(&mut db, g).unwrap();
    outbox::acknowledge_published(
        &mut db,
        g,
        u.batch_id(),
        None,
        "a".repeat(40),
        u.packet(),
        u.envelope(),
    )
    .unwrap();
    (db, u)
}
fn start(db: &mut Connection) -> RecoveryCode {
    let g = generation(db);
    begin(db, g, NEW_PASSWORD).unwrap()
}
fn ready(db: &mut Connection, code: &RecoveryCode) -> outbox::Upload {
    let g = generation(db);
    confirm_recovery(db, g, code.expose()).unwrap();
    outbox::stage(db, g).unwrap()
}
fn ack(db: &mut Connection, u: &outbox::Upload) -> Result<state::State> {
    outbox::acknowledge_published(
        db,
        u.generation(),
        u.batch_id(),
        Some("a".repeat(40)),
        "b".repeat(40),
        u.packet(),
        u.envelope(),
    )
}
#[test]
fn rotation_reopens_keeps_old_key_until_ack_and_preserves_history_and_edits() {
    let dir = tempfile::tempdir().unwrap();
    let (mut db, old_packet) = make_db(&dir);
    let old_id = load(&db).unwrap().unwrap().0.id().to_owned();
    let code = start(&mut db);
    let g = generation(&db);
    assert_eq!(load(&db).unwrap().unwrap().0.id(), old_id);
    assert!(outbox::stage(&mut db, g).is_err());
    assert!(confirm_recovery(&mut db, g, initial().2.expose()).is_err());
    assert!(encrypt_pending(&db).is_err());
    let u = ready(&mut db, &code);
    assert!(decrypt(u.packet(), &initial().0).is_err());
    let next_envelope = KeyEnvelope::decode(u.envelope()).unwrap();
    assert!(unlock_password(&next_envelope, SPACE, OLD_PASSWORD).is_err());
    let new_key = unlock_recovery(&next_envelope, SPACE, code.expose()).unwrap();
    assert!(decrypt(u.packet(), &new_key).is_ok());
    assert!(unlock_password(&next_envelope, SPACE, NEW_PASSWORD).is_ok());
    put_record(
        &db,
        "snippets",
        r#"[{"id":"command","name":"Later","command":"echo later-edit"}]"#,
    )
    .unwrap();
    drop(db);
    let mut db = open_database(&dir.path().join("rotation.db"), LOCAL_PASSWORD, false).unwrap();
    assert!(outbox::stage(&mut db, g).unwrap().packet() == u.packet());
    let s = ack(&mut db, &u).unwrap();
    assert_eq!(load(&db).unwrap().unwrap().0.id(), new_key.id());
    assert!(!exists_in_transaction(&db).unwrap());
    assert!(decrypt_retained(&db, old_packet.packet()).is_ok());
    assert!(decrypt_retained(&db, u.packet()).is_ok());
    assert!(read_record(&db, "snippets").unwrap().contains("later-edit"));
    assert_eq!(ack(&mut db, &u).unwrap().generation(), s.generation());
    let (_, stored) = load(&db).unwrap().unwrap();
    let other_dir = tempfile::tempdir().unwrap();
    let (mut other, _) = make_db(&other_dir);
    // Candidate envelopes already support recovery elsewhere; no automatic peer adoption.
    let recovered = unlock_recovery(&stored, SPACE, code.expose()).unwrap();
    let opened = decrypt(u.packet(), &recovered).unwrap();
    let g = generation(&other);
    assert!(matches!(
        state::prepare(&mut other, g, &opened.snapshot, Some("b".repeat(40))).unwrap(),
        state::Preparation::Ready(_)
    ));
    drop(db);
    let db = open_database(&dir.path().join("rotation.db"), LOCAL_PASSWORD, false).unwrap();
    assert!(decrypt_retained(&db, old_packet.packet()).is_ok());
    let raw = std::fs::read(dir.path().join("rotation.db")).unwrap();
    for secret in [code.expose(), "historical-secret", NEW_PASSWORD] {
        assert!(!raw.windows(secret.len()).any(|w| w == secret.as_bytes()));
    }
}
#[test]
fn pending_unpublished_or_stale_state_cannot_begin_rotation() {
    let dir = tempfile::tempdir().unwrap();
    let (mut db, _) = make_db(&dir);
    let g = generation(&db);
    assert!(begin(&mut db, g + 1, NEW_PASSWORD).is_err());
    assert!(begin(&mut db, g, "short").is_err());
    let code = start(&mut db);
    let g = generation(&db);
    assert!(begin(&mut db, g, NEW_PASSWORD).is_err());
    let p = state::pending_upload(&db).unwrap().unwrap();
    assert!(state::acknowledge(&mut db, g, p.id(), Some("a".repeat(40)), "b".repeat(40)).is_err());
    assert!(confirm_recovery(&mut db, g + 1, code.expose()).is_err());
    let other = tempfile::tempdir().unwrap();
    let mut db = open_database(&other.path().join("unpublished"), LOCAL_PASSWORD, true).unwrap();
    let s = state::initialize(&mut db, SPACE.into()).unwrap();
    install(&mut db, &initial().0, &initial().1).unwrap();
    assert!(begin(&mut db, s.generation(), NEW_PASSWORD).is_err());
    assert!(!state::load(&db).unwrap().unwrap().has_pending());
}
#[test]
fn begin_and_activation_failures_roll_back_every_key_and_checkpoint() {
    let dir = tempfile::tempdir().unwrap();
    let (mut db, _) = make_db(&dir);
    let g = generation(&db);
    db.execute_batch("CREATE TRIGGER fail_candidate BEFORE INSERT ON metadata WHEN NEW.key='sync_key_rotation_v1' BEGIN SELECT RAISE(ABORT,'fixture'); END;").unwrap();
    assert!(begin(&mut db, g, NEW_PASSWORD).is_err());
    assert_eq!(generation(&db), g);
    assert!(!state::load(&db).unwrap().unwrap().has_pending());
    db.execute_batch("DROP TRIGGER fail_candidate").unwrap();
    let code = start(&mut db);
    let u = ready(&mut db, &code);
    for sql in [
        "CREATE TRIGGER fail_activation BEFORE INSERT ON metadata WHEN NEW.key='sync_key_history_v1' BEGIN SELECT RAISE(ABORT,'fixture'); END;",
        "CREATE TRIGGER fail_activation BEFORE UPDATE ON metadata WHEN NEW.key='sync_key_v1' BEGIN SELECT RAISE(ABORT,'fixture'); END;",
        "CREATE TRIGGER fail_activation BEFORE UPDATE ON metadata WHEN NEW.key='sync_delivery_receipt_v1' BEGIN SELECT RAISE(ABORT,'fixture'); END;",
    ] {
        db.execute_batch(sql).unwrap();assert!(ack(&mut db,&u).is_err());
        assert_eq!(load(&db).unwrap().unwrap().0.id(),initial().0.id());
        assert_eq!(generation(&db),u.generation());assert!(exists_in_transaction(&db).unwrap());
        assert!(history(&db,&initial().0).unwrap().keys.is_empty());
        assert!(outbox::stage(&mut db,u.generation()).unwrap().packet()==u.packet());
        db.execute_batch("DROP TRIGGER fail_activation").unwrap();
    }
    ack(&mut db, &u).unwrap();
}
#[test]
fn cancellation_reverts_candidate_without_changing_active_key_or_business_data() {
    let dir = tempfile::tempdir().unwrap();
    let (mut db, _) = make_db(&dir);
    let code = start(&mut db);
    let u = ready(&mut db, &code);
    db.execute_batch("CREATE TRIGGER fail_cancel BEFORE DELETE ON metadata WHEN OLD.key='sync_key_rotation_v1' BEGIN SELECT RAISE(ABORT,'fixture'); END;").unwrap();
    assert!(state::discard_pending(&mut db, u.generation(), u.batch_id()).is_err());
    assert!(outbox::stage(&mut db, u.generation()).unwrap().packet() == u.packet());
    db.execute_batch("DROP TRIGGER fail_cancel").unwrap();
    state::discard_pending(&mut db, u.generation(), u.batch_id()).unwrap();
    assert!(!exists_in_transaction(&db).unwrap());
    assert!(!outbox::exists_in_transaction(&db).unwrap());
    assert_eq!(load(&db).unwrap().unwrap().0.id(), initial().0.id());
    assert!(read_record(&db, "snippets")
        .unwrap()
        .contains("historical-secret"));
    assert!(ack(&mut db, &u).is_err());
    let replacement = start(&mut db);
    assert_ne!(replacement.expose(), code.expose());
}
#[test]
fn missing_or_corrupted_candidate_never_falls_back_to_old_upload_key() {
    let dir = tempfile::tempdir().unwrap();
    let (mut db, _) = make_db(&dir);
    let code = start(&mut db);
    let u = ready(&mut db, &code);
    let original = read::<Value>(&db, CANDIDATE, KEY_LIMIT).unwrap().unwrap();
    for (field, value) in [
        ("version", json!(2)),
        ("generation", json!(0)),
        ("previous_key_id", json!(uuid::Uuid::new_v4().to_string())),
        ("recovery_confirmed", json!(false)),
    ] {
        let mut bad = original.clone();
        bad[field] = value;
        write(&db, CANDIDATE, &bad, KEY_LIMIT).unwrap();
        assert!(outbox::stage(&mut db, u.generation()).is_err());
        assert!(ack(&mut db, &u).is_err());
    }
    db.execute("DELETE FROM metadata WHERE key=?1", [CANDIDATE])
        .unwrap();
    assert!(outbox::stage(&mut db, u.generation()).is_err());
    assert!(ack(&mut db, &u).is_err());
    assert!(state::acknowledge(
        &mut db,
        u.generation(),
        u.batch_id(),
        Some("a".repeat(40)),
        "b".repeat(40)
    )
    .is_err());
    write(&db, CANDIDATE, &original, KEY_LIMIT).unwrap();
    ack(&mut db, &u).unwrap();
}
#[test]
fn history_is_bounded_and_unknown_or_tampered_ciphertext_is_rejected() {
    let dir = tempfile::tempdir().unwrap();
    let (mut db, old) = make_db(&dir);
    let code = start(&mut db);
    let u = ready(&mut db, &code);
    ack(&mut db, &u).unwrap();
    let valid_history = read::<Value>(&db, HISTORY, HISTORY_LIMIT).unwrap().unwrap();
    let mut oversized = valid_history.clone();
    oversized["keys"] = json!(vec![valid_history["keys"][0].clone(); MAX_HISTORY + 1]);
    write(&db, HISTORY, &oversized, HISTORY_LIMIT).unwrap();
    let g = generation(&db);
    assert!(begin(&mut db, g, NEW_PASSWORD).is_err());
    assert!(decrypt_retained(&db, old.packet()).is_err());
    write(&db, HISTORY, &valid_history, HISTORY_LIMIT).unwrap();
    let mut packet: Value = serde_json::from_slice(old.packet()).unwrap();
    packet["header"]["key_id"] = json!(uuid::Uuid::new_v4().to_string());
    assert!(decrypt_retained(&db, &serde_json::to_vec(&packet).unwrap()).is_err());
    packet = serde_json::from_slice(old.packet()).unwrap();
    packet["header"]["batch_id"] = json!(uuid::Uuid::new_v4().to_string());
    assert!(decrypt_retained(&db, &serde_json::to_vec(&packet).unwrap()).is_err());
    db.execute(
        "UPDATE metadata SET value=zeroblob(?1) WHERE key=?2",
        params![(HISTORY_LIMIT + 1) as i64, HISTORY],
    )
    .unwrap();
    assert!(decrypt_retained(&db, old.packet()).is_err());
}

#[test]
fn consecutive_rotations_preserve_every_retained_key_and_new_uploads_use_new_key() {
    let dir = tempfile::tempdir().unwrap();
    let (mut db, first) = make_db(&dir);
    let code = start(&mut db);
    let second = ready(&mut db, &code);
    assert!(outbox::acknowledge_published(
        &mut db,
        second.generation(),
        second.batch_id(),
        None,
        "b".repeat(40),
        second.packet(),
        second.envelope()
    )
    .is_err());
    assert_eq!(load(&db).unwrap().unwrap().0.id(), initial().0.id());
    ack(&mut db, &second).unwrap();
    let previous_id = load(&db).unwrap().unwrap().0.id().to_owned();
    let next_code = start(&mut db);
    let third = ready(&mut db, &next_code);
    outbox::acknowledge_published(
        &mut db,
        third.generation(),
        third.batch_id(),
        Some("b".repeat(40)),
        "c".repeat(40),
        third.packet(),
        third.envelope(),
    )
    .unwrap();
    let (current, _) = load(&db).unwrap().unwrap();
    assert_ne!(current.id(), previous_id);
    assert_eq!(history(&db, &current).unwrap().keys.len(), 2);
    for bytes in [first.packet(), second.packet(), third.packet()] {
        assert!(decrypt_retained(&db, bytes).is_ok());
    }
    let remote = decrypt(third.packet(), &current).unwrap();
    put_record(
        &db,
        "snippets",
        r#"[{"id":"command","name":"New","command":"echo new-key-upload"}]"#,
    )
    .unwrap();
    let g = generation(&db);
    state::prepare(&mut db, g, &remote.snapshot, Some("c".repeat(40))).unwrap();
    let g = generation(&db);
    let ordinary = outbox::stage(&mut db, g).unwrap();
    assert!(decrypt(ordinary.packet(), &current).is_ok());
    assert!(decrypt(ordinary.packet(), &initial().0).is_err());
}

#[test]
fn adopted_keys_cannot_reactivate_history_or_rotate_before_merging() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let (mut db, packet) = make_db(&dir);
    let (next, envelope, _) = create(SPACE.into(), NEW_PASSWORD)?;
    let g = generation(&db);
    let tx = db.transaction()?;
    adopt_in_transaction(&tx, initial().0.id(), &next, &envelope)?;
    state::adopt_key_revision_in_transaction(&tx, g, "b".repeat(40))?;
    tx.commit()?;
    decrypt_retained(&db, packet.packet())?;
    let tx = db.transaction()?;
    assert!(adopt_in_transaction(&tx, next.id(), &initial().0, &initial().1).is_err());
    tx.rollback()?;
    let g = generation(&db);
    assert!(begin(&mut db, g, NEW_PASSWORD).is_err());
    assert_eq!(load(&db)?.unwrap().0.id(), next.id());
    assert_eq!(history(&db, &next)?.keys.len(), 1);
    Ok(())
}
