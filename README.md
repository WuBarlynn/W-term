# W Term

接手开发请先阅读 [AI 项目交接文档](AI_HANDOFF.md)（2026-10-30 核对）。

Apple-first SSH / SFTP workspace: Flutter UI, Rust networking core. macOS and iOS/iPadOS first; Windows starts after the Apple milestone; Android is deferred. See the [active development roadmap](docs/ROADMAP.md), [long-term plan](PLAN.md), and [implementation status](docs/STATUS.md).

## Current development

The current source version is **1.0.14 (67)**. This is a three-platform development release; real-device/day-to-day acceptance and independent pop-out windows are still pending. P1.5-A/B introduces a session/view split: `TerminalSession` owns terminal output and lifetime while movable panes only display it, tabs can be reordered and renamed, and terminals support horizontal/vertical/nested splits with resizable dividers, focus switching, split-back-to-tab and dragging a tab onto a pane edge to merge. A whole tab can be dragged (the left handle still reorders), drops choose the nearest pane edge, and the tab context menu adds two-pane and four-pane layouts. Terminal input can be broadcast explicitly to the current tab or all connected sessions, with macOS shortcuts and an open-terminal picker. A disconnected saved-host pane can be reconnected in place without losing its tab or split layout, layouts restore as disconnected panes after restart, and macOS hides instead of quitting when the last window closes so sessions survive until Quit. Closing one tab only disconnects its own sessions. The desktop sidebar and SFTP pane are both resizable; the sidebar collapses to a narrow rail (expand, new connection, settings, lock) and the file pane collapses to a rail with show/upload/refresh. Touch ID/Face ID is now prompted automatically at launch when enrolled, and the iOS privacy shield no longer lingers after unlocking. See [tabs and splits](docs/WORKSPACE_TABS.md). P1-C adds local (`-L`), remote (`-R`) and dynamic SOCKS5 (`-D`) forwarding plus device-local saved rules; P1-B adds persistent interactive identities, named/per-host proxies and layered tests; P1-A adds jump-host routes. See [port forwarding](docs/SSH_FORWARDING.md), [jump routes](docs/SSH_ROUTES.md), [interactive authentication](docs/SSH_INTERACTIVE_AUTH.md) and [SSH proxies](docs/SSH_PROXY.md). GitHub manual encrypted sync with conflict review remains available; see [conflict handling](docs/SYNC_CONFLICTS.md) and [sync setup](docs/SYNC_SETUP.md). Real GitHub and signed-device validation remain pending. Layout restore and macOS close-to-hide keep-alive are implemented; independent pop-out windows remain blocked by the single-engine session architecture. Windows validation is in progress. SFTP feature work is active again under the Cloud Term feature audit. Latest results are tracked in [STATUS.md](docs/STATUS.md).

## Original prototype (0.1.0, historical)

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

This is an Apple development preview, **not the full V1.0**. Quick unlock, key generation, sync, jump hosts, proxies, local forwarding and MFA have landed but still need real-device acceptance; remote/dynamic forwarding, transfer queue/resume, recursive transfers and richer editing are still pending. On iOS this preview deliberately disconnects SSH on backgrounding while keeping the vault unlocked; it never automatically reconnects or replays commands.

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
- Touch ID 签名预检拒绝 unsigned/ad-hoc，允许 Apple Development、Developer ID 和自签名证书；macOS 使用 Secure Enclave 加密凭证，解决自签名版本的 Keychain -34018，详见 [macOS 签名说明](docs/MACOS_SIGNING.md)。
- 运行 `bash scripts/build-macos-signed.sh`，使用现有 `W Term Vault Code Signing` 自签名身份生成当前 Mac 的 Release 签名版：`build/macos-signed/Build/Products/Release/W Term.app`。保留用户自签名脚本与 Xcode 团队设置；签名通过不能代替真实 Touch ID 验收。

本轮上传更新验证：38 项 Flutter 测试、11 项 Rust 测试及 1 项真实桥接测试通过；macOS/iOS 模拟器 Debug 构建完成。


### 0.1.2 (3)：主机列表与文件夹管理

