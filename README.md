# W Term

Apple-first SSH / SFTP workspace: Flutter UI, Rust networking core. macOS and iOS/iPadOS first; Windows starts after the Apple milestone; Android is deferred. See [PLAN.md](PLAN.md) and [implementation status](docs/STATUS.md).

## Current preview (0.1.0)

- Real SSH with password or encrypted OpenSSH private key authentication.
- Fingerprint approval **before authentication**, bound to the same transport; later host-key changes are blocked. Confirmed fingerprints are stored in the Apple Keychain.
- Multiple sessions, xterm terminal, incremental UTF-8 decoding, resize, copy/paste and mobile auxiliary keys.
- SFTP browsing, new directories, bounded UTF-8 previews, streamed single-file upload/download. Uploads never overwrite existing files.
- macOS file dialogs and iOS share sheet export to Files.
- Device-local host profiles: create/edit/delete, groups, tags, favorites and search. Profiles are stored in the master-password-protected SQLCipher vault and prefill the connection form; credential references are separate from host metadata.
- Master-password create/unlock/lock, transactional import of legacy Keychain profiles, and iOS background locking.
- Encrypted reusable identities: usernames with passwords or imported private keys/passphrases; double-click a host to authenticate directly through Rust.
- Nested folders with recursive deletion that preserves hosts; a single host click does nothing, and Edit opens the profile editor.
- Master-password changes and independently encrypted backup export/restore. No demo connections or simulated operations.

This is an Apple development preview, **not the full V1.0**. Quick unlock, recovery codes, key generation, sync, jump hosts, proxies, forwarding, MFA, transfer queue/resume, recursive transfers and editing are not yet implemented. On iOS this preview deliberately disconnects and locks on backgrounding. It never automatically reconnects or replays commands.

## Toolchain

- Flutter **3.47.4**, Dart 3.13.3, Rust **1.98.1**, flutter_rust_bridge **2.13.0**.
- Xcode and macOS to build Apple applications.
- macOS 14+ / Apple Silicon; iOS/iPadOS 17+.
- Rust targets: `aarch64-apple-darwin`, `aarch64-apple-ios`, `aarch64-apple-ios-sim`, `x86_64-apple-ios` (generic simulator builds include both simulator architectures).

In this workspace the toolchains are installed under ignored `.toolchains/`:

```bash
source scripts/env.sh
flutter pub get --enforce-lockfile
flutter run -d macos
```

On another machine, install the pinned Flutter and Rust versions normally; do not source `scripts/env.sh` unless using the project-local installation. The Flutter build hook compiles and bundles Rust automatically; CocoaPods is not required by the Rust bridge (Apple plugins use Swift Package Manager).

```bash
flutter build macos --debug
flutter build ios --simulator --debug
flutter devices
flutter run -d <simulator-id>
```

For an iPhone, open `ios/Runner.xcworkspace`, select your own development team and unique bundle ID, then run on the device. No Apple account, certificate or provisioning profile is bundled. Simulator builds do not prove hardware behavior.

macOS preview uses the standard login Keychain (rather than the development-team-bound Data Protection Keychain). macOS may ask permission when a rebuilt application accesses previously stored fingerprints. Failure to read the Keychain blocks connection; the app never silently resets trust. iOS uses device-only, unlocked Keychain accessibility.

## Tests

```bash
flutter analyze
cargo fmt --manifest-path rust/Cargo.toml -- --check
cargo clippy --manifest-path rust/Cargo.toml --locked --all-targets -- -D warnings
flutter test
```

Real interoperability tests use a temporary AsyncSSH server on loopback. They do not enable macOS Remote Login, read your SSH keys or connect to a real server.

```bash
python3 -m venv .toolchains/test-venv
.toolchains/test-venv/bin/pip install -r tests/requirements.txt
bash scripts/test-core.sh
```

The script starts and stops its own server, uses generated disposable keys and a temporary filesystem, and checks password/key authentication, fingerprint rejection, cancellation, Unicode terminal I/O and binary SFTP roundtrips. Synthetic fixture credentials are only for localhost tests.

## Bridge regeneration

Generated Dart/Rust bindings are checked in. After changing `rust/src/api/`:

```bash
cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked
flutter_rust_bridge_codegen generate
```

## Security notes

