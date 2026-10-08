//! Sync encryption draft v1. No network or Flutter secret API.
//! Authenticity is not freshness: transport must verify/pin revisions separately.
pub mod rotation;

use super::*;
use argon2::{Algorithm, Argon2, Params, Version};
use base64ct::{Base64, Encoding};
use ring::{
    aead, digest, hkdf, hmac,
    rand::{SecureRandom, SystemRandom},
};
use rusqlite::{params, Connection, OptionalExtension};

const SUITE: &str = "aes256gcm-hkdfsha256-v1";
const KDF: &str = "argon2id-v19-m65536-t3-p1";
const PACKET_LIMIT: usize = 24 * 1024 * 1024;
const KEY_LIMIT: usize = 16 * 1024;
const LOCAL_KEY: &str = "sync_key_v1";

pub struct SyncKey {
    space: String,
    id: String,
    secret: Zeroizing<[u8; 32]>,
}
impl SyncKey {
    pub fn space(&self) -> &str {
        &self.space
    }
    pub fn id(&self) -> &str {
        &self.id
    }
}
pub struct RecoveryCode(Zeroizing<String>);
impl RecoveryCode {
    pub fn expose(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct KeyHeader {
    version: u32,
    suite: String,
    kdf: String,
    space: String,
    key_id: String,
    password_salt: String,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Sealed {
    salt: String,
    nonce: String,
    ciphertext: String,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct WrappedKeys {
    header: KeyHeader,
    password: Sealed,
    recovery: Sealed,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct KeyEnvelope {
    wrapped: WrappedKeys,
    mac: String,
}
impl KeyEnvelope {
    pub fn space(&self) -> &str {
        &self.wrapped.header.space
    }
    pub fn encode(&self) -> Result<Vec<u8>> {
        self.validate()?;
        Ok(serde_json::to_vec(self)?)
    }
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        ensure!(bytes.len() <= KEY_LIMIT, "同步密钥文件过大");
        let value: Self =
            serde_json::from_slice(bytes).map_err(|_| anyhow::anyhow!("同步密钥格式无效"))?;
        value.validate()?;
        Ok(value)
    }
    fn validate(&self) -> Result<()> {
        let h = &self.wrapped.header;
        ensure!(
            h.version == 1 && h.suite == SUITE && h.kdf == KDF,
            "不支持的同步加密格式或参数"
        );
        uuid::Uuid::parse_str(&h.space).context("同步空间无效")?;
        uuid::Uuid::parse_str(&h.key_id).context("同步密钥编号无效")?;
        decode_fixed::<16>(&h.password_salt)?;
        decode_fixed::<32>(&self.mac)?;
        validate_sealed(&self.wrapped.password, 32)?;
        validate_sealed(&self.wrapped.recovery, 32)?;
        Ok(())
    }
}
fn random<const N: usize>() -> Result<Zeroizing<[u8; N]>> {
    let mut bytes = Zeroizing::new([0; N]);
    SystemRandom::new()
        .fill(bytes.as_mut())
        .map_err(|_| anyhow::anyhow!("系统随机源不可用"))?;
    Ok(bytes)
}
fn decode_fixed<const N: usize>(text: &str) -> Result<Zeroizing<[u8; N]>> {
    ensure!(text.len() <= N.div_ceil(3) * 4, "加密字段长度无效");
    let bytes =
        Zeroizing::new(Base64::decode_vec(text).map_err(|_| anyhow::anyhow!("加密字段编码无效"))?);
    ensure!(bytes.len() == N, "加密字段长度无效");
    let mut result = Zeroizing::new([0; N]);
    result.copy_from_slice(&bytes);
    Ok(result)
}
fn validate_sealed(value: &Sealed, max_plain: usize) -> Result<()> {
    decode_fixed::<32>(&value.salt)?;
    decode_fixed::<12>(&value.nonce)?;
    ensure!(
        value.ciphertext.len() >= 24 && value.ciphertext.len() <= (max_plain + 16).div_ceil(3) * 4,
        "密文长度无效"
    );
    Ok(())
}
fn derived(root: &[u8], salt: &[u8], context: &[u8]) -> Result<Zeroizing<[u8; 32]>> {
    let extract = hkdf::Salt::new(hkdf::HKDF_SHA256, salt).extract(root);
    let info = [b"wterm-sync-v1".as_slice(), context];
    let expanded = extract
        .expand(&info, hkdf::HKDF_SHA256)
        .map_err(|_| anyhow::anyhow!("密钥派生失败"))?;
    let mut key = Zeroizing::new([0; 32]);
    expanded
        .fill(key.as_mut())
        .map_err(|_| anyhow::anyhow!("密钥派生失败"))?;
    Ok(key)
}
fn aead_key(key: &[u8]) -> Result<aead::LessSafeKey> {
    Ok(aead::LessSafeKey::new(
        aead::UnboundKey::new(&aead::AES_256_GCM, key)
            .map_err(|_| anyhow::anyhow!("同步密钥无效"))?,
    ))
}
fn seal(root: &[u8], aad: &[u8], plaintext: &[u8]) -> Result<Sealed> {
    // Fresh 256-bit salt gives every seal an independently derived key; a fresh
    // 96-bit nonce is also generated. Keys/nonces are never supplied by callers.
    let salt = random::<32>()?;
    let nonce = random::<12>()?;
    let key = derived(root, salt.as_ref(), aad)?;
    let mut buffer = Zeroizing::new(plaintext.to_vec());
    aead_key(key.as_ref())?
        .seal_in_place_append_tag(
            aead::Nonce::assume_unique_for_key(*nonce),
            aead::Aad::from(aad),
            &mut *buffer,
        )
        .map_err(|_| anyhow::anyhow!("同步加密失败"))?;
    Ok(Sealed {
        salt: Base64::encode_string(salt.as_ref()),
        nonce: Base64::encode_string(nonce.as_ref()),
        ciphertext: Base64::encode_string(&buffer),
    })
}
fn unseal(
    root: &[u8],
    aad: &[u8],
    sealed: &Sealed,
    max_plain: usize,
) -> Result<Zeroizing<Vec<u8>>> {
    validate_sealed(sealed, max_plain)?;
    let salt = decode_fixed::<32>(&sealed.salt)?;
    let nonce = decode_fixed::<12>(&sealed.nonce)?;
    let key = derived(root, salt.as_ref(), aad)?;
    let mut buffer = Zeroizing::new(
        Base64::decode_vec(&sealed.ciphertext).map_err(|_| anyhow::anyhow!("密文编码无效"))?,
    );
    ensure!(
        buffer.len() >= 16 && buffer.len() <= max_plain + 16,
        "密文长度无效"
    );
    let length = aead_key(key.as_ref())?
        .open_in_place(
            aead::Nonce::assume_unique_for_key(*nonce),
            aead::Aad::from(aad),
            &mut buffer,
        )
        .map_err(|_| anyhow::anyhow!("解密失败：凭证错误或加密数据已损坏"))?
        .len();
    buffer.truncate(length);
    Ok(buffer)
}
fn password_key(password: &str, salt: &[u8]) -> Result<Zeroizing<[u8; 32]>> {
    ensure!(
        password.chars().count() >= 12 && password.len() <= 1024,
        "同步口令至少 12 个字符，最多 1024 字节"
    );
    static KDF_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let _guard = KDF_LOCK
        .lock()
        .map_err(|_| anyhow::anyhow!("口令派生状态不可用"))?;
    let params =
        Params::new(65536, 3, 1, Some(32)).map_err(|_| anyhow::anyhow!("口令派生参数无效"))?;
    let mut memory = Zeroizing::new(Vec::new());
    memory
        .try_reserve_exact(params.block_count())
        .map_err(|_| anyhow::anyhow!("口令派生内存不足"))?;
    memory.resize(params.block_count(), argon2::Block::new());
    let mut key = Zeroizing::new([0; 32]);
    Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
        .hash_password_into_with_memory(
            password.as_bytes(),
            salt,
            key.as_mut(),
            memory.as_mut_slice(),
        )
        .map_err(|_| anyhow::anyhow!("口令密钥派生失败"))?;
    Ok(key)
}
fn wrapping_aad(header: &KeyHeader, purpose: &str) -> Result<Vec<u8>> {
    Ok(serde_json::to_vec(&(
        "wterm-sync-key-wrap-v1",
        header,
        purpose,
    ))?)
}
fn envelope_mac(key: &SyncKey, wrapped: &WrappedKeys) -> Result<hmac::Tag> {
    let mac_key = derived(key.secret.as_ref(), &[0; 32], b"key-envelope-mac")?;
    Ok(hmac::sign(
        &hmac::Key::new(hmac::HMAC_SHA256, mac_key.as_ref()),
        &serde_json::to_vec(wrapped)?,
    ))
}
fn verify_envelope(key: &SyncKey, envelope: &KeyEnvelope) -> Result<()> {
    envelope.validate()?;
    ensure!(
        key.space == envelope.wrapped.header.space && key.id == envelope.wrapped.header.key_id,
        "同步密钥与空间不匹配"
    );
    let mac_key = derived(key.secret.as_ref(), &[0; 32], b"key-envelope-mac")?;
    let tag = decode_fixed::<32>(&envelope.mac)?;
    hmac::verify(
        &hmac::Key::new(hmac::HMAC_SHA256, mac_key.as_ref()),
        &serde_json::to_vec(&envelope.wrapped)?,
        tag.as_ref(),
    )
    .map_err(|_| anyhow::anyhow!("同步密钥文件认证失败"))
}
fn hex(bytes: &[u8]) -> Zeroizing<String> {
    use std::fmt::Write;
    let mut text = Zeroizing::new(String::new());
    for byte in bytes {
        write!(&mut *text, "{byte:02X}").expect("string formatting");
    }
    text
}
fn recovery_checksum(key: &[u8]) -> [u8; 4] {
    let mut hash = digest::Context::new(&digest::SHA256);
    hash.update(b"WTERM-RECOVERY-1");
    hash.update(key);
    hash.finish().as_ref()[..4]
        .try_into()
        .expect("SHA256 length")
}
fn new_recovery() -> Result<(RecoveryCode, Zeroizing<[u8; 32]>)> {
    let key = random::<32>()?;
    let encoded = hex(key.as_ref());
    let mut code = Zeroizing::new(String::from("WT1"));
    for chunk in encoded.as_bytes().chunks(8) {
        code.push('-');
        code.push_str(std::str::from_utf8(chunk)?);
    }
    code.push('-');
    code.push_str(&hex(&recovery_checksum(key.as_ref())));
    Ok((RecoveryCode(code), key))
}
fn parse_recovery(code: &str) -> Result<Zeroizing<[u8; 32]>> {
    ensure!(code.len() <= 128, "恢复码格式无效");
    let parts: Vec<_> = code.trim().split('-').collect();
    ensure!(
        parts.len() == 10
            && parts[0].eq_ignore_ascii_case("WT1")
            && parts[1..]
                .iter()
                .all(|p| p.len() == 8 && p.bytes().all(|b| b.is_ascii_hexdigit())),
        "恢复码格式无效"
    );
    let mut raw = Zeroizing::new([0; 36]);
    for (index, pair) in parts[1..]
        .iter()
        .flat_map(|p| p.as_bytes().chunks(2))
        .enumerate()
    {
        raw[index] = u8::from_str_radix(std::str::from_utf8(pair)?, 16)
            .map_err(|_| anyhow::anyhow!("恢复码格式无效"))?;
    }
    ensure!(
        raw[32..] == recovery_checksum(&raw[..32]),
        "恢复码校验失败，请检查输入"
    );
    let mut key = Zeroizing::new([0; 32]);
    key.copy_from_slice(&raw[..32]);
    Ok(key)
}

/// Generates a separate random data key. Recovery code is returned, never stored.
pub fn create(space: String, password: &str) -> Result<(SyncKey, KeyEnvelope, RecoveryCode)> {
    uuid::Uuid::parse_str(&space).context("同步空间无效")?;
    let key = SyncKey {
        space,
        id: uuid::Uuid::new_v4().to_string(),
        secret: random::<32>()?,
    };
    let salt = random::<16>()?;
    let header = KeyHeader {
        version: 1,
        suite: SUITE.into(),
        kdf: KDF.into(),
        space: key.space.clone(),
        key_id: key.id.clone(),
        password_salt: Base64::encode_string(salt.as_ref()),
    };
    let wrapping = password_key(password, salt.as_ref())?;
    let (code, recovery) = new_recovery()?;
    let wrapped = WrappedKeys {
        password: seal(
            wrapping.as_ref(),
            &wrapping_aad(&header, "password")?,
            key.secret.as_ref(),
        )?,
        recovery: seal(
            recovery.as_ref(),
            &wrapping_aad(&header, "recovery")?,
            key.secret.as_ref(),
        )?,
        header,
    };
    let mac = Base64::encode_string(envelope_mac(&key, &wrapped)?.as_ref());
    Ok((key, KeyEnvelope { wrapped, mac }, code))
}
fn unwrap_key(envelope: &KeyEnvelope, wrapping: &[u8], purpose: &str) -> Result<SyncKey> {
    let h = &envelope.wrapped.header;
    let sealed = if purpose == "password" {
        &envelope.wrapped.password
    } else {
        &envelope.wrapped.recovery
    };
    let secret = unseal(wrapping, &wrapping_aad(h, purpose)?, sealed, 32)?;
    ensure!(secret.len() == 32, "同步密钥长度无效");
    let mut bytes = Zeroizing::new([0; 32]);
    bytes.copy_from_slice(&secret);
    let key = SyncKey {
        space: h.space.clone(),
        id: h.key_id.clone(),
        secret: bytes,
    };
    verify_envelope(&key, envelope)?;
    Ok(key)
}
pub fn unlock_password(
    envelope: &KeyEnvelope,
    expected_space: &str,
    password: &str,
) -> Result<SyncKey> {
    envelope.validate()?;
    ensure!(
        envelope.wrapped.header.space == expected_space,
        "同步空间不匹配"
    );
    let salt = decode_fixed::<16>(&envelope.wrapped.header.password_salt)?;
    let wrapping = password_key(password, salt.as_ref())?;
    unwrap_key(envelope, wrapping.as_ref(), "password")
}
pub fn unlock_recovery(
    envelope: &KeyEnvelope,
    expected_space: &str,
    code: &str,
) -> Result<SyncKey> {
    envelope.validate()?;
    ensure!(
        envelope.wrapped.header.space == expected_space,
        "同步空间不匹配"
    );
    let wrapping = parse_recovery(code)?;
    unwrap_key(envelope, wrapping.as_ref(), "recovery")
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct PacketHeader {
    version: u32,
    suite: String,
    space: String,
    key_id: String,
    batch_id: String,
    #[serde(deserialize_with = "required_parent")]
    parent: Option<String>,
}
fn required_parent<'de, D: serde::Deserializer<'de>>(
    d: D,
) -> std::result::Result<Option<String>, D::Error> {
    Option::deserialize(d)
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Packet {
    header: PacketHeader,
    sealed: Sealed,
}
pub struct OpenedPacket {
    pub snapshot: Snapshot,
    pub batch_id: String,
    pub parent: Option<String>,
}
fn check_header(header: &PacketHeader, key: &SyncKey) -> Result<()> {
    ensure!(
        header.version == 1 && header.suite == SUITE,
        "不支持的同步密文版本"
    );
    ensure!(
        header.space == key.space && header.key_id == key.id,
        "同步空间或密钥编号不匹配"
    );
    uuid::Uuid::parse_str(&header.batch_id).context("同步批次编号无效")?;
    if let Some(parent) = &header.parent {
        ensure!(
            [40, 64].contains(&parent.len()) && parent.bytes().all(|b| b.is_ascii_hexdigit()),
            "同步父版本无效"
        );
    }
    Ok(())
}
pub fn encrypt(
    snapshot: &Snapshot,
    key: &SyncKey,
    batch_id: String,
    parent: Option<String>,
) -> Result<Vec<u8>> {
    ensure!(snapshot.space == key.space, "同步空间不匹配");
    let header = PacketHeader {
        version: 1,
        suite: SUITE.into(),
        space: key.space.clone(),
        key_id: key.id.clone(),
        batch_id,
        parent,
    };
    check_header(&header, key)?;
    let aad = serde_json::to_vec(&header)?;
    let plaintext = snapshot.encode()?;
    let packet = Packet {
        header,
        sealed: seal(key.secret.as_ref(), &aad, &plaintext)?,
    };
    let bytes = serde_json::to_vec(&packet)?;
    ensure!(bytes.len() <= PACKET_LIMIT, "同步密文过大");
    Ok(bytes)
}
pub fn decrypt(bytes: &[u8], key: &SyncKey) -> Result<OpenedPacket> {
    ensure!(bytes.len() <= PACKET_LIMIT, "同步密文过大");
    let packet: Packet =
        serde_json::from_slice(bytes).map_err(|_| anyhow::anyhow!("同步密文格式无效"))?;
    check_header(&packet.header, key)?;
    let plaintext = unseal(
        key.secret.as_ref(),
        &serde_json::to_vec(&packet.header)?,
        &packet.sealed,
        MAX_BYTES,
    )?;
    let snapshot = Snapshot::decode(&plaintext)?;
    ensure!(snapshot.space == key.space, "同步空间不匹配");
    Ok(OpenedPacket {
        snapshot,
        batch_id: packet.header.batch_id,
        parent: packet.header.parent,
    })
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct StoredKey {
    version: u32,
    space: String,
    id: String,
    secret: String,
    envelope: KeyEnvelope,
}
impl StoredKey {
    fn from_key(key: &SyncKey, envelope: &KeyEnvelope) -> Self {
        Self {
            version: 1,
            space: key.space.clone(),
            id: key.id.clone(),
            secret: Base64::encode_string(key.secret.as_ref()),
            envelope: envelope.clone(),
        }
    }
    fn open(&self) -> Result<SyncKey> {
        ensure!(self.version == 1, "不支持的本机同步密钥版本");
        let key = SyncKey {
            space: self.space.clone(),
            id: self.id.clone(),
            secret: decode_fixed::<32>(&self.secret)?,
        };
        verify_envelope(&key, &self.envelope)?;
        Ok(key)
    }
}
impl Drop for StoredKey {
    fn drop(&mut self) {
        self.secret.zeroize();
    }
}
/// First install only. Later changes use rotation with publication confirmation.
pub fn install(db: &mut Connection, key: &SyncKey, envelope: &KeyEnvelope) -> Result<()> {
    let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    install_in_transaction(&tx, key, envelope)?;
    tx.commit()?;
    Ok(())
}
pub(super) fn install_in_transaction(
    db: &Connection,
    key: &SyncKey,
    envelope: &KeyEnvelope,
) -> Result<()> {
    verify_envelope(key, envelope)?;
    let state = super::state::load(db)?.context("请先初始化同步状态")?;
    ensure!(state.space() == key.space, "同步空间不匹配");
    ensure!(!state.has_pending(), "请先处理待同步批次");
    let exists: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM metadata WHERE key=?1)",
        [LOCAL_KEY],
        |r| r.get(0),
    )?;
    ensure!(!exists, "已有同步密钥，不能覆盖");
    let stored = StoredKey::from_key(key, envelope);
    let json = Zeroizing::new(serde_json::to_string(&stored)?);
    db.execute(
        "INSERT INTO metadata(key,value) VALUES (?1,?2)",
        params![LOCAL_KEY, json.as_str()],
    )?;
    Ok(())
}
pub fn load(db: &Connection) -> Result<Option<(SyncKey, KeyEnvelope)>> {
    let length: Option<i64> = db
        .query_row(
            "SELECT length(CAST(value AS BLOB)) FROM metadata WHERE key=?1",
            [LOCAL_KEY],
            |r| r.get(0),
        )
        .optional()?;
    let Some(length) = length else {
        return Ok(None);
    };
    ensure!(
        length >= 0 && length as usize <= KEY_LIMIT,
        "本机同步密钥状态过大"
    );
    let json = Zeroizing::new(db.query_row::<String, _, _>(
        "SELECT value FROM metadata WHERE key=?1",
        [LOCAL_KEY],
        |r| r.get(0),
    )?);
    ensure!(json.len() <= KEY_LIMIT, "本机同步密钥状态过大");
    let stored: StoredKey =
        serde_json::from_str(&json).map_err(|_| anyhow::anyhow!("本机同步密钥状态损坏"))?;
    let key = stored.open()?;
    let state = super::state::load(db)?.context("同步状态不存在")?;
    ensure!(state.space() == key.space, "本机同步密钥空间不匹配");
    Ok(Some((key, stored.envelope.clone())))
}
/// One-shot encryption helper, not a retryable publication. Transport must use
/// outbox::stage to persist stable bytes before sending.
/// Rechecks local-only dependencies via the durable pending-batch accessor.
pub fn encrypt_pending(db: &Connection) -> Result<Vec<u8>> {
    let (key, _) = load(db)?.context("请先配置同步密钥")?;
    let pending = super::state::pending_upload(db)?.context("没有待同步批次")?;
    ensure!(pending.needs_upload(), "该批次只需确认拉取，无需上传");
    ensure!(
        !pending.is_key_rotation(),
        "密钥轮换必须通过持久化发件箱发送"
    );
    encrypt(
        pending.snapshot(),
        &key,
        pending.id().into(),
        pending.expected_revision().map(str::to_string),
    )
}

#[cfg(test)]
mod tests;
