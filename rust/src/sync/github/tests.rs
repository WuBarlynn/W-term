use super::*;
use crate::api::vault::{open_database, put_record};
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
const SPACE: &str = "10000000-0000-4000-8000-000000000001";
const PASSWORD: &str = "synthetic transport password";
const TOKEN: &str = "synthetic-github-token";
struct Fake {
    head: String,
    commits: BTreeMap<String, Value>,
    trees: BTreeMap<String, Value>,
    blobs: BTreeMap<String, Vec<u8>>,
    counter: u64,
    requests: Vec<(String, String, Value)>,
    private: bool,
    repo_id: u64,
    lose_patch: bool,
    race: bool,
    corrupt_blob: bool,
    status: u16,
    status_path: Option<String>,
    oversized: bool,
    advance_after_reads: Option<usize>,
}
impl Fake {
    fn new() -> Self {
        let tree = "b".repeat(40);
        let head = "a".repeat(40);
        let readme = b"fixture readme".to_vec();
        let blob = blob_sha(&readme);
        Self {
            head: head.clone(),
            commits: BTreeMap::from([(
                head.clone(),
                json!({"sha":head,"tree":{"sha":tree},"parents":[]}),
            )]),
            trees: BTreeMap::from([(
                tree.clone(),
                json!({"sha":tree,"truncated":false,"tree":[{"path":"README.md","mode":"100644","type":"blob","sha":blob}]}),
            )]),
            blobs: BTreeMap::from([(blob, readme)]),
            counter: 10,
            requests: vec![],
            private: true,
            repo_id: 17,
            lose_patch: false,
            race: false,
            corrupt_blob: false,
            status: 0,
            status_path: None,
            oversized: false,
            advance_after_reads: None,
        }
    }
    fn id(&mut self) -> String {
        self.counter += 1;
        format!("{:040x}", self.counter)
    }
    fn child(&mut self, parent: String) -> String {
        let tree = self.commits[&parent]["tree"].clone();
        let id = self.id();
        self.commits.insert(
            id.clone(),
            json!({"sha":id,"tree":tree,"parents":[{"sha":parent}]}),
        );
        id
    }
    fn handle(&mut self, method: &str, path: &str, body: Value) -> (u16, Value) {
        self.requests
            .push((method.into(), path.into(), body.clone()));
        let path = path
            .strip_prefix("/repos/fixture/vault")
            .unwrap_or("INVALID");
        if self.status != 0 && self.status_path.as_deref().is_none_or(|p| p == path) {
            return (self.status, json!({"message":TOKEN}));
        }
        if method == "GET" && path == "/git/ref/heads/sync" {
            if let Some(left) = self.advance_after_reads.as_mut() {
                *left -= 1;
                if *left == 0 {
                    self.advance_after_reads = None;
                    self.head = self.child(self.head.clone());
                }
            }
        }
        match (method, path) {
            ("GET", "") => (
                200,
                json!({"id":self.repo_id,"full_name":"fixture/vault","private":self.private,"archived":false,"permissions":{"push":true}}),
            ),
            ("GET", "/git/ref/heads/sync") => (
                200,
                json!({"ref":"refs/heads/sync","object":{"type":"commit","sha":self.head}}),
            ),
            ("POST", "/git/blobs") => {
                let data = Base64::decode_vec(body["content"].as_str().unwrap()).unwrap();
                let id = blob_sha(&data);
                self.blobs.insert(id.clone(), data);
                (201, json!({"sha":id}))
            }
            ("POST", "/git/trees") => {
                let mut entries = self.trees[body["base_tree"].as_str().unwrap()]["tree"]
                    .as_array()
                    .unwrap()
                    .clone();
                for item in body["tree"].as_array().unwrap() {
                    entries.retain(|e| e["path"] != item["path"]);
                    entries.push(item.clone());
                }
                let id = self.id();
                let tree = json!({"sha":id,"truncated":false,"tree":entries});
                self.trees.insert(id.clone(), tree.clone());
                (201, tree)
            }
            ("POST", "/git/commits") => {
                let id = self.id();
                let parents = body["parents"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|p| json!({"sha":p}))
                    .collect::<Vec<_>>();
                let c = json!({"sha":id,"tree":{"sha":body["tree"]},"parents":parents});
                self.commits.insert(id, c.clone());
                (201, c)
            }
            ("PATCH", "/git/refs/heads/sync") => {
                assert_eq!(body["force"], false);
                if self.race {
                    self.race = false;
                    self.head = self.child(self.head.clone());
                }
                let id = body["sha"].as_str().unwrap().to_string();
                if self.commits[&id]["parents"][0]["sha"] != self.head {
                    return (422, json!({"message":"non-fast-forward"}));
                }
                self.head = id;
                if self.lose_patch {
                    self.lose_patch = false;
                    return (503, json!({"message":"response unavailable"}));
                }
                (
                    200,
                    json!({"ref":"refs/heads/sync","object":{"type":"commit","sha":self.head}}),
                )
            }
            ("GET", p) if p.starts_with("/git/commits/") => (
                200,
                self.commits.get(&p[13..]).cloned().unwrap_or(Value::Null),
            ),
            ("GET", p) if p.starts_with("/git/trees/") => (
                200,
                self.trees.get(&p[11..]).cloned().unwrap_or(Value::Null),
            ),
            ("GET", p) if p.starts_with("/git/blobs/") => {
                let id = &p[11..];
                let mut data = self.blobs[id].clone();
                if self.corrupt_blob && !data.is_empty() {
                    data[0] ^= 1;
                }
                (
                    200,
                    json!({"sha":id,"encoding":"base64","size":data.len(),"content":Base64::encode_string(&data)}),
                )
            }
            _ => (404, json!({"message":"unknown fixture path"})),
        }
    }
    fn mutations(&self) -> usize {
        self.requests.iter().filter(|r| r.0 != "GET").count()
    }
}
struct Server {
    data: Arc<Mutex<Fake>>,
    task: tokio::task::JoinHandle<()>,
    base: String,
}
impl Drop for Server {
    fn drop(&mut self) {
        self.task.abort();
    }
}
impl Server {
    async fn new() -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let data = Arc::new(Mutex::new(Fake::new()));
        let shared = data.clone();
        let task = tokio::spawn(async move {
            loop {
                let (mut socket, _) = listener.accept().await.unwrap();
                let shared = shared.clone();
                tokio::spawn(async move {
                    let mut request = Vec::new();
                    let mut buf = [0u8; 8192];
                    let (end, len) = loop {
                        let n = socket.read(&mut buf).await.unwrap();
                        if n == 0 {
                            return;
                        }
                        request.extend_from_slice(&buf[..n]);
                        if let Some(end) = request.windows(4).position(|s| s == b"\r\n\r\n") {
                            let header = String::from_utf8_lossy(&request[..end]);
                            let len = header
                                .lines()
                                .find_map(|l| {
                                    l.to_ascii_lowercase()
                                        .strip_prefix("content-length:")
                                        .map(|s| s.trim().parse::<usize>().unwrap())
                                })
                                .unwrap_or(0);
                            break (end + 4, len);
                        }
                        assert!(request.len() < 16384);
                    };
                    while request.len() < end + len {
                        let n = socket.read(&mut buf).await.unwrap();
                        if n == 0 {
                            return;
                        }
                        request.extend_from_slice(&buf[..n]);
                    }
                    let header = String::from_utf8_lossy(&request[..end]);
                    assert!(header
                        .to_ascii_lowercase()
                        .contains(&format!("authorization: bearer {TOKEN}")));
                    let mut line = header.lines().next().unwrap().split_whitespace();
                    let method = line.next().unwrap();
                    let path = line.next().unwrap();
                    let body = if len == 0 {
                        Value::Null
                    } else {
                        serde_json::from_slice(&request[end..end + len]).unwrap()
                    };
                    let (status, value, oversized) = {
                        let mut f = shared.lock().unwrap();
                        let (s, v) = f.handle(method, path, body);
                        (s, v, f.oversized)
                    };
                    let bytes = serde_json::to_vec(&value).unwrap();
                    let len = if oversized { 999_999_999 } else { bytes.len() };
                    let header=format!("HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {len}\r\nConnection: close\r\nLocation: http://127.0.0.1:1/never-follow\r\n\r\n");
                    let _ = socket.write_all(header.as_bytes()).await;
                    let _ = socket.write_all(&bytes).await;
                });
            }
        });
        Self {
            data,
            task,
            base: format!("http://{addr}"),
        }
    }
    fn client(&self) -> GitHub {
        GitHub::build(
            Target::new("fixture".into(), "vault".into(), "sync".into()).unwrap(),
            TOKEN,
            self.base.clone(),
            false,
        )
        .unwrap()
    }
}
fn key() -> &'static (crypto::SyncKey, crypto::KeyEnvelope, crypto::RecoveryCode) {
    static KEY: std::sync::OnceLock<(crypto::SyncKey, crypto::KeyEnvelope, crypto::RecoveryCode)> =
        std::sync::OnceLock::new();
    KEY.get_or_init(|| crypto::create(SPACE.into(), PASSWORD).unwrap())
}
fn db(dir: &tempfile::TempDir) -> Connection {
    let mut db = open_database(&dir.path().join("github.db"), PASSWORD, true).unwrap();
    let s = state::initialize(&mut db, SPACE.into()).unwrap();
    crypto::install(&mut db, &key().0, &key().1).unwrap();
    put_record(
        &db,
        "snippets",
        r#"[{"id":"command","name":"Fixture","command":"echo secret-payload"}]"#,
    )
    .unwrap();
    state::prepare(
        &mut db,
        s.generation(),
        &Snapshot::empty(SPACE.into()).unwrap(),
        None,
    )
    .unwrap();
    db
}
fn generation(db: &Connection) -> u64 {
    state::load(db).unwrap().unwrap().generation()
}
#[test]
fn target_and_token_validation_rejects_url_injection() {
    for (owner, repo, branch) in [
        ("fixture/evil", "vault", "sync"),
        ("fixture", "../vault", "sync"),
        ("fixture", "vault", "a//b"),
        ("fixture", "vault", "a?x"),
        ("fixture", "vault", "../x"),
    ] {
        assert!(Target::new(owner.into(), repo.into(), branch.into()).is_err());
    }
    let target = Target::new("fixture".into(), "vault".into(), "sync".into()).unwrap();
    assert!(GitHub::new(target, "token\r\nInjected: true").is_err());
}
#[tokio::test]
async fn publishes_both_files_in_one_commit_and_fetches_with_pinned_ancestry() {
    let server = Server::new().await;
    let client = server.client();
    let dir = tempfile::tempdir().unwrap();
    let mut db = db(&dir);
    let g = generation(&db);
    let s = client.publish(&mut db, g).await.unwrap();
    assert!(!s.has_pending());
    assert!(!journal::exists(&db).unwrap());
    let files = client.fetch(s.remote_revision()).await.unwrap();
    let opened = crypto::decrypt(files.packet.as_ref().unwrap(), &key().0).unwrap();
    assert!(opened
        .snapshot
        .encode()
        .unwrap()
        .windows(b"secret-payload".len())
        .any(|b| b == b"secret-payload"));
    {
        let f = server.data.lock().unwrap();
        let tree = f.commits[&f.head]["tree"]["sha"].as_str().unwrap();
        assert_eq!(f.trees[tree]["tree"].as_array().unwrap().len(), 3);
        assert!(f
            .requests
            .iter()
            .filter(|r| r.0 == "POST")
            .all(|r| !r.2.to_string().contains("secret-payload")));
    }
    put_record(
        &db,
        "snippets",
        r#"[{"id":"command","name":"Second","command":"echo second"}]"#,
    )
    .unwrap();
    state::prepare(
        &mut db,
        s.generation(),
        &opened.snapshot,
        Some(files.revision.clone()),
    )
    .unwrap();
    let g = generation(&db);
    let s = client.publish(&mut db, g).await.unwrap();
    assert_ne!(s.remote_revision(), Some(files.revision.as_str()));
    assert!(client.fetch(Some(&files.revision)).await.is_ok());
}
#[tokio::test]
async fn lost_response_recovers_after_reopen_even_with_a_later_descendant() {
    let server = Server::new().await;
    server.data.lock().unwrap().lose_patch = true;
    let client = server.client();
    let dir = tempfile::tempdir().unwrap();
    let mut db = db(&dir);
    let g = generation(&db);
    assert!(client.publish(&mut db, g).await.is_err());
    assert!(journal::exists(&db).unwrap());
    let accepted = server.data.lock().unwrap().head.clone();
    let mutations = server.data.lock().unwrap().mutations();
    {
        let mut f = server.data.lock().unwrap();
        f.head = f.child(accepted.clone());
    }
    drop(db);
    let mut db = open_database(&dir.path().join("github.db"), PASSWORD, false).unwrap();
    let s = client.publish(&mut db, g).await.unwrap();
    assert_eq!(s.remote_revision(), Some(accepted.as_str()));
    assert_eq!(server.data.lock().unwrap().mutations(), mutations);
    assert!(!journal::exists(&db).unwrap());
}
#[tokio::test]
async fn competing_commit_never_force_pushes_or_clears_pending() {
    let server = Server::new().await;
    server.data.lock().unwrap().race = true;
    let client = server.client();
    let dir = tempfile::tempdir().unwrap();
    let mut db = db(&dir);
    let g = generation(&db);
    assert!(client.publish(&mut db, g).await.is_err());
    let head = server.data.lock().unwrap().head.clone();
    let count = server.data.lock().unwrap().mutations();
    assert!(client.publish(&mut db, g).await.is_err());
    assert_eq!(server.data.lock().unwrap().head, head);
    assert_eq!(server.data.lock().unwrap().mutations(), count);
    assert!(state::load(&db).unwrap().unwrap().has_pending());
    let p = state::pending_upload(&db).unwrap().unwrap();
    assert!(state::discard_pending(&mut db, g, p.id()).is_err());
}
#[tokio::test]
async fn public_repo_errors_redirects_and_oversized_responses_fail_without_upload() {
    let server = Server::new().await;
    let client = server.client();
    let dir = tempfile::tempdir().unwrap();
    let mut db = db(&dir);
    let g = generation(&db);
    server.data.lock().unwrap().private = false;
    assert!(client.publish(&mut db, g).await.is_err());
    server.data.lock().unwrap().private = true;
    for status in [401, 403, 429, 503, 302] {
        server.data.lock().unwrap().status = status;
        let error = client.publish(&mut db, g).await.err().unwrap().to_string();
        assert!(!error.contains(TOKEN));
    }
    {
        let mut f = server.data.lock().unwrap();
        f.status = 0;
        f.oversized = true;
    }
    assert!(client.publish(&mut db, g).await.is_err());
    assert_eq!(server.data.lock().unwrap().mutations(), 0);
    assert!(!journal::exists(&db).unwrap());
}
#[tokio::test]
async fn tampered_blob_is_not_acknowledged_and_retry_verifies_original_commit() {
    let server = Server::new().await;
    server.data.lock().unwrap().corrupt_blob = true;
    let client = server.client();
    let dir = tempfile::tempdir().unwrap();
    let mut db = db(&dir);
    let g = generation(&db);
    assert!(client.publish(&mut db, g).await.is_err());
    assert!(state::load(&db).unwrap().unwrap().has_pending());
    let count = server.data.lock().unwrap().mutations();
    server.data.lock().unwrap().corrupt_blob = false;
    client.publish(&mut db, g).await.unwrap();
    assert_eq!(server.data.lock().unwrap().mutations(), count);
}
#[tokio::test]
async fn receipt_cleanup_failure_rolls_back_and_repo_identity_cannot_change() {
    let server = Server::new().await;
    let client = server.client();
    let dir = tempfile::tempdir().unwrap();
    let mut db = db(&dir);
    let g = generation(&db);
    db.execute_batch("CREATE TRIGGER fail_cleanup BEFORE DELETE ON metadata WHEN OLD.key='sync_github_attempt_v1' BEGIN SELECT RAISE(ABORT,'fixture'); END;").unwrap();
    assert!(client.publish(&mut db, g).await.is_err());
    assert_eq!(generation(&db), g);
    assert!(journal::exists(&db).unwrap());
    assert!(outbox::exists_in_transaction(&db).unwrap());
    server.data.lock().unwrap().repo_id = 99;
    assert!(client.publish(&mut db, g).await.is_err());
    server.data.lock().unwrap().repo_id = 17;
    db.execute_batch("DROP TRIGGER fail_cleanup").unwrap();
    assert!(client.publish(&mut db, g).await.is_ok());
}
#[tokio::test]
async fn fetch_rejects_rollback_partial_files_symlinks_and_truncated_tree() {
    let server = Server::new().await;
    let client = server.client();
    let dir = tempfile::tempdir().unwrap();
    let mut db = db(&dir);
    let g = generation(&db);
    let s = client.publish(&mut db, g).await.unwrap();
    let head = server.data.lock().unwrap().head.clone();
    server.data.lock().unwrap().head = "a".repeat(40);
    assert!(client.fetch(s.remote_revision()).await.is_err());
    server.data.lock().unwrap().head = head;
    let (tree, original) = {
        let f = server.data.lock().unwrap();
        let tree = f.commits[&f.head]["tree"]["sha"]
            .as_str()
            .unwrap()
            .to_string();
        (tree.clone(), f.trees[&tree].clone())
    };
    let mut broken = original.clone();
    broken["truncated"] = json!(true);
    server
        .data
        .lock()
        .unwrap()
        .trees
        .insert(tree.clone(), broken);
    assert!(client.fetch(None).await.is_err());
    let mut broken = original.clone();
    broken["tree"]
        .as_array_mut()
        .unwrap()
        .retain(|e| e["path"] != KEY_FILE);
    server
        .data
        .lock()
        .unwrap()
        .trees
        .insert(tree.clone(), broken);
    assert!(client.fetch(None).await.is_err());
    let mut broken = original.clone();
    for e in broken["tree"].as_array_mut().unwrap() {
        if e["path"] == KEY_FILE {
            e["mode"] = json!("120000");
        }
    }
    server
        .data
        .lock()
        .unwrap()
        .trees
        .insert(tree.clone(), broken);
    assert!(client.fetch(None).await.is_err());
    // A first publication must not make its own new tree exceed the read limit.
    let entries = (0..999).map(|i| json!({"path":format!("file-{i}"),"mode":"100644","type":"blob","sha":"c".repeat(40)})).collect::<Vec<_>>();
    server.data.lock().unwrap().trees.insert(
        tree.clone(),
        json!({"sha":tree,"truncated":false,"tree":entries}),
    );
    assert!(client.fetch(None).await.is_err());
}
#[tokio::test]
async fn rotation_switches_key_only_after_verified_http_publication() {
    let server = Server::new().await;
    let client = server.client();
    let dir = tempfile::tempdir().unwrap();
    let mut db = db(&dir);
    let g = generation(&db);
    let s = client.publish(&mut db, g).await.unwrap();
    let code =
        crypto::rotation::begin(&mut db, s.generation(), "new transport sync password").unwrap();
    let g = generation(&db);
    crypto::rotation::confirm_recovery(&mut db, g, code.expose()).unwrap();
    server.data.lock().unwrap().lose_patch = true;
    assert!(client.publish(&mut db, g).await.is_err());
    assert_eq!(crypto::load(&db).unwrap().unwrap().0.id(), key().0.id());
    client.publish(&mut db, g).await.unwrap();
    assert_ne!(crypto::load(&db).unwrap().unwrap().0.id(), key().0.id());
}

