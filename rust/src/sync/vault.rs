use super::*;
use crate::api::vault::{put_record, read_record, validate};
use rusqlite::{params, Connection};

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Identity {
    id: String,
    name: String,
    username: String,
    kind: String,
    password: String,
    private_key: String,
    passphrase: String,
}
impl Drop for Identity {
    fn drop(&mut self) {
        self.password.zeroize();
        self.private_key.zeroize();
        self.passphrase.zeroize();
    }
}
fn identity(value: &Value) -> Result<Identity> {
    let item: Identity =
        serde_json::from_value(value.clone()).map_err(|_| anyhow::anyhow!("同步身份数据无效"))?;
    ensure!(
        !item.name.trim().is_empty()
            && item.name.len() <= 4096
            && !item.username.trim().is_empty()
            && item.username.len() <= 4096,
        "同步身份名称或用户名无效"
    );
    ensure!(
        item.password.len() <= 16384
            && item.private_key.len() <= 65536
            && item.passphrase.len() <= 16384,
        "同步凭证过长"
    );
    match item.kind.as_str() {
        "password" => ensure!(
            !item.password.is_empty() && item.private_key.is_empty() && item.passphrase.is_empty(),
            "同步密码身份无效"
        ),
        "key" => ensure!(
            item.password.is_empty() && !item.private_key.is_empty(),
            "同步密钥身份无效"
        ),
        _ => anyhow::bail!("同步身份类型无效"),
    }
    Ok(item)
}
pub(super) fn validate_value(key: &Key, value: &Value) -> Result<()> {
    if key.kind != Kind::Folders {
        ensure!(
            value.get("id").and_then(Value::as_str) == Some(key.id.as_str()),
            "同步记录 ID 不一致"
        );
    }
    match key.kind {
        Kind::Host | Kind::Snippet => {
            let json = Zeroizing::new(serde_json::to_string(&[value])?);
            validate(
                if key.kind == Kind::Host {
                    "hosts"
                } else {
                    "snippets"
                },
                &json,
            )
            .map_err(|_| anyhow::anyhow!("同步记录内容无效"))
        }
        Kind::Folders => {
            let json = Zeroizing::new(serde_json::to_string(value)?);
            validate("folders", &json)
        }
        Kind::Identity => {
            identity(value)?;
            Ok(())
        }
    }
}

pub(super) fn validate_collection(kind: &Kind, values: &[&Value]) -> Result<()> {
    let json = Zeroizing::new(serde_json::to_string(values)?);
    validate(
        if *kind == Kind::Host {
            "hosts"
        } else {
            "snippets"
        },
        &json,
    )
    .map_err(|_| anyhow::anyhow!("同步集合超过保险库限制或内容无效"))
}

pub(super) fn current(db: &Connection) -> Result<Vec<Record>> {
    let mut records = vec![];
    let revision = Revision {
        counter: 1,
        device: uuid::Uuid::nil().to_string(),
    };
    for (kind, name) in [
        (Kind::Host, "hosts"),
        (Kind::Snippet, "snippets"),
        (Kind::Folders, "folders"),
    ] {
        let json = Zeroizing::new(read_record(db, name)?);
        validate(name, &json)?;
        let value: Value =
            serde_json::from_str(&json).map_err(|_| anyhow::anyhow!("保险库记录格式无效"))?;
        // Empty collections are absent on first sync; later removal becomes a tombstone.
        if kind == Kind::Folders && value.as_array().is_some_and(Vec::is_empty) {
            continue;
        }
        let values = if kind == Kind::Folders {
            vec![value]
        } else {
            match value {
                Value::Array(items) => items,
                _ => unreachable!(),
            }
        };
        for value in values {
            let id = if kind == Kind::Folders {
                "tree".into()
            } else {
                value
                    .get("id")
                    .and_then(Value::as_str)
                    .context("保险库记录 ID 无效")?
                    .to_string()
            };
            records.push(Record {
                key: Key {
                    kind: kind.clone(),
                    id,
                },
                revision: revision.clone(),
                value: Some(value),
            });
        }
    }
    let mut stmt =
        db.prepare("SELECT id,name,username,kind,password,private_key,passphrase FROM identities")?;
    let items = stmt.query_map([], |row| {
        Ok(Identity {
            id: row.get(0)?,
            name: row.get(1)?,
            username: row.get(2)?,
            kind: row.get(3)?,
            password: row.get(4)?,
            private_key: row.get(5)?,
            passphrase: row.get(6)?,
        })
    })?;
    let mut bytes = 0;
    for (index, item) in items.enumerate() {
        ensure!(index < 10000, "同步身份数量过多");
        let item = item?;
        bytes += item.password.len() + item.private_key.len() + item.passphrase.len();
        ensure!(bytes <= MAX_BYTES, "同步凭证超过 16 MiB");
        records.push(Record {
            key: Key {
                kind: Kind::Identity,
                id: item.id.clone(),
            },
            revision: revision.clone(),
            value: Some(serde_json::to_value(&item)?),
        });
    }
    Ok(records)
}

