//! GitHub.com encrypted transport. No implicit repository creation.
//! Journal first, non-forced publication, verified read-back.
pub(super) mod journal;
use super::{outbox, state, *};
use base64ct::{Base64, Encoding};
use reqwest::{header, Method};
use rusqlite::Connection;
use serde_json::json;
use std::time::Duration;

const PACKET_FILE: &str = "wterm-packet.json";
const KEY_FILE: &str = "wterm-key.json";
const PACKET_LIMIT: usize = 24 * 1024 * 1024;
const KEY_LIMIT: usize = 16 * 1024;
const META_LIMIT: usize = 1024 * 1024;
const WALK_LIMIT: usize = 64;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Target {
    owner: String,
    repo: String,
    branch: String,
}
impl Target {
    pub fn new(owner: String, repo: String, branch: String) -> Result<Self> {
        fn slug(s: &str) -> bool {
            !s.is_empty()
                && s.len() <= 100
                && s.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"-_".contains(&b))
        }
        ensure!(
            slug(&owner)
                && !repo.is_empty()
                && repo.len() <= 100
                && repo != "."
                && repo != ".."
                && repo
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b)),
            "GitHub 仓库名称无效"
        );
        ensure!(
            branch.len() <= 200 && branch.split('/').all(slug),
            "同步分支名称无效（支持字母、数字、横线、下划线和斜线）"
        );
        Ok(Self {
            owner: owner.to_ascii_lowercase(),
            repo: repo.to_ascii_lowercase(),
            branch,
        })
    }
}
pub struct GitHub {
    target: Target,
    client: reqwest::Client,
    base: String,
}
pub struct RemoteFiles {
    pub revision: String,
    pub packet: Option<Vec<u8>>,
    pub envelope: Option<Vec<u8>>,
}
#[derive(Debug)]
struct HttpFailure {
    status: u16,
    message: String,
}
impl std::fmt::Display for HttpFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}
impl std::error::Error for HttpFailure {}

struct Commit {
    sha: String,
    tree: String,
    parents: Vec<String>,
}
fn sha(text: &str) -> Result<String> {
    ensure!(
        text.len() == 40
            && text
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
        "GitHub 对象编号无效"
    );
    Ok(text.into())
}
fn text_field<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    v.get(key)
        .and_then(Value::as_str)
        .context("GitHub 响应缺少必需字段")
}
fn blob_sha(bytes: &[u8]) -> String {
    // Git object identity only; payload authenticity is provided by AES-GCM.
    let mut ctx = ring::digest::Context::new(&ring::digest::SHA1_FOR_LEGACY_USE_ONLY);
    ctx.update(format!("blob {}\0", bytes.len()).as_bytes());
    ctx.update(bytes);
    ctx.finish()
        .as_ref()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}