#[tokio::test]
async fn journal_must_be_durable_before_any_publication_and_failed_saves_can_retry() {
    let server = Server::new().await;
    let client = server.client();
    let dir = tempfile::tempdir().unwrap();
    let mut db = db(&dir);
    let g = generation(&db);
    db.execute_batch("CREATE TRIGGER fail_journal BEFORE INSERT ON metadata WHEN NEW.key='sync_github_attempt_v1' BEGIN SELECT RAISE(ABORT,'fixture'); END;").unwrap();
    assert!(client.publish(&mut db, g).await.is_err());
    assert_eq!(server.data.lock().unwrap().mutations(), 0);
    assert!(!journal::exists(&db).unwrap());
    db.execute_batch("DROP TRIGGER fail_journal; CREATE TRIGGER fail_journal BEFORE UPDATE ON metadata WHEN NEW.key='sync_github_attempt_v1' BEGIN SELECT RAISE(ABORT,'fixture'); END;").unwrap();
    assert!(client.publish(&mut db, g).await.is_err());
    assert!(journal::load(&db).unwrap().unwrap().commit.is_none());
    assert!(!server
        .data
        .lock()
        .unwrap()
        .requests
        .iter()
        .any(|r| r.0 == "PATCH"));
    db.execute_batch("DROP TRIGGER fail_journal").unwrap();
    assert!(client.publish(&mut db, g).await.is_ok());
}

