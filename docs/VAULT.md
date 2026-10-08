# Local vault — schema 3

The application starts with master-password creation/unlock. Host profiles, folder paths, reusable identities and credential secrets are stored in `wterm-vault.db` under the platform application-support directory. By default the master password is not persisted. Opting into quick unlock uses a device-only biometric Keychain item on iOS, and a Secure Enclave protected encrypted envelope on macOS (0.1.36+).

## Encryption and schema

Rust `rusqlite` builds SQLCipher 4.10.0 through `libsqlite3-sys` 0.36.0. Apple builds use CommonCrypto. The app checks `cipher_version` and uses compatibility mode 4, memory-only temporary SQLite storage, SQLCipher memory security, DELETE journals and FULL synchronous mode. Master passwords are passed using `sqlite3_key` / `sqlite3_rekey`, not SQL string interpolation. See the [SQLCipher API](https://www.zetetic.net/sqlcipher/sqlcipher-api/).

Schema 3 has encrypted host/folder/snippet records, metadata, and an `identities` table. Each identity contains a display name, username, authentication type and either a password or private-key material plus its optional passphrase. A host carries only an `identityId` reference. Unexpected secret fields in host JSON are rejected. Private keys are parsed and their passphrases verified before saving. Creating a host with a new identity is a single transaction. Updating an identity's username also updates referencing host metadata. Deleting an identity still referenced by hosts is blocked.

The Flutter identity list receives only ID/name/username/type. Stored secrets are not read back into the editor: edits retain the existing secret unless replacement is explicitly selected. On connection, Rust retrieves the saved credential and uses it on the already verified SSH transport. Initial private-key import and typed passwords necessarily pass through Dart/FFI. Rust uses zeroizing buffers and sensitive-input guards where owned; Dart strings and intermediate copies cannot guarantee erasure. No credential logging or plaintext credential export is enabled.

## Upgrade and migration

Authenticated opening upgrades schema 1 identities first, then schema 1/2 to schema 3, preserving existing profiles. Older application versions reject schema 3 rather than silently dropping snippets on backup restore. The format marker remains `wterm-vault-v1`; the SQL `user_version` distinguishes schema revisions.

Legacy Keychain host/folder records import once in a transaction. They remain as an OS-protected fallback copy; subsequent edits update only SQLCipher. The old application did not save passwords or private keys, so those cannot be recovered by migration: existing hosts need credentials attached once. The verified-server fingerprint store remains independent in Keychain, including after backup restore.

## Locking and connection

The unlocked database is accessed by a random session token. Dropping the handle locks the vault; stale tokens cannot read/write or close a newly unlocked session. Manual lock removes the workspace and disconnects SSH sessions. iOS backgrounding retains the in-process vault session, including a successful unlock finishing behind the privacy shield. Returning to the app does not require authentication again. Process termination (including an OS kill) loses the session; launching again requires password or biometric unlock. A Flutter privacy cover sits above navigation while inactive. Real-device app-switcher timing remains unverified; macOS system-lock/inactivity integration is not implemented.

Double-click a host to connect; a single click does nothing. The host menu's Edit action opens the separate profile editor. A first-time or changed server fingerprint still requires the existing verification/blocking flow. There is no automatic command replay.

## Master password and encrypted backups

**保险库与备份** in the sidebar supports:

- Master-password change after validating the current password; SQLCipher re-encrypts the database. Existing backup passwords do not change.
- Export to a new encrypted database using an independent backup password of at least 12 characters. The schema and encrypted identity secrets are included. The `sqlcipher_export` target receives a bound key and an explicit schema version. Only an encrypted temporary file is handed to the native save/share flow.
- Restore from a read-only encrypted source (up to 512 MiB). Invalid passwords/formats fail before destination changes. Hosts and identities receive new IDs and a ` (恢复)` suffix, and identity references are remapped in a transaction. Existing records are retained. Folder paths merge by name. Repeated restores intentionally create additional copies.

There is no recovery code or passwordless reset. If the main password is lost, an independently password-protected backup can be restored into a new unlocked vault, such as on another installation. Losing both passwords cannot recover the contents. Backup/save/share UI and interruption behavior still need real-device testing.

## Folder semantics

Folder paths use `/` between levels. New subfolders appear beneath their parent; ancestors are derived for existing grouped hosts. Deleting a folder removes its subtree and either moves all contained hosts to Uncategorized or deletes them, in one transaction. Reusable identity secrets are retained in both modes. Folder rename updates the entire subtree and host groups in one transaction, preserving host IDs and identity references. A destination which already exists, including an implicit parent, is rejected without changes. Folder drag-to-move is not implemented; host editing can change its folder path.

## Tests and remaining scope

Rust tests cover ciphertext inspection, wrong-password nonmutation, schema-1 upgrade, transaction rollback, stale tokens, reference validation, credential persistence, recursive folder deletion, master-password rotation, and backup restore without overwriting current data. An isolated AsyncSSH test authenticates with both a saved password and saved encrypted private key. The native Dart bridge smoke test exercises the same storage and maintenance APIs through generated bindings.

Quick unlock builds on macOS and the iOS simulator; mocked UI flows pass. System biometric/Keychain behavior still requires real-device verification. Still pending: recovery codes, generated keys and standalone encrypted key export, GitHub synchronization, real Keychain/device integration and full lifecycle/security review. This remains a development preview.

## Biometric quick unlock — compiled, device validation pending

The unlock screen offers enrollment after opening the vault with the master password. iOS continues to use `flutter_secure_storage`, service `dev.wterm.biometric-vault`, `biometryCurrentSet`, and device-only unlocked accessibility.

macOS 0.1.36 uses `SecureEnclave.P256.KeyAgreement.PrivateKey` with `privateKeyUsage + biometryCurrentSet`, avoiding the Data Protection Keychain entitlement error encountered by self-signed builds. An ephemeral ECDH sender derives an AES-256-GCM wrapping key with HKDF-SHA256. Only the Secure Enclave encrypted key representation, peer public key, random salt, and authenticated ciphertext are persisted. The context, wrapped-key hash, peer public key, and salt are authenticated. Enrollment proves decryption through the hardware key before replacing the old envelope; a new LAContext is used for each attempt and invalidated afterwards. There is no software-key fallback or password-only biometric bypass.

The envelope is stored at application support `dev.wterm.wterm/biometric-unlock-v2.json`, mode 0600, excluded from backup, and never synced. Previous macOS Keychain enrollment is ignored and must be re-enrolled after manual unlock; old items are not automatically deleted through an entitlement-requiring API. See [macOS signing and tests](MACOS_SIGNING.md) for migration and verification boundaries. Cancellation or invalidated enrollment retains the master-password path.

The Settings dialog can delete enrollment. Password rotation invalidates enrollment before rekeying, so a crash cannot leave an old credential enabled against the new vault password. A rejected password change can also disable enrollment; re-enable it on the unlock screen after a successful manual unlock. The password is held transiently in Dart during open/enrollment; clearing references does not guarantee zeroization of Dart strings.

`NSFaceIDUsageDescription` is declared for iOS. Signed-device Keychain access, biometric enrollment changes, cancellation, lockout, and process restart require later manual validation. The subsequent iteration completed macOS/iOS simulator builds, 35 Flutter tests and the native vault bridge smoke test. Mocked authentication tests do not certify device Keychain access.

## 软件密钥生成

0.1.3 起支持 Ed25519 生成。Rust 使用 `rand` 密码学随机源调用 `ssh-key`，私钥在核心内生成后直接保存到 SQLCipher；明文 OpenSSH 编码由可清零容器持有并在使用后释放。生成接口仅返回身份 ID，公钥接口只返回 OpenSSH 公钥文本，也支持已有加密私钥。身份按原有备份/恢复流程保存，不更改保险库格式。0.1.4 起提供私钥独立加密导出；硬件密钥尚未实现。

## 私钥独立加密导出

使用独立口令重新加密为 OpenSSH 私钥格式（库提供的 AES-256-CTR 与 bcrypt KDF）。口令要求至少 12 个字符、最多 1024 字节。生成和导入的可解析软件私钥均通过同一接口导出，保存的凭证不变。Rust 临时文件仅写密文、同步后以不覆盖方式发布；应用的平台保存流程随后复制密文或交给分享面板，并清理缓存。异常退出可能留下加密临时文件，但不会留下明文私钥。真实桥接测试使用系统 OpenSSH 读取导出文件，UI 的文件面板及 iOS 分享流程仍需实机验证。

## 命令片段（0.1.10）

片段保存在加密 records 的 `snippets` 中，包含 ID、名称和单行 command。Rust 校验 1000 条、16 KiB 单条上限并拒绝 Unicode 控制字符；Flutter 插入前再次校验。终端使用粘贴接口发送原始单行内容，不附加回车，不提供自动执行或重连重放。Dart 编辑缓冲可能包含敏感命令，锁定保险库时连同工作区移除。备份格式升级为 schema 3；旧备份无此字段时按空集合处理，恢复保留已有片段并生成新 ID。

0.1.11 增加工作区侧栏的离线管理入口，与终端工具栏共用同一个加密片段存储。管理模式点击条目打开编辑器，菜单可复制原始命令到系统剪贴板。保存失败保留编辑草稿直到重试成功或主动取消；本次不改变保险库 schema。

## 同步适配器草案（0.1.26）

Rust 同步核心可在已打开的 SQLCipher 数据库内捕获主机、身份、文件夹及片段，并用事务应用无冲突合并。现有 schema 3 不变，应用暂不调用该适配器，没有同步按钮或明文导出接口。只有测试中的独立保险库执行此流程。备份恢复仍创建新 ID，同步适配器保留 ID；两者不可互换。协议、内存明文边界及必须完成的持久化/加密步骤见 [SYNC.md](SYNC.md)。

## 持久化同步状态（0.1.27）

同步核心在加密 `metadata` 中使用独立键 `sync_state_v1` 保存设备标识、基线、私有范围和待处理批次。业务数据与批次准备共用事务，检查点写入失败时整体回滚；不增加 schema 版本。该模块尚未由应用入口调用，仅在隔离库中测试。完整加密备份可以包含这些元数据，但现有“恢复为新记录”流程不会复制它们；新记录使用新 ID，不能假定自动继承原仅本机规则。

## 同步密钥托管（0.1.28）

Rust 核心新增 `metadata.sync_key_v1`，在 SQLCipher 内保存独立随机同步密钥及经认证的密钥信封；恢复码和同步口令不存入该记录。安装需匹配已初始化的同步空间，拒绝覆盖现有密钥或跨越待处理批次。schema 3 不变；应用尚未调用这些接口。现有备份恢复不会重新启用同步或复制同步元数据。详见 [SYNC_CRYPTO.md](SYNC_CRYPTO.md)。

## 同步密文发件箱（0.1.29）

加密 metadata 增加 `sync_outbox_v1` 和 `sync_delivery_receipt_v1`，分别保存待发密文/信封和最近的内容确认摘要。schema 3 不变，确认或取消与检查点更新、密文清理同事务。普通备份恢复不复制这些状态；应用尚未启用同步。详见 [SYNC_OUTBOX.md](SYNC_OUTBOX.md)。

## 同步密钥轮换（0.1.30）

新增加密 metadata `sync_key_rotation_v1` 与 `sync_key_history_v1`。候选和待处理批次同事务创建；发件箱内容确认时同事务归档旧密钥、切换活动密钥、删除候选并确认检查点。恢复码仅创建时返回，不保存到候选。最多保留 16 把旧密钥，满后拒绝新轮换，不自动清除。schema 3 和恢复为新记录的逻辑不变。详见 [SYNC_ROTATION.md](SYNC_ROTATION.md)。

## GitHub 发布记录（0.1.31）

`sync_github_target_v1` 绑定仓库数字 ID/名称及分支，`sync_github_attempt_v1` 记录未确认的提交。均在 SQLCipher metadata 内，schema 3 不变。确认事务同时处理发件箱、检查点、轮换和发布记录清理。令牌不写入这两项记录；账户配置与令牌安全存储尚待接入。详见 [SYNC_GITHUB.md](SYNC_GITHUB.md)。