impl GitHub {
    pub fn new(target: Target, token: &str) -> Result<Self> {
        Self::build(target, token, "https://api.github.com".into(), true)
    }
    fn build(target: Target, token: &str, base: String, https_only: bool) -> Result<Self> {
        let target = Target::new(target.owner, target.repo, target.branch)?;
        ensure!(
            !token.is_empty() && token.len() <= 4096 && token.bytes().all(|b| b.is_ascii_graphic()),
            "GitHub 令牌格式无效"
        );
        // Never format the client/token in Debug or propagate reqwest errors.
        let auth_text = Zeroizing::new(format!("Bearer {token}"));
        let mut auth = header::HeaderValue::from_str(&auth_text)
            .map_err(|_| anyhow::anyhow!("GitHub 令牌格式无效"))?;
        auth.set_sensitive(true);
        let mut headers = header::HeaderMap::new();
        headers.insert(header::AUTHORIZATION, auth);
        headers.insert(
            header::ACCEPT,
            header::HeaderValue::from_static("application/vnd.github+json"),
        );
        headers.insert(
            "x-github-api-version",
            header::HeaderValue::from_static("2026-03-10"),
        );
        let client = reqwest::Client::builder()
            .default_headers(headers)
            .user_agent("WTerm-Sync/1")
            .https_only(https_only)
            .redirect(reqwest::redirect::Policy::none())
            .retry(reqwest::retry::never())
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(30))
            .build()
            .map_err(|_| anyhow::anyhow!("无法创建 GitHub HTTPS 客户端"))?;
        Ok(Self {
            target,
            client,
            base,
        })
    }
    async fn request(
        &self,
        method: Method,
        path: &str,
        body: Option<Value>,
        expected: u16,
        limit: usize,
    ) -> Result<Value> {
        let url = format!(
            "{}/repos/{}/{}{}",
            self.base, self.target.owner, self.target.repo, path
        );
        let operation = match (method.as_str(), path) {
            ("GET", "") => "读取仓库信息",
            ("GET", p) if p.starts_with("/git/ref/") => "读取同步分支",
            ("GET", p) if p.starts_with("/git/commits/") => "读取提交",
            ("GET", p) if p.starts_with("/git/trees/") => "读取文件目录",
            ("GET", p) if p.starts_with("/git/blobs/") => "读取同步文件",
            ("POST", "/git/blobs") => "上传加密文件",
            ("POST", "/git/trees") => "创建文件目录",
            ("POST", "/git/commits") => "创建同步提交",
            ("PATCH", _) => "更新同步分支",
            _ => "访问 GitHub",
        };
        let mut request = self.client.request(method, url);
        if let Some(body) = body {
            request = request.json(&body);
        }
        let mut response = request
            .send()
            .await
            .map_err(|_| anyhow::anyhow!("{operation}失败：网络请求未完成，请检查网络后重试"))?;
        let status = response.status().as_u16();
        if status != expected {
            // Do not expose server response bodies: they can echo Authorization.
            let advice = match status {
                404 if path.is_empty() => "仓库不存在或当前令牌不可见。请核对所有者/仓库名称，以及令牌的 Resource owner 和 Repository access 是否包含该私有仓库；组织仓库还需确认令牌已获批准或完成 SSO 授权。",
                404 if path.starts_with("/git/ref/") => "仓库信息可读取，但目标分支不可读取。请核对分支名称（区分大小写）和令牌的 Contents 读取权限；空仓库请先添加 README 形成首次提交。",
                404 => "该资源不存在或令牌无权访问。请确认令牌已授权此仓库并具备 Contents 读写权限，然后重新检查仓库与分支。",
                401 => "令牌无效、已过期或已撤销，请替换令牌并保存设置。",
                403 => "请求被拒绝。请检查令牌权限、组织授权和分支规则；若触发 GitHub 限流，请稍后再试。",
                409 if path.starts_with("/git/ref/") => "分支当前不可用；空仓库请先添加 README 形成首次提交，再核对分支名称。",
                409 | 422 => "远端状态冲突或请求被拒绝，请检查分支规则与远端更新后重试。",
                429 => "GitHub 请求过于频繁，请稍后重试。",
                500..=599 => "GitHub 服务暂时不可用，请稍后重试。",
                _ => "请求未成功，请检查仓库设置与网络后重试。",
            };
            return Err(HttpFailure {
                status,
                message: format!("{operation}失败（GitHub HTTP {status}）：{advice}"),
            }
            .into());
        }
        ensure!(
            response.content_length().is_none_or(|n| n <= limit as u64),
            "GitHub 响应过大"
        );
        let mut bytes = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| anyhow::anyhow!("GitHub 响应未完整读取"))?
        {
            ensure!(bytes.len() + chunk.len() <= limit, "GitHub 响应过大");
            bytes.extend_from_slice(&chunk);
        }
        serde_json::from_slice(&bytes).map_err(|_| anyhow::anyhow!("GitHub JSON 响应无效"))
    }
    pub(in crate::sync) async fn repository(&self, write: bool) -> Result<u64> {
        let r = self.request(Method::GET, "", None, 200, META_LIMIT).await?;
        ensure!(
            r["private"].as_bool() == Some(true) && r["archived"].as_bool() == Some(false),
            "同步需要可用的私有仓库"
        );
        ensure!(
            text_field(&r, "full_name")?
                .eq_ignore_ascii_case(&format!("{}/{}", self.target.owner, self.target.repo)),
            "GitHub 仓库身份不一致"
        );
        ensure!(
            !write || r["permissions"]["push"].as_bool() == Some(true),
            "GitHub 令牌没有仓库写入权限"
        );
        let id = r["id"].as_u64().context("GitHub 仓库编号无效")?;
        ensure!(id > 0, "GitHub 仓库编号无效");
        Ok(id)
    }
    pub(in crate::sync) async fn check(&self) -> Result<String> {
        let before = self.repository(true).await?;
        let files = self.fetch(None).await?;
        ensure!(self.repository(true).await? == before, "仓库身份已变化");
        let next = if files.packet.is_some() {
            "检测到已有同步文件，可使用同步口令或恢复码接入。"
        } else {
            "未发现同步文件，可创建同步空间。"
        };
        Ok(format!("仓库与分支读取成功。{next}本次检查未写入数据；令牌的 Contents 写入权限需在 GitHub 设置中确认。"))
    }
    async fn head(&self) -> Result<String> {
        let r = self
            .request(
                Method::GET,
                &format!("/git/ref/heads/{}", self.target.branch),
                None,
                200,
                META_LIMIT,
            )
            .await?;
        ensure!(
            text_field(&r, "ref")? == format!("refs/heads/{}", self.target.branch)
                && r["object"]["type"].as_str() == Some("commit"),
            "GitHub 分支引用不一致"
        );
        sha(text_field(&r["object"], "sha")?)
    }
    async fn commit(&self, id: &str) -> Result<Commit> {
        sha(id)?;
        let r = self
            .request(
                Method::GET,
                &format!("/git/commits/{id}"),
                None,
                200,
                META_LIMIT,
            )
            .await?;
        ensure!(text_field(&r, "sha")? == id, "GitHub 提交编号不一致");
        let values = r["parents"].as_array().context("GitHub 提交缺少父版本")?;
        ensure!(
            values.len() <= 1,
            "同步分支包含合并提交，请使用独立线性分支"
        );
        let parents = values
            .iter()
            .map(|p| sha(text_field(p, "sha")?))
            .collect::<Result<Vec<_>>>()?;
        Ok(Commit {
            sha: id.into(),
            tree: sha(text_field(&r["tree"], "sha")?)?,
            parents,
        })
    }
    async fn contains(&self, head: &str, wanted: &str) -> Result<bool> {
        let mut cursor = head.to_string();
        let mut seen = BTreeSet::new();
        for _ in 0..WALK_LIMIT {
            if cursor == wanted {
                return Ok(true);
            }
            ensure!(seen.insert(cursor.clone()), "GitHub 提交历史存在循环");
            let c = self.commit(&cursor).await?;
            match c.parents.first() {
                Some(parent) => cursor = parent.clone(),
                None => return Ok(false),
            }
        }
        anyhow::bail!("提交历史超过核对上限，已保留待处理状态")
    }
    async fn blob(&self, id: &str, limit: usize) -> Result<Vec<u8>> {
        let r = self
            .request(
                Method::GET,
                &format!("/git/blobs/{id}"),
                None,
                200,
                limit * 2 + 4096,
            )
            .await?;
        ensure!(
            text_field(&r, "sha")? == id && text_field(&r, "encoding")? == "base64",
            "GitHub blob 格式不一致"
        );
        let size = r["size"].as_u64().context("GitHub blob 大小无效")?;
        ensure!(size <= limit as u64, "同步文件过大");
        let encoded: String = text_field(&r, "content")?
            .chars()
            .filter(|c| !c.is_ascii_whitespace())
            .collect();
        let bytes =
            Base64::decode_vec(&encoded).map_err(|_| anyhow::anyhow!("GitHub blob 编码无效"))?;
        ensure!(
            bytes.len() == size as usize && bytes.len() <= limit && blob_sha(&bytes) == id,
            "GitHub blob 内容校验失败"
        );
        Ok(bytes)
    }
    async fn files(&self, c: &Commit) -> Result<RemoteFiles> {
        let r = self
            .request(
                Method::GET,
                &format!("/git/trees/{}", c.tree),
                None,
                200,
                META_LIMIT,
            )
            .await?;
        ensure!(
            text_field(&r, "sha")? == c.tree && r["truncated"].as_bool() == Some(false),
            "GitHub 文件树不完整"
        );
        let entries = r["tree"].as_array().context("GitHub 文件树无效")?;
        ensure!(entries.len() <= 1000, "同步分支根目录文件过多");
        let mut packet = None;
        let mut envelope = None;
        for entry in entries {
            let path = text_field(entry, "path")?;
            let slot = match path {
                PACKET_FILE => &mut packet,
                KEY_FILE => &mut envelope,
                _ => continue,
            };
            ensure!(
                slot.is_none()
                    && entry["mode"].as_str() == Some("100644")
                    && entry["type"].as_str() == Some("blob"),
                "同步文件类型或数量无效"
            );
            *slot = Some(sha(text_field(entry, "sha")?)?);
        }
        ensure!(
            packet.is_some() == envelope.is_some(),
            "远端同步文件不完整，已阻止覆盖"
        );
        ensure!(
            packet.is_some() || entries.len() <= 998,
            "首次同步需要为两份加密文件预留目录容量"
        );
        Ok(RemoteFiles {
            revision: c.sha.clone(),
            packet: match packet {
                Some(id) => Some(self.blob(&id, PACKET_LIMIT).await?),
                None => None,
            },
            envelope: match envelope {
                Some(id) => Some(self.blob(&id, KEY_LIMIT).await?),
                None => None,
            },
        })
    }
    /// Read from one immutable commit. A known revision must remain in branch ancestry.
    pub async fn fetch(&self, pinned: Option<&str>) -> Result<RemoteFiles> {
        tokio::time::timeout(Duration::from_secs(120), self.fetch_inner(pinned))
            .await
            .map_err(|_| anyhow::anyhow!("GitHub 读取超时"))?
    }
    async fn fetch_inner(&self, pinned: Option<&str>) -> Result<RemoteFiles> {
        self.repository(false).await?;
        let head = self.head().await?;
        if let Some(pinned) = pinned {
            sha(pinned)?;
            ensure!(self.contains(&head, pinned).await?, "远端历史已回退或分叉");
        }
        self.files(&self.commit(&head).await?).await
    }
    async fn create_blob(&self, bytes: &[u8]) -> Result<String> {
        let r = self
            .request(
                Method::POST,
                "/git/blobs",
                Some(json!({"content":Base64::encode_string(bytes),"encoding":"base64"})),
                201,
                META_LIMIT,
            )
            .await?;
        let id = sha(text_field(&r, "sha")?)?;
        ensure!(id == blob_sha(bytes), "新建 GitHub blob 内容不一致");
        Ok(id)
    }
    async fn create_commit(&self, base: &Commit, u: &outbox::Upload) -> Result<String> {
        let packet = self.create_blob(u.packet()).await?;
        let envelope = self.create_blob(u.envelope()).await?;
        let tree = self
            .request(
                Method::POST,
                "/git/trees",
                Some(json!({"base_tree":base.tree,"tree":[
            {"path":PACKET_FILE,"mode":"100644","type":"blob","sha":packet},
            {"path":KEY_FILE,"mode":"100644","type":"blob","sha":envelope}]})),
                201,
                META_LIMIT,
            )
            .await?;
        let tree = sha(text_field(&tree, "sha")?)?;
        let c = self
            .request(
                Method::POST,
                "/git/commits",
                Some(json!({"message":"W Term encrypted sync","tree":tree,"parents":[base.sha]})),
                201,
                META_LIMIT,
            )
            .await?;
        sha(text_field(&c, "sha")?)
    }
    /// Publishes only a pre-existing pending upload. Never force-pushes, creates a
    /// repository/branch, resolves merge conflicts, or discards ambiguous work.
    pub async fn publish(&self, db: &mut Connection, generation: u64) -> Result<state::State> {
        tokio::time::timeout(Duration::from_secs(120), self.publish_inner(db, generation))
            .await
            .map_err(|_| anyhow::anyhow!("GitHub 发布超时；已保留状态，请核对后重试"))?
    }
    async fn publish_inner(&self, db: &mut Connection, generation: u64) -> Result<state::State> {
        let existing = journal::load(db)?;
        let upload = if existing.is_some() {
            outbox::restore_for_confirmation(db, generation)?
        } else {
            outbox::stage(db, generation)?
        };
        let repo_id = self.repository(true).await?;
        let head = self.head().await?;
        let mut attempt = if let Some(a) = existing {
            journal::check(db, &a, &self.target, repo_id, &upload)?;
            a
        } else {
            let s = state::load(db)?.context("同步状态不存在")?;
            let p = s.pending().context("待处理批次不存在")?;
            if let Some(expected) = p.expected_revision() {
                ensure!(head == expected, "远端已更新，请先合并；待处理批次保留");
            }
            let files = self.files(&self.commit(&head).await?).await?;
            ensure!(
                files.packet.is_some() == p.expected_revision().is_some(),
                "远端同步空间状态不符，已阻止覆盖"
            );
            journal::start(db, &self.target, repo_id, &upload, head.clone())?
        };
        if let Some(commit) = &attempt.commit {
            if self.contains(&head, commit).await? {
                return self.settle(db, &attempt, &upload).await;
            }
        }
        ensure!(
            head == attempt.base_head,
            "远端分支已变化，待处理批次保留；不能覆盖新提交"
        );
        // Privacy may have changed during prior I/O. Never use confirmation-only bytes to send.
        outbox::stage(db, generation)?;
        if attempt.commit.is_none() {
            let commit = self
                .create_commit(&self.commit(&attempt.base_head).await?, &upload)
                .await?;
            attempt = journal::set_commit(db, &attempt, commit)?;
        }
        outbox::stage(db, generation)?;
        let commit = attempt.commit.clone().context("发布提交不存在")?;
        let latest = self.head().await?;
        if self.contains(&latest, &commit).await? {
            return self.settle(db, &attempt, &upload).await;
        }
        ensure!(
            latest == attempt.base_head,
            "发布前远端分支已变化，已保留批次"
        );
        outbox::stage(db, generation)?;
        let was_ambiguous = attempt.ref_update_started;
        attempt = journal::mark_ref_update(db, &attempt, true)?;
        let publication = self
            .request(
                Method::PATCH,
                &format!("/git/refs/heads/{}", self.target.branch),
                Some(json!({"sha":commit,"force":false})),
                200,
                META_LIMIT,
            )
            .await;
        if let Err(error) = publication {
            // Only a definitive rejection of the FIRST non-ambiguous request
            // proves this batch was never accepted. 5xx/timeouts stay unknown.
            if !was_ambiguous
                && error
                    .downcast_ref::<HttpFailure>()
                    .is_some_and(|e| matches!(e.status, 409 | 422))
            {
                journal::mark_ref_update(db, &attempt, false)?;
            }
            return Err(error);
        }
        let head = self.head().await?;
        ensure!(
            self.contains(&head, &commit).await?,
            "发布结果尚未确认，已保留批次"
        );
        self.settle(db, &attempt, &upload).await
    }
    /// Rebase only when the journal proves no ref update could have succeeded.
    /// Content/key/ancestry validation happens BEFORE any local cleanup.
    pub(in crate::sync) async fn recover_competition(
        &self,
        db: &mut Connection,
        generation: u64,
        expected_repo_id: u64,
    ) -> Result<bool> {
        tokio::time::timeout(
            Duration::from_secs(120),
            self.recover_competition_inner(db, generation, expected_repo_id),
        )
        .await
        .map_err(|_| anyhow::anyhow!("竞争恢复核对超时；待处理批次保留"))?
    }
    async fn recover_competition_inner(
        &self,
        db: &mut Connection,
        generation: u64,
        expected_repo_id: u64,
    ) -> Result<bool> {
        let s = state::load(db)?.context("同步状态不存在")?;
        ensure!(s.generation() == generation, "同步状态已变化");
        let p = s.pending().context("待处理批次不存在")?;
        // A rotation should not be silently cancelled; its recovery code and
        // candidate key require a separate user-directed workflow.
        if !p.needs_upload() || p.is_key_rotation() {
            return Ok(false);
        }
        let attempt = journal::load(db)?;
        if attempt.as_ref().is_some_and(|a| a.ref_update_started) {
            return Ok(false);
        }
        let upload = if attempt.is_some() {
            outbox::restore_for_confirmation(db, generation)?
        } else {
            outbox::stage(db, generation)?
        };
        let repo_id = self.repository(true).await?;
        ensure!(repo_id == expected_repo_id, "GitHub 仓库身份已变化");
        if let Some(a) = &attempt {
            journal::check(db, a, &self.target, repo_id, &upload)?;
        }
        let pinned = attempt
            .as_ref()
            .map(|a| a.base_head.as_str())
            .or(p.expected_revision());
        let remote = self.fetch(pinned).await?;
        if pinned == Some(remote.revision.as_str()) {
            return Ok(false);
        }
        if let Some(commit) = attempt.as_ref().and_then(|a| a.commit.as_ref()) {
            if self.contains(&remote.revision, commit).await? {
                return Ok(false);
            }
        }
        if p.expected_revision().is_none() && remote.packet.is_none() {
            // An unrelated README update still changes a journal's base head.
            if attempt.is_none() {
                return Ok(false);
            }
        } else {
            let (key, envelope) = crypto::load(db)?.context("同步密钥不存在")?;
            ensure!(
                remote.envelope.as_deref() == Some(envelope.encode()?.as_slice()),
                "远端同步密钥已变化，待处理批次保留；请先完成换钥接入"
            );
            crypto::decrypt(
                remote.packet.as_deref().context("远端同步文件不存在")?,
                &key,
            )?;
        }
        ensure!(
            self.repository(true).await? == repo_id,
            "GitHub 仓库身份已变化"
        );
        journal::discard_unpublished(db, generation, p.id(), attempt.as_ref())?;
        Ok(true)
    }

    async fn settle(
        &self,
        db: &mut Connection,
        a: &journal::Attempt,
        u: &outbox::Upload,
    ) -> Result<state::State> {
        let c = self
            .commit(a.commit.as_deref().context("发布提交不存在")?)
            .await?;
        ensure!(
            c.parents == vec![a.base_head.clone()],
            "发布提交父版本不一致"
        );
        let files = self.files(&c).await?;
        ensure!(
            files.packet.as_deref() == Some(u.packet())
                && files.envelope.as_deref() == Some(u.envelope()),
            "发布内容与发件箱不一致"
        );
        journal::acknowledge(db, a, u, &files)
    }
}

#[cfg(test)]
mod tests;