fn service_db(dir: &tempfile::TempDir) -> Connection {
    let mut db = open_database(&dir.path().join("service.db"), PASSWORD, true).unwrap();
    crate::sync::service::save_config(
        &mut db,
        "fixture".into(),
        "vault".into(),
        "sync".into(),
        TOKEN,
    )
    .unwrap();
    db
}

#[tokio::test]
async fn manual_sync_creates_joins_merges_and_preserves_conflicts() -> Result<()> {
    use crate::sync::service;
    let server = Server::new().await;
    let client = server.client();
    let a_dir = tempfile::tempdir()?;
    let b_dir = tempfile::tempdir()?;
    let mut a = service_db(&a_dir);
    let mut b = service_db(&b_dir);
    put_record(
        &a,
        "snippets",
        r#"[{"id":"a","name":"A","command":"echo a"}]"#,
    )?;
    let code = service::initialize_with(&mut a, "create", PASSWORD, &client).await?;
    assert!(!service::settings(&mut a)?.recovery_confirmed);
    assert!(service::run_with(&mut a, &client).await.is_err());
    assert!(service::confirm(&mut a, "wrong").is_err());
    service::confirm(&mut a, &code)?;
    service::run_with(&mut a, &client).await?;
    assert!(
        service::initialize_with(&mut b, "password", "wrong password", &client)
            .await
            .is_err()
    );
    assert!(!service::settings(&mut b)?.initialized);
    assert!(crypto::load(&b)?.is_none());
    service::initialize_with(&mut b, "recovery", &code, &client).await?;
    put_record(
        &b,
        "snippets",
        r#"[{"id":"b","name":"B","command":"echo b"}]"#,
    )?;
    service::run_with(&mut b, &client).await?;
    service::run_with(&mut a, &client).await?;
    let read = |db: &Connection| -> Result<String> {
        Ok(
            db.query_row("SELECT value FROM records WHERE kind='snippets'", [], |r| {
                r.get(0)
            })?,
        )
    };
    let aa: Value = serde_json::from_str(&read(&a)?)?;
    let bb: Value = serde_json::from_str(&read(&b)?)?;
    assert_eq!(aa, bb);
    assert_eq!(aa.as_array().unwrap().len(), 2);
    // A no-op pull acknowledges without another commit.
    let head = server.data.lock().unwrap().head.clone();
    service::run_with(&mut a, &client).await?;
    assert_eq!(head, server.data.lock().unwrap().head);
    let mut av = aa.clone();
    av[0]["command"] = json!("echo local");
    let mut bv = aa;
    bv[0]["command"] = json!("echo remote");
    put_record(&a, "snippets", &av.to_string())?;
    put_record(&b, "snippets", &bv.to_string())?;
    service::run_with(&mut b, &client).await?;
    let remote_head = server.data.lock().unwrap().head.clone();
    assert!(service::run_with(&mut a, &client).await?.contains("冲突"));
    assert_eq!(read(&a)?, av.to_string());
    assert_eq!(remote_head, server.data.lock().unwrap().head);
    assert!(!service::settings(&mut a)?.pending);
    let review = state::conflict_review(&a)?.unwrap();
    let choices = vec![crate::api::sync::SyncConflictChoice {
        kind: review.items[0].kind.clone(),
        id: review.items[0].id.clone(),
        side: "local".into(),
    }];
    // A new remote commit invalidates the displayed review before any local write.
    {
        let mut f = server.data.lock().unwrap();
        let parent = f.head.clone();
        f.head = f.child(parent);
    }
    assert!(service::resolve_with(&mut a, &review.id, &choices, &client)
        .await
        .is_err());
    assert_eq!(read(&a)?, av.to_string());
    assert!(!service::settings(&mut a)?.pending);
    service::run_with(&mut a, &client).await?;
    let current = state::conflict_review(&a)?.unwrap();
    assert_ne!(current.id, review.id);
    assert!(service::resolve_with(&mut a, &review.id, &choices, &client)
        .await
        .is_err());
    server.data.lock().unwrap().lose_patch = true;
    assert!(
        service::resolve_with(&mut a, &current.id, &choices, &client)
            .await
            .is_err()
    );
    assert!(service::settings(&mut a)?.pending);
    assert!(state::conflict_review(&a)?.is_none());
    service::run_with(&mut a, &client).await?;
    service::run_with(&mut b, &client).await?;
    assert_eq!(
        serde_json::from_str::<Value>(&read(&a)?)?,
        serde_json::from_str::<Value>(&read(&b)?)?
    );
    assert!(read(&b)?.contains("echo local"));
    // Settings never return a credential; blank token retains the saved value.
    service::save_config(&mut a, "fixture".into(), "vault".into(), "sync".into(), "")?;
    assert!(service::settings(&mut a)?.token_saved);
    assert!(service::save_config(
        &mut a,
        "fixture".into(),
        "other".into(),
        "sync".into(),
        TOKEN
    )
    .is_err());
    Ok(())
}

