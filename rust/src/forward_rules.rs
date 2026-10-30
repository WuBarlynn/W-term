//! Device-local saved forwarding rules; never synced or restored as business data.
use crate::api::forward::ForwardRule;
use anyhow::{ensure, Context, Result};
use rusqlite::{Connection, OptionalExtension};
use std::collections::HashSet;
use zeroize::Zeroizing;

const KEY: &str = "forward_rules_v1";
const MAX_RULES: usize = 64;
const MAX_BYTES: usize = 512 * 1024;

fn valid_host(host: &str) -> bool {
    !host.is_empty()
        && host.len() <= 253
        && !host.chars().any(|c| c.is_whitespace() || c.is_control())
}

fn stored(db: &Connection) -> Result<Vec<ForwardRule>> {
    let raw: Option<String> = db
        .query_row("SELECT value FROM metadata WHERE key=?1", [KEY], |r| {
            r.get(0)
        })
        .optional()?;
    let Some(raw) = raw else {
        return Ok(vec![]);
    };
    let raw = Zeroizing::new(raw);
    ensure!(raw.len() <= MAX_BYTES, "转发规则配置过大");
    let items: Vec<ForwardRule> =
        serde_json::from_str(&raw).map_err(|_| anyhow::anyhow!("转发规则配置损坏，请重新保存"))?;
    ensure!(items.len() <= MAX_RULES, "转发规则最多 {MAX_RULES} 条");
    let mut ids = HashSet::new();
    for rule in &items {
        validate(rule)?;
        ensure!(ids.insert(rule.id.clone()), "转发规则 ID 重复");
    }
    Ok(items)
}

fn validate(rule: &ForwardRule) -> Result<()> {
    ensure!(
        matches!(rule.kind.as_str(), "local" | "remote" | "dynamic"),
        "不支持的转发类型"
    );
    ensure!(
        !rule.id.is_empty() && rule.id.len() <= 128,
        "转发规则标识无效"
    );
    ensure!(
        !rule.host_id.is_empty() && rule.host_id.len() <= 4096,
        "转发规则缺少主机"
    );
    ensure!(
        !rule.name.trim().is_empty()
            && rule.name.len() <= 64
            && !rule.name.chars().any(char::is_control),
        "规则名称须为 1–64 字节且不含控制字符"
    );
    ensure!(valid_host(&rule.listen_host), "监听地址无效");
    if rule.kind == "dynamic" {
        ensure!(
            rule.target_host.is_empty() && rule.target_port == 0,
            "动态转发不指定固定目标"
        );
    } else {
        ensure!(
            valid_host(&rule.target_host) && rule.target_port > 0,
            "目标主机或端口无效"
        );
    }
    Ok(())
}

fn write(db: &Connection, items: &[ForwardRule]) -> Result<()> {
    let raw = Zeroizing::new(serde_json::to_string(items)?);
    db.execute(
        "INSERT OR REPLACE INTO metadata(key,value) VALUES (?1,?2)",
        [KEY, raw.as_str()],
    )?;
    Ok(())
}

fn host_exists(db: &Connection, host_id: &str) -> Result<bool> {
    let raw: Option<String> = db
        .query_row("SELECT value FROM records WHERE kind='hosts'", [], |r| {
            r.get(0)
        })
        .optional()?;
    let Some(raw) = raw else {
        return Ok(false);
    };
    let value: serde_json::Value =
        serde_json::from_str(&raw).map_err(|_| anyhow::anyhow!("主机数据格式无效"))?;
    let items = value.as_array().context("主机数据格式无效")?;
    ensure!(items.len() <= 10000, "主机数量过多");
    Ok(items.iter().any(|item| {
        item.get("id")
            .and_then(serde_json::Value::as_str)
            .is_some_and(|id| id == host_id)
    }))
}

pub(crate) fn rules(db: &Connection, host_id: &str) -> Result<Vec<ForwardRule>> {
    ensure!(!host_id.is_empty(), "主机标识无效");
    let mut result: Vec<_> = stored(db)?
        .into_iter()
        .filter(|rule| rule.host_id == host_id)
        .collect();
    result.sort_by(|a, b| {
        a.kind
            .cmp(&b.kind)
            .then(a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    Ok(result)
}

pub(crate) fn save(db: &mut Connection, mut rule: ForwardRule) -> Result<ForwardRule> {
    let tx = db.transaction()?;
    let mut items = stored(&tx)?;
    ensure!(host_exists(&tx, &rule.host_id)?, "主机不存在，请刷新后重试");
    let id = if rule.id.is_empty() {
        ensure!(items.len() < MAX_RULES, "转发规则最多 {MAX_RULES} 条");
        uuid::Uuid::new_v4().to_string()
    } else {
        ensure!(
            items.iter().any(|item| item.id == rule.id),
            "转发规则已被删除，请刷新列表"
        );
        rule.id.clone()
    };
    ensure!(
        !items.iter().any(|item| {
            item.id != id
                && item.host_id == rule.host_id
                && item.name.eq_ignore_ascii_case(rule.name.trim())
        }),
        "该主机下已有同名转发规则"
    );
    rule.id = id.clone();
    rule.name = rule.name.trim().to_string();
    rule.listen_host = rule.listen_host.trim().to_string();
    rule.target_host = rule.target_host.trim().to_string();
    if rule.kind == "dynamic" {
        rule.target_host.clear();
        rule.target_port = 0;
    }
    validate(&rule)?;
    items.retain(|item| item.id != id);
    items.push(rule.clone());
    write(&tx, &items)?;
    tx.commit()?;
    Ok(rule)
}

pub(crate) fn delete(db: &mut Connection, id: &str) -> Result<()> {
    let tx = db.transaction()?;
    let mut items = stored(&tx)?;
    ensure!(
        items.iter().any(|item| item.id == id),
        "转发规则已被删除，请刷新列表"
    );
    items.retain(|item| item.id != id);
    write(&tx, &items)?;
    tx.commit()?;
    Ok(())
}