- 主机支持悬停/选中高亮，单击只选中，双击连接。
- 文件夹菜单支持重命名，连同子文件夹和主机归属一起更新，并阻止重名合并。
- 解锁页和侧栏显示实际安装版本。iOS 若仍显示“上传文件（不会覆盖同名文件）”，说明装的是旧包，请检查已安装版本；可用包与构建阻塞见 [开发记录](docs/STATUS.md)。
- iOS 真机包通过 `bash scripts/package-ios-unsigned.sh` 构建；输出为未签名 Release IPA，需要签名后安装，不能直接把模拟器 App 装到 iPhone。

### 0.1.3 (4)：生成 SSH 密钥

在左侧“身份与密钥”点击钥匙按钮，填写名称和用户名即可生成 Ed25519 身份。私钥直接写入本地加密保险库，界面仅提供公钥查看与复制；将公钥配置到服务器后，在主机设置中选择该身份连接。已有私钥身份也可通过菜单提取公钥。0.1.4 起可通过身份菜单独立导出加密私钥，也可使用保险库加密备份保存身份。

### 0.1.4 (5)：导出加密私钥

在私钥身份菜单选择“导出加密私钥”，输入并确认至少 12 个字符的独立口令。macOS 选择保存位置；iOS 通过分享面板保存到“文件”等目标。导出文件使用 OpenSSH 加密格式，其他客户端导入时需要该口令，原身份不变。可用构建及真机验证状态见 [开发记录](docs/STATUS.md)。

### 0.1.5 (6)：SFTP 重命名与删除

文件面板每行右侧菜单支持下载、重命名和删除。重命名不会覆盖同名项目；删除前需要确认，符号链接仅删除链接本身，非空目录拒绝删除。操作完成后刷新当前目录。递归目录删除尚未提供。

### 0.1.6 (7)：SFTP 搜索与排序

文件面板支持当前目录名称搜索、隐藏点文件开关，以及名称/大小/修改时间升降序排序。目录始终排在前面，列表显示设备本地时区的修改时间和筛选后的项目数量。筛选只作用于当前目录，不进行递归搜索；关闭会话后恢复默认设置。

### 0.1.7 (8)：SFTP 权限管理

普通文件和文件夹的菜单可打开“权限”。输入 000–777，或勾选所有者、用户组和其他人的读/写/执行权限；已有特殊权限位保留，不递归修改子项目。保存前检查权限是否改变，保存后读取服务器结果。符号链接不提供此操作。

### 0.1.8 (9)：OpenSSH 配置导入

主机栏文件图标支持选择或粘贴 `ssh_config`，预览后勾选保存到“OpenSSH 导入”。支持 Host、HostName、User、Port 和常用 Host 匹配规则；缺少 User 时可填写默认用户名。IdentityFile 仅提示路径，需自行关联保存的身份。暂不支持 Include/Match、跳板/代理等其他选项，预览会标出不可导入的配置。相同配置跳过，现有主机不覆盖。

### 0.1.9 (10)：SFTP 远程文本编辑

普通文件菜单支持“编辑文本”，可编辑最多 256 KiB 的 UTF-8 文件，保留 CRLF 换行。Cmd/Ctrl+S 保存；关闭未保存内容需确认，失败时可继续编辑或复制内容。检测到远程内容或权限变更时拒绝覆盖。保存依赖服务器的 POSIX 原子替换扩展，不支持时保留原文件；权限与属主保留，ACL/扩展属性和硬链接关系不保留。并发检查及其他验证边界见 [开发记录](docs/STATUS.md)。

### 0.1.10 (11)：加密命令片段

在终端工具栏的代码图标中管理常用单行命令，支持搜索、编辑和删除；选中后预览并确认插入，内容追加到当前输入，不发送回车。片段随保险库加密备份恢复，跨会话复用。

此版本会将已解锁的保险库升级到 schema 3，旧应用不能读取升级后的保险库或新版备份；新版本仍支持恢复旧备份。

### 0.1.11 (12)：离线管理命令片段

左侧“命令片段”可在未连接服务器时管理保险库中的命令，手机从主机抽屉进入。点击片段编辑，菜单支持复制命令；终端工具栏仍提供预览后插入。保存失败保留名称和命令，可以直接重试，保存期间禁止重复提交及关闭编辑器。列表刷新按钮可重新读取保险库。

### 0.1.12 (13)：批量上传任务列表