#[tokio::test]
async fn manual_setup_is_atomic_and_unconfirmed_recovery_can_be_replaced() -> Result<()> {
    use crate::sync::service;
    let server = Server::new().await;
    let client = server.client();
    let dir = tempfile::tempdir()?;
    let mut db = service_db(&dir);
    db.execute_batch("CREATE TRIGGER fail_config BEFORE UPDATE ON metadata WHEN NEW.key='sync_account_v1' BEGIN SELECT RAISE(ABORT,'fixture'); END;")?;
    assert!(
        service::initialize_with(&mut db, "create", PASSWORD, &client)
            .await
            .is_err()
    );
    assert!(state::load(&db)?.is_none());
    assert!(crypto::load(&db)?.is_none());
    assert_eq!(
        db.query_row::<i64, _, _>(
            "SELECT count(*) FROM metadata WHERE key='sync_github_target_v1'",
            [],
            |r| r.get(0)
        )?,
        0
    );
    db.execute_batch("DROP TRIGGER fail_config;")?;
    let old = service::initialize_with(&mut db, "create", PASSWORD, &client).await?;
    let next = service::initialize_with(&mut db, "create", PASSWORD, &client).await?;
    assert_ne!(old, next);
    assert!(service::confirm(&mut db, &old).is_err());
    service::confirm(&mut db, &next)?;
    assert!(
        service::initialize_with(&mut db, "create", PASSWORD, &client)
            .await
            .is_err()
    );
    assert!(!server
        .data
        .lock()
        .unwrap()
        .requests
        .iter()
        .any(|(method, _, _)| method != "GET"));
    service::run_with(&mut db, &client).await?;
    let join_dir = tempfile::tempdir()?;
    let mut joined = service_db(&join_dir);
    service::initialize_with(&mut joined, "password", PASSWORD, &client).await?;
    service::run_with(&mut joined, &client).await?;
    assert!(service::settings(&mut joined)?.recovery_confirmed);
    Ok(())
}

