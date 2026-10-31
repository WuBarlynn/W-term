use super::*;
use crate::api::vault::{open_database, put_record, read_record};
use rusqlite::{params, Connection};
use serde_json::json;
const DEVICE_A: &str = "00000000-0000-4000-8000-000000000001";
const DEVICE_B: &str = "00000000-0000-4000-8000-000000000002";
fn empty() -> Snapshot {
    Snapshot::empty("10000000-0000-4000-8000-000000000001".into()).unwrap()
}
fn database(dir: &tempfile::TempDir, name: &str) -> Connection {
    open_database(&dir.path().join(name), "sync test master password", true).unwrap()
}
fn host(id: &str, name: &str, identity: &str) -> Value {
    json!({"id":id,"name":name,"host":"127.0.0.1","username":"tester","port":22,"group":"","tags":[],"favorite":false,"identityId":identity})
}
fn seed(db: &Connection) {
    put_record(
        db,
        "hosts",
        &json!([host("host-one", "Original", "identity-one")]).to_string(),
    )
    .unwrap();
    put_record(db, "folders", "[\"Work\"]").unwrap();
    put_record(db, "snippets", "[]").unwrap();
    db.execute(
        "INSERT INTO identities VALUES ('identity-one','Test login','tester','password',?1,'','')",
        ["unique-sync-secret"],
    )
    .unwrap();
}
fn pair() -> (tempfile::TempDir, Connection, Connection, Snapshot) {
    let dir = tempfile::tempdir().unwrap();
    let a = database(&dir, "a.db");
    let mut b = database(&dir, "b.db");
    seed(&a);
    let base = empty();
    let local = capture(&b, &base, DEVICE_B).unwrap();
    let remote = capture(&a, &base, DEVICE_A).unwrap();
    let plan = merge(&base, &local, &remote).unwrap();
    assert!(plan.is_resolved());
    apply_merge(&mut b, &plan).unwrap();
    let shared = plan.snapshot().unwrap().clone();
    (dir, a, b, shared)
}
#[test]
fn sync_two_encrypted_vaults_merge_independent_edits_and_converge() {
    let (dir, mut a, mut b, base) = pair();
    put_record(
        &a,
        "hosts",
        &json!([host("host-one", "Renamed on Mac", "identity-one")]).to_string(),
    )
    .unwrap();
    put_record(
        &b,
        "snippets",
        &json!([{"id":"snippet-one","name":"Phone","command":"pwd"}]).to_string(),
    )
    .unwrap();
    let local = capture(&a, &base, DEVICE_A).unwrap();
    let remote = capture(&b, &base, DEVICE_B).unwrap();
    let to_a = merge(&base, &local, &remote).unwrap();
    let to_b = merge(&base, &remote, &local).unwrap();
    assert!(to_a.snapshot().unwrap() == to_b.snapshot().unwrap());
    apply_merge(&mut a, &to_a).unwrap();
    apply_merge(&mut b, &to_b).unwrap();
    let shared = to_a.snapshot().unwrap();
    assert!(capture(&a, shared, DEVICE_A).unwrap() == capture(&b, shared, DEVICE_B).unwrap());
    let secret: String = b
        .query_row(
            "SELECT password FROM identities WHERE id='identity-one'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(secret, "unique-sync-secret");
    assert!(read_record(&b, "hosts").unwrap().contains("Renamed on Mac"));
    for name in ["a.db", "b.db"] {
        let bytes = std::fs::read(dir.path().join(name)).unwrap();
        assert!(!bytes
            .windows(secret.len())
            .any(|part| part == secret.as_bytes()));
    }
}
#[test]
fn sync_interactive_identity_must_not_carry_secrets() {
    let (_dir, a, _b, base) = pair();
    a.execute(
        "INSERT INTO identities VALUES ('interactive','MFA','mfa','interactive','','','')",
        [],
    )
    .unwrap();
    let local = capture(&a, &base, DEVICE_A).unwrap();
    assert!(local.validate().is_ok());
    let plan = merge(&base, &local, &base).unwrap();
    assert!(plan.is_resolved());
    let mut invalid = local.clone();
    for record in &mut invalid.records {
        if record.key.kind == Kind::Identity {
            record.value.as_mut().unwrap()["password"] = json!("stored-secret");
        }
    }
    assert!(invalid.validate().is_err());
}
#[test]
fn sync_dangling_jump_reference_blocks_publish() {
    let (_dir, _a, mut b, base) = pair();
    put_record(
        &b,
        "hosts",
        &json!([
            host("host-one", "Original", "identity-one"),
            {"id":"jump-target","name":"Target","host":"127.0.0.1","username":"tester","port":22,"group":"","tags":[],"favorite":false,"identityId":"identity-one","jumpHostIds":["missing-jump"]}
        ])
        .to_string(),
    )
    .unwrap();
    let local = capture(&b, &base, DEVICE_B).unwrap();
    let plan = merge(&base, &local, &base).unwrap();
    assert!(!plan.is_resolved());
    assert_eq!(plan.missing_jump_hosts().len(), 1);
    assert_eq!(plan.missing_jump_hosts()[0].host_id, "jump-target");
    assert_eq!(plan.missing_jump_hosts()[0].jump_host_id, "missing-jump");
    assert!(plan.snapshot().is_err());
    assert!(apply_merge(&mut b, &plan).is_err());
}
#[test]
fn sync_conflicting_edit_and_delete_preserve_both_and_block_all_writes() {
    let (_dir, mut a, b, base) = pair();
    put_record(
        &a,
        "hosts",
        &json!([host("host-one", "Edited", "identity-one")]).to_string(),
    )
    .unwrap();
    put_record(&b, "hosts", "[]").unwrap();
    let local = capture(&a, &base, DEVICE_A).unwrap();
    let remote = capture(&b, &base, DEVICE_B).unwrap();
    let plan = merge(&base, &local, &remote).unwrap();
    assert_eq!(plan.conflicts().len(), 1);
    let conflict = &plan.conflicts()[0];
    assert!(conflict.existed_in_base());
    assert!(!conflict.local_deleted());
    assert!(conflict.remote_deleted());
    assert_eq!(
        conflict.local.as_ref().unwrap().value.as_ref().unwrap()["name"],
        "Edited"
    );
    assert!(plan.snapshot().is_err());
    assert!(apply_merge(&mut a, &plan).is_err());
    assert!(capture(&a, &base, DEVICE_A).unwrap() == local);
}
#[test]
fn sync_two_edits_and_identical_edits_are_distinguished() {
    let (_dir, a, b, base) = pair();
    put_record(
        &a,
        "hosts",
        &json!([host("host-one", "Mac", "identity-one")]).to_string(),
    )
    .unwrap();
    put_record(
        &b,
        "hosts",
        &json!([host("host-one", "Phone", "identity-one")]).to_string(),
    )
    .unwrap();
    let local = capture(&a, &base, DEVICE_A).unwrap();
    let remote = capture(&b, &base, DEVICE_B).unwrap();
    assert_eq!(merge(&base, &local, &remote).unwrap().conflicts().len(), 1);
    put_record(
        &b,
        "hosts",
        &json!([host("host-one", "Mac", "identity-one")]).to_string(),
    )
    .unwrap();
    let remote = capture(&b, &base, DEVICE_B).unwrap();
    assert!(
        merge(&base, &local, &remote).unwrap().snapshot().unwrap()
            == merge(&base, &remote, &local).unwrap().snapshot().unwrap()
    );
}
#[test]
fn sync_tombstones_prevent_unchanged_device_resurrection() {
    let (_dir, mut a, b, base) = pair();
    put_record(&b, "hosts", "[]").unwrap();
    let local = capture(&a, &base, DEVICE_A).unwrap();
    let remote = capture(&b, &base, DEVICE_B).unwrap();
    let plan = merge(&base, &local, &remote).unwrap();
    apply_merge(&mut a, &plan).unwrap();
    assert_eq!(read_record(&a, "hosts").unwrap(), "[]");
    let result = plan.snapshot().unwrap();
    let recaptured = capture(&a, result, DEVICE_A).unwrap();
    assert!(recaptured == *result);
    assert!(recaptured
        .records
        .iter()
        .any(|r| r.key.kind == Kind::Host && r.value.is_none()));
    let mut malformed = remote.clone();
    malformed.records.retain(|r| r.key.kind != Kind::Host);
    assert!(merge(&base, &local, &malformed).is_err());
}
#[test]
fn sync_stale_local_plan_is_rejected_without_overwrite() {
    let (_dir, mut a, b, base) = pair();
    let local = capture(&a, &base, DEVICE_A).unwrap();
    let remote = capture(&b, &base, DEVICE_B).unwrap();
    let plan = merge(&base, &local, &remote).unwrap();
    a.execute("UPDATE identities SET password='new-local-secret'", [])
        .unwrap();
    assert!(apply_merge(&mut a, &plan).is_err());
    let secret: String = a
        .query_row("SELECT password FROM identities", [], |r| r.get(0))
        .unwrap();
    assert_eq!(secret, "new-local-secret");
}
#[test]
fn sync_cross_record_identity_deletion_blocks_merge() {
    let (_dir, mut a, b, base) = pair();
    // One device removes the old host and identity; another adds a referencing host.
    put_record(&a, "hosts", "[]").unwrap();
    a.execute("DELETE FROM identities", []).unwrap();
    put_record(
        &b,
        "hosts",
        &json!([
            host("host-one", "Original", "identity-one"),
            host("host-two", "New", "identity-one")
        ])
        .to_string(),
    )
    .unwrap();
    let local = capture(&a, &base, DEVICE_A).unwrap();
    let remote = capture(&b, &base, DEVICE_B).unwrap();
    let plan = merge(&base, &local, &remote).unwrap();
    assert_eq!(plan.missing_identities().len(), 1);
    assert_eq!(plan.missing_identities()[0].host_id, "host-two");
    assert!(apply_merge(&mut a, &plan).is_err());
    assert!(capture(&a, &base, DEVICE_A).unwrap() == local);
}
#[test]
fn sync_bad_key_rolls_back_partial_identity_writes() {
    let (_dir, mut a, b, base) = pair();
    let local = capture(&a, &base, DEVICE_A).unwrap();
    let mut remote = capture(&b, &base, DEVICE_B).unwrap();
    remote.records.push(Record { key: Key { kind: Kind::Identity, id: "zz-bad-key".into() },
        revision: Revision { counter: 2, device: DEVICE_B.into() },
        value: Some(json!({"id":"zz-bad-key","name":"Bad","username":"u","kind":"key","password":"","private_key":"synthetic-invalid-key","passphrase":""})) });
    let plan = merge(&base, &local, &remote).unwrap();
    assert!(apply_merge(&mut a, &plan).is_err());
    assert!(capture(&a, &base, DEVICE_A).unwrap() == local);
}
#[test]
fn sync_folder_tree_conflicts_are_conservative() {
    let (_dir, a, b, base) = pair();
    put_record(&a, "folders", "[\"Mac\"]").unwrap();
    put_record(&b, "folders", "[\"Phone\"]").unwrap();
    let plan = merge(
        &base,
        &capture(&a, &base, DEVICE_A).unwrap(),
        &capture(&b, &base, DEVICE_B).unwrap(),
    )
    .unwrap();
    assert!(plan.conflicts()[0].key().kind == Kind::Folders);
}
#[test]
fn sync_protocol_rejects_wrong_space_version_duplicates_and_revision_rollback() {
    let (_dir, a, b, base) = pair();
    let local = capture(&a, &base, DEVICE_A).unwrap();
    let remote = capture(&b, &base, DEVICE_B).unwrap();
    let bytes = remote.encode().unwrap();
    assert!(Snapshot::decode(&bytes).unwrap() == remote);
    assert!(Snapshot::decode(b"{bad secret payload")
        .err()
        .unwrap()
        .to_string()
        .contains("格式无效"));
    let mut wrong = remote.clone();
    wrong.version = 100;
    assert!(merge(&base, &local, &wrong).is_err());
    let mut wrong = remote.clone();
    wrong.space = uuid::Uuid::new_v4().to_string();
    assert!(merge(&base, &local, &wrong).is_err());
    let mut wrong = remote.clone();
    wrong.records.push(wrong.records[0].clone());
    assert!(merge(&base, &local, &wrong).is_err());
    let mut wrong = remote.clone();
    wrong.records[0].revision.counter = 0;
    assert!(merge(&base, &local, &wrong).is_err());
    let mut wrong = remote.clone();
    let h = wrong
        .records
        .iter_mut()
        .find(|r| r.key.kind == Kind::Host)
        .unwrap();
    h.value.as_mut().unwrap()["name"] = json!("Unversioned edit");
    assert!(merge(&base, &local, &wrong).is_err());
    // Encoding errors never echo credentials or unknown payload field names.
    let mut raw: Value = serde_json::from_slice(&bytes).unwrap();
    raw["unique-secret-field"] = json!("secret");
    assert!(Snapshot::decode(&serde_json::to_vec(&raw).unwrap()).is_err());
    let mut omitted: Value = serde_json::from_slice(&bytes).unwrap();
    omitted["records"][0]
        .as_object_mut()
        .unwrap()
        .remove("value");
    assert!(Snapshot::decode(&serde_json::to_vec(&omitted).unwrap()).is_err());
    assert!(Snapshot::decode(&vec![0; MAX_BYTES + 1]).is_err());
    let count: i64 = a
        .query_row(
            "SELECT count(*) FROM identities WHERE password=?1",
            params!["unique-sync-secret"],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(count, 1);
}

#[test]
fn sync_encrypted_software_key_keeps_id_and_authentication_material() {
    let (_dir, mut a, b, base) = pair();
    let key =
        russh::keys::PrivateKey::random(&mut rand::rng(), russh::keys::Algorithm::Ed25519).unwrap();
    let encrypted = key
        .encrypt(&mut rand::rng(), "fixture-key-passphrase")
        .unwrap();
    let encoded = encrypted
        .to_openssh(russh::keys::ssh_key::LineEnding::LF)
        .unwrap();
    b.execute(
        "INSERT INTO identities VALUES ('software-key','Key','tester','key','',?1,?2)",
        params![encoded.as_str(), "fixture-key-passphrase"],
    )
    .unwrap();
    let local = capture(&a, &base, DEVICE_A).unwrap();
    let remote = capture(&b, &base, DEVICE_B).unwrap();
    apply_merge(&mut a, &merge(&base, &local, &remote).unwrap()).unwrap();
    let saved: String = a
        .query_row(
            "SELECT private_key FROM identities WHERE id='software-key'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    let decoded = russh::keys::decode_secret_key(&saved, Some("fixture-key-passphrase")).unwrap();
    assert_eq!(decoded.public_key(), key.public_key());
}

#[test]
fn sync_conflicting_passwords_keep_both_original_values() {
    let (_dir, a, b, base) = pair();
    a.execute("UPDATE identities SET password='mac-password'", [])
        .unwrap();
    b.execute("UPDATE identities SET password='phone-password'", [])
        .unwrap();
    let plan = merge(
        &base,
        &capture(&a, &base, DEVICE_A).unwrap(),
        &capture(&b, &base, DEVICE_B).unwrap(),
    )
    .unwrap();
    assert_eq!(plan.conflicts().len(), 1);
    let c = &plan.conflicts()[0];
    assert!(c.key().kind == Kind::Identity);
    assert!(c.local.as_ref().unwrap().value.as_ref().unwrap()["password"] == "mac-password");
    assert!(c.remote.as_ref().unwrap().value.as_ref().unwrap()["password"] == "phone-password");
}

#[test]
fn sync_snapshot_canonical_order_and_aggregate_capacity_are_enforced() {
    let (_dir, a, _b, base) = pair();
    let original = capture(&a, &base, DEVICE_A).unwrap();
    let mut reordered = original.clone();
    reordered.records.reverse();
    assert!(Snapshot::decode(&reordered.encode().unwrap()).unwrap() == original);
    let mut too_many = empty();
    too_many.records = (0..1001)
        .map(|index| {
            let id = format!("snippet-{index}");
            Record {
                key: Key {
                    kind: Kind::Snippet,
                    id: id.clone(),
                },
                revision: Revision {
                    counter: 1,
                    device: DEVICE_A.into(),
                },
                value: Some(json!({"id":id,"name":"Snippet","command":"pwd"})),
            }
        })
        .collect();
    assert!(too_many.encode().is_err());
    // Individually valid branches can still exceed the destination capacity together.
    let mut local = too_many.clone();
    local.records.truncate(501);
    let mut remote = too_many;
    remote.records.drain(0..501);
    assert!(merge(&empty(), &local, &remote).is_err());
}

#[test]
fn sync_merge_rejects_combined_collection_larger_than_vault_limit() {
    let mut local = empty();
    local.records = (0..300)
        .map(|index| {
            let id = format!("large-snippet-{index}");
            Record {
                key: Key {
                    kind: Kind::Snippet,
                    id: id.clone(),
                },
                revision: Revision {
                    counter: 1,
                    device: DEVICE_A.into(),
                },
                value: Some(json!({"id":id,"name":"Large","command":"a".repeat(16000)})),
            }
        })
        .collect();
    let remote = Snapshot {
        records: local.records.split_off(150),
        ..empty()
    };
    assert!(local.encode().is_ok());
    assert!(remote.encode().is_ok());
    assert!(merge(&empty(), &local, &remote).is_err());
}

#[test]
fn sync_settings_roundtrip_and_merge() {
    let (_dir, mut a, _b, base) = pair();
    let settings = json!({
        "version": 1,
        "appearance": {"palette": "nord", "fontSize": 15},
        "plugins": {"linkUnderline": true},
        "pinned": {"version": 1, "entries": []},
        "highlights": {"enabled": false, "keywords": [], "colorArgb": 4294958438u32}
    });
    put_record(&a, "settings", &settings.to_string()).unwrap();
    let local = capture(&a, &base, DEVICE_A).unwrap();
    assert!(local
        .records
        .iter()
        .any(|r| r.key.kind == Kind::Settings && r.value.is_some()));
    let plan = merge(&base, &local, &base).unwrap();
    assert!(plan.is_resolved());
    apply_merge(&mut a, &plan).unwrap();
    let stored: Value =
        serde_json::from_str(&read_record(&a, "settings").unwrap()).unwrap();
    assert_eq!(stored, settings);
    let recaptured = capture(&a, plan.snapshot().unwrap(), DEVICE_A).unwrap();
    assert!(recaptured
        .records
        .iter()
        .any(|r| r.key.kind == Kind::Settings));
}
