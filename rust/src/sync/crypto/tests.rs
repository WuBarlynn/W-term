use super::*;
use crate::api::vault::{open_database, put_record};
use serde_json::json;
const SPACE: &str = "10000000-0000-4000-8000-000000000001";
const PASSWORD: &str = "synthetic sync password";
fn fixture() -> &'static (SyncKey, KeyEnvelope, RecoveryCode) {
    static FIXTURE: std::sync::OnceLock<(SyncKey, KeyEnvelope, RecoveryCode)> =
        std::sync::OnceLock::new();
    FIXTURE.get_or_init(|| create(SPACE.into(), PASSWORD).unwrap())
}
fn snapshot() -> Snapshot {
    let mut snapshot = Snapshot::empty(SPACE.into()).unwrap();
    snapshot.records.push(Record{key:Key{kind:Kind::Identity,id:"fixture-identity".into()},revision:Revision{counter:1,device:uuid::Uuid::new_v4().to_string()},
        value:Some(json!({"id":"fixture-identity","name":"Synthetic","username":"tester","kind":"password","password":"unique-sync-plaintext","private_key":"","passphrase":""}))});
    snapshot
}
fn batch() -> String {
    uuid::Uuid::new_v4().to_string()
}
#[test]
fn password_and_recovery_unlock_the_same_key_across_devices() {
    let (key, envelope, code) = fixture();
    let bytes = envelope.encode().unwrap();
    let copy = KeyEnvelope::decode(&bytes).unwrap();
    let password = unlock_password(&copy, SPACE, PASSWORD).unwrap();
    let recovered = unlock_recovery(&copy, SPACE, &code.expose().to_ascii_lowercase()).unwrap();
    let snapshot = snapshot();
    let packet = encrypt(&snapshot, key, batch(), Some("a".repeat(40))).unwrap();
    for key in [&password, &recovered] {
        assert!(decrypt(&packet, key).unwrap().snapshot == snapshot);
    }
    for secret in [PASSWORD, code.expose(), "unique-sync-plaintext"] {
        assert!(!bytes.windows(secret.len()).any(|w| w == secret.as_bytes()));
    }
}
#[test]
fn wrong_password_recovery_and_space_are_rejected() {
    let (_, envelope, _) = fixture();
    assert!(unlock_password(envelope, SPACE, "wrong fixture password").is_err());
    let (code, _) = new_recovery().unwrap();
    assert!(unlock_recovery(envelope, SPACE, code.expose()).is_err());
    assert!(unlock_recovery(envelope, SPACE, "WT1-broken").is_err());
    assert!(unlock_password(envelope, &uuid::Uuid::new_v4().to_string(), PASSWORD).is_err());
}
#[test]
fn packet_is_randomized_and_authenticated_before_snapshot_parsing() {
    let (key, _, _) = fixture();
    let snapshot = snapshot();
    let id = batch();
    let one = encrypt(&snapshot, key, id.clone(), None).unwrap();
    let two = encrypt(&snapshot, key, id.clone(), None).unwrap();
    assert_ne!(one, two);
    let opened = decrypt(&one, key).unwrap();
    assert_eq!(opened.batch_id, id);
    assert!(opened.snapshot == snapshot);
    assert!(!one
        .windows(b"unique-sync-plaintext".len())
        .any(|w| w == b"unique-sync-plaintext"));
    let original: Value = serde_json::from_slice(&one).unwrap();
    for (field, value) in [
        ("batch_id", json!(batch())),
        ("parent", json!("a".repeat(40))),
        ("space", json!(uuid::Uuid::new_v4().to_string())),
        ("key_id", json!(uuid::Uuid::new_v4().to_string())),
        ("version", json!(2)),
        ("suite", json!("unknown")),
    ] {
        let mut modified = original.clone();
        modified["header"][field] = value;
        assert!(decrypt(&serde_json::to_vec(&modified).unwrap(), key).is_err());
    }
    for field in ["salt", "nonce", "ciphertext"] {
        let mut modified = original.clone();
        let mut decoded = Base64::decode_vec(modified["sealed"][field].as_str().unwrap()).unwrap();
        decoded[0] ^= 1;
        modified["sealed"][field] = json!(Base64::encode_string(&decoded));
        assert!(decrypt(&serde_json::to_vec(&modified).unwrap(), key).is_err());
    }
    let other = SyncKey {
        space: SPACE.into(),
        id: key.id.clone(),
        secret: random::<32>().unwrap(),
    };
    assert!(decrypt(&one, &other).is_err());
}
#[test]
fn envelope_mac_protects_both_unlock_paths_and_kdf_cannot_be_inflated() {
    let (_, original, code) = fixture();
    let mut changed = original.clone();
    let mut bytes = Base64::decode_vec(&changed.wrapped.password.ciphertext).unwrap();
    bytes[0] ^= 1;
    changed.wrapped.password.ciphertext = Base64::encode_string(&bytes);
    // Even the still-intact recovery slot rejects a tampered password slot.
    assert!(unlock_recovery(&changed, SPACE, code.expose()).is_err());
    let mut changed = original.clone();
    changed.wrapped.header.kdf = "argon2id-m4294967295".into();
    assert!(changed.encode().is_err());
    assert!(unlock_password(&changed, SPACE, PASSWORD).is_err());
    let mut changed = original.clone();
    changed.mac = Base64::encode_string(&[0; 32]);
    assert!(unlock_recovery(&changed, SPACE, code.expose()).is_err());
}
#[test]
fn recovery_checksum_rejects_typos_and_codes_are_independent() {
    let (one, key) = new_recovery().unwrap();
    let (two, _) = new_recovery().unwrap();
    assert_ne!(one.expose(), two.expose());
    assert!(parse_recovery(one.expose()).unwrap() == key);
    let mut typo = one.expose().as_bytes().to_vec();
    typo[4] = if typo[4] == b'A' { b'B' } else { b'A' };
    assert!(parse_recovery(std::str::from_utf8(&typo).unwrap()).is_err());
    assert!(parse_recovery(&"a".repeat(129)).is_err());
}
#[test]
fn bounded_decoders_reject_truncation_missing_fields_and_oversized_data() {
    let (key, envelope, _) = fixture();
    let packet = encrypt(&snapshot(), key, batch(), None).unwrap();
    assert!(decrypt(&packet[..packet.len() - 1], key).is_err());
    let mut raw: Value = serde_json::from_slice(&packet).unwrap();
    raw["header"].as_object_mut().unwrap().remove("parent");
    assert!(decrypt(&serde_json::to_vec(&raw).unwrap(), key).is_err());
    assert!(decrypt(&vec![0; PACKET_LIMIT + 1], key).is_err());
    assert!(KeyEnvelope::decode(&vec![0; KEY_LIMIT + 1]).is_err());
    let mut raw: Value = serde_json::from_slice(&envelope.encode().unwrap()).unwrap();
    raw["extra"] = json!("secret");
    assert!(KeyEnvelope::decode(&serde_json::to_vec(&raw).unwrap()).is_err());
    assert!(create(SPACE.into(), "short").is_err());
}
#[test]
fn key_custody_reopens_and_ciphertext_roundtrips_into_another_vault() {
    let (key, envelope, code) = fixture();
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("a.db");
    let mut a = open_database(&path, "local fixture password", true).unwrap();
    super::super::state::initialize(&mut a, SPACE.into()).unwrap();
    install(&mut a, key, envelope).unwrap();
    assert!(install(&mut a, key, envelope).is_err());
    put_record(
        &a,
        "snippets",
        r#"[{"id":"snippet","name":"Synthetic","command":"echo unique-encrypted-pending"}]"#,
    )
    .unwrap();
    let state = super::super::state::load(&a).unwrap().unwrap();
    let prepared = super::super::state::prepare(
        &mut a,
        state.generation(),
        &Snapshot::empty(SPACE.into()).unwrap(),
        None,
    )
    .unwrap();
    let super::super::state::Preparation::Ready(pending) = prepared else {
        panic!("unexpected conflict")
    };
    let packet = encrypt_pending(&a).unwrap();
    drop(a);
    let a = open_database(&path, "local fixture password", false).unwrap();
    let (saved, _) = load(&a).unwrap().unwrap();
    assert_eq!(saved.id(), key.id());
    assert!(decrypt(&packet, &saved).unwrap().snapshot == *pending.snapshot());
    let recovered = unlock_recovery(envelope, SPACE, code.expose()).unwrap();
    let opened = decrypt(&packet, &recovered).unwrap();
    let mut b = open_database(&dir.path().join("b.db"), "other local password", true).unwrap();
    let state = super::super::state::initialize(&mut b, SPACE.into()).unwrap();
    install(&mut b, &recovered, envelope).unwrap();
    let result = super::super::state::prepare(
        &mut b,
        state.generation(),
        &opened.snapshot,
        Some("a".repeat(40)),
    )
    .unwrap();
    assert!(matches!(result, super::super::state::Preparation::Ready(_)));
    assert!(crate::api::vault::read_record(&b, "snippets")
        .unwrap()
        .contains("unique-encrypted-pending"));
    let file = std::fs::read(path).unwrap();
    let root = Base64::encode_string(key.secret.as_ref());
    for secret in [root.as_str(), code.expose(), "unique-encrypted-pending"] {
        assert!(!file.windows(secret.len()).any(|w| w == secret.as_bytes()));
    }
}
#[test]
fn encrypt_pending_keeps_local_only_material_out_of_decrypted_payload() {
    let (key, envelope, _) = fixture();
    let dir = tempfile::tempdir().unwrap();
    let mut db = open_database(&dir.path().join("a"), "local fixture password", true).unwrap();
    let s = super::super::state::initialize(&mut db, SPACE.into()).unwrap();
    install(&mut db, key, envelope).unwrap();
    put_record(
        &db,
        "snippets",
        r#"[{"id":"private","name":"Only here","command":"echo only-local-secret"}]"#,
    )
    .unwrap();
    let p = super::super::state::Policy::new(BTreeSet::from([Key {
        kind: Kind::Snippet,
        id: "private".into(),
    }]))
    .unwrap();
    let s = super::super::state::set_policy(&mut db, s.generation(), p).unwrap();
    super::super::state::prepare(
        &mut db,
        s.generation(),
        &Snapshot::empty(SPACE.into()).unwrap(),
        None,
    )
    .unwrap();
    let opened = decrypt(&encrypt_pending(&db).unwrap(), key).unwrap();
    assert!(opened.snapshot.records.is_empty());
}
#[test]
#[ignore = "Run scripts/test-core.sh for the independent Python cryptography runtime"]
fn fixture_crypto_python_interoperability() {
    use std::io::Write;
    let (key, _, _) = fixture();
    let snapshot = snapshot();
    let packet = encrypt(&snapshot, key, batch(), None).unwrap();
    let python = std::env::var("WTERM_CRYPTO_PYTHON").unwrap();
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap();
    let mut child = std::process::Command::new(python)
        .arg(root.join("tests/fixtures/crypto_interop.py"))
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let input = json!({"root":Base64::encode_string(key.secret.as_ref()),"packet":String::from_utf8(packet).unwrap()});
    child
        .stdin
        .take()
        .unwrap()
        .write_all(&serde_json::to_vec(&input).unwrap())
        .unwrap();
    let result = child.wait_with_output().unwrap();
    assert!(
        result.status.success(),
        "independent crypto implementation failed"
    );
    assert!(decrypt(&result.stdout, key).unwrap().snapshot == snapshot);
}