#[tokio::test]
async fn setup_404_identifies_repository_or_branch_without_creating_pending_state() -> Result<()> {
    use crate::sync::service;
    let server = Server::new().await;
    let client = server.client();
    let dir = tempfile::tempdir()?;
    let mut db = service_db(&dir);
    for (path, status, expected) in [
        ("", 404, "Resource owner"),
        ("/git/ref/heads/sync", 404, "Contents 读取权限"),
        ("/git/ref/heads/sync", 409, "首次提交"),
        ("", 401, "已过期"),
        ("", 403, "组织授权"),
    ] {
        {
            let mut f = server.data.lock().unwrap();
            f.status = status;
            f.status_path = Some(path.into());
        }
        for error in [
            service::initialize_with(&mut db, "create", PASSWORD, &client)
                .await
                .unwrap_err(),
            client.check().await.unwrap_err(),
        ] {
            let text = error.to_string();
            assert!(text.contains(expected), "{text}");
            assert!(text.contains(&format!("GitHub HTTP {status}")));
            assert!(!text.contains(TOKEN));
            assert!(!text.contains("待处理"));
            assert!(!text.contains("未确认发布"));
        }
        assert!(!service::settings(&mut db)?.initialized);
        assert!(!service::settings(&mut db)?.pending);
        assert!(crypto::load(&db)?.is_none());
        assert!(!journal::exists(&db)?);
        assert_eq!(server.data.lock().unwrap().mutations(), 0);
    }
    server.data.lock().unwrap().status = 0;
    assert!(client.check().await?.contains("可创建同步空间"));
    assert_eq!(server.data.lock().unwrap().mutations(), 0);
    // The same setup succeeds after fixing remote access; no local reset needed.
    let code = service::initialize_with(&mut db, "create", PASSWORD, &client).await?;
    service::confirm(&mut db, &code)?;
    service::run_with(&mut db, &client).await?;
    let writes = server.data.lock().unwrap().mutations();
    assert!(client.check().await?.contains("已有同步文件"));
    assert_eq!(server.data.lock().unwrap().mutations(), writes);
    // Read errors on a later upload must preserve the actual pending batch.
    put_record(
        &db,
        "snippets",
        r#"[{"id":"next","name":"Next","command":"pwd"}]"#,
    )?;
    let s = state::load(&db)?.unwrap();
    let files = client.fetch(s.remote_revision()).await?;
    let key = crypto::load(&db)?.unwrap().0;
    let remote = crypto::decrypt(files.packet.as_deref().unwrap(), &key)?.snapshot;
    state::prepare(&mut db, s.generation(), &remote, Some(files.revision))?;
    server.data.lock().unwrap().status = 404;
    assert!(service::run_with(&mut db, &client).await.is_err());
    assert!(service::settings(&mut db)?.pending);
    Ok(())
}

#[tokio::test]
async fn rejected_competition_reopens_and_remerges_later_local_edits() -> Result<()> {
    use crate::sync::service;
    let server = Server::new().await;
    let client = server.client();
    let dir = tempfile::tempdir()?;
    let mut db = service_db(&dir);
    let code = service::initialize_with(&mut db, "create", PASSWORD, &client).await?;
    service::confirm(&mut db, &code)?;
    put_record(
        &db,
        "snippets",
        r#"[{"id":"a","name":"Before","command":"echo before"}]"#,
    )?;
    server.data.lock().unwrap().race = true;
    assert!(service::run_with(&mut db, &client).await.is_err());
    let old_batch = state::pending_upload(&db)?.unwrap().id().to_owned();
    assert!(!journal::load(&db)?.unwrap().ref_update_started);
    put_record(
        &db,
        "snippets",
        r#"[{"id":"a","name":"After","command":"echo after"}]"#,
    )?;
    drop(db);
    let mut db = open_database(&dir.path().join("service.db"), PASSWORD, false)?;
    let result = service::run_with(&mut db, &client).await?;
    assert!(result.contains("重新合并"));
    assert!(!state::load(&db)?.unwrap().has_pending());
    assert!(!journal::exists(&db)?);
    let files = client.fetch(None).await?;
    let key = crypto::load(&db)?.unwrap().0;
    let packet = crypto::decrypt(files.packet.as_deref().unwrap(), &key)?;
    assert_ne!(packet.batch_id, old_batch);
    assert!(serde_json::to_string(&packet.snapshot)?.contains("echo after"));
    Ok(())
}

#[tokio::test]
async fn unsent_competition_remerges_remote_changes_and_preserves_conflicts() -> Result<()> {
    use crate::sync::service;
    let server = Server::new().await;
    let client = server.client();
    let a_dir = tempfile::tempdir()?;
    let b_dir = tempfile::tempdir()?;
    let mut a = service_db(&a_dir);
    let mut b = service_db(&b_dir);
    put_record(
        &a,
        "snippets",
        r#"[{"id":"shared","name":"Base","command":"echo base"}]"#,
    )?;
    let code = service::initialize_with(&mut a, "create", PASSWORD, &client).await?;
    service::confirm(&mut a, &code)?;
    service::run_with(&mut a, &client).await?;
    service::initialize_with(&mut b, "recovery", &code, &client).await?;
    service::run_with(&mut b, &client).await?;
    put_record(
        &a,
        "snippets",
        r#"[{"id":"shared","name":"Local","command":"echo local"}]"#,
    )?;
    // Fail before creating the tree: a journal exists, but PATCH was never sent.
    {
        let mut f = server.data.lock().unwrap();
        f.status = 503;
        f.status_path = Some("/git/trees".into());
    }
    assert!(service::run_with(&mut a, &client).await.is_err());
    assert!(!journal::load(&a)?.unwrap().ref_update_started);
    server.data.lock().unwrap().status = 0;
    put_record(
        &b,
        "snippets",
        r#"[{"id":"shared","name":"Remote","command":"echo remote"}]"#,
    )?;
    service::run_with(&mut b, &client).await?;
    let writes = server.data.lock().unwrap().mutations();
    assert!(service::run_with(&mut a, &client).await?.contains("冲突"));
    let review = state::conflict_review(&a)?.unwrap();
    assert_eq!(review.items.len(), 1);
    assert!(review.items[0].local_summary.contains("Local"));
    assert!(review.items[0].remote_summary.contains("Remote"));
    assert_eq!(server.data.lock().unwrap().mutations(), writes);
    assert!(!journal::exists(&a)?);
    Ok(())
}

#[tokio::test]
async fn ambiguous_and_legacy_attempts_are_not_discarded_by_later_rejection() -> Result<()> {
    let server = Server::new().await;
    let client = server.client();
    let dir = tempfile::tempdir()?;
    let mut db = db(&dir);
    let g = generation(&db);
    {
        let mut f = server.data.lock().unwrap();
        f.status = 503;
        f.status_path = Some("/git/refs/heads/sync".into());
    }
    assert!(client.publish(&mut db, g).await.is_err());
    assert!(journal::load(&db)?.unwrap().ref_update_started);
    server.data.lock().unwrap().status = 422;
    assert!(client.publish(&mut db, g).await.is_err());
    assert!(journal::load(&db)?.unwrap().ref_update_started);
    {
        let mut f = server.data.lock().unwrap();
        f.status = 0;
        let parent = f.head.clone();
        f.head = f.child(parent);
    }
    let original = outbox::restore_for_confirmation(&db, g)?;
    assert!(!client.recover_competition(&mut db, g, 17).await?);
    let same = outbox::restore_for_confirmation(&db, g)?;
    assert_eq!(original.packet(), same.packet());
    // Old journal has no durable evidence of whether PATCH was sent.
    db.execute("UPDATE metadata SET value=json_remove(value,'$.ref_update_started') WHERE key='sync_github_attempt_v1'", [])?;
    assert!(journal::load(&db)?.unwrap().ref_update_started);
    assert!(!client.recover_competition(&mut db, g, 17).await?);
    assert!(state::load(&db)?.unwrap().has_pending());
    Ok(())
}