选择多个文件或拖入文件后，文件面板的“上传任务”按钮显示本批次每个文件的等待、上传中、完成、失败与取消状态，以及实际保存路径或错误原因。可取消剩余任务；正在传输的文件会先完成，失败项不会阻止后续文件。文件重名仍需选择替换、保留两个或取消。

任务列表仅保留在当前会话内，下一批上传会替换列表；没有字节级进度、断点续传或重启恢复。本轮不提供目录递归上传。宽窄布局切换复用文件面板状态。

### 0.1.13 (14)：重试失败的上传

本批上传结束后，在“上传任务”中点击“重试失败项”。只重试失败记录，成功和主动取消的项目保持不变；始终上传到本批原始目录，同名文件重新询问替换、保留两个或取消。

重试会重新读取原本选择的本地文件（不是上一次内容快照）；如果文件已更改，将上传新内容。原文件被删除或授权失效时会显示失败原因，需要重新选择。仅当前会话可用，不自动重试，不保存待上传文件副本用于重启恢复。

### 0.1.14 (15)：下载结果与重新下载

文件面板的“传输任务”菜单统一提供“上传任务”和“最近下载”。最近下载显示原路径、接收字节数、保存/分享结果及失败原因，可点击“重新下载”读取服务器当前文件，再选择保存或分享。记录仅保留当前会话最近一次下载，不是下载队列或断点续传。

取消桌面保存或 iOS 分享不再提示完成；iOS 分享结果不可用时显示“分享结果未确认”，分享完成不等同于已保存到本地。下载或保存失败仍会清理临时文件；清理失败单独提示，界面恢复可操作。

### 0.1.15 (16)：macOS 文件夹上传预览

在文件面板“上传”菜单选择“上传文件夹”，扫描并确认后，将根目录及子目录、普通文件和空目录上传到当前服务器目录。支持中文、隐藏文件；拒绝符号链接和特殊文件，最多 2,000 项、32 层。服务器已有同名根目录时拒绝本批上传，不合并已有目录。

目录和文件均显示在上传任务列表中，支持取消剩余项目和重试失败项；父目录创建失败时子项不会写入。取消或失败保留已上传内容，重试读取本地当前内容。扫描后新增文件不会自动加入本批，文件内容和目录元数据不提供快照一致性，权限/时间戳不复制。

本轮目录选择入口仅支持 macOS 按钮选择；拖入文件夹和 iOS 目录授权尚未接入。iOS 继续支持多文件上传，目录适配待原生授权实现，尚未达到最终多端功能一致的验收标准。

### 0.1.16 (17)：iOS 文件夹选择与上传

iPhone/iPad 的“上传”菜单现在也提供“上传文件夹”，通过原生“文件”选择器授予所选目录的访问权限，再复用目录扫描、确认、上传任务和失败重试逻辑。授权只在当前批次/会话内保留，替换批次或关闭会话时释放；正在传输时延迟到本次传输退出后释放，不将授权存入备份或同步。

取消选择、取消上传确认或扫描失败都会释放新授权。目录上限、拒绝链接、已有根目录不合并等规则与 macOS 相同。iCloud 或第三方文件提供方仍可能因未下载、权限或离线而读取失败，届时显示错误并允许重新选择。原生选择器、iCloud 提供方和真机整批上传尚待实机验收；未实现后台持续上传或断点续传。

### 0.1.17 (18)：目录扫描进度与取消

macOS/iOS 选择上传文件夹后显示已扫描项目数，并提供“取消扫描”。取消或关闭会话后停止后续遍历，不返回部分上传计划，不创建服务器目录；iOS 新授权随后释放。取消需等待当前文件系统读取返回，无法强制打断卡住的云文件提供方。扫描上限和上传前确认规则不变。

### 0.1.18 (19)：目录上传明细预览

macOS/iOS 扫描文件夹后，确认窗口显示文件数、目录数（含根目录）、总大小和可滚动的相对路径清单，文件逐项显示大小。大小通过扫描时读取元数据获得，不读取文件内容；本地文件后续变更可能使实际传输量不同。支持 KiB/MiB/GiB/TiB 显示，上传仍需明确确认。

### 0.1.19 (20)：macOS 拖入文件夹上传

从 Finder 拖入单个文件夹到当前会话的文件面板后，会先扫描并显示目录上传预览，确认后才上传。沿用空目录保留、上限、链接拒绝、不合并已有根目录、取消剩余项和失败重试规则。拖入目录的安全访问授权覆盖扫描及本批次重试，替换批次或关闭会话时释放，在途传输结束前保持授权。

