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
    db: Connection,
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
fn open_database(path: &Path, password: &str, create: bool) -> Result<Connection> {
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
    ensure!((1..=2).contains(&version), "不支持的保险库版本");
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
        db,
    });
    Ok(VaultOpened {
        token,
        legacy_imported,
    })
}
fn with_vault<T>(token: &str, f: impl FnOnce(&mut Connection) -> Result<T>) -> Result<T> {
    let mut state = registry().lock().map_err(|_| anyhow!("保险库状态不可用"))?;
    let vault = state
        .as_mut()
        .filter(|v| v.token == token)
        .context("保险库已锁定，请重新解锁")?;
    f(&mut vault.db)
}
pub fn vault_lock(token: String) -> Result<()> {
    let mut state = registry().lock().map_err(|_| anyhow!("保险库状态不可用"))?;
    if state.as_ref().is_some_and(|v| v.token == token) {
        *state = None;
    }
    Ok(())
}
fn check_kind(kind: &str) -> Result<()> {
    ensure!(matches!(kind, "hosts" | "folders"), "Unknown vault record");
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
struct Host {
    id: String,
    name: String,
    host: String,
    username: String,
    port: u16,
    group: String,
    tags: Vec<String>,
    favorite: bool,
    #[serde(default, rename = "identityId")]
    identity_id: String,
}
fn validate(kind: &str, json: &str) -> Result<()> {
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
            ensure!(h.port > 0 && ids.insert(h.id), "端口无效或主机 ID 重复");
            ensure!(
                h.group.len() <= 4096
                    && h.tags.len() <= 100
                    && h.tags.iter().all(|t| t.len() <= 4096),
                "分类或标签过长"
            );
            let _ = h.favorite;
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
pub fn vault_write(token: String, kind: String, json: String) -> Result<()> {
    validate(&kind, &json)?;
    with_vault(&token, |db| {
        ensure!(imported(db)?, "请先完成旧配置迁移");
        if kind == "hosts" {
            validate_references(db, &serde_json::from_str::<Vec<Host>>(&json)?)?;
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
fn read_record(db: &Connection, kind: &str) -> Result<String> {
    Ok(db
        .query_row("SELECT value FROM records WHERE kind=?1", [kind], |r| {
            r.get(0)
        })
        .optional()?
        .unwrap_or_else(|| "[]".into()))
}
fn put_record(db: &Connection, kind: &str, json: &str) -> Result<()> {
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
        matches!(input.kind.as_str(), "password" | "key"),
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
    let (username, mut secrets) = with_vault(&token, |db| {
        db.query_row(
            "SELECT username,password,private_key,passphrase FROM identities WHERE id=?1",
            [&identity_id],
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
    })?;
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
    let verified = key_database_mode(&vault.path, &current, true)?;
    verified
        .query_row("SELECT count(*) FROM sqlite_master", [], |r| {
            r.get::<_, i64>(0)
        })
        .map_err(|_| anyhow!("当前主密码错误"))?;
    drop(verified);
    let rc = unsafe {
        rusqlite::ffi::sqlite3_rekey(vault.db.handle(), new.as_ptr().cast(), new.len() as i32)
    };
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
            db.execute_batch("PRAGMA vault_backup.user_version=2;")?;
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
    ensure!((1..=2).contains(&version), "不支持的备份版本");
    let format: String =
        source.query_row("SELECT value FROM metadata WHERE key='format'", [], |r| {
            r.get(0)
        })?;
    ensure!(format == "wterm-vault-v1", "不是 W Term 备份");
    let host_json = read_record(&source, "hosts")?;
    let folder_json = read_record(&source, "folders")?;
    validate("hosts", &host_json)?;
    validate("folders", &folder_json)?;
    let mut restored: Vec<Host> = serde_json::from_str(&host_json)?;
    let count = restored.len() as u32;
    with_vault(&token, |db| {
        let tx = db.transaction()?;
        let mut ids = HashMap::new();
        if version == 2 {
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
        for h in &mut restored {
            h.id = uuid::Uuid::new_v4().to_string();
            h.name.push_str(" (恢复)");
            if !h.identity_id.is_empty() {
                h.identity_id = ids.get(&h.identity_id).context("备份身份引用无效")?.clone();
            }
        }
        hosts.extend(restored);
        let mut folders: Vec<String> = serde_json::from_str(&read_record(&tx, "folders")?)?;
        folders.extend(serde_json::from_str::<Vec<String>>(&folder_json)?);
        folders.sort();
        folders.dedup();
        put_record(&tx, "hosts", &serde_json::to_string(&hosts)?)?;
        put_record(&tx, "folders", &serde_json::to_string(&folders)?)?;
        tx.commit()?;
        Ok(count)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    static SERIAL: Mutex<()> = Mutex::new(());
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