#[tokio::test]
async fn recovery_cleanup_is_atomic_and_publish_marker_precedes_patch() -> Result<()> {
    let server = Server::new().await;
    let client = server.client();
    let dir = tempfile::tempdir()?;
    let mut db = db(&dir);
    let g = generation(&db);
    db.execute_batch("CREATE TRIGGER fail_marker BEFORE UPDATE ON metadata WHEN NEW.key='sync_github_attempt_v1' AND json_extract(NEW.value,'$.ref_update_started')=1 BEGIN SELECT RAISE(ABORT,'fixture'); END;")?;
    assert!(client.publish(&mut db, g).await.is_err());
    assert!(!server
        .data
        .lock()
        .unwrap()
        .requests
        .iter()
        .any(|r| r.0 == "PATCH"));
    assert!(!journal::load(&db)?.unwrap().ref_update_started);
    db.execute_batch("DROP TRIGGER fail_marker")?;
    {
        let mut f = server.data.lock().unwrap();
        let parent = f.head.clone();
        f.head = f.child(parent);
    }
    let bytes = outbox::restore_for_confirmation(&db, g)?.packet().to_vec();
    db.execute_batch("CREATE TRIGGER fail_cleanup BEFORE DELETE ON metadata WHEN OLD.key='sync_outbox_v1' BEGIN SELECT RAISE(ABORT,'fixture'); END;")?;
    assert!(client.recover_competition(&mut db, g, 17).await.is_err());
    assert!(journal::exists(&db)?);
    assert_eq!(generation(&db), g);
    assert_eq!(outbox::restore_for_confirmation(&db, g)?.packet(), bytes);
    db.execute_batch("DROP TRIGGER fail_cleanup")?;
    assert!(client.recover_competition(&mut db, g, 17).await?);
    assert!(!journal::exists(&db)?);
    assert!(!state::load(&db)?.unwrap().has_pending());
    Ok(())
}

#[tokio::test]
async fn no_journal_pending_recovers_but_wrong_repo_and_tampered_remote_do_not() -> Result<()> {
    use crate::sync::service;
    let server = Server::new().await;
    let client = server.client();
    let dir = tempfile::tempdir()?;
    let mut db = service_db(&dir);
    let code = service::initialize_with(&mut db, "create", PASSWORD, &client).await?;
    service::confirm(&mut db, &code)?;
    service::run_with(&mut db, &client).await?;
    put_record(
        &db,
        "snippets",
        r#"[{"id":"a","name":"A","command":"echo local"}]"#,
    )?;
    let s = state::load(&db)?.unwrap();
    let files = client.fetch(s.remote_revision()).await?;
    let snapshot = crypto::decrypt(
        files.packet.as_deref().unwrap(),
        &crypto::load(&db)?.unwrap().0,
    )?
    .snapshot;
    state::prepare(&mut db, s.generation(), &snapshot, Some(files.revision))?;
    let g = generation(&db);
    assert!(!journal::exists(&db)?);
    {
        let mut f = server.data.lock().unwrap();
        let parent = f.head.clone();
        f.head = f.child(parent);
        f.repo_id = 18;
    }
    assert!(client.recover_competition(&mut db, g, 17).await.is_err());
    assert!(state::load(&db)?.unwrap().has_pending());
    {
        let mut f = server.data.lock().unwrap();
        f.repo_id = 17;
        f.corrupt_blob = true;
    }
    assert!(client.recover_competition(&mut db, g, 17).await.is_err());
    assert!(state::load(&db)?.unwrap().has_pending());
    server.data.lock().unwrap().corrupt_blob = false;
    assert!(service::run_with(&mut db, &client)
        .await?
        .contains("重新合并"));
    assert!(!state::load(&db)?.unwrap().has_pending());
    Ok(())
}

const ROTATED_PASSWORD: &str = "new synthetic sync password";
async fn publish_rotation(db: &mut Connection, client: &GitHub) -> Result<String> {
    let code = crypto::rotation::begin(db, generation(db), ROTATED_PASSWORD)?;
    let g = generation(db);
    crypto::rotation::confirm_recovery(db, g, code.expose())?;
    client.publish(db, g).await?;
    Ok(code.expose().into())
}
fn metadata(db: &Connection) -> Result<Vec<(String, String)>> {
    let mut stmt = db.prepare("SELECT key,value FROM metadata ORDER BY key")?;
    let values = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<rusqlite::Result<_>>()?;
    Ok(values)
}

#[tokio::test]
async fn adopted_key_keeps_local_edits_history_and_conflicts_across_reopen() -> Result<()> {
    use crate::sync::service;
    let server = Server::new().await;
    let client = server.client();
    let a_dir = tempfile::tempdir()?;
    let b_dir = tempfile::tempdir()?;
    let mut a = service_db(&a_dir);
    let mut b = service_db(&b_dir);
    put_record(
        &a,
        "snippets",
        r#"[{"id":"shared","name":"Base","command":"echo base"}]"#,
    )?;
    let code = service::initialize_with(&mut a, "create", PASSWORD, &client).await?;
    service::confirm(&mut a, &code)?;
    service::run_with(&mut a, &client).await?;
    let old_packet = client.fetch(None).await?.packet.unwrap();
    service::initialize_with(&mut b, "recovery", &code, &client).await?;
    service::run_with(&mut b, &client).await?;
    let baseline = state::load(&b)?
        .unwrap()
        .remote_revision()
        .unwrap()
        .to_owned();
    put_record(
        &b,
        "snippets",
        r#"[{"id":"shared","name":"Local","command":"echo local"}]"#,
    )?;
    put_record(
        &a,
        "snippets",
        r#"[{"id":"shared","name":"Remote","command":"echo remote"}]"#,
    )?;
    service::run_with(&mut a, &client).await?;
    let code = publish_rotation(&mut a, &client).await?;
    let rotated_revision = server.data.lock().unwrap().head.clone();
    let writes = server.data.lock().unwrap().mutations();
    assert!(service::run_with(&mut b, &client).await.is_err());
    assert!(!state::load(&b)?.unwrap().has_pending());
    service::adopt_key_with(&mut b, "recovery", &code, &client).await?;
    assert_eq!(server.data.lock().unwrap().mutations(), writes);
    assert_eq!(
        state::load(&b)?.unwrap().remote_revision(),
        Some(baseline.as_str())
    );
    assert_eq!(
        state::load(&b)?.unwrap().fetch_revision(),
        Some(rotated_revision.as_str())
    );
    assert_eq!(
        crypto::load(&b)?.unwrap().0.id(),
        crypto::load(&a)?.unwrap().0.id()
    );
    crypto::rotation::decrypt_retained(&b, &old_packet)?;
    assert!(b
        .query_row::<String, _, _>("SELECT value FROM records WHERE kind='snippets'", [], |r| r
            .get(0))?
        .contains("echo local"));
    let after = metadata(&b)?;
    assert!(
        service::adopt_key_with(&mut b, "password", ROTATED_PASSWORD, &client)
            .await?
            .contains("已使用")
    );
    assert_eq!(after, metadata(&b)?);
    drop(b);
    let mut b = open_database(&b_dir.path().join("service.db"), PASSWORD, false)?;
    // The new key's read fence survives restart before any data was merged.
    server.data.lock().unwrap().head = baseline;
    assert!(service::run_with(&mut b, &client).await.is_err());
    assert_eq!(after, metadata(&b)?);
    server.data.lock().unwrap().head = rotated_revision;
    assert!(service::run_with(&mut b, &client).await?.contains("冲突"));
    let review = state::conflict_review(&b)?.unwrap();
    assert_eq!(review.items.len(), 1);
    let choices = review
        .items
        .iter()
        .map(|i| crate::api::sync::SyncConflictChoice {
            kind: i.kind.clone(),
            id: i.id.clone(),
            side: "local".into(),
        })
        .collect::<Vec<_>>();
    service::resolve_with(&mut b, &review.id, &choices, &client).await?;
    assert!(!state::load(&b)?.unwrap().has_pending());
    service::run_with(&mut a, &client).await?;
    assert!(a
        .query_row::<String, _, _>("SELECT value FROM records WHERE kind='snippets'", [], |r| r
            .get(0))?
        .contains("echo local"));
    Ok(())
}