多文件拖放保持可用；一次拖入多个文件夹或混合文件/文件夹会整体拒绝并提示分批操作。此入口仅 macOS；iOS 继续通过原生文件夹选择器上传。Finder 沙盒授权与实际目录传输仍待人工验收。

### 0.1.20 (21)：设置上传目标目录名

目录上传预览增加“目标文件夹名称”，默认使用本地根目录名，也可改为新的服务器目录名，路径列表随输入更新。本地文件不改名，子目录结构、任务顺序和失败重试保持一致。已有同名目标仍拒绝上传；可重新选择目录后换名上传。

拒绝空名称、`.`/`..`、路径分隔符和控制字符。手机键盘弹出时确认窗口可滚动，保留确认和取消按钮。

### 0.1.21 (22)：批量上传统一处理同名文件

上传遇到同名文件时，可勾选“对本批后续冲突使用相同选择”，再选择替换或保留两个文件。默认不勾选，继续逐项询问；取消仍停止本批剩余上传。

选择仅保留在当前上传尝试内，不跨会话、新批次或失败重试沿用。每个文件仍先按不覆盖方式尝试，只有确认同名冲突后才应用选择；目录创建冲突和服务器拒绝不会被绕过。目录任务中的冲突窗口显示完整相对路径，便于识别不同子目录下的同名文件。

### 0.1.22 (23)：跳过同名文件

上传冲突窗口新增“跳过”，保留服务器已有项目并继续后续文件；可勾选应用到本批后续冲突。任务列表显示“已跳过”，完成汇总单列跳过数量，不计为成功或失败。重试失败项不会包含已跳过的文件；重新选择新批次时重新询问。

跳过仅在文件上传遇到同名冲突时提供，目录创建冲突仍拒绝，不合并已有目录。选择跳过后不会调用替换或保留两个文件操作。

### 0.1.23 (24)：搜索与筛选上传任务

上传任务窗口支持按文件名/相对路径搜索（不区分大小写），以及全部、等待、上传中、完成、失败、已取消、已跳过状态筛选。显示匹配项/总项数及全批状态数量，随任务变化实时更新。

搜索与筛选只改变显示，不改变任务顺序或取消范围。“重试全部失败项”始终重试本批所有失败项，不受筛选影响。手机键盘显示时窗口可滚动；关闭窗口后搜索条件不保留。

### 0.1.24 (25)：SFTP 目录历史

文件面板支持后退、前进和目录历史菜单，可跳回本会话已访问的远程目录。历史使用服务器返回的规范路径，只有读取成功才更新；读取失败保留当前目录并恢复路径栏。刷新同一位置不重复记录，后退后进入新目录会替换原前进分支。

每个文件面板最多保留 100 个位置，宽窄布局切换继续保留，关闭会话后清除；不保存滚动位置，不跨会话同步。加载和传输期间禁用导航操作。

### 0.1.25 (26)：本地 SSH 端口转发

已认证会话顶部打开“端口转发”，填写目标主机/端口及本地端口，启动后使用显示的 `127.0.0.1:端口` 访问。填 `0` 自动分配本地端口。可查看目标连接错误并单独停止转发；关闭窗口继续运行，停止、远端终端退出或 SSH 断开会清理转发。iOS 切后台沿用断开会话策略。

首版每会话最多 8 条转发、每条 32 个并发连接；只监听本机回环地址，不持久化或自动重启规则。目标由 SSH 服务器连接，监听成功不代表目标可达；使用后可刷新查看错误。远程/动态转发及规则保存纳入后续连接能力阶段。macOS Release 沙盒补充监听权限。

使用临时 SSH 服务验证真实桥接：

```bash
source scripts/env.sh
WTERM_TEST_FORWARD_BRIDGE=1 bash scripts/test-core.sh
```

该测试使用独立生成的测试密钥与本机回环端口，不启用系统远程登录。已中断的上一轮目录上传隐藏项过滤改动一并完成回归；后续暂停 SFTP 新功能。

### 0.1.26 (27)：同步数据协议与合并核心

实现 Rust 内存协议草案、保险库快照和三方合并：单端修改自动合并，双端不同修改或修改/删除冲突保留双方并阻止写入。删除标记保留，避免旧设备无意恢复已删除项；主机/身份引用失效、合并时本机再次修改以及无效密钥都会阻止写入。事务失败回滚全部数据。