- This preview requires explicit verification for new hosts; it has no accept-all mode. Host certificates are currently rejected.
- Passwords/private keys/passphrases are written only inside the encrypted SQLCipher vault and encrypted backups. The identity list/editor does not read stored secrets back. Dart strings cannot guarantee zeroization.
- SFTP downloads and uploads use app-private temporary files; selected files are intentionally exported in ordinary file form. Temporary files are removed after operations; secure erasure on flash storage is not promised.
- A failed upload attempts to remove its random `.part` file. A lost network connection can leave the file remotely; it is not treated as a completed upload.
- No telemetry or terminal logging is enabled by application code.

## Host management

The desktop left sidebar now shows the host list directly, grouped into collapsible folders. On phones, open the host drawer using the top-left menu. Add a name, address, port and username; folders/categories and comma-separated tags are optional. Use the folder-plus button to create an empty folder, the plus beside a folder to add a host there, or the folder picker in the editor to move a host. Existing groups appear as folders automatically. Double-click a saved host to connect with its encrypted identity. Single-click does nothing. Use the host menu to edit. Older profiles need a password or saved identity attached once. Editing/deleting a profile does not modify existing sessions or host fingerprint trust.

Host profiles and folders now use the Rust SQLCipher vault. The first unlock imports legacy Keychain records transactionally and retains the old copy. Corrupt or unsupported data blocks editing; it is not silently replaced. Saving failures retain the last successfully saved list. See [vault format, migration and limitations](docs/VAULT.md).

Sessions now appear as compact, horizontally scrollable tabs at the top of the right workspace (36 px on desktop, 44 px on phones), with connection status, selection and close actions. Host editing and favorite actions are available in each host’s overflow menu. Folder menus support subfolder creation and recursive deletion. Deletion moves contained hosts to Uncategorized and retains their credentials. Folder rename/drag-to-move are not implemented.

## Master password

On first launch, create a master password (at least 12 characters). Subsequent launches require it to unlock the workspace. Use **锁定保险库** at the bottom of the host sidebar to end sessions and lock. The sidebar’s **保险库与备份** supports changing the master password and exporting/restoring independently encrypted backups. There is no recovery code or quick unlock yet. Old Keychain data is retained after import, while new edits go only to the vault.

To test the real native vault bridge on macOS:

```bash
bash scripts/test-vault-bridge.sh
```

## Identity / key management

Switch the left sidebar to **身份 / 密钥** to add or edit a username/password or username/private-key identity. Select it in a host’s authentication settings to reuse it. Existing secrets remain unchanged when editing metadata; select **替换保存的凭证** to replace them. Referenced identities cannot be deleted until hosts are reassigned. New quick connections save their host and credentials atomically before connecting. First-use fingerprint verification and changed-fingerprint blocking remain mandatory.


### 最新更新（已编译开发版）

- iOS 切后台只隐藏敏感界面，返回保持保险库解锁；进程退出后重新启动需要认证。
- 解锁页可启用本机 Touch ID / Face ID 快速解锁，保险库设置可关闭；修改主密码后需重新启用。
- 终端工具栏新增历史搜索，快捷键 Cmd+F / Ctrl+Shift+F，支持大小写筛选及快照刷新。
- 终端工具栏可设置深灰/纯黑/浅色配色及 10–28 号字体，保存后同步更新所有会话并在本机保留。
- 本轮分析通过，35 项 Flutter 测试及真实保险库桥接测试通过；macOS Debug 和 iOS 模拟器 Debug 构建成功。Touch ID / Face ID 系统认证仍待实机验证，详见 `docs/STATUS.md`。


### 上传与 macOS 签名

- 上传时遇到同名文件，可以替换、保留两个文件或取消；macOS 可拖入文件到当前 SFTP 面板上传。
- 替换要求服务器支持 OpenSSH 原子重命名扩展；不支持时原文件保留，可选择保留两个文件。文件夹递归上传尚未实现。
- Touch ID 需要正确的应用签名及 Keychain 权限。移除 `com.apple.quarantine` 不等于签名，详见 [macOS 签名说明](docs/MACOS_SIGNING.md)。

本轮上传更新验证：38 项 Flutter 测试、11 项 Rust 测试及 1 项真实桥接测试通过；macOS/iOS 模拟器 Debug 构建完成。