/// Reads an already decrypted SQLCipher connection. Does not alter the vault or disk.
/// Previous sync snapshot carries tombstones; unchanged records keep their revision.
pub fn capture(db: &Connection, previous: &Snapshot, device: &str) -> Result<Snapshot> {
    let read = db.unchecked_transaction()?;
    let result = capture_in_transaction(&read, previous, device)?;
    read.commit()?;
    Ok(result)
}

pub(super) fn capture_in_transaction(
    db: &Connection,
    previous: &Snapshot,
    device: &str,
) -> Result<Snapshot> {
    previous.validate()?;
    uuid::Uuid::parse_str(device).context("同步设备 ID 无效")?;
    let before = previous.map();
    let counter = previous
        .records
        .iter()
        .map(|r| r.revision.counter)
        .max()
        .unwrap_or(0)
        .checked_add(1)
        .context("同步版本计数已耗尽")?;
    let revision = Revision {
        counter,
        device: device.to_string(),
    };
    let mut records = current(db)?;
    let mut keys = BTreeSet::new();
    for record in &mut records {
        keys.insert(record.key.clone());
        record.revision = match before.get(&record.key) {
            Some(old) if old.value == record.value => old.revision.clone(),
            _ => revision.clone(),
        };
    }
    for old in &previous.records {
        if !keys.contains(&old.key) {
            let mut tombstone = old.clone();
            if let Some(mut value) = tombstone.value.take() {
                wipe(&mut value);
                tombstone.revision = revision.clone();
            }
            records.push(tombstone);
        }
    }
    records.sort_by(|a, b| a.key.cmp(&b.key));
    let result = Snapshot {
        version: FORMAT_VERSION,
        space: previous.space.clone(),
        records,
    };
    result.validate()?;
    ensure!(missing_identities(&result).is_empty(), "保险库身份引用无效");
    Ok(result)
}

pub(super) fn missing_identities(snapshot: &Snapshot) -> Vec<MissingIdentity> {
    let identities: BTreeSet<_> = snapshot
        .records
        .iter()
        .filter(|r| r.key.kind == Kind::Identity && r.value.is_some())
        .map(|r| r.key.id.as_str())
        .collect();
    snapshot
        .records
        .iter()
        .filter(|r| r.key.kind == Kind::Host)
        .filter_map(|r| {
            let id = r.value.as_ref()?.get("identityId")?.as_str()?;
            (!id.is_empty() && !identities.contains(id)).then(|| MissingIdentity {
                host_id: r.key.id.clone(),
                identity_id: id.into(),
            })
        })
        .collect()
}

/// Atomically writes only a conflict-free plan. A fresh local edit invalidates it.
/// This is a Rust-only building block, not a plaintext import/export endpoint.
pub fn apply_merge(db: &mut Connection, plan: &MergePlan) -> Result<()> {
    let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    apply_in_transaction(&tx, plan)?;
    tx.commit()?;
    Ok(())
}

pub(super) fn apply_in_transaction(tx: &Connection, plan: &MergePlan) -> Result<()> {
    let merged = plan.snapshot()?;
    merged.validate()?;
    let observed = current(tx)?;
    let expected: BTreeMap<_, _> = plan
        .expected_local
        .records
        .iter()
        .filter(|r| r.value.is_some())
        .map(|r| (&r.key, &r.value))
        .collect();
    let actual: BTreeMap<_, _> = observed.iter().map(|r| (&r.key, &r.value)).collect();
    ensure!(actual == expected, "本机数据已变化，请重新合并");
    let mut hosts = vec![];
    let mut snippets = vec![];
    let mut folders = Value::Array(vec![]);
    tx.execute("DELETE FROM identities", [])?;
    for record in &merged.records {
        let Some(value) = &record.value else {
            continue;
        };
        match record.key.kind {
            Kind::Identity => {
                let item = identity(value)?;
                if item.kind == "key" {
                    russh::keys::decode_secret_key(
                        &item.private_key,
                        if item.passphrase.is_empty() {
                            None
                        } else {
                            Some(&item.passphrase)
                        },
                    )
                    .map_err(|_| anyhow::anyhow!("同步私钥或口令无效"))?;
                }
                tx.execute(
                    "INSERT INTO identities VALUES (?1,?2,?3,?4,?5,?6,?7)",
                    params![
                        item.id,
                        item.name,
                        item.username,
                        item.kind,
                        item.password,
                        item.private_key,
                        item.passphrase
                    ],
                )?;
            }
            Kind::Host => hosts.push(value),
            Kind::Snippet => snippets.push(value),
            Kind::Folders => folders = value.clone(),
        }
    }
    for (kind, value) in [
        ("hosts", serde_json::to_string(&hosts)?),
        ("snippets", serde_json::to_string(&snippets)?),
        ("folders", serde_json::to_string(&folders)?),
    ] {
        let json = Zeroizing::new(value);
        put_record(tx, kind, &json)?;
    }
    Ok(())
}
