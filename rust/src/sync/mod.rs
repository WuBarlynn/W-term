//! Versioned in-memory sync protocol. No network, file export, or Flutter secret API.
//! A common baseline is mandatory; conflict resolution never uses wall-clock time.
pub mod crypto;
pub mod disconnect;
pub mod github;
pub mod outbox;
mod review;
pub mod scope;
pub mod service;
pub mod state;
mod vault;

use anyhow::{ensure, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};
use zeroize::{Zeroize, Zeroizing};

pub use vault::{apply_merge, capture};
pub const FORMAT_VERSION: u32 = 1;
const MAX_BYTES: usize = 16 * 1024 * 1024;
const MAX_RECORDS: usize = 32_000;

#[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    Host,
    Identity,
    Snippet,
    Folders,
}

#[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Key {
    pub kind: Kind,
    pub id: String,
}

#[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Revision {
    counter: u64,
    device: String,
}

// Deliberately no Debug: payloads can contain private keys and passwords.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Record {
    key: Key,
    revision: Revision,
    #[serde(deserialize_with = "required_value")]
    value: Option<Value>,
}
fn required_value<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> std::result::Result<Option<Value>, D::Error> {
    Option::<Value>::deserialize(deserializer)
}
impl Drop for Record {
    fn drop(&mut self) {
        if let Some(value) = &mut self.value {
            wipe(value);
        }
    }
}
fn wipe(value: &mut Value) {
    match value {
        Value::String(text) => text.zeroize(),
        Value::Array(items) => items.iter_mut().for_each(wipe),
        Value::Object(items) => items.values_mut().for_each(wipe),
        _ => {}
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Snapshot {
    version: u32,
    space: String,
    records: Vec<Record>,
}
impl Snapshot {
    /// New sync namespace. Callers must retain the same namespace on both devices.
    pub fn empty(space: String) -> Result<Self> {
        uuid::Uuid::parse_str(&space).context("无效的同步空间 ID")?;
        Ok(Self {
            version: FORMAT_VERSION,
            space,
            records: vec![],
        })
    }
    /// Plaintext memory only. The future transport must authenticate/decrypt first.
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        ensure!(bytes.len() <= MAX_BYTES, "同步数据超过 16 MiB");
        let mut value: Self =
            serde_json::from_slice(bytes).map_err(|_| anyhow::anyhow!("同步数据格式无效"))?;
        value.validate()?;
        value.records.sort_by(|a, b| a.key.cmp(&b.key));
        Ok(value)
    }
    /// Never write this plaintext buffer to a file or send it to a transport.
    pub fn encode(&self) -> Result<Zeroizing<Vec<u8>>> {
        self.validate()?;
        Ok(Zeroizing::new(serde_json::to_vec(self)?))
    }
    fn validate(&self) -> Result<()> {
        ensure!(self.version == FORMAT_VERSION, "不支持的同步协议版本");
        uuid::Uuid::parse_str(&self.space).context("无效的同步空间 ID")?;
        ensure!(self.records.len() <= MAX_RECORDS, "同步记录数量过多");
        let mut keys = BTreeSet::new();
        let mut live_counts = BTreeMap::<Kind, usize>::new();
        for record in &self.records {
            ensure!(
                !record.key.id.is_empty() && record.key.id.len() <= 4096,
                "同步记录 ID 无效"
            );
            ensure!(keys.insert(&record.key), "同步记录 ID 重复");
            ensure!(record.revision.counter > 0, "同步记录版本无效");
            uuid::Uuid::parse_str(&record.revision.device).context("同步设备 ID 无效")?;
            if let Some(value) = &record.value {
                vault::validate_value(&record.key, value)?;
                *live_counts.entry(record.key.kind.clone()).or_default() += 1;
            }
            if record.key.kind == Kind::Folders {
                ensure!(record.key.id == "tree", "文件夹集合 ID 无效");
            }
        }
        for (kind, count) in live_counts {
            let limit = match kind {
                Kind::Snippet => 1000,
                Kind::Folders => 1,
                _ => 10000,
            };
            ensure!(count <= limit, "同步记录超过保险库容量限制");
        }
        for kind in [Kind::Host, Kind::Snippet] {
            let values: Vec<_> = self
                .records
                .iter()
                .filter(|r| r.key.kind == kind)
                .filter_map(|r| r.value.as_ref())
                .collect();
            vault::validate_collection(&kind, &values)?;
        }
        let encoded = Zeroizing::new(serde_json::to_vec(self)?);
        ensure!(encoded.len() <= MAX_BYTES, "同步数据超过 16 MiB");
        Ok(())
    }
    fn map(&self) -> BTreeMap<Key, &Record> {
        self.records.iter().map(|r| (r.key.clone(), r)).collect()
    }
}

/// Both alternatives (including deletion) remain owned by the plan. No Debug/FFI.
pub struct Conflict {
    key: Key,
    base: Option<Record>,
    local: Option<Record>,
    remote: Option<Record>,
}
impl Conflict {
    pub fn key(&self) -> &Key {
        &self.key
    }
    pub fn local_deleted(&self) -> bool {
        payload(self.local.as_ref()).is_none()
    }
    pub fn remote_deleted(&self) -> bool {
        payload(self.remote.as_ref()).is_none()
    }
    pub fn existed_in_base(&self) -> bool {
        payload(self.base.as_ref()).is_some()
    }
}
pub struct MissingIdentity {
    pub host_id: String,
    pub identity_id: String,
}
pub struct MergePlan {
    merged: Snapshot,
    expected_local: Snapshot,
    conflicts: Vec<Conflict>,
    missing_identities: Vec<MissingIdentity>,
}
impl MergePlan {
    pub fn conflicts(&self) -> &[Conflict] {
        &self.conflicts
    }
    pub fn missing_identities(&self) -> &[MissingIdentity] {
        &self.missing_identities
    }
    pub fn is_resolved(&self) -> bool {
        self.conflicts.is_empty() && self.missing_identities.is_empty()
    }
    /// Unresolved plans cannot produce a publishable snapshot.
    pub fn snapshot(&self) -> Result<&Snapshot> {
        ensure!(self.is_resolved(), "同步存在未解决的冲突，已阻止写入");
        Ok(&self.merged)
    }
}
fn payload(record: Option<&Record>) -> Option<&Value> {
    record.and_then(|r| r.value.as_ref())
}

/// Three-way merge: compare values to the shared baseline, never compare timestamps.
/// Input snapshots must retain baseline keys as records or explicit tombstones.
pub fn merge(base: &Snapshot, local: &Snapshot, remote: &Snapshot) -> Result<MergePlan> {
    for snapshot in [base, local, remote] {
        snapshot.validate()?;
    }
    ensure!(
        base.space == local.space && base.space == remote.space,
        "同步空间不一致"
    );
    let (b, l, r) = (base.map(), local.map(), remote.map());
    for (key, previous) in &b {
        for branch in [&l, &r] {
            let item = branch.get(key).context("同步缺少历史记录或删除标记")?;
            ensure!(
                item.revision.counter >= previous.revision.counter,
                "同步记录版本倒退"
            );
            if item.value != previous.value {
                ensure!(
                    item.revision.counter > previous.revision.counter,
                    "修改未更新同步记录版本"
                );
            }
        }
    }
    let keys: BTreeSet<_> = b.keys().chain(l.keys()).chain(r.keys()).cloned().collect();
    let mut records = Vec::new();
    let mut conflicts = Vec::new();
    for key in keys {
        let (bv, lv, rv) = (
            b.get(&key).copied(),
            l.get(&key).copied(),
            r.get(&key).copied(),
        );
        let chosen = if payload(lv) == payload(rv) {
            // Identical edits converge to deterministic metadata regardless of input order.
            [lv, rv]
                .into_iter()
                .flatten()
                .max_by_key(|item| &item.revision)
        } else if payload(lv) == payload(bv) {
            rv
        } else if payload(rv) == payload(bv) {
            lv
        } else {
            conflicts.push(Conflict {
                key,
                base: bv.cloned(),
                local: lv.cloned(),
                remote: rv.cloned(),
            });
            None
        };
        if let Some(item) = chosen {
            records.push(item.clone());
        }
    }
    let merged = Snapshot {
        version: FORMAT_VERSION,
        space: base.space.clone(),
        records,
    };
    merged.validate()?;
    let missing_identities = vault::missing_identities(&merged);
    Ok(MergePlan {
        merged,
        expected_local: local.clone(),
        conflicts,
        missing_identities,
    })
}

#[cfg(test)]
mod tests;