#[tokio::test]
async fn adoption_rejects_bad_credentials_changed_remote_and_rolls_back_failed_save() -> Result<()>
{
    use crate::sync::service;
    let server = Server::new().await;
    let client = server.client();
    let a_dir = tempfile::tempdir()?;
    let b_dir = tempfile::tempdir()?;
    let mut a = service_db(&a_dir);
    let mut b = service_db(&b_dir);
    let code = service::initialize_with(&mut a, "create", PASSWORD, &client).await?;
    service::confirm(&mut a, &code)?;
    service::run_with(&mut a, &client).await?;
    service::initialize_with(&mut b, "recovery", &code, &client).await?;
    service::run_with(&mut b, &client).await?;
    publish_rotation(&mut a, &client).await?;
    let original = metadata(&b)?;
    for (mode, secret) in [
        ("password", PASSWORD),
        ("recovery", code.as_str()),
        ("create", ROTATED_PASSWORD),
    ] {
        assert!(service::adopt_key_with(&mut b, mode, secret, &client)
            .await
            .is_err());
        assert_eq!(metadata(&b)?, original);
    }
    server.data.lock().unwrap().repo_id = 99;
    assert!(
        service::adopt_key_with(&mut b, "password", ROTATED_PASSWORD, &client)
            .await
            .is_err()
    );
    server.data.lock().unwrap().repo_id = 17;
    server.data.lock().unwrap().corrupt_blob = true;
    assert!(
        service::adopt_key_with(&mut b, "password", ROTATED_PASSWORD, &client)
            .await
            .is_err()
    );
    server.data.lock().unwrap().corrupt_blob = false;
    server.data.lock().unwrap().advance_after_reads = Some(2);
    assert!(
        service::adopt_key_with(&mut b, "password", ROTATED_PASSWORD, &client)
            .await
            .is_err()
    );
    assert_eq!(metadata(&b)?, original);
    b.execute_batch("CREATE TRIGGER fail_adopt BEFORE UPDATE ON metadata WHEN NEW.key='sync_state_v1' BEGIN SELECT RAISE(ABORT,'fixture'); END;")?;
    assert!(
        service::adopt_key_with(&mut b, "password", ROTATED_PASSWORD, &client)
            .await
            .is_err()
    );
    assert_eq!(metadata(&b)?, original);
    b.execute_batch("DROP TRIGGER fail_adopt")?;
    service::adopt_key_with(&mut b, "password", ROTATED_PASSWORD, &client).await?;
    service::run_with(&mut b, &client).await?;
    assert_eq!(
        crypto::load(&b)?.unwrap().0.id(),
        crypto::load(&a)?.unwrap().0.id()
    );
    Ok(())
}

#[tokio::test]
async fn adoption_never_discards_pending_publication_or_installs_another_space() -> Result<()> {
    use crate::sync::service;
    let server = Server::new().await;
    let client = server.client();
    let dir = tempfile::tempdir()?;
    let mut db = service_db(&dir);
    let code = service::initialize_with(&mut db, "create", PASSWORD, &client).await?;
    service::confirm(&mut db, &code)?;
    server.data.lock().unwrap().lose_patch = true;
    assert!(service::run_with(&mut db, &client).await.is_err());
    let original = metadata(&db)?;
    let count = server.data.lock().unwrap().requests.len();
    assert!(service::adopt_key_with(&mut db, "recovery", &code, &client)
        .await
        .is_err());
    assert_eq!(metadata(&db)?, original);
    assert_eq!(server.data.lock().unwrap().requests.len(), count);
    service::run_with(&mut db, &client).await?;
    // A second initialized space in the same fake repository must not replace it.
    let other_dir = tempfile::tempdir()?;
    let other = db_for_other_space(&other_dir)?;
    let files = client.fetch(None).await?;
    let other_key = crypto::load(&other)?.unwrap().0;
    let snapshot = Snapshot::empty(other_key.space().into())?;
    // Directly replace the fake tree's files with authentic ciphertext from another space.
    let packet = crypto::encrypt(
        &snapshot,
        &other_key,
        uuid::Uuid::new_v4().to_string(),
        Some(files.revision.clone()),
    )?;
    let envelope = crypto::load(&other)?.unwrap().1.encode()?;
    {
        let mut f = server.data.lock().unwrap();
        let parent = f.head.clone();
        let child = f.child(parent);
        f.head = child;
        let tree_id = f.commits[&f.head]["tree"]["sha"]
            .as_str()
            .unwrap()
            .to_owned();
        for (path, bytes) in [(PACKET_FILE, packet), (KEY_FILE, envelope)] {
            let id = blob_sha(&bytes);
            f.blobs.insert(id.clone(), bytes);
            for entry in f.trees.get_mut(&tree_id).unwrap()["tree"]
                .as_array_mut()
                .unwrap()
            {
                if entry["path"] == path {
                    entry["sha"] = json!(id);
                }
            }
        }
    }
    let original = metadata(&db)?;
    assert!(
        service::adopt_key_with(&mut db, "password", PASSWORD, &client)
            .await
            .is_err()
    );
    assert_eq!(metadata(&db)?, original);
    Ok(())
}
fn db_for_other_space(dir: &tempfile::TempDir) -> Result<Connection> {
    let mut db = open_database(&dir.path().join("other.db"), PASSWORD, true)?;
    let space = uuid::Uuid::new_v4().to_string();
    state::initialize(&mut db, space.clone())?;
    let (key, envelope, _) = crypto::create(space, PASSWORD)?;
    crypto::install(&mut db, &key, &envelope)?;
    Ok(db)
}