新增两个独立 SQLCipher 保险库的合并、收敛、冲突、私钥解析和容量边界测试。本轮没有新增同步界面或 GitHub 网络操作；传输加密、恢复码、持久化同步检查点和“仅本机保存”规则仍待实现。文件夹以整棵树保守处理冲突。见 [同步协议及边界](docs/SYNC.md)。

### 0.1.27 (28)：同步状态持久化与仅本机规则

同步核心将设备 ID、基线、待处理批次和回执保存到 SQLCipher。批次准备与业务合并同事务提交，重开保险库可恢复同一批次；确认不会覆盖准备后新增的本机修改，重复回执不会重复提交。仅拉取可直接确认已有远端版本，提交失败后重新合并不会把已接收的远端修改误当作本机修改。

主机、身份及片段支持核心层的仅本机排除；凭证与关联主机一并保护，远端删除不能删除本机专用记录。已发布数据改为仅本机需要后续撤回流程。本轮仍没有同步设置入口或 GitHub 上传，传输加密及系统集成待完成。详见 [同步状态与规则](docs/SYNC.md)。

### 0.1.28 (29)：同步加密与恢复核心

独立同步密钥、认证加密包、同步口令和恢复码解锁，以及 SQLCipher 密钥托管已在 Rust 核心实现。新增 8 项单元测试和 1 项独立 Python 加密互操作测试；应用界面和 GitHub 尚未接入，密钥轮换及密文发件箱仍待实现。详见 [加密设计与边界](docs/SYNC_CRYPTO.md)。

### 0.1.29 (30)：同步密文发件箱

密文和密钥信封持久化后才允许发送；重试及关闭重开复用原字节。读回内容逐字节核对后，检查点、密文清理和确认回执同事务提交；保留后续编辑，拒绝损坏或过期批次。新增 8 项专项测试。仍未接入 GitHub 和同步界面，详见 [发件箱流程](docs/SYNC_OUTBOX.md)。

### 0.1.30 (31)：同步密钥分阶段轮换

候选密钥与轮换批次持久化，新恢复码核验后才可生成上传包；确认内容后原子切换活动密钥并保留旧密钥用于本机历史读取。关闭重开、取消、错误回执和写入失败均保持可恢复状态。新增 7 项专项测试；尚无 GitHub、其他已绑定设备自动换钥或 UI。详见 [轮换流程与边界](docs/SYNC_ROTATION.md)。

### 0.1.31 (32)：GitHub HTTPS 传输核心

新增私有仓库验证、同提交发布密文/信封、非强制分支更新、持久发布记录和响应丢失核对。新增 10 项真实 HTTP 客户端测试；尚无账户/同步界面或真实 GitHub 仓库验收。详见 [传输流程与边界](docs/SYNC_GITHUB.md)。

### 0.1.32 (33)：GitHub 手动同步入口

侧栏“GitHub 同步”可配置已有私有仓库与分支，将令牌加密保存在本机保险库。创建同步空间后需离线保存并重新输入恢复码；其他设备通过同步口令或恢复码接入，再手动合并与同步。失败保留待处理批次，取消或锁定保险库会停止网络流程。遇到冲突或远端换钥先停止，相关处理界面仍待开发。使用说明见 [SYNC_SETUP.md](docs/SYNC_SETUP.md)。

### 原生增量构建依赖

`hook/rust_inputs.dart` 显式登记 Rust 源码、源码目录、Cargo 清单/锁文件及 `.cargo/config.toml`，补足上游 dep-info 对含空格路径的解析问题。构建不会扫描 `rust/target` 生成目录。修改 Rust 后应重新构建应用；发布验证同时检查 Native Assets 依赖清单和包内原生库时间，避免成功日志掩盖旧库复用。

## Windows build

Windows builds require a Windows 10/11 host with the Visual Studio C++ toolchain and Rust. Run `flutter build windows --release`; the GitHub `Windows preview` workflow performs the same build and verifies that the executable's FileVersion/ProductVersion match `pubspec.yaml`. The app uses vendored OpenSSL for Windows SQLCipher and does not require a system OpenSSL installation.

## License

MIT License. See [LICENSE](LICENSE).
