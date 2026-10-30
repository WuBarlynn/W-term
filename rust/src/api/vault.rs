//! Device-local SQLCipher vault. Keys and database handles never cross the FFI.
use anyhow::{anyhow, ensure, Context, Result};
use rusqlite::{params, Connection, OpenFlags, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet},
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
    time::Duration,
};
use zeroize::{Zeroize, Zeroizing};

pub struct VaultOpened {
    pub token: String,
    pub legacy_imported: bool,
}
struct OpenVault {
    token: String,
    db: Option<Connection>,
    cancel: Option<std::sync::Arc<tokio::sync::Notify>>,
    path: PathBuf,
}
static VAULT: OnceLock<Mutex<Option<OpenVault>>> = OnceLock::new();
fn registry() -> &'static Mutex<Option<OpenVault>> {
    VAULT.get_or_init(|| Mutex::new(None))
}

fn key_database(path: &Path, password: &str) -> Result<Connection> {
    key_database_mode(path, password, false)
}
fn key_database_mode(path: &Path, password: &str, readonly: bool) -> Result<Connection> {
    ensure!(
        !password.is_empty() && password.len() <= 1024,
        "密码长度无效"
    );
    let db = Connection::open_with_flags(
        path,
        (if readonly {
            OpenFlags::SQLITE_OPEN_READ_ONLY
        } else {
            OpenFlags::SQLITE_OPEN_READ_WRITE
        }) | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    let cipher: String = db
        .query_row("PRAGMA cipher_version", [], |row| row.get(0))
        .context("SQLCipher unavailable; refusing plaintext storage")?;
    ensure!(!cipher.is_empty(), "SQLCipher unavailable");
    // sqlite3_key copies the passphrase into SQLCipher's protected context.
    // No SQL text contains the password, including diagnostic error messages.
    let rc = unsafe {
        rusqlite::ffi::sqlite3_key(db.handle(), password.as_ptr().cast(), password.len() as i32)
    };
    ensure!(rc == rusqlite::ffi::SQLITE_OK, "Unable to set vault key");
    db.execute_batch("PRAGMA cipher_compatibility=4; PRAGMA cipher_memory_security=ON; PRAGMA temp_store=MEMORY;")?;
    db.busy_timeout(Duration::from_secs(5))?;
    Ok(db)
}
#[flutter_rust_bridge::frb(ignore)]
pub(crate) fn open_database(path: &Path, password: &str, create: bool) -> Result<Connection> {
    ensure!(
        password.len() <= 1024 && !password.is_empty(),
        "主密码长度无效"
    );
    if create {
        ensure!(password.chars().count() >= 12, "主密码至少需要 12 个字符");
        ensure!(!path.exists(), "保险库已存在，不能覆盖");
        let parent = path.parent().context("Invalid vault path")?;
        let temporary = tempfile::NamedTempFile::new_in(parent)?;
        {
            let db = key_database(temporary.path(), password)?;
            db.execute_batch(
                "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;
                BEGIN IMMEDIATE;
                CREATE TABLE records (kind TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                INSERT INTO metadata VALUES ('format', 'wterm-vault-v1');
                PRAGMA user_version=1;
                COMMIT;",
            )?;
        }
        temporary.as_file().sync_all()?;
        // Atomic publication with no replacement of an existing vault.
        temporary
            .persist_noclobber(path)
            .map_err(|_| anyhow!("无法创建保险库，目标可能已存在"))?;
    }
    let db = key_database(path, password)?;
    let version: i32 = db
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .map_err(|_| anyhow!("主密码错误或保险库已损坏"))?;
    ensure!((1..=3).contains(&version), "不支持的保险库版本");
    let format: String =
        db.query_row("SELECT value FROM metadata WHERE key='format'", [], |r| {
            r.get(0)
        })?;
    ensure!(format == "wterm-vault-v1", "Invalid vault format");
    db.execute_batch(
        "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA secure_delete=ON;",
    )?;
    if version == 1 {
        db.execute_batch(
            "BEGIN IMMEDIATE; CREATE TABLE identities (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, username TEXT NOT NULL, kind TEXT NOT NULL,
            password TEXT NOT NULL, private_key TEXT NOT NULL, passphrase TEXT NOT NULL);
            PRAGMA user_version=2; COMMIT;",
        )?;
    }
    if version < 3 {
        db.execute_batch("PRAGMA user_version=3;")?;
    }
    Ok(db)
}

/// Expensive SQLCipher KDF runs on the bridge worker pool, never the Flutter UI.
pub fn vault_open(path: String, password: String, create: bool) -> Result<VaultOpened> {
    let password = Zeroizing::new(password);
    let mut state = registry().lock().map_err(|_| anyhow!("保险库状态不可用"))?;
    ensure!(state.is_none(), "请先锁定当前保险库");
    let db = open_database(Path::new(&path), &password, create)?;
    let legacy_imported = imported(&db)?;
    let token = uuid::Uuid::new_v4().to_string();
    *state = Some(OpenVault {
        token: token.clone(),
        path: PathBuf::from(path),
        db: Some(db),
        cancel: None,
    });
    Ok(VaultOpened {
        token,
        legacy_imported,
    })
}
#[flutter_rust_bridge::frb(ignore)]
pub(crate) fn with_vault<T>(
    token: &str,
    f: impl FnOnce(&mut Connection) -> Result<T>,
) -> Result<T> {
    let mut state = registry().lock().map_err(|_| anyhow!("保险库状态不可用"))?;
    let vault = state
        .as_mut()
        .filter(|v| v.token == token)
        .context("保险库已锁定，请重新解锁")?;
    f(vault.db.as_mut().context("同步正在进行，请稍后重试")?)
}
pub fn vault_lock(token: String) -> Result<()> {
    let mut state = registry().lock().map_err(|_| anyhow!("保险库状态不可用"))?;
    if state.as_ref().is_some_and(|v| v.token == token) {
        if let Some(cancel) = state.as_ref().and_then(|v| v.cancel.as_ref()) {
            cancel.notify_one();
        }
        *state = None;
    }
    Ok(())
}
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct VaultLease {
    token: String,
    pub(crate) db: Option<Connection>,
    pub(crate) cancelled: std::sync::Arc<tokio::sync::Notify>,
}
impl Drop for VaultLease {
    fn drop(&mut self) {
        if let Ok(mut state) = registry().lock() {
            if let Some(v) = state
                .as_mut()
                .filter(|v| v.token == self.token && v.db.is_none())
            {
                v.db = self.db.take();
                v.cancel = None;
            }
        }
    }
}
#[flutter_rust_bridge::frb(ignore)]
pub(crate) fn lease(token: &str) -> Result<VaultLease> {
    let mut state = registry().lock().map_err(|_| anyhow!("保险库状态不可用"))?;
    let v = state
        .as_mut()
        .filter(|v| v.token == token)
        .context("保险库已锁定")?;
    let db = v.db.take().context("同步正在进行，请勿重复操作")?;
    let cancelled = std::sync::Arc::new(tokio::sync::Notify::new());
    v.cancel = Some(cancelled.clone());
    Ok(VaultLease {
        token: token.into(),
        db: Some(db),
        cancelled,
    })
}
#[flutter_rust_bridge::frb(ignore)]
pub(crate) fn cancel_sync(token: &str) -> Result<()> {
    let state = registry().lock().map_err(|_| anyhow!("保险库状态不可用"))?;
    let v = state
        .as_ref()
        .filter(|v| v.token == token)
        .context("保险库已锁定")?;
    if let Some(cancel) = &v.cancel {
        cancel.notify_one();
    }
    Ok(())
}
fn check_kind(kind: &str) -> Result<()> {
    ensure!(
        matches!(kind, "hosts" | "folders" | "snippets"),
        "Unknown vault record"
    );
    Ok(())
}
pub fn vault_read(token: String, kind: String) -> Result<String> {
    check_kind(&kind)?;
    with_vault(&token, |db| {
        Ok(db
            .query_row("SELECT value FROM records WHERE kind=?1", [&kind], |r| {
                r.get(0)
            })
            .optional()?
            .unwrap_or_else(|| "[]".into()))
    })
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Host {
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) host: String,
    pub(crate) username: String,
    pub(crate) port: u16,
    pub(crate) group: String,
    pub(crate) tags: Vec<String>,
    pub(crate) favorite: bool,
    #[serde(default, rename = "identityId")]
    pub(crate) identity_id: String,
    #[serde(default, rename = "jumpHostIds", skip_serializing_if = "Vec::is_empty")]
    pub(crate) jump_host_ids: Vec<String>,
}
pub(crate) const MAX_JUMP_HOSTS: usize = 4;

/// Checks that every jump reference exists and the whole saved host graph is
/// acyclic and bounded. Called only with the complete host collection.
pub(crate) fn validate_host_routes(hosts: &[Host]) -> Result<()> {
    let by_id: HashMap<&str, &Host> = hosts.iter().map(|h| (h.id.as_str(), h)).collect();
    fn visit<'a>(
        id: &'a str,
        by_id: &HashMap<&'a str, &'a Host>,
        stack: &mut Vec<&'a str>,
        depth: usize,
    ) -> Result<()> {
        ensure!(depth <= MAX_JUMP_HOSTS, "跳板路线最多 4 台跳板主机");
        ensure!(!stack.contains(&id), "跳板路线存在循环引用");
        let host = by_id
            .get(id)
            .context("跳板主机不存在或已被删除，请重新编辑路线")?;
        stack.push(id);
        for jump in &host.jump_host_ids {
            visit(jump, by_id, stack, depth + 1)?;
        }
        stack.pop();
        Ok(())
    }
    for host in hosts {
        visit(&host.id, &by_id, &mut Vec::new(), 0)?;
    }
    Ok(())
}
#[flutter_rust_bridge::frb(ignore)]
pub(crate) fn validate(kind: &str, json: &str) -> Result<()> {
    check_kind(kind)?;
    ensure!(json.len() <= 4 * 1024 * 1024, "主机数据过大");
    if kind == "hosts" {
        let hosts: Vec<Host> =
            serde_json::from_str(json).map_err(|_| anyhow!("主机数据格式无效"))?;
        ensure!(hosts.len() <= 10000, "主机数量过多");
        let mut ids = HashSet::new();
        for h in hosts {
            ensure!(
                [&h.id, &h.name, &h.host, &h.username]
                    .iter()
                    .all(|s| !s.trim().is_empty() && s.len() <= 4096),
                "主机字段无效"
            );
            ensure!(
                h.port > 0 && ids.insert(h.id.clone()),
                "端口无效或主机 ID 重复"
            );
            ensure!(
                h.group.len() <= 4096
                    && h.tags.len() <= 100
                    && h.tags.iter().all(|t| t.len() <= 4096),
                "分类或标签过长"
            );
            let _ = h.favorite;
            ensure!(
                h.jump_host_ids.len() <= MAX_JUMP_HOSTS,
                "每台主机最多 4 台跳板主机"
            );
            let mut jumps = HashSet::new();
            for jump in &h.jump_host_ids {
                ensure!(
                    !jump.trim().is_empty() && jump.len() <= 4096,
                    "跳板主机引用无效"
                );
                ensure!(jump != &h.id, "主机不能把自己设为跳板");
                ensure!(jumps.insert(jump), "跳板主机重复");
            }
        }
    } else if kind == "snippets" {
        let entries: Vec<Snippet> = serde_json::from_str(json)?;
        ensure!(entries.len() <= 1000, "命令片段最多 1000 条");
        let mut ids = HashSet::new();
        for e in entries {
            ensure!(
                !e.id.is_empty()
                    && ids.insert(e.id)
                    && !e.name.trim().is_empty()
                    && e.name.len() <= 4096,
                "片段名称无效或 ID 重复"
            );
            ensure!(
                !e.command.trim().is_empty()
                    && e.command.len() <= 16384
                    && !e.command.chars().any(char::is_control),
                "片段仅支持不含控制字符的单行命令，最多 16 KiB"
            );
        }
    } else {
        let folders: Vec<String> =
            serde_json::from_str(json).map_err(|_| anyhow!("文件夹格式无效"))?;
        let mut unique = HashSet::new();
        ensure!(folders.len() <= 10000, "文件夹数量过多");
        for f in folders {
            ensure!(
                !f.trim().is_empty() && f.len() <= 4096 && unique.insert(f),
                "文件夹无效或重复"
            );
        }
    }
    Ok(())
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Snippet {
    id: String,
    name: String,
    command: String,
}

pub fn vault_save_snippet(token: String, id: String, name: String, command: String) -> Result<()> {
    with_vault(&token, |db| {
        let mut entries: Vec<Snippet> = serde_json::from_str(&read_record(db, "snippets")?)?;
        let id = if id.is_empty() {
            uuid::Uuid::new_v4().to_string()
        } else {
            ensure!(
                entries.iter().any(|s| s.id == id),
                "片段已被删除，请重新创建"
            );
            id
        };
        entries.retain(|s| s.id != id);
        entries.push(Snippet {
            id,
            name: name.trim().into(),
            command,
        });
        put_record(db, "snippets", &serde_json::to_string(&entries)?)
    })
}
pub fn vault_delete_snippet(token: String, id: String) -> Result<()> {
    with_vault(&token, |db| {
        let mut entries: Vec<Snippet> = serde_json::from_str(&read_record(db, "snippets")?)?;
        entries.retain(|s| s.id != id);
        put_record(db, "snippets", &serde_json::to_string(&entries)?)
    })
}

pub fn vault_write(token: String, kind: String, json: String) -> Result<()> {
    validate(&kind, &json)?;
    with_vault(&token, |db| {
        ensure!(imported(db)?, "请先完成旧配置迁移");
        if kind == "hosts" {
            let hosts: Vec<Host> = serde_json::from_str(&json)?;
            validate_references(db, &hosts)?;
            validate_host_routes(&hosts)?;
        }
        db.execute("INSERT INTO records(kind,value) VALUES (?1,?2) ON CONFLICT(kind) DO UPDATE SET value=excluded.value", params![kind, json])?;
        Ok(())
    })
}
fn imported(db: &Connection) -> Result<bool> {
    Ok(db
        .query_row(
            "SELECT value FROM metadata WHERE key='legacy_imported'",
            [],
            |r| r.get::<_, String>(0),
        )
        .optional()?
        .is_some())
}
/// One transaction, idempotent, never replaces previously imported/edited data.
pub fn vault_import_legacy(token: String, hosts_json: String, folders_json: String) -> Result<()> {
    validate("hosts", &hosts_json)?;
    validate("folders", &folders_json)?;
    let hosts: Vec<Host> = serde_json::from_str(&hosts_json)?;
    validate_host_routes(&hosts)?;
    with_vault(&token, |db| {
        let tx = db.transaction()?;
        if imported(&tx)? {
            return Ok(());
        }
        let count: i32 = tx.query_row("SELECT count(*) FROM records", [], |r| r.get(0))?;
        ensure!(count == 0, "保险库已有数据，已阻止覆盖");
        tx.execute("INSERT INTO records VALUES ('hosts',?1)", [&hosts_json])?;
        tx.execute("INSERT INTO records VALUES ('folders',?1)", [&folders_json])?;
        tx.execute("INSERT INTO metadata VALUES ('legacy_imported','1')", [])?;
        tx.commit()?;
        Ok(())
    })
}

pub struct IdentitySummary {
    pub id: String,
    pub name: String,
    pub username: String,
    pub kind: String,
}
pub struct IdentityInput {
    pub id: String,
    pub name: String,
    pub username: String,
    pub kind: String,
    pub password: String,
    pub private_key: String,
    pub passphrase: String,
    pub replace_secret: bool,
}
struct SensitiveInput(IdentityInput);
impl std::ops::Deref for SensitiveInput {
    type Target = IdentityInput;
    fn deref(&self) -> &IdentityInput {
        &self.0
    }
}
impl std::ops::DerefMut for SensitiveInput {
    fn deref_mut(&mut self) -> &mut IdentityInput {
        &mut self.0
    }
}
impl Drop for SensitiveInput {
    fn drop(&mut self) {
        self.password.zeroize();
        self.private_key.zeroize();
        self.passphrase.zeroize();
    }
}
struct Secrets {
    password: Zeroizing<String>,
    private_key: Zeroizing<String>,
    passphrase: Zeroizing<String>,
}
#[flutter_rust_bridge::frb(ignore)]
pub(crate) fn read_record(db: &Connection, kind: &str) -> Result<String> {
    Ok(db
        .query_row("SELECT value FROM records WHERE kind=?1", [kind], |r| {
            r.get(0)
        })
        .optional()?
        .unwrap_or_else(|| "[]".into()))
}
#[flutter_rust_bridge::frb(ignore)]
pub(crate) fn put_record(db: &Connection, kind: &str, json: &str) -> Result<()> {
    validate(kind, json)?;
    db.execute(
        "INSERT INTO records VALUES (?1,?2) ON CONFLICT(kind) DO UPDATE SET value=excluded.value",
        params![kind, json],
    )?;
    Ok(())
}
fn validate_references(db: &Connection, hosts: &[Host]) -> Result<()> {
    for h in hosts.iter().filter(|h| !h.identity_id.is_empty()) {
        let exists: bool = db.query_row(
            "SELECT EXISTS(SELECT 1 FROM identities WHERE id=?1)",
            [&h.identity_id],
            |r| r.get(0),
        )?;
        ensure!(exists, "主机关联的身份不存在，请重新选择");
    }
    Ok(())
}
fn save_identity(db: &Connection, mut input: SensitiveInput) -> Result<String> {
    let secrets = Secrets {
        password: Zeroizing::new(std::mem::take(&mut input.password)),
        private_key: Zeroizing::new(std::mem::take(&mut input.private_key)),
        passphrase: Zeroizing::new(std::mem::take(&mut input.passphrase)),
    };
    ensure!(
        !input.name.trim().is_empty()
            && !input.username.trim().is_empty()
            && input.name.len() <= 4096
            && input.username.len() <= 4096,
        "请输入身份名称和用户名"
    );
    ensure!(
        matches!(input.kind.as_str(), "password" | "key" | "interactive"),
        "身份类型无效"
    );
    let id = if input.id.is_empty() {
        uuid::Uuid::new_v4().to_string()
    } else {
        std::mem::take(&mut input.id)
    };
    if !input.replace_secret {
        let changed = db.execute(
            "UPDATE identities SET name=?1,username=?2 WHERE id=?3 AND kind=?4",
            params![input.name, input.username, id, input.kind],
        )?;
        ensure!(changed == 1, "身份不存在或类型已变更");
        return Ok(id);
    }
    ensure!(
        secrets.password.len() <= 16384
            && secrets.private_key.len() <= 65536
            && secrets.passphrase.len() <= 16384,
        "凭证过长"
    );
    if input.kind == "key" {
        ensure!(
            secrets.password.is_empty() && !secrets.private_key.is_empty(),
            "请选择私钥"
        );
        russh::keys::decode_secret_key(
            &secrets.private_key,
            if secrets.passphrase.is_empty() {
                None
            } else {
                Some(secrets.passphrase.as_str())
            },
        )
        .map_err(|_| anyhow!("私钥无法解析，请检查文件和口令"))?;
    } else if input.kind == "interactive" {
        ensure!(
            secrets.password.is_empty()
                && secrets.private_key.is_empty()
                && secrets.passphrase.is_empty(),
            "仅交互式身份不保存凭证"
        );
    } else {
        ensure!(
            !secrets.password.is_empty()
                && secrets.private_key.is_empty()
                && secrets.passphrase.is_empty(),
            "请输入密码"
        );
    }
    db.execute("INSERT INTO identities VALUES (?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(id) DO UPDATE SET name=excluded.name,username=excluded.username,kind=excluded.kind,password=excluded.password,private_key=excluded.private_key,passphrase=excluded.passphrase",
        params![id,input.name,input.username,input.kind,secrets.password.as_str(),secrets.private_key.as_str(),secrets.passphrase.as_str()])?;
    Ok(id)
}
pub fn vault_identities(token: String) -> Result<Vec<IdentitySummary>> {
    with_vault(&token, |db| {
        let mut query =
            db.prepare("SELECT id,name,username,kind FROM identities ORDER BY name,id")?;
        let rows = query.query_map([], |r| {
            Ok(IdentitySummary {
                id: r.get(0)?,
                name: r.get(1)?,
                username: r.get(2)?,
                kind: r.get(3)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    })
}
pub fn vault_save_identity(token: String, input: IdentityInput) -> Result<String> {
    let input = SensitiveInput(input);
    with_vault(&token, |db| {
        ensure!(imported(db)?, "请先完成迁移");
        let tx = db.transaction()?;
        let id = save_identity(&tx, input)?;
        let username: String =
            tx.query_row("SELECT username FROM identities WHERE id=?1", [&id], |r| {
                r.get(0)
            })?;
        let mut hosts: Vec<Host> = serde_json::from_str(&read_record(&tx, "hosts")?)?;
        for h in &mut hosts {
            if h.identity_id == id {
                h.username = username.clone();
            }
        }
        put_record(&tx, "hosts", &serde_json::to_string(&hosts)?)?;
        tx.commit()?;
        Ok(id)
    })
}
/// Generate directly into SQLCipher; only the identity ID crosses the bridge.
pub fn vault_generate_key(token: String, name: String, username: String) -> Result<String> {
    with_vault(&token, |db| {
        ensure!(imported(db)?, "请先完成迁移");
        ensure!(
            !name.trim().is_empty()
                && name.len() <= 4096
                && !username.trim().is_empty()
                && username.len() <= 4096,
            "请输入身份名称和用户名"
        );
        let key =
            russh::keys::PrivateKey::random(&mut rand::rng(), russh::keys::Algorithm::Ed25519)?;
        let encoded = key.to_openssh(russh::keys::ssh_key::LineEnding::LF)?;
        save_identity(
            db,
            SensitiveInput(IdentityInput {
                id: String::new(),
                name: name.trim().into(),
                username: username.trim().into(),
                kind: "key".into(),
                password: String::new(),
                private_key: encoded.to_string(),
                passphrase: String::new(),
                replace_secret: true,
            }),
        )
    })
}

/// Public material only. Also works for imported password-protected private keys.
pub fn vault_public_key(token: String, id: String) -> Result<String> {
    with_vault(&token, |db| {
        let key = read_private_key(db, &id)?;
        Ok(key.public_key().to_openssh()?)
    })
}

fn read_private_key(db: &Connection, id: &str) -> Result<russh::keys::PrivateKey> {
    let (private_key, passphrase) = db
        .query_row(
            "SELECT private_key,passphrase FROM identities WHERE id=?1 AND kind='key'",
            [id],
            |r| {
                Ok((
                    Zeroizing::new(r.get::<_, String>(0)?),
                    Zeroizing::new(r.get::<_, String>(1)?),
                ))
            },
        )
        .map_err(|_| anyhow!("私钥身份不存在"))?;
    let key = russh::keys::decode_secret_key(
        &private_key,
        if passphrase.is_empty() {
            None
        } else {
            Some(passphrase.as_str())
        },
    )
    .map_err(|_| anyhow!("私钥无法解析，请检查文件和口令"))?;
    Ok(key)
}

/// Only encrypted OpenSSH bytes are written. Never replaces an existing file.
pub fn vault_export_private_key(
    token: String,
    id: String,
    path: String,
    password: String,
) -> Result<()> {
    use std::io::Write;
    let password = Zeroizing::new(password);
    ensure!(
        password.chars().count() >= 12 && password.len() <= 1024,
        "导出口令至少 12 个字符，最多 1024 字节"
    );
    with_vault(&token, |db| {
        let key = read_private_key(db, &id)?;
        let encrypted = key.encrypt(&mut rand::rng(), password.as_bytes())?;
        let encoded = encrypted.to_openssh(russh::keys::ssh_key::LineEnding::LF)?;
        let destination = Path::new(&path);
        let mut staging =
            tempfile::NamedTempFile::new_in(destination.parent().context("无效的导出路径")?)?;
        staging.write_all(encoded.as_bytes())?;
        staging.as_file().sync_all()?;
        staging
            .persist_noclobber(destination)
            .map_err(|_| anyhow!("无法保存私钥，目标可能已存在"))?;
        Ok(())
    })
}

pub fn vault_delete_identity(token: String, id: String) -> Result<()> {
    with_vault(&token, |db| {
        let hosts: Vec<Host> = serde_json::from_str(&read_record(db, "hosts")?)?;
        ensure!(
            !hosts.iter().any(|h| h.identity_id == id),
            "此身份仍被主机使用，请先修改相关主机的认证方式"
        );
        db.execute("DELETE FROM identities WHERE id=?1", [id])?;
        Ok(())
    })
}
/// Saves credential and host in one transaction. No plaintext credential is returned.
pub fn vault_save_host(
    token: String,
    host_json: String,
    identity: Option<IdentityInput>,
) -> Result<String> {
    let identity = identity.map(SensitiveInput);
    validate("hosts", &format!("[{host_json}]"))?;
    let mut host: Host = serde_json::from_str(&host_json)?;
    with_vault(&token, |db| {
        ensure!(imported(db)?, "请先完成迁移");
        let tx = db.transaction()?;
        if let Some(input) = identity {
            host.identity_id = save_identity(&tx, input)?;
        }
        validate_references(&tx, std::slice::from_ref(&host))?;
        if !host.identity_id.is_empty() {
            host.username = tx.query_row(
                "SELECT username FROM identities WHERE id=?1",
                [&host.identity_id],
                |r| r.get(0),
            )?;
        }
        let json = serde_json::to_string(&host)?;
        let mut hosts: Vec<Host> = serde_json::from_str(&read_record(&tx, "hosts")?)?;
        hosts.retain(|h| h.id != host.id);
        hosts.push(host);
        validate_host_routes(&hosts)?;
        put_record(&tx, "hosts", &serde_json::to_string(&hosts)?)?;
        tx.commit()?;
        Ok(json)
    })
}
pub async fn vault_authenticate_identity(
    token: String,
    identity_id: String,
    connection_id: String,
    approved_fingerprint: String,
) -> Result<String> {
    let (username, mut secrets) = identity_secrets(&token, &identity_id)?;
    crate::session::authenticate(
        &connection_id,
        &approved_fingerprint,
        username.clone(),
        std::mem::take(&mut *secrets.password),
        std::mem::take(&mut *secrets.private_key),
        std::mem::take(&mut *secrets.passphrase),
    )
    .await?;
    // A lock racing with authentication must not leave an authenticated session.
    if with_vault(&token, |_| Ok(())).is_err() {
        crate::session::disconnect(&connection_id).await?;
        return Err(anyhow!("保险库已锁定"));
    }
    Ok(username)
}
/// Authenticates an intermediate route hop without opening a terminal.
pub async fn vault_authenticate_jump_identity(
    token: String,
    identity_id: String,
    connection_id: String,
    approved_fingerprint: String,
) -> Result<String> {
    let (username, mut secrets) = identity_secrets(&token, &identity_id)?;
    crate::session::authenticate_jump(
        &connection_id,
        &approved_fingerprint,
        username.clone(),
        std::mem::take(&mut *secrets.password),
        std::mem::take(&mut *secrets.private_key),
        std::mem::take(&mut *secrets.passphrase),
    )
    .await?;
    if with_vault(&token, |_| Ok(())).is_err() {
        crate::session::disconnect(&connection_id).await?;
        return Err(anyhow!("保险库已锁定"));
    }
    Ok(username)
}
fn identity_secrets(token: &str, identity_id: &str) -> Result<(String, Secrets)> {
    with_vault(token, |db| {
        db.query_row(
            "SELECT username,password,private_key,passphrase FROM identities WHERE id=?1",
            [identity_id],
            |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    Secrets {
                        password: Zeroizing::new(r.get(1)?),
                        private_key: Zeroizing::new(r.get(2)?),
                        passphrase: Zeroizing::new(r.get(3)?),
                    },
                ))
            },
        )
        .map_err(|_| anyhow!("身份不存在，请编辑主机重新选择"))
    })
}
fn within_folder(path: &str, parent: &str) -> bool {
    path == parent || path.starts_with(&format!("{parent}/"))
}
pub fn vault_delete_folder(token: String, path: String, delete_hosts: bool) -> Result<()> {
    ensure!(!path.is_empty(), "未分类不能删除");
    with_vault(&token, |db| {
        let tx = db.transaction()?;
        let mut hosts: Vec<Host> = serde_json::from_str(&read_record(&tx, "hosts")?)?;
        if delete_hosts {
            hosts.retain(|h| !within_folder(&h.group, &path));
            validate_host_routes(&hosts)
                .context("有主机以被删除的主机为跳板，请先修改这些主机的路线")?;
        }
        for h in &mut hosts {
            if within_folder(&h.group, &path) {
                h.group.clear();
            }
        }
        let mut folders: Vec<String> = serde_json::from_str(&read_record(&tx, "folders")?)?;
        folders.retain(|f| !within_folder(f, &path));
        put_record(&tx, "hosts", &serde_json::to_string(&hosts)?)?;
        put_record(&tx, "folders", &serde_json::to_string(&folders)?)?;
        tx.commit()?;
        Ok(())
    })
}
/// Rename a whole subtree atomically, retaining host and identity IDs.
pub fn vault_rename_folder(token: String, path: String, name: String) -> Result<String> {
    let leaf = name.trim();
    ensure!(!path.is_empty(), "未分类不能重命名");
    ensure!(
        !leaf.is_empty()
            && leaf != "."
            && leaf != ".."
            && !leaf.contains('/')
            && !leaf.chars().any(char::is_control),
        "请输入有效的文件夹名称"
    );
    let destination = match path.rsplit_once('/') {
        Some((parent, _)) => format!("{parent}/{leaf}"),
        None => leaf.to_string(),
    };
    ensure!(destination.len() <= 4096, "文件夹路径过长");
    with_vault(&token, |db| {
        let tx = db.transaction()?;
        let mut hosts: Vec<Host> = serde_json::from_str(&read_record(&tx, "hosts")?)?;
        let mut folders: Vec<String> = serde_json::from_str(&read_record(&tx, "folders")?)?;
        ensure!(
            folders
                .iter()
                .chain(hosts.iter().map(|h| &h.group))
                .any(|f| within_folder(f, &path)),
            "文件夹不存在，请刷新列表"
        );
        if destination == path {
            return Ok(destination.clone());
        }
        ensure!(
            !folders
                .iter()
                .chain(hosts.iter().map(|h| &h.group))
                .any(|f| within_folder(f, &destination)),
            "同级文件夹已存在，不能合并覆盖"
        );
        for folder in &mut folders {
            if within_folder(folder, &path) {
                *folder = format!("{}{}", destination, &folder[path.len()..]);
            }
        }
        for host in &mut hosts {
            if within_folder(&host.group, &path) {
                host.group = format!("{}{}", destination, &host.group[path.len()..]);
            }
        }
        if !folders.contains(&destination) {
            folders.push(destination.clone());
        }
        put_record(&tx, "folders", &serde_json::to_string(&folders)?)?;
        put_record(&tx, "hosts", &serde_json::to_string(&hosts)?)?;
        tx.commit()?;
        Ok(destination.clone())
    })
}

pub fn vault_change_password(
    token: String,
    current_password: String,
    new_password: String,
) -> Result<()> {
    let current = Zeroizing::new(current_password);
    let new = Zeroizing::new(new_password);
    ensure!(
        new.chars().count() >= 12 && new.len() <= 1024,
        "新主密码至少 12 个字符，最多 1024 字节"
    );
    let mut state = registry().lock().map_err(|_| anyhow!("保险库状态不可用"))?;
    let vault = state
        .as_mut()
        .filter(|v| v.token == token)
        .context("保险库已锁定")?;
    let db = vault
        .db
        .as_mut()
        .context("同步正在进行，请稍后修改主密码")?;
    let verified = key_database_mode(&vault.path, &current, true)?;
    verified
        .query_row("SELECT count(*) FROM sqlite_master", [], |r| {
            r.get::<_, i64>(0)
        })
        .map_err(|_| anyhow!("当前主密码错误"))?;
    drop(verified);
    let rc =
        unsafe { rusqlite::ffi::sqlite3_rekey(db.handle(), new.as_ptr().cast(), new.len() as i32) };
    ensure!(rc == rusqlite::ffi::SQLITE_OK, "主密码修改失败");
    Ok(())
}
pub fn vault_export_backup(token: String, path: String, password: String) -> Result<()> {
    let password = Zeroizing::new(password);
    ensure!(
        password.chars().count() >= 12 && password.len() <= 1024,
        "备份密码至少需要 12 个字符"
    );
    let path = Path::new(&path);
    ensure!(!path.exists(), "备份文件已存在，不能覆盖");
    let file = tempfile::NamedTempFile::new_in(path.parent().context("Invalid backup path")?)?;
    with_vault(&token, |db| {
        db.execute(
            "ATTACH DATABASE ?1 AS vault_backup KEY ?2",
            params![file.path().to_string_lossy(), password.as_str()],
        )?;
        let result = (|| -> Result<()> {
            db.execute_batch("PRAGMA vault_backup.cipher_compatibility=4;")?;
            db.query_row("SELECT sqlcipher_export('vault_backup')", [], |_| Ok(()))?;
            db.execute_batch("PRAGMA vault_backup.user_version=3;")?;
            Ok(())
        })();
        let detached = db.execute_batch("DETACH DATABASE vault_backup");
        result?;
        detached?;
        Ok(())
    })?;
    file.as_file().sync_all()?;
    file.persist_noclobber(path)
        .map_err(|_| anyhow!("无法保存备份，目标可能已存在"))?;
    Ok(())
}
/// Import as new records, preserving all existing hosts and identities.
pub fn vault_restore_backup(token: String, path: String, password: String) -> Result<u32> {
    let password = Zeroizing::new(password);
    ensure!(
        std::fs::metadata(&path)?.len() <= 512 * 1024 * 1024,
        "备份文件不能超过 512 MiB"
    );
    let source = key_database_mode(Path::new(&path), &password, true)?;
    let version: i32 = source
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .map_err(|_| anyhow!("备份密码错误或文件损坏"))?;
    ensure!((1..=3).contains(&version), "不支持的备份版本");
    let format: String =
        source.query_row("SELECT value FROM metadata WHERE key='format'", [], |r| {
            r.get(0)
        })?;
    ensure!(format == "wterm-vault-v1", "不是 W Term 备份");
    let host_json = read_record(&source, "hosts")?;
    let folder_json = read_record(&source, "folders")?;
    let snippet_json = read_record(&source, "snippets")?;
    validate("snippets", &snippet_json)?;
    validate("hosts", &host_json)?;
    validate("folders", &folder_json)?;
    let mut restored: Vec<Host> = serde_json::from_str(&host_json)?;
    let count = restored.len() as u32;
    with_vault(&token, |db| {
        let tx = db.transaction()?;
        let mut ids = HashMap::new();
        if version >= 2 {
            let mut stmt = source.prepare(
                "SELECT id,name,username,kind,password,private_key,passphrase FROM identities",
            )?;
            let rows = stmt.query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    IdentityInput {
                        id: String::new(),
                        name: r.get(1)?,
                        username: r.get(2)?,
                        kind: r.get(3)?,
                        password: r.get(4)?,
                        private_key: r.get(5)?,
                        passphrase: r.get(6)?,
                        replace_secret: true,
                    },
                ))
            })?;
            for row in rows {
                let (old, input) = row?;
                let mut input = SensitiveInput(input);
                ensure!(ids.len() < 10000, "备份身份数量过多");
                input.name.push_str(" (恢复)");
                ids.insert(old, save_identity(&tx, input)?);
            }
        }
        let mut hosts: Vec<Host> = serde_json::from_str(&read_record(&tx, "hosts")?)?;
        let mut host_ids = HashMap::new();
        for h in &mut restored {
            let old = std::mem::take(&mut h.id);
            let new_id = uuid::Uuid::new_v4().to_string();
            host_ids.insert(old, new_id.clone());
            h.id = new_id;
            h.name.push_str(" (恢复)");
            if !h.identity_id.is_empty() {
                h.identity_id = ids.get(&h.identity_id).context("备份身份引用无效")?.clone();
            }
        }
        for h in &mut restored {
            h.jump_host_ids = h
                .jump_host_ids
                .iter()
                .map(|id| {
                    host_ids
                        .get(id)
                        .context("备份中的跳板主机引用无效")
                        .cloned()
                })
                .collect::<Result<_>>()?;
        }
        hosts.extend(restored);
        validate_host_routes(&hosts)?;
        let mut folders: Vec<String> = serde_json::from_str(&read_record(&tx, "folders")?)?;
        folders.extend(serde_json::from_str::<Vec<String>>(&folder_json)?);
        folders.sort();
        folders.dedup();
        put_record(&tx, "hosts", &serde_json::to_string(&hosts)?)?;
        put_record(&tx, "folders", &serde_json::to_string(&folders)?)?;
        let mut snippets: Vec<Snippet> = serde_json::from_str(&read_record(&tx, "snippets")?)?;
        for mut entry in serde_json::from_str::<Vec<Snippet>>(&snippet_json)? {
            entry.id = uuid::Uuid::new_v4().to_string();
            entry.name.push_str(" (恢复)");
            snippets.push(entry);
        }
        put_record(&tx, "snippets", &serde_json::to_string(&snippets)?)?;
        tx.commit()?;
        Ok(count)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    static SERIAL: Mutex<()> = Mutex::new(());
    #[test]
    fn sync_lease_cancel_lock_and_reopen_do_not_reattach_stale_database() -> Result<()> {
        let _serial = SERIAL.lock().unwrap();
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("lease.db").to_string_lossy().to_string();
        let password = "lease fixture master password".to_owned();
        let token = vault_open(path.clone(), password.clone(), true)?.token;
        let first = lease(&token)?;
        assert!(with_vault(&token, |_| Ok(())).is_err());
        assert!(lease(&token).is_err());
        assert!(vault_change_password(
            token.clone(),
            password.clone(),
            "another long password".into()
        )
        .is_err());
        cancel_sync(&token)?;
        let runtime = tokio::runtime::Runtime::new()?;
        runtime.block_on(async {
            tokio::time::timeout(
                std::time::Duration::from_secs(1),
                first.cancelled.notified(),
            )
            .await
            .unwrap();
        });
        drop(first);
        with_vault(&token, |_| Ok(()))?;
        let old = lease(&token)?;
        vault_lock(token.clone())?;
        runtime.block_on(async {
            tokio::time::timeout(std::time::Duration::from_secs(1), old.cancelled.notified())
                .await
                .unwrap();
        });
        let fresh = vault_open(path, password, false)?.token;
        let current = lease(&fresh)?;
        drop(old);
        assert!(with_vault(&fresh, |_| Ok(())).is_err());
        drop(current);
        with_vault(&fresh, |_| Ok(()))?;
        assert!(cancel_sync(&token).is_err());
        vault_lock(fresh)?;
        Ok(())
    }
    #[test]
    fn snippets_are_encrypted_backed_up_and_reject_control_characters() -> Result<()> {
        let _serial = SERIAL.lock().unwrap();
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("vault.db").to_string_lossy().to_string();
        let token = vault_open(path.clone(), "snippet master password".into(), true)?.token;
        vault_import_legacy(token.clone(), "[]".into(), "[]".into())?;
        with_vault(&token, |db| {
            db.execute_batch("PRAGMA user_version=2;")?;
            Ok(())
        })?;
        vault_lock(token)?;
        let token = vault_open(path.clone(), "snippet master password".into(), false)?.token;
        with_vault(&token, |db| {
            let version: i32 = db.query_row("PRAGMA user_version", [], |r| r.get(0))?;
            assert_eq!(version, 3);
            Ok(())
        })?;
        for command in ["ls\nreboot", "\u{1b}[200~", "", "tab\t"] {
            assert!(
                vault_save_snippet(token.clone(), "".into(), "Bad".into(), command.into()).is_err()
            );
        }
        vault_save_snippet(
            token.clone(),
            "".into(),
            "Secret snippet".into(),
            "echo unique-snippet-fixture".into(),
        )?;
        let entries: Vec<Snippet> =
            serde_json::from_str(&vault_read(token.clone(), "snippets".into())?)?;
        let id = entries[0].id.clone();
        let backup = dir.path().join("backup").to_string_lossy().to_string();
        vault_export_backup(
            token.clone(),
            backup.clone(),
            "snippet backup password".into(),
        )?;
        vault_restore_backup(token.clone(), backup, "snippet backup password".into())?;
        let restored: Vec<Snippet> =
            serde_json::from_str(&vault_read(token.clone(), "snippets".into())?)?;
        assert_eq!(restored.len(), 2);
        assert_ne!(restored[0].id, restored[1].id);
        vault_delete_snippet(token.clone(), id.clone())?;
        assert!(vault_save_snippet(token.clone(), id, "stale".into(), "ls".into()).is_err());
        vault_lock(token.clone())?;
        assert!(vault_read(token, "snippets".into()).is_err());
        let bytes = std::fs::read(&path)?;
        assert!(!bytes
            .windows(b"unique-snippet-fixture".len())
            .any(|w| w == b"unique-snippet-fixture"));
        let token = vault_open(path, "snippet master password".into(), false)?.token;
        assert_eq!(
            serde_json::from_str::<Vec<Snippet>>(&vault_read(token.clone(), "snippets".into())?)?
                .len(),
            1
        );
        vault_lock(token)?;
        Ok(())
    }
    #[test]
    fn encrypted_key_export_roundtrip_and_no_overwrite() -> Result<()> {
        let _serial = SERIAL.lock().unwrap();
        let dir = tempfile::tempdir()?;
        let token = vault_open(
            dir.path().join("vault.db").to_string_lossy().into(),
            "export fixture master".into(),
            true,
        )?
        .token;
        vault_import_legacy(token.clone(), "[]".into(), "[]".into())?;
        let id = vault_generate_key(token.clone(), "Export key".into(), "root".into())?;
        let public = vault_public_key(token.clone(), id.clone())?;
        let path = dir.path().join("id_ed25519").to_string_lossy().to_string();
        let password = "separate export password".to_string();
        assert!(
            vault_export_private_key(token.clone(), id.clone(), path.clone(), "short".into())
                .is_err()
        );
        assert!(!Path::new(&path).exists());
        vault_export_private_key(token.clone(), id.clone(), path.clone(), password.clone())?;
        let encoded = std::fs::read_to_string(&path)?;
        let encrypted = russh::keys::PrivateKey::from_openssh(&encoded)?;
        assert!(encrypted.is_encrypted());
        assert!(russh::keys::decode_secret_key(&encoded, Some("wrong")).is_err());
        let decoded = russh::keys::decode_secret_key(&encoded, Some(&password))?;
        assert_eq!(decoded.public_key().to_openssh()?, public);
        assert!(vault_export_private_key(
            token.clone(),
            id.clone(),
            path.clone(),
            password.clone()
        )
        .is_err());
        assert_eq!(std::fs::read_to_string(&path)?, encoded);
        let imported = vault_save_identity(
            token.clone(),
            IdentityInput {
                id: String::new(),
                name: "Imported export".into(),
                username: "root".into(),
                kind: "key".into(),
                password: String::new(),
                private_key: encoded,
                passphrase: password.clone(),
                replace_secret: true,
            },
        )?;
        assert_eq!(vault_public_key(token.clone(), imported.clone())?, public);
        let second = dir.path().join("second").to_string_lossy().to_string();
        vault_export_private_key(
            token.clone(),
            imported,
            second.clone(),
            "different export password".into(),
        )?;
        let reexported = std::fs::read_to_string(&second)?;
        assert!(russh::keys::decode_secret_key(&reexported, Some(&password)).is_err());
        assert_eq!(
            russh::keys::decode_secret_key(&reexported, Some("different export password"))?
                .public_key()
                .to_openssh()?,
            public
        );
        vault_lock(token.clone())?;
        assert!(vault_export_private_key(
            token,
            id,
            dir.path().join("locked").to_string_lossy().into(),
            password
        )
        .is_err());
        Ok(())
    }
    #[test]
    fn generated_keys_persist_and_are_distinct() -> Result<()> {
        let _serial = SERIAL.lock().unwrap();
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("keys.db").to_string_lossy().to_string();
        let password = "generated key test password".to_string();
        let token = vault_open(path.clone(), password.clone(), true)?.token;
        vault_import_legacy(token.clone(), "[]".into(), "[]".into())?;
        assert!(vault_generate_key(token.clone(), " ".into(), "root".into()).is_err());
        let first = vault_generate_key(token.clone(), "Mac key".into(), "root".into())?;
        let second = vault_generate_key(token.clone(), "Phone key".into(), "user".into())?;
        let public = vault_public_key(token.clone(), first.clone())?;
        assert!(public.starts_with("ssh-ed25519 "));
        assert_ne!(public, vault_public_key(token.clone(), second)?);
        assert!(!public.contains("PRIVATE"));
        let parsed = russh::keys::PublicKey::from_openssh(&public)?;
        with_vault(&token, |db| {
            let encoded = Zeroizing::new(db.query_row(
                "SELECT private_key FROM identities WHERE id=?1",
                [&first],
                |r| r.get::<_, String>(0),
            )?);
            let key = russh::keys::decode_secret_key(&encoded, None)?;
            assert_eq!(key.public_key(), &parsed);
            Ok(())
        })?;
        vault_lock(token.clone())?;
        assert!(vault_public_key(token.clone(), first.clone()).is_err());
        assert!(vault_generate_key(token, "Locked".into(), "root".into()).is_err());
        let token = vault_open(path, password, false)?.token;
        assert_eq!(public, vault_public_key(token.clone(), first)?);
        vault_lock(token)?;
        Ok(())
    }
    #[test]
    fn encrypted_lifecycle_migration_and_stale_tokens() -> Result<()> {
        let _serial = SERIAL.lock().unwrap();
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("vault.db").to_string_lossy().to_string();
        let pass = "a sufficiently long master password".to_string();
        let opened = vault_open(path.clone(), pass.clone(), true)?;
        assert!(!opened.legacy_imported);
        assert!(vault_write(opened.token.clone(), "hosts".into(), "[]".into()).is_err());
        let hosts = r#"[{"id":"a","name":"secret-server-name","host":"internal.example","username":"alice","port":22,"group":"Work","tags":[],"favorite":false}]"#;
        assert!(vault_import_legacy(opened.token.clone(), hosts.into(), "[1]".into()).is_err());
        assert_eq!(vault_read(opened.token.clone(), "hosts".into())?, "[]");
        vault_import_legacy(opened.token.clone(), hosts.into(), "[\"Work\"]".into())?;
        vault_import_legacy(opened.token.clone(), "[]".into(), "[]".into())?;
        assert_eq!(vault_read(opened.token.clone(), "hosts".into())?, hosts);
        assert!(vault_write(
            opened.token.clone(),
            "hosts".into(),
            hosts.replace("\"port\":22", "\"port\":0")
        )
        .is_err());
        vault_lock(opened.token.clone())?;
        assert!(vault_read(opened.token.clone(), "hosts".into()).is_err());
        let bytes = std::fs::read(&path)?;
        assert!(!bytes.starts_with(b"SQLite format 3"));
        for text in ["secret-server-name", "internal.example", pass.as_str()] {
            assert!(!bytes.windows(text.len()).any(|w| w == text.as_bytes()));
        }
        assert!(vault_open(path.clone(), "wrong password".into(), false).is_err());
        assert_eq!(std::fs::read(&path)?, bytes);
        assert!(vault_open(path.clone(), pass.clone(), true).is_err());
        let reopened = vault_open(path.clone(), pass, false)?;
        assert!(reopened.legacy_imported);
        assert_eq!(vault_read(reopened.token.clone(), "hosts".into())?, hosts);
        vault_lock(opened.token.clone())?; // stale lock cannot close a new session
        assert!(vault_write(opened.token, "hosts".into(), "[]".into()).is_err());
        vault_write(
            reopened.token.clone(),
            "folders".into(),
            "[\"Personal\"]".into(),
        )?;
        vault_lock(reopened.token)?;
        Ok(())
    }
    #[test]
    fn rejects_invalid_schema_and_weak_password_without_creating_file() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("vault.db");
        assert!(open_database(&path, "short", true).is_err());
        assert!(!path.exists());
        assert!(validate("folders", "[\"a\",\"a\"]").is_err());
        assert!(validate("secrets", "[]").is_err());
        let hosts = r#"[{"id":"a","name":"b","host":"h","username":"u","port":22,"group":"","tags":[],"favorite":false,"password":"do-not-store"}]"#;
        assert!(validate("hosts", hosts).is_err());
        Ok(())
    }
    fn password_input() -> IdentityInput {
        IdentityInput {
            id: String::new(),
            name: "Login".into(),
            username: "wterm".into(),
            kind: "password".into(),
            password: "wterm-test-only".into(),
            private_key: String::new(),
            passphrase: String::new(),
            replace_secret: true,
        }
    }
    #[test]
    fn folder_rename_is_atomic_and_preserves_ids() -> Result<()> {
        let _serial = SERIAL.lock().unwrap();
        let dir = tempfile::tempdir()?;
        let token = vault_open(
            dir.path().join("rename.db").to_string_lossy().into(),
            "rename fixture password".into(),
            true,
        )?
        .token;
        vault_import_legacy(
            token.clone(),
            "[]".into(),
            r#"["Work/Sub","Work2","Other/Child"]"#.into(),
        )?;
        let input = r#"{"id":"rename-host","name":"Saved","host":"127.0.0.1","username":"wterm","port":22,"group":"Work/Sub","tags":[],"favorite":true}"#;
        let saved: Host = serde_json::from_str(&vault_save_host(
            token.clone(),
            input.into(),
            Some(password_input()),
        )?)?;
        assert_eq!(
            vault_rename_folder(token.clone(), "Work".into(), "生产".into())?,
            "生产"
        );
        let hosts: Vec<Host> = serde_json::from_str(&vault_read(token.clone(), "hosts".into())?)?;
        assert_eq!(hosts[0].group, "生产/Sub");
        assert_eq!(hosts[0].id, saved.id);
        assert_eq!(hosts[0].identity_id, saved.identity_id);
        assert!(hosts[0].favorite);
        let before_hosts = vault_read(token.clone(), "hosts".into())?;
        let before_folders = vault_read(token.clone(), "folders".into())?;
        for name in ["Other", "Work2", "bad/name", "..", "", "bad\0name"] {
            assert!(vault_rename_folder(token.clone(), "生产".into(), name.into()).is_err());
            assert_eq!(vault_read(token.clone(), "hosts".into())?, before_hosts);
            assert_eq!(vault_read(token.clone(), "folders".into())?, before_folders);
        }
        assert!(vault_rename_folder(token.clone(), "missing".into(), "Next".into()).is_err());
        assert!(vault_rename_folder(token.clone(), "".into(), "Next".into()).is_err());
        assert_eq!(
            vault_rename_folder(token.clone(), "生产/Sub".into(), " 服务 ".into())?,
            "生产/服务"
        );
        vault_lock(token)?;
        Ok(())
    }

    #[test]
    fn credentials_folders_rotation_and_backup_roundtrip() -> Result<()> {
        let _serial = SERIAL.lock().unwrap();
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("vault.db").to_string_lossy().to_string();
        let backup = dir.path().join("backup.db").to_string_lossy().to_string();
        let pass = "a long original password".to_string();
        let opened = vault_open(path.clone(), pass.clone(), true)?;
        let token = opened.token;
        vault_import_legacy(token.clone(), "[]".into(), "[]".into())?;
        let input = r#"{"id":"host","name":"Saved","host":"127.0.0.1","username":"wterm","port":22,"group":"Work/Prod/Api","tags":[],"favorite":false}"#;
        let saved = vault_save_host(token.clone(), input.into(), Some(password_input()))?;
        let host: Host = serde_json::from_str(&saved)?;
        assert!(!host.identity_id.is_empty());
        assert_eq!(vault_identities(token.clone())?.len(), 1);
        assert!(!vault_read(token.clone(), "hosts".into())?.contains("wterm-test-only"));
        assert!(vault_delete_identity(token.clone(), host.identity_id.clone()).is_err());
        let invalid = input.replace(
            "\"id\":\"host\"",
            "\"id\":\"invalid\",\"identityId\":\"missing\"",
        );
        assert!(vault_save_host(token.clone(), invalid, None).is_err());
        vault_write(
            token.clone(),
            "folders".into(),
            r#"["Work","Work/Prod","Work/Prod/Api","Other"]"#.into(),
        )?;
        vault_delete_folder(token.clone(), "Work/Prod".into(), false)?;
        let hosts: Vec<Host> = serde_json::from_str(&vault_read(token.clone(), "hosts".into())?)?;
        assert_eq!(hosts[0].group, "");
        assert_eq!(hosts[0].identity_id, host.identity_id);
        assert_eq!(
            vault_read(token.clone(), "folders".into())?,
            r#"["Work","Other"]"#
        );
        vault_export_backup(
            token.clone(),
            backup.clone(),
            "independent backup password".into(),
        )?;
        assert!(vault_export_backup(
            token.clone(),
            backup.clone(),
            "independent backup password".into()
        )
        .is_err());
        assert!(vault_restore_backup(token.clone(), backup.clone(), "wrong".into()).is_err());
        assert_eq!(
            vault_restore_backup(
                token.clone(),
                backup.clone(),
                "independent backup password".into()
            )?,
            1
        );
        assert_eq!(vault_identities(token.clone())?.len(), 2);
        let hosts: Vec<Host> = serde_json::from_str(&vault_read(token.clone(), "hosts".into())?)?;
        assert_eq!(hosts.len(), 2);
        assert_ne!(hosts[0].id, hosts[1].id);
        assert_ne!(hosts[0].identity_id, hosts[1].identity_id);
        assert!(
            vault_change_password(token.clone(), "wrong".into(), "a long new password".into())
                .is_err()
        );
        vault_change_password(token.clone(), pass.clone(), "a long new password".into())?;
        vault_lock(token)?;
        assert!(vault_open(path.clone(), pass, false).is_err());
        let reopened = vault_open(path.clone(), "a long new password".into(), false)?;
        assert_eq!(vault_identities(reopened.token.clone())?.len(), 2);
        vault_lock(reopened.token)?;
        for file in [path, backup] {
            let bytes = std::fs::read(file)?;
            assert!(!bytes
                .windows(b"wterm-test-only".len())
                .any(|w| w == b"wterm-test-only"));
            assert!(!bytes.starts_with(b"SQLite format 3"));
        }
        Ok(())
    }
    #[tokio::test]
    #[ignore = "Run scripts/test-core.sh to start the loopback fixture"]
    async fn fixture_saved_password_and_private_key_authenticate() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("vault.db").to_string_lossy().to_string();
        let opened = vault_open(path.clone(), "fixture master password".into(), true)?;
        let token = opened.token;
        vault_import_legacy(token.clone(), "[]".into(), "[]".into())?;
        let password_id = vault_save_identity(token.clone(), password_input())?;
        let key = std::fs::read_to_string(
            Path::new(&std::env::var("WTERM_FIXTURE_ROOT")?).join("client_key"),
        )?;
        let key_id = vault_save_identity(
            token.clone(),
            IdentityInput {
                id: String::new(),
                name: "Encrypted key".into(),
                username: "wterm".into(),
                kind: "key".into(),
                password: String::new(),
                private_key: key,
                passphrase: "fixture-passphrase".into(),
                replace_secret: true,
            },
        )?;
        let port: u16 = std::env::var("WTERM_TEST_PORT")?.parse()?;
        for identity_id in [password_id, key_id] {
            let (connection_id, fingerprint) =
                crate::session::probe("127.0.0.1".into(), port).await?;
            let username = vault_authenticate_identity(
                token.clone(),
                identity_id,
                connection_id.clone(),
                fingerprint,
            )
            .await?;
            assert_eq!(username, "wterm");
            assert!(crate::session::live(&connection_id).await.is_ok());
            crate::session::disconnect(&connection_id).await?;
        }
        vault_lock(token)?;
        let bytes = std::fs::read(&path)?;
        for secret in [
            "wterm-test-only",
            "fixture-passphrase",
            "BEGIN OPENSSH PRIVATE KEY",
        ] {
            assert!(!bytes.windows(secret.len()).any(|b| b == secret.as_bytes()));
        }
        Ok(())
    }
    #[test]
    fn interactive_identity_persists_without_secrets() -> Result<()> {
        let _serial = SERIAL.lock().unwrap();
        let dir = tempfile::tempdir()?;
        let path = dir
            .path()
            .join("interactive.db")
            .to_string_lossy()
            .to_string();
        let token = vault_open(path.clone(), "interactive identity password".into(), true)?.token;
        vault_import_legacy(token.clone(), "[]".into(), "[]".into())?;
        let id = vault_save_identity(
            token.clone(),
            IdentityInput {
                id: String::new(),
                name: "MFA only".into(),
                username: "mfa".into(),
                kind: "interactive".into(),
                password: String::new(),
                private_key: String::new(),
                passphrase: String::new(),
                replace_secret: true,
            },
        )?;
        assert_eq!(vault_identities(token.clone())?[0].kind, "interactive");
        assert!(vault_save_identity(
            token.clone(),
            IdentityInput {
                id: id.clone(),
                name: "MFA only".into(),
                username: "mfa".into(),
                kind: "interactive".into(),
                password: "must-not-store".into(),
                private_key: String::new(),
                passphrase: String::new(),
                replace_secret: true,
            },
        )
        .is_err());
        vault_lock(token)?;
        let reopened = vault_open(path, "interactive identity password".into(), false)?;
        let items = vault_identities(reopened.token.clone())?;
        assert_eq!(
            (items[0].id.as_str(), items[0].kind.as_str()),
            (id.as_str(), "interactive")
        );
        vault_lock(reopened.token)?;
        Ok(())
    }
    #[tokio::test]
    #[ignore = "Run scripts/test-core.sh to start the loopback fixture"]
    async fn fixture_saved_interactive_identity_asks_each_connection() -> Result<()> {
        async fn authenticate_with_mfa(token: &str, identity: &str, port: u16) -> Result<()> {
            let (id, fingerprint) = crate::session::probe("127.0.0.1".into(), port).await?;
            let task_id = id.clone();
            let task_token = token.to_string();
            let task_identity = identity.to_string();
            let auth = tokio::spawn(async move {
                vault_authenticate_identity(task_token, task_identity, task_id, fingerprint).await
            });
            for _ in 0..2 {
                let challenge = tokio::time::timeout(Duration::from_secs(5), async {
                    loop {
                        if let Some(challenge) = crate::session::interactive::challenge(&id).await {
                            return challenge;
                        }
                        tokio::time::sleep(Duration::from_millis(5)).await;
                    }
                })
                .await
                .context("fixture challenge timeout")?;
                let answers = if challenge.prompts.len() == 2 {
                    vec!["654321".into(), "visible".into()]
                } else {
                    vec![]
                };
                crate::session::interactive::respond(&id, &challenge.id, answers).await?;
            }
            tokio::time::timeout(Duration::from_secs(10), auth).await???;
            assert!(crate::session::live(&id).await.is_ok());
            crate::session::disconnect(&id).await?;
            Ok(())
        }
        let dir = tempfile::tempdir()?;
        let path = dir
            .path()
            .join("interactive.db")
            .to_string_lossy()
            .to_string();
        let password = "interactive fixture master";
        let opened = vault_open(path.clone(), password.into(), true)?;
        let token = opened.token;
        vault_import_legacy(token.clone(), "[]".into(), "[]".into())?;
        let id = vault_save_identity(
            token.clone(),
            IdentityInput {
                id: String::new(),
                name: "Fixture MFA".into(),
                username: "mfa".into(),
                kind: "interactive".into(),
                password: String::new(),
                private_key: String::new(),
                passphrase: String::new(),
                replace_secret: true,
            },
        )?;
        let port: u16 = std::env::var("WTERM_TEST_PORT")?.parse()?;
        authenticate_with_mfa(&token, &id, port).await?;
        vault_lock(token)?;
        let reopened = vault_open(path, password.into(), false)?;
        authenticate_with_mfa(&reopened.token, &id, port).await?;
        vault_lock(reopened.token)?;
        Ok(())
    }
    #[test]
    fn jump_routes_are_bounded_acyclic_and_remapped_on_restore() -> Result<()> {
        let _serial = SERIAL.lock().unwrap();
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("routes.db").to_string_lossy().to_string();
        let backup = dir
            .path()
            .join("routes-backup.db")
            .to_string_lossy()
            .to_string();
        let token = vault_open(path, "jump route fixture password".into(), true)?.token;
        vault_import_legacy(token.clone(), "[]".into(), "[]".into())?;
        let host = |id: &str, name: &str, jumps: &[&str]| {
            serde_json::json!({
                "id": id, "name": name, "host": "127.0.0.1", "username": "wterm",
                "port": 22, "group": "", "tags": [], "favorite": false,
                "jumpHostIds": jumps
            })
            .to_string()
        };
        let save = |id: &str, name: &str, jumps: &[&str]| {
            vault_save_host(token.clone(), host(id, name, jumps), None)
        };
        save("jump-a", "Jump A", &[])?;
        save("jump-b", "Jump B", &["jump-a"])?;
        save("target", "Target", &["jump-b"])?;
        let stored: Vec<serde_json::Value> =
            serde_json::from_str(&vault_read(token.clone(), "hosts".into())?)?;
        assert!(stored
            .iter()
            .find(|v| v["id"] == "jump-a")
            .unwrap()
            .get("jumpHostIds")
            .is_none());
        assert!(vault_read(token.clone(), "hosts".into())?.contains("jumpHostIds"));
        assert!(save("orphan", "Orphan", &["missing"]).is_err());
        assert!(save("self", "Self", &["self"]).is_err());
        assert!(save("jump-a", "Jump A", &["target"]).is_err());
        assert!(save("jump-b", "Jump B", &["jump-a", "jump-a"]).is_err());
        for (index, id) in ["d1", "d2", "d3", "d4", "d5"].iter().enumerate() {
            let jumps: Vec<&str> = if index == 0 {
                vec![]
            } else {
                vec![["d1", "d2", "d3", "d4", "d5"][index - 1]]
            };
            save(id, id, &jumps)?;
        }
        assert!(save("d6", "d6", &["d5"]).is_err());
        let hosts: Vec<Host> = serde_json::from_str(&vault_read(token.clone(), "hosts".into())?)?;
        let without_a = hosts
            .iter()
            .filter(|h| h.id != "jump-a")
            .map(|h| serde_json::to_value(h).unwrap())
            .collect::<Vec<_>>();
        assert!(vault_write(
            token.clone(),
            "hosts".into(),
            serde_json::to_string(&without_a)?
        )
        .is_err());
        vault_export_backup(token.clone(), backup.clone(), "jump backup password".into())?;
        vault_write(token.clone(), "hosts".into(), "[]".into())?;
        vault_restore_backup(token.clone(), backup, "jump backup password".into())?;
        let restored: Vec<Host> =
            serde_json::from_str(&vault_read(token.clone(), "hosts".into())?)?;
        let jump_a = restored.iter().find(|h| h.name == "Jump A (恢复)").unwrap();
        let jump_b = restored.iter().find(|h| h.name == "Jump B (恢复)").unwrap();
        let target = restored.iter().find(|h| h.name == "Target (恢复)").unwrap();
        assert_ne!(jump_a.id, "jump-a");
        assert_eq!(jump_b.jump_host_ids, vec![jump_a.id.clone()]);
        assert_eq!(target.jump_host_ids, vec![jump_b.id.clone()]);
        vault_lock(token)?;
        Ok(())
    }
    #[test]
    fn upgrades_populated_v1_without_losing_profiles() -> Result<()> {
        let _serial = SERIAL.lock().unwrap();
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("old.db");
        let pass = "legacy fixture master";
        let db = open_database(&path, pass, true)?;
        db.execute_batch("DROP TABLE identities; PRAGMA user_version=1;")?;
        let host = r#"[{"id":"old","name":"Legacy","host":"old.example","username":"alice","port":22,"group":"Work","tags":[],"favorite":true}]"#;
        put_record(&db, "hosts", host)?;
        put_record(&db, "folders", r#"["Work"]"#)?;
        db.execute("INSERT INTO metadata VALUES ('legacy_imported','1')", [])?;
        drop(db);
        let opened = vault_open(path.to_string_lossy().into(), pass.into(), false)?;
        assert!(opened.legacy_imported);
        assert_eq!(vault_read(opened.token.clone(), "hosts".into())?, host);
        assert!(vault_identities(opened.token.clone())?.is_empty());
        vault_lock(opened.token)?;
        Ok(())
    }
}