#[tokio::test]
async fn rotation_service_recovers_exact_batch_and_preserves_later_edits() -> Result<()> {
    use crate::sync::service;
    let server = Server::new().await;
    let client = server.client();
    let dir = tempfile::tempdir()?;
    let mut db = service_db(&dir);
    assert!(!service::rotation_status(&mut db)?.can_begin);
    assert!(
        service::begin_rotation_with(&mut db, ROTATED_PASSWORD, &client)
            .await
            .is_err()
    );
    let initial = service::initialize_with(&mut db, "create", PASSWORD, &client).await?;
    service::confirm(&mut db, &initial)?;
    service::run_with(&mut db, &client).await?;
    let old_id = crypto::load(&db)?.unwrap().0.id().to_owned();
    let writes = server.data.lock().unwrap().mutations();
    let code = service::begin_rotation_with(&mut db, ROTATED_PASSWORD, &client).await?;
    let status = service::rotation_status(&mut db)?;
    assert!(!status.can_begin && !status.recovery_confirmed && status.can_discard);
    let batch = status.batch_id;
    assert!(service::confirm_rotation(&mut db, &batch, &initial).is_err());
    assert!(service::publish_rotation_with(&mut db, &batch, &client)
        .await
        .is_err());
    assert_eq!(writes, server.data.lock().unwrap().mutations());
    drop(db);
    let mut db = open_database(&dir.path().join("service.db"), PASSWORD, false)?;
    assert_eq!(service::rotation_status(&mut db)?.batch_id, batch);
    service::confirm_rotation(&mut db, &batch, &code)?;
    put_record(
        &db,
        "snippets",
        r#"[{"id":"later","name":"Later","command":"echo later"}]"#,
    )?;
    server.data.lock().unwrap().lose_patch = true;
    assert!(service::publish_rotation_with(&mut db, &batch, &client)
        .await
        .is_err());
    assert_eq!(crypto::load(&db)?.unwrap().0.id(), old_id);
    assert!(!service::rotation_status(&mut db)?.can_discard);
    let pending = metadata(&db)?;
    assert!(service::discard_rotation(&mut db, &batch).is_err());
    assert_eq!(metadata(&db)?, pending);
    let writes = server.data.lock().unwrap().mutations();
    assert!(service::publish_rotation_with(&mut db, &batch, &client)
        .await?
        .contains("已发布"));
    assert_eq!(writes, server.data.lock().unwrap().mutations());
    assert_ne!(crypto::load(&db)?.unwrap().0.id(), old_id);
    assert!(service::rotation_status(&mut db)?.batch_id.is_empty());
    assert!(db
        .query_row::<String, _, _>("SELECT value FROM records WHERE kind='snippets'", [], |r| r
            .get(0))?
        .contains("echo later"));
    service::run_with(&mut db, &client).await?;
    let files = client.fetch(None).await?;
    let packet = crypto::decrypt(
        files.packet.as_deref().unwrap(),
        &crypto::load(&db)?.unwrap().0,
    )?;
    assert!(serde_json::to_string(&packet.snapshot)?.contains("echo later"));
    Ok(())
}

#[tokio::test]
async fn rotation_service_discard_is_atomic_and_rejects_stale_dialogs() -> Result<()> {
    use crate::sync::service;
    let server = Server::new().await;
    let client = server.client();
    let dir = tempfile::tempdir()?;
    let mut db = service_db(&dir);
    let code = service::initialize_with(&mut db, "create", PASSWORD, &client).await?;
    service::confirm(&mut db, &code)?;
    service::run_with(&mut db, &client).await?;
    let old_id = crypto::load(&db)?.unwrap().0.id().to_owned();
    let first = service::begin_rotation_with(&mut db, ROTATED_PASSWORD, &client).await?;
    let first_batch = service::rotation_status(&mut db)?.batch_id;
    db.execute_batch("CREATE TRIGGER fail_rotation_discard BEFORE DELETE ON metadata WHEN OLD.key='sync_key_rotation_v1' BEGIN SELECT RAISE(ABORT,'fixture'); END;")?;
    let before = metadata(&db)?;
    assert!(service::discard_rotation(&mut db, &first_batch).is_err());
    assert_eq!(before, metadata(&db)?);
    db.execute_batch("DROP TRIGGER fail_rotation_discard")?;
    service::discard_rotation(&mut db, &first_batch)?;
    assert_eq!(crypto::load(&db)?.unwrap().0.id(), old_id);
    assert!(service::rotation_status(&mut db)?.can_begin);
    let second = service::begin_rotation_with(&mut db, ROTATED_PASSWORD, &client).await?;
    assert_ne!(first, second);
    let second_batch = service::rotation_status(&mut db)?.batch_id;
    assert_ne!(first_batch, second_batch);
    let before = metadata(&db)?;
    assert!(service::confirm_rotation(&mut db, &first_batch, &second).is_err());
    assert!(service::discard_rotation(&mut db, &first_batch).is_err());
    assert!(
        service::publish_rotation_with(&mut db, &first_batch, &client)
            .await
            .is_err()
    );
    assert_eq!(before, metadata(&db)?);
    service::confirm_rotation(&mut db, &second_batch, &second)?;
    server.data.lock().unwrap().race = true;
    assert!(
        service::publish_rotation_with(&mut db, &second_batch, &client)
            .await
            .is_err()
    );
    assert!(service::rotation_status(&mut db)?.can_discard);
    // A legacy journal without proof of non-publication must fail closed.
    let raw: String = db.query_row(
        "SELECT value FROM metadata WHERE key='sync_github_attempt_v1'",
        [],
        |r| r.get(0),
    )?;
    let mut legacy: serde_json::Value = serde_json::from_str(&raw)?;
    legacy.as_object_mut().unwrap().remove("ref_update_started");
    db.execute(
        "UPDATE metadata SET value=?1 WHERE key='sync_github_attempt_v1'",
        [legacy.to_string()],
    )?;
    assert!(!service::rotation_status(&mut db)?.can_discard);
    assert!(service::discard_rotation(&mut db, &second_batch).is_err());
    db.execute(
        "UPDATE metadata SET value=?1 WHERE key='sync_github_attempt_v1'",
        [raw],
    )?;
    service::discard_rotation(&mut db, &second_batch)?;
    let before = metadata(&db)?;
    assert!(
        service::begin_rotation_with(&mut db, ROTATED_PASSWORD, &client)
            .await
            .is_err()
    );
    assert_eq!(before, metadata(&db)?);
    service::run_with(&mut db, &client).await?;
    assert!(service::rotation_status(&mut db)?.can_begin);
    Ok(())
}

#[tokio::test]
async fn disconnect_and_reinitialize_preserve_scope_without_remote_mutation() -> Result<()> {
    use crate::sync::{disconnect, service};
    let server = Server::new().await;
    let client = server.client();
    let dir = tempfile::tempdir()?;
    let mut db = service_db(&dir);
    put_record(
        &db,
        "snippets",
        r#"[{"id":"private","name":"Private","command":"echo private"}]"#,
    )?;
    service::initialize_with(&mut db, "create", PASSWORD, &client).await?;
    let s = state::load(&db)?.unwrap();
    state::set_policy(
        &mut db,
        s.generation(),
        state::Policy::new(BTreeSet::from([Key {
            kind: Kind::Snippet,
            id: "private".into(),
        }]))?,
    )?;
    // Regenerating an unconfirmed recovery code must not reset exclusions.
    let code = service::initialize_with(&mut db, "create", PASSWORD, &client).await?;
    assert_eq!(state::load(&db)?.unwrap().policy().local_only().len(), 1);
    service::confirm(&mut db, &code)?;
    service::run_with(&mut db, &client).await?;
    let old_space = crypto::load(&db)?.unwrap().0.space().to_owned();
    let requests = server.data.lock().unwrap().requests.len();
    let v = disconnect::preview(&mut db)?;
    disconnect::disconnect(&mut db, &v.revision, "断开")?;
    assert_eq!(server.data.lock().unwrap().requests.len(), requests);
    assert!(crypto::load(&db)?.is_none());
    assert!(!journal::exists(&db)?);
    service::save_config(
        &mut db,
        "fixture".into(),
        "vault".into(),
        "sync".into(),
        TOKEN,
    )?;
    // Rejoining the old space needs its existing recovery credential.
    service::initialize_with(&mut db, "recovery", &code, &client).await?;
    assert_eq!(crypto::load(&db)?.unwrap().0.space(), old_space);
    assert_eq!(state::load(&db)?.unwrap().policy().local_only().len(), 1);
    service::run_with(&mut db, &client).await?;
    assert!(crate::api::vault::read_record(&db, "snippets")?.contains("echo private"));
    Ok(())
}
