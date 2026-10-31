# W Term 项目交接文档

> 面向接手本项目的 AI 或开发者。先读本文，再按任务读取对应源码。
>
> 原完整交接核对日期：**2026-10-15（Asia/Shanghai）**；规划补充日期：**2026-10-24**；功能交付更新：**2026-10-30**。当前应用版本：**1.0.48+101**。
> 最近一轮更新为 2026-10-31：设置工作区与 GitHub 设置同步、在线字体库、应用级上传队列、Windows 硬件键盘默认输入与 Menlo 默认字体。此前同轮已完成整标签拖动分屏、标签右键/长按菜单、双/四宫格、标签关闭隔离、面板折叠/调宽、自动生物识别与 iOS 遮罩修复。P1.5-F 手动重连/布局恢复与 macOS 关窗保活已实现；1.0.0 已产出三端构建。独立弹出窗口仍受单 Flutter 引擎架构限制，P2 真机/日用验收未完成。测试与构建证据见第 10 节。

## 1. 一分钟了解现状

W Term 是对标 Termius 的多端 SSH 工具，采用 **Flutter 自适应界面 + Rust 共享核心**。目标是简约、顺手、功能全面，并在不同设备间复用业务与同步协议。

- **当前平台：macOS、iOS/iPadOS。** Apple V1.0 验收后才开发 Windows；Android 延后到其余已规划阶段完成后单独评估，当前不创建 Android 工程。
- **当前阶段：P1.5 日常终端工作区（进行中）。** P1 连接闭环与 P1.5-A/B（会话/视图分离、标签、嵌套分屏、拖拽落点）已实现；P1.5-C/D（弹窗/保活、广播）与 E/F（快捷键/重连/布局）尚未完成。
- **下一项：P1.5-C/D。** 弹出/拖出独立窗口、保活迁移/收回、目标可见广播；随后 E/F，再进入 P2 Apple 真机验收。不得把标签+SFTP 并排当多终端分屏。
- **用户明确暂停 SFTP 新功能开发。** 保留现有功能，处理影响使用或数据安全的缺陷；不要再次连续扩展文件管理、递归下载或续传。
- 当前仍是**开发预览**，不是已验收日用版或 V1.0。构建成功、自动化通过与真机通过必须分开陈述。
- 项目存在**未提交修改和未跟踪文件**；最新功能不能仅从 Git HEAD 恢复。

## 2. 事实来源与阅读顺序

1. 本文：接手入口、当前快照、约束与操作方法。
2. [docs/ROADMAP.md](docs/ROADMAP.md)：当前阶段顺序与每次交付要求。
3. [docs/STATUS.md](docs/STATUS.md)：按版本倒序的完成情况、验证证据与未完成事项。
4. 当前任务对应的功能文档与源码。
5. [docs/CLOUDTERM_PLAN.md](docs/CLOUDTERM_PLAN.md)：2026-10-24补充的Cloud Term公开对标来源、203条跟踪项、平台/安全边界；公开内容8页，发布清单最新0.3.5，日志HTML仍0.3.3。它是未来计划，不是W Term交付记录。
6. [PLAN.md](PLAN.md)：长期原始目标，不代表所有功能已经实现，也不覆盖后来的范围调整。

**注意旧文档中的历史描述：**

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) 标题就是纵向原型架构，其中“不支持覆盖”“后续才做同步/密钥生成”等段落不是当前功能清单。
- [docs/VAULT.md](docs/VAULT.md) 前面的部分待办已被后面的版本章节实现；软件密钥生成和加密导出已经存在。
- [docs/SYNC_SETUP.md](docs/SYNC_SETUP.md) 早期章节与末尾版本补充并存；竞争恢复、换钥、仅本机范围和断开仓库均已有后续实现。
- ROADMAP 概览中“主要缺口”是宽泛阶段描述。判断某项是否已实现，结合其后版本记录、STATUS 最新章节和源码，不能只读概览。
- 发生冲突时，以用户最新指令和实际代码为准；文档中的“完成”需继续区分“实现完成”和“真实环境验收完成”。

当前专题索引：

- SSH：[MFA](docs/SSH_INTERACTIVE_AUTH.md)、[连接代理](docs/SSH_PROXY.md)、[跳板路线](docs/SSH_ROUTES.md)、[端口转发](docs/SSH_FORWARDING.md)、[标签与分屏](docs/WORKSPACE_TABS.md)。
- 同步：[数据协议](docs/SYNC.md)、[加密](docs/SYNC_CRYPTO.md)、[GitHub 传输](docs/SYNC_GITHUB.md)、[发件箱](docs/SYNC_OUTBOX.md)。
- 同步恢复：[冲突审阅](docs/SYNC_CONFLICTS.md)、[竞争恢复](docs/SYNC_RECOVERY.md)、[接入新密钥](docs/SYNC_KEY_ADOPTION.md)、[本机轮换](docs/SYNC_ROTATION.md)、[仅本机范围](docs/SYNC_SCOPE.md)、[断开/更换仓库](docs/SYNC_DISCONNECT.md)。

## 3. 工作区与版本管理

| 项目 | 交接时快照 |
| --- | --- |
| 本机目录 | `/Users/a5580/W term`，路径含空格，命令必须正确引用 |
| Git 分支 | `main` |
| HEAD | `c1891db`，提交标题 `update` |
| 应用版本来源 | `pubspec.yaml`：`0.1.48+49` |
| Bundle ID | `dev.wterm.wterm` |
| Rust crate | `wterm_core`，crate 版本仍为 `0.1.0`，不是应用显示版本 |
| 本机工具目录 | `.toolchains/`，含 Flutter、Rust/Cargo、Pub cache、Python 测试环境 |

**不要执行清空工作区、批量还原或删除未跟踪文件的操作。** 当前已有改动属于前序开发成果，不是待清理垃圾。本次交接没有提交或推送代码。

交接前就存在的未跟踪功能文件包括：

```text
docs/SSH_INTERACTIVE_AUTH.md
docs/SSH_PROXY.md
lib/app/interactive_auth.dart
lib/app/proxy_store.dart
lib/features/auth_challenge_dialog.dart
lib/features/proxy_dialog.dart
lib/src/rust/api/proxy.dart
rust/src/api/proxy.rs
rust/src/proxy.rs
rust/src/proxy/                    # 代理测试
rust/src/session/                  # MFA 实现及协议测试
test/interactive_auth_test.dart
test/proxy_dialog_test.dart
tests/smoke/interactive_auth_bridge_test.dart
tests/smoke/proxy_bridge_test.dart
```

此外，工作区中已有 bridge 生成文件、workspace、vault adapter、session、测试脚本、Python fixture、版本和文档的已跟踪修改。**迁移给另一台机器时，仅复制提交历史或 `git diff` 都不够，必须包含这些未跟踪源码。** 不要把真实保险库、令牌、证书私钥或凭证写进交接包。

接手第一步执行 `git status --short` 和 `git diff --stat`，重新核对当时状态。不要把这里的文件清单当作永久不变的清单。

## 4. 用户已确定的产品行为

- 主机树放在主界面左侧，支持文件夹、子文件夹、分类、标签、收藏及搜索；会话位于右侧顶部，标签占地小。
- 单击主机不连接、不打开编辑窗口；可以显示选中/悬停高亮。**双击直接连接**。菜单“编辑”打开主机编辑器，不能显示成新建连接。
- 删除文件夹提供两种选择：将整个子树的主机移到“未分类”，或删除这些主机；不要连带删除可复用身份。子文件夹内主机须正确缩进。
- 用户名与密码/私钥作为可复用身份管理，凭证加密落盘；已绑定身份的主机连接时无需反复输入，首次指纹确认、指纹变化和服务器 MFA 仍按规则处理。
- **iOS 切后台不应重新锁保险库。** 解锁会话在进程内保留，后台显示隐私遮罩；完全结束进程、系统杀进程后再打开才重新认证。用户手动锁定仍有效。
- 保险库生命周期与 SSH 生命周期不同：当前 iOS `paused` 会取消连接并断开已有 SSH/转发；返回后不自动重连、不自动重放命令。
- 支持 macOS Touch ID、iOS Face ID 快速解锁，同时保留主密码入口。不能为了消除错误而绕过真正的生物识别保护。
- 已有上传重名选择：替换、保留两个文件、取消；macOS 拖入文件面板上传到当前远端目录。历史 iOS 旧窗口/覆盖问题用户曾自行修复并编译，不要依据早期聊天再次回退现有实现。
- 用户倾向直接推进完整功能。收到“继续开发”时按当前路线完成核心、界面、测试、文档和构建；有明确“先不编译”等当次限制时遵从该限制。

## 5. 功能状态总览

| 模块 | 当前已有 | 尚未完成或限制 |
| --- | --- | --- |
| SSH/终端 | 真实密码/加密私钥连接，服务器指纹验证，多会话，输入/输出/尺寸，主题、搜索、片段 | 真实 OpenSSH、中文输入、vim/tmux、外接键盘、弱网及长连接验收 |
| 主机与身份 | 树形文件夹、增删改、标签/收藏/搜索、身份复用、常用 OpenSSH config 导入 | 导入不等于支持 OpenSSH 全部配置字段 |
| 保险库与密钥 | SQLCipher、主密码、软件 Ed25519 生成、导入、公钥读取、私钥独立加密导出、加密备份/恢复 | 不支持本地保险库主密码无损重置；同步恢复码不是本地保险库万能恢复码 |
| 快速解锁 | macOS Secure Enclave 加密封装；iOS 生物识别 Keychain | 真人认证、录入变化、锁定、重启及跨版本复用待设备验证 |
| SFTP | 文件浏览、已有上传下载/队列、重名处理、拖放、目录上传、权限/文本编辑等 | 新功能暂停；不能宣称完整续传、递归下载和目录对比已实现 |
| 终端/工作区（0.1.47/0.1.48） | 会话/视图分离；标签拖动排序/重命名/关闭；水平/垂直/嵌套分屏、比例、焦点、拆回/关闭窗格；标签拖到窗格边缘合并；左侧栏/文件面板可调宽与折叠；标签关闭只影响自身会话 | 弹窗/保活收回、广播、全局快捷键、重连/布局恢复未实现；真实设备手势/焦点待验收 |
| 解锁体验（0.1.48） | 启动自动 Touch ID/Face ID（取消不循环）、锁屏不叠加遮罩、生物弹窗期间抑制遮罩、解锁/resumed 立即清除 | 真实签名设备后台/解锁残留与自动弹窗待用户复核 |
| 端口转发（0.1.46） | 本地 -L、远程 -R、动态 SOCKS5 -D；默认回环、非回环需勾选确认；每会话 8 条/每条 32 并发；断链/停止清理；本机保存规则、搜索/编辑/删除/手动启停，保存不自动启动 | 规则不同步/不随业务恢复；SOCKS5 无认证且仅 TCP；自动启动/保活、Web 网关、UDP/VPN 未实现；真实 OpenSSH/GatewayPorts/压力待验收 |
| GitHub 同步 | 手动端到端加密同步、创建/接入、恢复码、持久冲突审阅、竞争恢复、换钥、轮换、本机范围、断开/更换仓库 | 真实私有仓库与双设备流程待验收；不支持后台自动同步、GitHub App、企业 GitHub |
| MFA（0.1.42） | 密码/私钥后 keyboard-interactive，多轮、echo、零输入轮、超时/取消；0.1.45 起可保存“仅交互式”无秘密身份 | 真实 OpenSSH/PAM/TOTP 与签名设备输入待验收 |
| 连接代理（0.1.43/0.1.45） | 默认 + 命名 HTTP CONNECT/SOCKS5、加密保存、代理解析目标域名、IPv4/IPv6、主机继承/直连/指定、分层 TCP/认证/目标测试 | 本机范围，不同步/不随业务恢复；无逐跳代理、HTTPS 代理或企业认证；不代理 GitHub |
| 多级跳板（0.1.44） | 已保存主机有序路线、逐跳指纹/MFA、路线隔离信任键、即时取消、整链清理；保存/删除/备份/同步引用闭包；第一跳可用主机绑定代理 | 跳板必须使用已保存身份；真实 OpenSSH 多跳/PAM/TOTP、弱网与签名真机待验收 |
| Windows / Android | 未创建应用实现 | 按平台顺序延后 |

### 最近交付

- **0.1.41（42）**：断开/更换 GitHub 仓库，保留业务与仅本机策略，未决发布等状态阻断断开。
- **0.1.42（43）**：MFA 完整调用链及本地真实协议验证。
- **0.1.43（44）**：连接代理完整调用链、加密配置、代理协议与真实桥接测试、低高度侧栏滚动。
- **0.1.44（45）**：多级跳板 P1-A、逐跳指纹/MFA、路线信任键、即时取消、整链清理、三机 fixture 与真实桥接。
- **0.1.45（46）**：持久仅交互式身份、命名/逐主机代理、继承/直连/指定绑定、分层连通测试、真实桥接与 UI。
- **0.1.46（47）**：本地/远程/动态转发、远端取消与清理、动态 SOCKS5、本机保存规则与手动启停。
- **0.1.47（48）**：会话/视图分离、标签拖动/重命名、嵌套分屏、拖拽落点合并、拆回/关闭窗格。
- **0.1.48（49）**：标签关闭隔离修复、左右面板调宽/折叠、左下折叠设置、自动生物识别、iOS 遮罩残留修复。
- **0.1.49（50）**：整标签拖动分屏、任意位置最近边缘落点、标签合并、右键/长按菜单、左右/上下双分屏与四宫格。
- **0.1.50（51）**：广播输入（当前标签/全部会话）、快捷键、已打开终端选择器、Windows vendored OpenSSL 构建。
- **0.1.51（52）**：断线窗格原位重连、无凭据布局恢复、macOS 关窗保活、MIT 协议与 Windows 版本号同步。
- **1.0.1（54）**：微软雅黑、三端圆角图标、Windows 安装程序、macOS DMG、启动命令/环境变量、服务器 Wiki、命令历史、系统监控、tmux、CSV 导入等。
- **1.0.2（55）**：终端 AI、插件/IP、PuTTY/INI 导入、SFTP 跟随/批量下载、主题字体、片段市场、固定命令条、分享图片。
- **1.0.3（56）**：多 AI 环境、8 套内置皮肤、自动更新检查、SSH 延迟显示。
- **1.0.4（57）**：文件预览插件、iOS 批量分享、延迟图表、URL 打开、更新包下载。
- **1.0.5（58）**：自定义终端主题编辑器、选中即复制、片段/分享快捷菜单、聚焦模式、定位主机、目录递归下载、可搜索主机图标、命令补全、5 分钟延迟与 CPU/内存图表。
- **1.0.6（59）**：AI 流式输出与只读工具自动多轮、任务完成通知、tmux 自动刷新/批量结束、进程排序筛选与结束 PID、端口筛选、Cmd/Ctrl+点击终端链接。
- **1.0.7（60）**：ZMODEM rz/sz 文件收发、Excel .xlsx 导入、103 条精选片段、命令历史主机/日期筛选。
- **1.0.8（61）**：macOS 独立终端窗口与 SSH 输出交接、更新包 SHA256 校验、PDF/媒体系统预览。
- **1.0.9（62）**：Windows 独立终端窗口（新引擎 + 插件注册 + 原生 handoff）、窗口关闭清理、Windows 多窗口构建验证。
- **1.0.10（63）**：CSV 密码列导入加密身份库、桌面托盘/菜单栏入口、Windows 窗口插件注册完善。
- **1.0.11（64）**：`wterm://connect` 深链接唤起快速连接、macOS/iOS URL Scheme、Windows 安装器协议注册。
- **1.0.12（65）**：本机自动加密备份（每日、保留 5 份、安全存储密钥）与恢复。
- **1.0.13（66）**：系统级任务完成通知、主机批量连接、独立临时终端入口。
- **1.0.14（67）**：终端关键字高亮、macOS/Windows 原生全局显示快捷键。
- **1.0.15（68）**：在线片段市场（128 条、缓存/刷新/校验）与市场添加入库。
- **1.0.16（69）**：OpenSSH 用户证书认证（证书+私钥合并保存、russh 证书登录、公钥导出兼容）。
- **1.0.17（70）**：桌面本地 Shell（真实 PTY、系统 shell、本地命令历史，隔离 SSH/SFTP 工具）。
- **1.0.18（71）**：Windows 静默更新安装/重启、可选 15 分钟自动加密同步（冲突不自动解决）。
- **1.0.19（72）**：Iconify 在线图标搜索/URL 主机图标、当前 shell 的 OSC 7 目录上报快捷注入。
- **1.0.20（73）**：macOS 终端聚焦自动切 ASCII 输入法（可关闭），离开恢复原输入法。
- **1.0.21（74）**：macOS 独立窗口收回主窗口（反向 handoff，不重连）。

## 6. 架构与关键入口

| 位置 | 责任 |
| --- | --- |
| `lib/main.dart`、`lib/features/vault_gate.dart` | 启动、保险库入口、隐私遮罩和工作区生命周期 |
| `lib/app/workspace.dart` | 左侧树/设置入口、右侧标签/窗格编排、逐跳连接、指纹确认、MFA 对话及取消 |
| `lib/app/terminal_session.dart` | 会话级 xterm 模型、SSH 输出/ACK、输入队列、resize 与结束状态；视图销毁不断链 |
| `lib/app/workspace_layout.dart` | 标签窗格树模型：会话收集、四边插入、嵌套、移除折叠、方向映射 |
| `lib/app/connection_route.dart` | 跳板路线展开、缺失/循环/深度校验、路线作用域信任键 |
| `lib/app/host_store.dart`、`identity_store.dart`、`vault_store.dart` | 业务模型/接口、`NativeVaultSession` 到 Rust 的适配 |
| `lib/features/hosts_page.dart`、`host_editor.dart`、`identities_pane.dart` | 主机树、主机编辑、身份/密钥管理 |
| `lib/features/terminal_pane.dart` | 终端视图：共享 `TerminalSession` 的 xterm 渲染、复制/粘贴/搜索/片段/外观、窗格操作菜单 |
| `lib/app/trust_store.dart` | 已信任指纹，独立于业务同步和备份恢复 |
| `lib/app/interactive_auth.dart`、`features/auth_challenge_dialog.dart` | MFA 问题轮询、回答及生命周期 |
| `lib/app/proxy_store.dart`、`features/proxy_dialog.dart` | 代理设置接口/页面 |
| `rust/src/api/forward.rs` | Flutter 可调用的转发 API：-L/-R/-D 启停、统一活动列表、本机规则 CRUD |
| `rust/src/forward_rules.rs` | 设备本地转发规则存储/校验（SQLCipher metadata，不同步/不随业务恢复） |
| `lib/app/forward_store.dart` | 会话转发与规则存储接口；工作区绑定连接 ID/主机 ID |
| `lib/features/forwarding_dialog.dart` | 转发类型、监听/目标、非回环警告、活动列表、规则搜索/编辑/启停 |
| `rust/src/api/{client,vault,forward,proxy,sync}.rs` | Flutter 可调用的强类型 API |
| `rust/src/session.rs` | SSH 传输、待确认/认证中/已连接登记、跳板父链与级联清理、探测取消、终端/SFTP 资源 |
| `rust/src/session/interactive.rs` | MFA 等待状态、连接/轮次绑定、一次性回答 |
| `rust/src/proxy.rs` | 默认/命名代理、HTTP/SOCKS5 协商、主机绑定、分层连通测试，返回可交给 SSH 的 TCP 流或测试结果 |
| `rust/src/api/vault.rs` | SQLCipher、会话 token、身份秘密、迁移、备份与恢复 |
| `rust/src/sync/` | 数据模型、三方合并、加密、发件箱、发布日志、GitHub、审阅、轮换、本机范围及断开 |
| `lib/app/quick_unlock.dart`、`macos/Runner/MacQuickUnlock.swift` | 快速解锁及 macOS 硬件保护封装 |
| `macos/Runner/BiometricSigningPolicy.swift` | 签名准入策略 |
| `hook/build.dart`、`hook/rust_inputs.dart` | 原生 Rust 编译、打包及完整依赖追踪 |
| `tests/fixtures/ssh_server.py` | 隔离 AsyncSSH + HTTP/SOCKS5 loopback 测试服务 |
| `tests/smoke/` | 加载真实 Rust 动态库的 Dart 桥接测试 |

### 当前连接调用链

```text
双击已保存主机 / 新建连接
  → Workspace.prepareConnection（必要时编辑身份与跳板路线）
  → buildRoute：展开 jumpHostIds，校验存在/循环/重复/最多 4 台跳板
  → 第 1 跳：probeWithHostProxy → config_for_host（继承默认 / 直连 / 指定命名代理）+ session.probe_hop
  → 后续跳：probeThrough(parent_id) → session.probe_hop 在上一跳 handle 上开 direct-tcpip
  → 每跳返回 connection_id 和 SHA256 指纹；Flutter 按路线信任键核对，新指纹确认，变化阻断
  → 跳板走 vault_authenticate_jump_identity（无 PTY/Shell）；目标走 identity 或临时 authenticate
  → 身份可为密码、私钥或“仅交互式”（无秘密，服务器逐次询问）
  → 每跳都可能进行多轮 keyboard-interactive/MFA
  → 目标 PTY/Shell 成功后登记终端会话；父链由该 Live 记录
  → 本地 -L / 动态 -D 在客户端监听并用 direct-tcpip；远程 -R 用 tcpip-forward 监听、forwarded-tcpip 回传
  → 断开目标/任一环节、锁库、取消、后台或销毁都会级联释放整条链和全部转发
```

探测另有 operation id，可在 SSH 握手/代理/跳板通道阶段即时取消。`probe_server` 直连 API 仍供不实现代理接口的 store 和部分测试使用；真实保险库工作区通过 `ConnectionProxyStore` 选择新链路。

### 生成代码

修改 `rust/src/api/` 公共接口后运行 `flutter_rust_bridge_codegen generate`。
生成文件位于 `lib/src/rust/` 和 `rust/src/frb_generated.rs`，**不要手改生成文件解决接口不匹配**。配置是 `flutter_rust_bridge.yaml`，FRB 固定为 `2.13.0`。

## 7. 必须保留的安全和数据规则

### SSH 与代理

- 探测只做握手；SSH 密码/私钥认证必须在指纹获准后，在**同一条传输**执行。禁止“先确认 A，再新连 B 后直接认证”。重密钥交换也必须保持服务器 key 一致。
- 指纹变化阻断，不能增加默认忽略或自动接受。主机证书目前在探测中明确拒绝。
- MFA 回答绑定连接和随机轮次 ID；过期、重复、跨连接、超限回答拒绝。答案不落库、不同步、不重放。
- 代理失败不得回退直连；目标域名由代理解析。代理凭证先发给代理，与之后的 SSH 认证凭证是两套不同数据。
- `connection_proxy_v1` 仅存于本机 SQLCipher 元数据，读取只返回“密码已保存”标记；改变代理类型、地址、端口或用户名后必须重新输入密码。
- 命名代理 `connection_proxies_v1`、主机绑定 `host_proxy_bindings_v1` 同样仅存本机，不进入同步或业务恢复；绑定为“direct”时必须真正直连，不得落入默认代理；指定代理缺失时拒绝连接，不回退默认或直连。
- 删除仍被现有主机使用的命名代理必须阻止；主机删除/同步后失效的绑定可清理，但不能把失效绑定当作继承处理。
- 分层测试只验证代理 TCP、代理认证、目标 TCP，不进行 SSH 握手或发送 SSH 凭证；错误信息不得回显代理响应正文或密码。
- 转发默认监听回环；非回环必须在界面显示外部暴露警告。动态 SOCKS5 无认证且仅 TCP；若绑定非回环，等于向可访问设备提供无认证代理。
- 远程 -R 只接受已注册端口的 `forwarded-tcpip` 通道；停止时先移除注册表/中止活动中继，再调用 `cancel-tcpip-forward`。断链时统一 `disconnect` 必须清理本地监听、动态监听、远端注册和活动 relay。
- 保存规则仅存本机 metadata，不进入同步/业务恢复；保存不等于启动，不自动监听。动态转发不要复用连接代理的入站实现，也不要把 SSH 凭证交给 SOCKS 客户端。
- 会话/视图：`TerminalSession` 拥有输出订阅、终端模型和断链；`TerminalPane`/标签/窗格只展示。移动视图不得调用 `disconnect`，关闭标签/窗格/工作区才释放会话。一个会话只能出现在一个窗格；分屏移动而非复制终端。
- 标签/窗格关闭：关闭标签会断开其中**且仅其中**的全部会话；关闭单个窗格只断开该会话。先从 `tabs`/`sessions` 移除视图与状态，再调用 `TerminalSession.close()`，不得在关闭过程中重建其他标签视图；确认框列出被断开的用户名@主机。弹窗/保活/广播未实现，不要声称 P1.5 已完成。
- 左侧栏/文件面板尺寸与折叠仅在本进程保存；左侧栏与右侧 FilesPane 的拖动条不得覆盖终端输入区域，折叠窄栏必须保留展开/新建/设置/锁定或显示/上传/刷新入口。
- 生物识别：仅在保险库已存在且已启用快速解锁时于首帧后自动尝试一次；取消/失败不得循环。锁屏和生物识别系统弹窗期间不显示隐私遮罩；成功解锁、resumed 和手动锁定立即清除 `hidden` 与 `vaultPrivacy`。
- HTTP Basic / SOCKS5 密码协议不加密到代理这一段，界面已有可信网络提示，不能宣称是 TLS 代理。
- 初始 TCP/代理/SSH/跳板通道建立各有 20 秒上限。探测现在有 operation id，可在握手阶段即时取消；连接 id 返回前的取消通过 `cancel_probe`，返回后通过断开对应待认证连接或整链根节点。
- 跳板：第一跳才应用全局代理；后续跳只允许通过上一跳 `direct-tcpip`，失败不得回退直连。每跳独立核对指纹并认证/MFA，跳板不打开 PTY/Shell。
- 跳板信任键：第一跳沿用 `host:port`；后续跳使用“上一跳端点 > … > 当前端点”的作用域键。不得把直连信任或另一条路线的信任自动复用到内网目标。
- 父链：每个 Pending/Live 记录 parent；断开任一环节会级联清理上下游；探测 120 秒未批准会清理整条链。不要在其他模块绕过 `session::disconnect` 直接删除登记。
- 断开、shell 结束和取消须释放通道/转发/等待问题；不要自动重放命令。

### 保险库与同步

- 当前本地保险库 schema 3，主机仅引用 `identityId`，秘密在独立身份表。旧 token 不能操作新解锁会话。
- 身份列表和编辑器不读回密码/私钥；没有明确替换时保留原凭证，使用时在 Rust 内取出。
- 备份恢复是“导入为新业务记录”：生成新 ID 并重映射引用，保留现有记录。**不是完整替换数据库**。
- 完整加密数据库导出包含元数据；恢复界面不复制同步绑定/密钥历史/代理配置。不要把当前同步恢复码说成全部历史密钥的备份。
- 同步冲突保留双方，用户审阅后才处理；确认时再次检查本机和远端状态。不得以最后时间戳简单覆盖。
- 禁止强制推送。发布结果未知时保留原批次/发件箱/日志，不能为了消除“待处理”删掉元数据。只有可证明未发布的普通批次才允许安全重新合并。
- 换钥/轮换须保留历史密钥和防回退检查；远端读回确认后才激活新密钥。恢复码一次性显示，不通过状态 API 读回。
- 仅本机策略需处理主机/身份依赖闭包；已同步项不能假装可以从远端历史撤回。
- 断开仓库仅解除本机绑定，保留业务及本机策略；不删除 GitHub 数据、不撤销令牌。待处理发布、轮换或冲突必须阻断。
- REST 快进保护不等于严格 CAS；外部强推竞态和分支规则仍是待验收边界。
- 使用临时保险库、合成凭证及隔离 fixture；不要将测试指向用户真实保险库、SSH 或 GitHub。真实环境验收需用户提供明确目标与授权。

## 8. macOS 签名和快速解锁：最容易误改的部分

详见 [docs/MACOS_SIGNING.md](docs/MACOS_SIGNING.md)。

1. 用户已在 Xcode 设置个人团队，并自己创建稳定的自签名证书。当前签名脚本是用户已验证的版本，默认身份 **`W Term Vault Code Signing`**。
2. 保留用户的 `scripts/build-macos-signed.sh`、Xcode 团队和 Bundle ID 配置。不要用 `.original.sh` 覆盖现脚本，不自动生成/更换证书。
3. 签名准入允许 Apple Development、Developer ID、稳定 self-signed identity；拒绝 unsigned / ad-hoc。不得重新添加必须具备 Apple Team ID 或专属 Keychain group 的门槛。
4. `xattr -rd com.apple.quarantine` 仅移除隔离属性，**不进行代码签名，也不修复钥匙串权限**。
5. 早期 `-34018` 根因是自签名版本的受保护 Keychain 访问权限。只放宽签名预检没有解决。macOS 0.1.36 起改成 **Secure Enclave P-256 + ECDH/HKDF + AES-GCM 本机凭证封装**，不走旧快速解锁 `SecItem` 路径。
6. 生物识别保护使用 `privateKeyUsage + biometryCurrentSet`，启用时真实解密成功后再原子保存；不降级到软件私钥或“先弹指纹再读明文密码”。iOS 的 Face ID/Keychain 路径保持独立。
7. macOS 封装文件 `biometric-unlock-v2.json` 位于应用 Application Support 下，0600、排除备份/同步；旧钥匙串项不自动迁移或删除。旧登记升级后需主密码解锁并重新启用。
8. 当前脚本是本机自签名流程，不做 Developer ID 公证；允许某类证书的运行时准入，不等于该脚本已经实现所有分发签名流程。

自动化只能证明加密封装、签名规则和部分硬件边界；真人 Touch ID 成功、取消、录入变化及升级复用仍需实测。不要把“已签名”写成“Touch ID 已验收”。

## 9. 开发环境与命令

### 初始化本机环境

使用 Bash 执行以下命令，所有命令从项目根目录运行：

```bash
cd '/Users/a5580/W term'
source scripts/env.sh
export RUSTUP_TOOLCHAIN=1.98.1-aarch64-apple-darwin
```

本机 Flutter 缓存版本为 `3.47.4`；CI 也配置该 Flutter 版本和 Rust `1.98.1`。`scripts/env.sh` 设置项目私有 Cargo/Rustup/Pub 路径和 loopback `NO_PROXY`。工具位于本地目录，不要因系统 PATH 缺少命令就判断项目不可构建。

保留锁文件；不要无任务依据升级 Flutter、Rust、FRB 或依赖。另一台机器需安装相应工具、Rust Apple targets、Xcode/SDK 及 `tests/requirements.txt` 的 Python 依赖，本机路径与证书不会随 Git 自动迁移。

**iOS 链接配置：** `.cargo/config.toml` 为 `aarch64-apple-ios` 链接 Xcode Clang 17 的 `libclang_rt.ios`，解决 SQLCipher 的 `___chkstk_darwin`。这是用户现有配置，不要删除。换 Xcode 后核对真实 compiler resource 目录再调整，不能机械复制其他机器的 Clang 路径。

### 修改接口后

```bash
flutter_rust_bridge_codegen generate
```

先完成源码编辑/生成/格式化，再测试和编译。不要一边改 Rust/生成文件，一边构建产物；不要并发启动多组 Flutter 构建/测试。

### 静态检查

```bash
cargo fmt --manifest-path rust/Cargo.toml -- --check
cargo clippy --manifest-path rust/Cargo.toml --locked --all-targets -- -D warnings
flutter analyze --no-pub
git diff --check
```

Dart 修改后对实际改动文件运行 `dart format`。按改动选择测试，不需要因只整理文档而重跑整套构建。

### 核心协议与真实桥接

```bash
WTERM_TEST_FORWARD_BRIDGE=1 bash scripts/test-core.sh
bash scripts/test-vault-bridge.sh
```

第一个脚本运行普通 Rust 测试，再运行依赖 fixture 的 ignored 测试；该环境开关虽然名为 FORWARD，但当前同时运行**转发、MFA、代理**三个真实桥接测试。第二个是独立保险库桥接测试。

Fixture 默认使用 `.toolchains/test-venv/bin/python`，SSH 监听 `127.0.0.1:22222`，代理使用随机 loopback 端口。端口占用时设置 `WTERM_TEST_PORT`，不要杀掉未知进程或启用系统 Remote Login。其他 Python 环境可通过 `WTERM_TEST_PYTHON` 指定。

常用 Flutter 回归组：

```bash
flutter test --no-pub \
  test/proxy_dialog_test.dart \
  test/workspace_layout_test.dart \
  test/credentials_and_folders_test.dart \
  test/interactive_auth_test.dart

# 修改同步时选择相关组，必要时扩展
flutter test --no-pub \
  test/sync_dialog_test.dart test/sync_conflicts_test.dart \
  test/sync_key_adoption_test.dart test/sync_rotation_test.dart \
  test/sync_scope_test.dart test/sync_disconnect_test.dart
```

快速解锁相关脚本：`scripts/test-macos-quick-unlock.sh`、`scripts/test-macos-signing.sh`。前者 `--hardware` 模式需要相应 Mac 硬件和本机身份；详细条件见签名文档，不要在交接时自动触发真人认证。

### 构建交付

```bash
# 顺序执行
bash scripts/build-macos-signed.sh
bash scripts/package-ios-unsigned.sh
```

Windows 构建必须在 Windows 主机执行（Visual Studio C++ + Rust）：`flutter build windows --release`；`.github/workflows/windows.yml` 会构建并用 `scripts/verify-windows-version.ps1` 校验 exe 的 FileVersion/ProductVersion 与 `pubspec.yaml` 一致。macOS 不能直接产出 Windows 二进制。

- macOS：`build/macos-signed/Build/Products/Release/W Term.app`。后续构建会覆盖同一路径。
- iOS：`build/ios/wterm-ios-<版本>-<构建号>-unsigned.ipa`。需要用户签名才能安装，不能称作已经可直接安装的签名版。
- 默认不安装或启动业务 App，不替换用户现用版本。
- `.github/workflows/apple.yml` 已存在，但主要是 Debug/模拟器构建；当前 CI 未设置 `WTERM_TEST_FORWARD_BRIDGE=1`，不能声称 CI 已运行这三项真实桥接或 Release 自签名验收。

### 不要只看到构建成功就交付

1. 核对 App/IPA 内 `Info.plist` 的版本和构建号，与 `pubspec.yaml` 一致。
2. macOS `codesign --verify --deep --strict` 检查完整签名，确认签名身份且不是 ad-hoc。
3. 核对包内 `wterm_core.framework/wterm_core` 来自最新源码；必要时用本轮实现的独特标记辅助检查，不能只看 App 文件时间。
4. 核对 `.dart_tool/hooks_runner/wterm/*/output.json` 的 dependencies 包含新增 Rust 文件的完整路径。路径含空格曾导致上游依赖解析漏掉源码，`hook/rust_inputs.dart` 正是为此保留的修复。
5. 检查 IPA ZIP 完整性及包内原生库与构建目录字节一致。
6. iOS `xcrun vtool -show-build` 可能输出 `LC_VERSION_MIN_IPHONEOS`，这是有效设备构建标志；不要只接受字面 `platform IOS` 而误判失败。也不能将模拟器库作为真机库。

## 10. 交接时的验证证据

以下是**本轮 2026-10-30（1.0.21）实际执行结果**，日志位于本机 `build/`：

| 证据 | 留存结果 |
| --- | --- |
| `build/p102-tests.log` | 118 项普通 Rust 通过；19 项 ignored fixture 通过；真实桥接通过（含系统监控与 detach 输出交接） |
| `build/flutter-tests-1.0.21.log` | **267 项** Flutter 全量测试通过（含窗口收回接线/输入法设置/在线图标/自动同步） |
| `build/vault-bridge-1.0.1.log` | 1 项真实保险库桥接通过 |
| `build/clippy-1.0.1.log`、`build/fmt-1.0.1.log`（1.0.4 未改 Rust 业务逻辑） | Rust 格式检查与 Clippy 通过 |
| `build/macos-signing-1.0.21.log` | macOS 自签名 Release 构建、严格签名验证通过 |
| `build/macos-dmg-1.0.21.log` | macOS UDZO DMG 打包完成 |
| `build/ios-build-1.0.21.log` | iOS Release 与 IPA 打包完成 |
| GitHub Actions `Windows preview` 41149755797 | Windows Release、版本校验、启动冒烟、Inno Setup 安装包与 Rust 测试/artifact 全部通过（含窗口收回代码） |

2026-10-30 核对三端版本均为 **1.0.21（74）**，当前存在：

```text
build/macos-signed/Build/Products/Release/W Term.app
build/release-1.0.21/wterm-macos-1.0.21-74.dmg
build/release-1.0.21/wterm-ios-1.0.21-74-unsigned.ipa
build/release-1.0.21/wterm-windows-1.0.21-74-setup.exe
build/release-1.0.21/wterm-windows-1.0.21-74-portable.zip
build/release-1.0.21/SHA256SUMS.txt
```

GitHub Release v1.0.21 已发布（上面 5 个附件 + 校验文件），三端包内版本一致。`build/detached-bridge.log` 保留真实 detach 桥接通过记录；Windows 独立窗口、托盘、深链接、系统通知、全局快捷键、静默安装、本地终端、在线图标与目录上报、macOS 窗口收回仅经 CI/本地构建；PTY 本地交互、静默安装/重启、自动同步、证书、在线市场、Iconify 搜索、macOS 输入法切换与窗口收回未在真实设备/网络执行。关键词高亮、在线市场/图标解析、目录上报命令、SSH 证书拆分、更新参数、插件设置由单元测试覆盖。

macOS 严格签名、IPA ZIP 完整性、iPhoneOS 平台标志、包内原生库与构建目录 SHA256 一致均已核对；Windows exe 版本由 CI 脚本校验，安装包由 Inno Setup 构建，CI 还执行了启动进程的冒烟检查。**未在 Windows 桌面实际交互、未在 Apple 真机验证雅黑/图标/DMG/安装和所有新功能**。Cloud Term 公开指南的逐项缺口见 [CLOUDTERM_FEATURE_AUDIT.md](docs/CLOUDTERM_FEATURE_AUDIT.md)；AI、插件、内置皮肤、云账号/团队/Web、导入格式完整覆盖等仍未实现，不能把 1.0.1 当作 Cloud Term 全功能等价或 P2 验收完成。0.1.51 及更早日志仅作历史证据。

## 11. 下一步如何推进

### 仍未关闭：P1.5-C 独立弹出窗口与 P2 真机验收

1. **独立弹出窗口/跨窗口迁移**：当前 Windows/macOS/iOS 客户端是单 Flutter 引擎；Rust `terminalOutput` 每连接只允许一个输出订阅，无法安全把活动 SSH 会话迁移到第二个引擎。需要先设计共享连接所有权、输出订阅交接（detach/re-attach 不触发 disconnect）和新窗口生命周期，再实现 macOS/iPad 多窗口。不要用重连冒充同一会话。
2. **P2 Apple 真机/日用**：真实 SSH/GitHub 双设备、Touch ID/Face ID、输入/外接键盘、后台/弱网、文件授权、迁移/诊断、至少四周日用仍待验收；不能因 1.0.0 构建成功跳过。
3. **Windows 验收**：在 Windows 10/11 实际启动 `wterm.exe`，验证 OpenSSL DLL 加载、保险库、SSH/MFA/代理/转发、SFTP、辅助键和输入法；当前只有 CI 构建与 Rust 测试证据。
4. **发布审计**：1.0.0 是用户要求的三端开发构建，不是已验收的日用 V1.0；发布说明必须保留 P1.5-C 和 P2 未完成声明。
4. **跨窗口**：不重复广播，目标 ACK 完成后再移除原视图；活跃任务提示与关闭确认。
5. 完成后补 E（基础快捷键/每窗格查找/统一已开终端选择器）与 F（手动重连/描述性布局恢复），再做 P2 真机验收。

### 接下来的顺序

执行采用2026-10-24路线P1–P13，以下为摘要，细项以[ROADMAP](docs/ROADMAP.md)与[对标计划](docs/CLOUDTERM_PLAN.md)为准：

1. P1 连接闭环（多级跳板、认证/代理、三类转发与规则）代码已完成（0.1.44–0.1.46）；P1.5-A/B 标签与分屏已交付（0.1.47）；当前做 P1.5-C/D 弹窗/保活/广播，再 E/F 与 P2 Apple 真机验收。
2. **新增P1.5日常终端工作区，Apple V1.0前必做**：会话/视图解耦、多标签拖动排序、水平/垂直及嵌套分屏、拖拽分屏/合并/拆回标签、macOS弹窗/保活收回、目标可见广播、基础快捷键/搜索/重连/布局恢复。用户明确这些是基础使用功能，不能延到Windows之后。iPad/iPhone按平台提供适配入口，不能把终端+SFTP并排当多终端分屏。
3. P2验收包含P1.5的完整Apple日用流程：真实GitHub双设备、Touch ID/Face ID、中文/删除键/辅助键、vim/tmux、外接键盘、旋转、文件授权、弱网、进程中断、升级迁移及至少四周日用。P3 Apple V1.0验收后再开发Windows；P4保留模板、参数化片段/历史、更多导入与资产效率增强。
4. P5保留文件增强候选，但SFTP仍暂停，未经用户明确恢复不得自动开工；P6监控/Docker/tmux，P7其他协议/Redis，P8外观/云资源包/快捷键与内置插件，P9受控AI，P10个人同步/备份扩展。
5. P11账号/组织/运营、P12Web需要单独立项，明确服务模式、成本与密钥/租户边界，不自动开建SaaS；P13再评估硬件、兼容与Android。

公开目录素材不等于获得再分发许可；本项目保留Flutter + Rust、原创资源与安全等效流程。新对标能力不应抢占当前连接闭环和真实验收。

## 12. 每次接手与交付清单

- [ ] 阅读本文、ROADMAP、STATUS 最新章节；确认用户这次是开发、修复、整理文档还是要求暂停。
- [ ] 查看当前未提交/未跟踪文件；保留用户签名脚本、Xcode 配置、`.cargo/config.toml` 和已有成果。
- [ ] 选择一个完整流程，说明本轮范围，不重新从零搭工程，不扩展已暂停的 SFTP。
- [ ] 核心/界面/桥接同时推进；公共接口变化后生成代码，避免业务模型漏改同步/备份。
- [ ] 跑与变更相关的单元、协议和桥接检查；故障明确定位，不能用模拟替代真实桥接。
- [ ] 功能交付按路线完成双端构建及包内核验；文档整理等任务无需无关重编译。
- [ ] 更新 STATUS，写清版本、入口、限制、测试和未验收项；需要时更新 ROADMAP 与专题文档。
- [ ] 用中文简洁交付：做了什么、哪里进入、验证到哪一步、产物路径、下一步。

### 可直接发给接手 AI 的提示词

```text
请接手 /Users/a5580/W term。先读取 AI_HANDOFF.md、docs/ROADMAP.md、
docs/STATUS.md 最新章节，并核对 git status 和实际源码。当前交接版本为
0.1.48+49，标签/分屏、面板折叠、自动生物识别、多级跳板、持久交互式身份、
命名代理、三类转发等最新功能有未提交及未跟踪文件，不要重置或清理它们。保留用户自签名脚本、Xcode
团队设置和 .cargo/config.toml。平台顺序是 macOS/iOS → Windows → 最后评估
Android；SFTP 新功能暂停。
如当前代码没有更新的安排，从 P1.5-C/D 开始：弹出/拖出窗口、保活收回、
目标可见广播输入；完成后补 P1.5-E/F。复用 Flutter + Rust 架构，完成核心、
UI、实际桥接、测试、文档与双端构建。
不得跳过指纹核验、代理失败回退直连、强推同步或清除未知发布结果。
测试使用隔离 fixture，不访问真实保险库/服务器/仓库；没有真机证据就明确写待验收。
```


## 13. 1.0.21 收尾审计（2026-10-31）

- 三端版本 **1.0.21（74）**；发布 https://github.com/WuBarlynn/W-term/releases/tag/v1.0.21 ；本地产物 `build/release-1.0.21/`。
- 验证：Flutter 267 项、Windows CI 41149755797、macOS 自签名严格校验、DMG、iOS IPA。截图/真机交互未验收。
- 未完成项以 [CLOUDTERM_FEATURE_AUDIT.md](docs/CLOUDTERM_FEATURE_AUDIT.md) 的“1.0.21 仍未完成”为准；不得把当前构建称为 Cloud Term 全功能等价或最终 V1.0。下一步优先：真机/Windows 交互验收、iPad/Windows 多窗口收回、Gist/S3 与团队/云服务立项评估。

## 14. 1.0.22 分屏/广播/更新/字体（2026-10-31）

- 三端版本 **1.0.22（75）**；本地产物 `build/release-1.0.22/`；发布 https://github.com/WuBarlynn/W-term/releases/tag/v1.0.22 。
- 分屏：每个窗格标题可拖到其他窗格边缘/标签，窗格内部可重排；分隔条按像素自由拖动、双击恢复均分；标签菜单新增“拆分所有窗格为标签”，无需断开连接。修复了窗格重建后广播失效的问题：输入广播移到 `TerminalSession`，目标在按键时动态解析；终端协议回复不再被广播到其他会话。
- 更新：仅 macOS/Windows 桌面端显示“检查更新（GitHub）”；启动 6 秒后自动查询 GitHub Release，解析 DMG/EXE 资产，SHA256 校验后 macOS 打开 DMG、Windows 静默安装并重启；iOS 不显示入口。
- 字体：内置 JetBrains Mono（常规/粗体）与 Noto Sans SC，界面/终端/CJK 字体改为可搜索选择并枚举 macOS/iOS/Windows 系统字体；Windows 界面默认微软雅黑 UI，终端默认 Cascadia Mono，CJK 回退优先微软雅黑。
- 验证：`build/flutter-tests-1.0.22-final.log` **275 项** Flutter 测试通过，`flutter analyze` 无问题；macOS 自签名 Release + 严格签名校验、DMG；iOS Runner.app/IPA 版本 1.0.22（75）；Windows CI **41157390012** 成功（Release 构建、启动冒烟、Inno Setup、Rust cargo 测试），安装包 1.0.22（75）。
- 未执行/限制：分屏拖拽/分隔条、广播多真实 SSH 会话、Touch ID/Face ID、Windows 安装升级与 GitHub 更新下载均未在真机/真实网络点击验收；仅完成代码、单元/组件测试与构建级验证。Cloud Term 剩余差距仍以 `docs/CLOUDTERM_FEATURE_AUDIT.md` 的“1.0.22 仍未完成”为准，不得宣称全功能等价或最终 V1.0。

## 15. 1.0.23 fish 目录上报与 Markdown 预览（2026-10-31）

- 三端版本 **1.0.23（76）**；本地产物 `build/release-1.0.23/`；发布 https://github.com/WuBarlynn/W-term/releases/tag/v1.0.23 。
- 目录上报：启用对话框可选 bash/zsh 或 fish；fish 通过 `--on-event fish_prompt` 注入 OSC 7，不修改远程启动文件。仍没有自动探测当前 shell。
- 文件预览：SFTP 文本预览识别 `.md/.markdown/.mdown`，默认 Markdown 渲染并可切源码；Markdown 链接仅允许 http/https 外开；图片仍由 Markdown 组件按文档加载。
- 验证：`build/flutter-tests-1.0.23.log` **277 项** Flutter 测试通过，`flutter analyze` 无问题；macOS 自签名 Release + DMG；iOS IPA 版本 1.0.23（76）；Windows CI 41158687700 成功（构建/启动冒烟/Inno Setup/Rust 测试），版本 1.0.23（76）。
- 未执行：fish 真实远端、Markdown 复杂文档/图片/链接、Windows 安装升级与真机 UI 点击。Cloud Term 剩余差距仍以审计文档“1.0.23 仍未完成”为准。

## 16. 1.0.24 按主机标签绑定固定命令（2026-10-31）

- 三端版本 **1.0.24（77）**；本地产物 `build/release-1.0.24/`；发布 https://github.com/WuBarlynn/W-term/releases/tag/v1.0.24 。
- 固定命令：`PinnedCommand` 增加 `tag` 字段；在带标签的主机中固定选中命令时可选择全局、仅当前主机或某个主机标签；`forHost(hostId, tags:)` 按当前主机标签动态显示，标签固定不会出现在没有该标签的主机；持久化与去重包含 tag。
- 验证：`build/flutter-tests-1.0.24.log` **278 项** Flutter 测试通过，`flutter analyze` 无问题；macOS 自签名 Release + DMG；iOS IPA 1.0.24（77）；Windows CI 41160793313 成功（构建/启动冒烟/Inno Setup/Rust 测试），安装包 1.0.24（77）。
- 未执行：标签绑定在真实多主机/真机点击验证；片段仍不能按标签过滤，右侧 Dock 未实现。Cloud Term 剩余差距以审计文档“1.0.24 仍未完成”为准。

## 17. 1.0.25 Windows 独立窗口收回（2026-10-31）

- 三端版本 **1.0.25（78）**；本地产物 `build/release-1.0.25/`；发布 https://github.com/WuBarlynn/W-term/releases/tag/v1.0.25 。
- 收回：新增 `SessionHandoffPayload` 统一载荷；Windows 独立窗口在“收回主窗口”时先 `detachForHandoff`，再通过 `WindowMethodChannel('dev.wterm/window-recall', unidirectional)` 把连接 ID/快照/hostId 交还主引擎；主工作区注册处理器，恢复标签并聚焦主窗口，Rust 连接不重连。失败时原窗口重新 attach 并提示。
- 主窗口未解锁（Workspace 未注册通道）时安全拒绝并回滚；macOS 原 native 收回路径复用同一载荷与解析逻辑，并补回 hostId 以恢复主机档案。
- 验证：`build/flutter-tests-1.0.25.log` **280 项** Flutter 测试通过，`flutter analyze` 无问题；macOS 自签名 Release + DMG；iOS IPA 1.0.25（78）；Windows CI 41162577816 成功（含 Windows 编译 WindowMethodChannel 路径、启动冒烟、Inno Setup、Rust 测试）。
- 未执行：真实 Windows 双窗口收回点击、Windows 关闭保活/托盘组合、iPad 多窗口；Windows 收回只验证到编译与启动。Cloud Term 剩余差距以审计文档“1.0.25 仍未完成”为准。

## 18. 1.0.26 字体导入（2026-10-31）

- 三端版本 **1.0.26（79）**；本地产物 `build/release-1.0.26/`；发布 https://github.com/WuBarlynn/W-term/releases/tag/v1.0.26 。
- 字体：外观设置新增本地文件导入与 http/https URL 安装；TTF/OTF/TTC、≤32 MB、校验 sfnt 文件头、名称去控制字符/限长；字体复制到应用支持目录并用 `FontLoader` 注册，启动自动加载，可删除。字体列表合并内置、系统枚举与已导入字体。
- 范围：用户明确 **云同步暂时不用，只用 GitHub 同步**；Cloud Term 云账号、团队协作、Gist/S3、Web 端从当前交付目标移除，仅保留 GitHub 私有仓库加密同步、本机备份与恢复。审计文档已加范围调整说明。
- 验证：`build/flutter-tests-1.0.26.log` **282 项** Flutter 测试通过，`flutter analyze` 无问题；macOS 自签名 Release + DMG；iOS IPA 1.0.26（79）；Windows CI 41164117553 成功（构建/启动冒烟/Inno Setup/Rust 测试）。
- 未执行：真实设备文件选择、URL 字体下载与渲染、字体授权/损坏文件样本；字体导入只覆盖单元/组件测试。

## 19. 1.0.27 Windows 输入法自动切换与广播回归（2026-10-31）

- 三端版本 **1.0.27（80）**；本地产物 `build/release-1.0.27/`；发布 https://github.com/WuBarlynn/W-term/releases/tag/v1.0.27 。
- Windows：主窗口注册 `dev.wterm/biometrics` 原生通道，终端聚焦时用 `ImmGetContext/ImmGetConversionStatus/ImmSetConversionStatus` 切到 ASCII，失焦/关闭时恢复进入前转换状态；跟随插件设置 `imeAutoEnglish`。Detached Windows 窗口未注册该原生通道，自动切换仅作用于主窗口。
- 广播回归：删除 `TerminalPane.dispose` 中遗留的 `terminal.onOutput = session.send`，新增 `terminal_pane_input_route_test.dart`，验证窗格销毁后输入仍经过会话层广播路由。
- 验证：`build/flutter-tests-1.0.27.log` **283 项** Flutter 测试通过，`flutter analyze` 无问题；macOS 自签名 Release + DMG；iOS IPA 1.0.27（80）；Windows CI 41165695844 成功（IME 原生代码编译、启动冒烟、Inno Setup、Rust 测试）。
- 未执行：Windows 微软拼音/其它输入法实机切换与恢复、Detached 窗口输入法、真实终端广播多会话点击。

## 20. 1.0.28 多选下载队列（2026-10-31）

- 三端版本 **1.0.28（81）**；本地产物 `build/release-1.0.28/`；发布 https://github.com/WuBarlynn/W-term/releases/tag/v1.0.28 。
- 文件：桌面多选下载会创建 `DownloadBatch`，选择一次本地目录后后台逐项执行；下载队列对话框显示等待/下载中/完成/失败/取消与详情，可取消剩余（当前文件完成后停止），文件面板不再被 `busy` 锁住，可继续浏览并重新打开队列。
- 限制：队列仍归当前 FilesPane/标签所有，换标签或关闭窗格会停止后续项；无百分比进度、无失败重试、无跨标签统一队列。
- 验证：`build/flutter-tests-1.0.28.log` **285 项** Flutter 测试通过，`flutter analyze` 无问题；macOS 自签名 Release + DMG；iOS IPA 1.0.28（81）；Windows CI 41167515357 成功（构建/启动冒烟/Inno Setup/Rust 测试）。
- 未执行：真实远端批量下载与并发浏览、目录递归队列、取消时机、Windows 安装升级。

## 21. 1.0.29 精确命令完成通知（2026-10-31）

- 三端版本 **1.0.29（82）**；本地产物 `build/release-1.0.29/`；发布 https://github.com/WuBarlynn/W-term/releases/tag/v1.0.29 。
- 通知：`TerminalSession` 解析 OSC 133;D（携带退出码），`TaskMonitor.commandFinished` 立即完成任务；通知正文显示退出码。终端菜单新增“命令完成通知钩子”，可选 bash/zsh/fish 注入 OSC 133;D；空闲启发式保留为回退。同时补上缺失的“目录上报（文件跟随）”菜单入口。
- 验证：`build/flutter-tests-1.0.29.log` **288 项** Flutter 测试通过，`flutter analyze` 无问题；macOS 自签名 Release + DMG；iOS IPA 1.0.29（82）；Windows CI 41169000225 成功（构建/启动冒烟/Inno Setup/Rust 测试）。
- 未执行：真实 bash/zsh/fish 远端钩子、已有 shell 集成的退出码、通知点击定位；钩子需用户在终端菜单手动安装且只作用于当前会话。

## 22. 1.0.30 Windows 输入与自动更新热修复（2026-10-31）

- 三端版本 **1.0.30（83）**；本地产物 `build/release-1.0.30/`；发布 https://github.com/WuBarlynn/W-term/releases/tag/v1.0.30 。
- Windows 输入：回退 1.0.27 的 `ImmSetConversionStatus` 原生自动切换；该实现会阻断 Flutter Windows 文本输入。移除 `dev.wterm/biometrics` Windows IME 通道、`SetAsciiInput` 与 `imm32` 链接；Dart 仅在 macOS 调用输入法自动切换。Windows 恢复 Flutter 默认输入法行为。
- Windows 更新：下载并 SHA256 校验后，先启动独立 PowerShell 助手（等待 2 秒），应用随后退出；助手用 `/VERYSILENT /SUPPRESSMSGBOXES /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS` 安装。安装器 `[Run]` 移除 `skipifsilent`，静默安装完成后自动启动新版。解决应用未退出导致文件锁定/安装器静默失败的问题。
- 验证：`build/flutter-tests-1.0.30.log` **288 项** Flutter 测试通过，`flutter analyze` 无问题；macOS 自签名 Release + DMG；iOS IPA 1.0.30（83）；Windows CI 41170799293 成功（移除 IME 代码后构建/启动冒烟/Inno Setup/Rust 测试）。
- 未执行：Windows 实体机打字（含中文 IME）复测、自动更新从旧版安装到新版并自动启动的端到端验证；这两项需用户在真实 Windows 环境确认。

## 23. 1.0.31 PDF 内嵌预览与 Windows 静默安装 CI（2026-10-31）

- 三端版本 **1.0.31（84）**；本地产物 `build/release-1.0.31/`；发布 https://github.com/WuBarlynn/W-term/releases/tag/v1.0.31 。
- PDF：SFTP 选中 `.pdf` 时通过 `native.downloadFile` 下载到临时目录，用 pdfrx/PDFium 内嵌渲染，限制 100 MB，关闭后删除临时文件；文本/Markdown/图片预览保留。iOS IPA 因此增至约 52 MB。
- Windows 安装 CI：新增 `scripts/test-windows-installer.ps1`，在 GitHub Windows runner 上实际静默安装到临时目录、等待 wterm.exe、杀掉安装器自动启动的进程并静默卸载。Windows CI 41173520983 通过该步骤。
- 注意：1.0.30 已回退阻断输入的 Windows IME 原生切换，并将更新改为“退出后独立 PowerShell 安装器 + VERYSILENT + 安装后启动”；1.0.31 沿用。自动更新从旧版本到新版本的完整链路与 Windows 实体机输入仍需用户复测。
- 验证：`build/flutter-tests-1.0.31.log` **289 项** Flutter 测试通过，`flutter analyze` 无问题；macOS 自签名 Release + DMG；iOS IPA 1.0.31（84）；Windows CI 41173520983 成功（pdfrx Windows 构建、启动冒烟、Inno Setup、静默安装/卸载冒烟、Rust 测试）。
- 未执行：真实 PDF 文件在 macOS/iOS/Windows 的渲染与滚动、超 100 MB 拒绝、Windows 输入与自动更新端到端点击。

## 24. 1.0.32 Windows 输入兼容与 PDF 预览适配（2026-10-31）

- 三端版本 **1.0.32（85）**；本地产物 `build/release-1.0.32/`；发布 https://github.com/WuBarlynn/W-term/releases/tag/v1.0.32 。
- Windows 输入：插件设置新增“Windows 硬件键盘输入”（默认关闭）。开启后 TerminalView 使用 `hardwareKeyboardOnly`，绕过 Flutter 文本输入/IME，用于输入法异常时恢复打字；中文组字可能不可用。1.0.30 已移除会阻断输入的 Windows IME 原生切换。
- PDF：预览对话框按屏幕尺寸自适应（手机/iPad 不再固定 920×720）；PDFium 内嵌渲染与 100 MB 限制沿用 1.0.31。
- 验证：`build/flutter-tests-1.0.32.log` **289 项** Flutter 测试通过，`flutter analyze` 无问题；macOS 自签名 Release + DMG；iOS IPA 1.0.32（85）；Windows CI 41175238616 成功（pdfrx 构建、启动冒烟、Inno Setup、静默安装/卸载冒烟、Rust 测试）。
- 未执行：Windows 实体机正常输入与兼容模式、中文 IME、PDF 真机渲染、从旧版本自动更新端到端。

## 25. 1.0.33 右侧固定命令 Dock（2026-10-31）

- 三端版本 **1.0.33（86）**；本地产物 `build/release-1.0.33/`；发布 https://github.com/WuBarlynn/W-term/releases/tag/v1.0.33 。
- 终端宽度 ≥1200 且当前主机/标签存在固定命令时，右侧显示纵向 Dock：点击发送命令，长按确认移除；窄窗口继续使用底部 chip 条，二者不重复显示。
- 组件测试 `terminal_pane_input_route_test.dart` 覆盖宽窗口 Dock 渲染。
- 验证：`build/flutter-tests-1.0.33.log` **290 项** Flutter 测试通过，`flutter analyze` 无问题；macOS 自签名 Release + DMG；iOS IPA 1.0.33（86）；Windows CI 41177156729 成功（pdfrx 构建、启动冒烟、Inno Setup、静默安装/卸载冒烟、Rust 测试）。
- 未执行：真实窗口缩放、Dock 点击/长按、标签绑定的多主机切换。

## 26. 1.0.34 跨标签下载队列（2026-10-31）

- 三端版本 **1.0.34（87）**；本地产物 `build/release-1.0.34/`；发布 https://github.com/WuBarlynn/W-term/releases/tag/v1.0.34 。
- 下载队列提升为应用级 `downloadQueue`：切换标签或关闭原文件面板后继续执行，任意文件面板可通过“传输任务”重新打开队列并取消剩余；上传任务仍属当前文件面板。
- 执行器仍由发起下载的 FilesPane state 闭包持有，应用退出即停止；不跨重启恢复，无百分比进度与失败重试。
- 验证：`build/flutter-tests-1.0.34.log` **291 项** Flutter 测试通过（含应用级队列测试），`flutter analyze` 无问题；macOS 自签名 Release + DMG；iOS IPA 1.0.34（87）；Windows CI 41178684577 成功（构建/启动冒烟/Inno Setup/静默安装卸载/Rust 测试）。
- 未执行：真实远端跨标签并发下载、关闭文件面板后的完成状态刷新、Windows 实体机输入与自动更新。

## 27. 1.0.35 终端链接自动下划线（2026-10-31）

- 三端版本 **1.0.35（88）**；本地产物 `build/release-1.0.35/`；发布 https://github.com/WuBarlynn/W-term/releases/tag/v1.0.35 。
- 终端输出中的 http/https 链接在可见行绘制下划线：按 TerminalView 的 `renderTerminal.getOffset` 定位，随输出、滚动和尺寸变化重绘；备用缓冲区跳过；插件设置“终端链接自动下划线”默认开启，可关闭。
- 新增 `terminal_links.dart` 纯逻辑（末尾标点/括号修剪、超长行保护）与 3 项测试；终端组件测试覆盖覆盖层存在。
- 验证：`build/flutter-tests-1.0.35.log` **295 项** Flutter 测试通过，`flutter analyze` 无问题；macOS 自签名 Release + DMG；iOS IPA 1.0.35（88）；Windows CI 41180550899 成功（构建/启动冒烟/Inno Setup/静默安装卸载/Rust 测试）。
- 未执行：真实长行/换行链接、多屏滚动、备用缓冲区切换与不同字体的像素级下划线位置；Windows 实体机输入与自动更新仍待用户复测。

## 28. 1.0.36 自动 shell 探测（2026-10-31）

- 三端版本 **1.0.36（89）**；本地产物 `build/release-1.0.36/`；发布 https://github.com/WuBarlynn/W-term/releases/tag/v1.0.36 。
- 目录上报与命令完成通知对话框新增“自动检测”：`TerminalSession` 解析 OSC 9 `shell;<path>`，TerminalPane 按 bash/zsh/fish 自动发送对应钩子；4 秒无响应提示手动选择。探测使用 `$SHELL`（登录 shell），嵌套/不一致时可能误判。
- 修复：自动探测/自动注入使用 `session.send` 而非广播输入，避免把设置命令发给广播目标。
- 验证：`build/flutter-tests-1.0.36.log` **296 项** Flutter 测试通过，`flutter analyze` 无问题；macOS 自签名 Release + DMG；iOS IPA 1.0.36（89）；Windows CI 41181756085 成功（构建/启动冒烟/Inno Setup/静默安装卸载/Rust 测试）。
- 未执行：真实 bash/zsh/fish 远端 OSC 9 探测与钩子安装、Windows 实体机输入/自动更新。

## 29. 1.0.37 片段标签（2026-10-31）

- 三端版本 **1.0.37（90）**；本地产物 `build/release-1.0.37/`；发布 https://github.com/WuBarlynn/W-term/releases/tag/v1.0.37 。
- Rust `Snippet` 新增 `tags`（`#[serde(default)]` 兼容旧记录），`vault_save_snippet` 接收标签并校验最多 20 个、单个 ≤48 字节、无控制字符；Flutter/Rust 绑定已用 FRB 2.13.0 重新生成。
- Dart：`CommandSnippet.tags`、`SnippetStore.saveSnippet(tags:)`、保险库读写；片段编辑器新增逗号分隔标签；片段列表显示标签，可用当前主机标签或片段标签筛选。
- 验证：`build/flutter-tests-1.0.37.log` **297 项** Flutter 测试通过，`flutter analyze` 无问题；Rust `snippets_are_encrypted_backed_up_and_reject_control_characters` 通过；macOS 自签名 Release + DMG；iOS IPA 1.0.37（90）；Windows CI 41183500739 成功（构建/启动冒烟/Inno Setup/静默安装卸载/Rust 全量测试）。
- 未执行：真实多主机标签筛选、旧保险库升级后的标签显示、同步/备份跨设备标签一致性；Windows 实体机输入/自动更新仍待用户复测。

## 30. 1.0.38 Office 文本预览（2026-10-31）

- 三端版本 **1.0.38（91）**；本地产物 `build/release-1.0.38/`；发布 https://github.com/WuBarlynn/W-term/releases/tag/v1.0.38 。
- SFTP 选中 docx/xlsx/pptx 时下载到临时文件，本地解析 OOXML：docx 段落、xlsx 首个工作表（共享字符串/数字/内联字符串）、pptx 幻灯片文本；≤50 MB，输出限制 300k 字符，复杂排版/图片/公式不保留。
- 旧版 .doc/.xls/.ppt 仍走系统打开；临时文件在关闭预览后删除。
- 验证：`build/flutter-tests-1.0.38.log` **301 项** Flutter 测试通过（含自建 ZIP 的 docx/xlsx/pptx 解析测试），`flutter analyze` 无问题；macOS 自签名 Release + DMG；iOS IPA 1.0.38（91）；Windows CI 41185043886 成功（构建/启动冒烟/Inno Setup/静默安装卸载/Rust 测试）。
- 未执行：真实 Office 文件（复杂表格、合并单元格、多工作表、加密文档）与三端真机渲染；Windows 实体机输入/自动更新仍待复测。

## 31. 1.0.39 Windows 等宽字体回退与链接下划线加固（2026-10-31）

- 三端版本 **1.0.39（92）**；本地产物 `build/release-1.0.39/`；发布 https://github.com/WuBarlynn/W-term/releases/tag/v1.0.39 。
- 字体：新增 `monoFontFallback`（Cascadia Mono → SF Mono → Menlo → Consolas → monospace），应用到终端搜索、命令历史、系统监控、远程文本编辑、AI/片段/文件预览等仍硬编码 Menlo/monospace 的区域；Windows 不再回退到比例字体造成列错位。UI/终端主字体设置保持原样。
- 链接下划线：获取 TerminalView 渲染对象时增加异常保护，布局切换帧直接跳过，避免新覆盖层在极早帧抛错。
- 验证：`build/flutter-tests-1.0.39.log` **301 项** Flutter 测试通过，`flutter analyze` 无问题；macOS 自签名 Release + DMG；iOS IPA 1.0.39（92）；Windows CI 41186496288 成功（构建/启动冒烟/Inno Setup/静默安装卸载/Rust 测试）。
- 未执行：Windows 实体机等宽字体/终端显示、链接下划线像素位置；Windows 输入与自动更新仍待用户复测。

## 32. 1.0.40 上传选项（2026-10-31）

- 三端版本 **1.0.40（93）**；本地产物 `build/release-1.0.40/`；发布 https://github.com/WuBarlynn/W-term/releases/tag/v1.0.40 。
- 插件设置新增“拖拽上传”开关与单文件大小上限（不限/50/100/500/1024/2048 MB）；macOS 与 Windows 均可拖入文件/文件夹，超限文件在上传前拒绝并逐项标记失败。
- 覆盖/保留并自动重命名/跳过冲突选项保留；“隐藏回显”不适用于 SFTP，未单独实现。
- 验证：`build/flutter-tests-1.0.40.log` **301 项** Flutter 测试通过，`flutter analyze` 无问题；macOS 自签名 Release + DMG；iOS IPA 1.0.40（93）；Windows CI 41188182230 成功（构建/启动冒烟/Inno Setup/静默安装卸载/Rust 测试）。
- 未执行：真实拖拽（含 Windows）、超限大文件、文件夹拖拽与冲突选择；Windows 实体机输入/自动更新仍待复测。

## 33. 完成度审计校正（2026-10-31）

已完成并有三端构建/CI/测试证据：三平台发布与校验；Windows 安装包/静默安装 CI、独立窗口收回、输入兼容开关、等宽字体回退；macOS 自签名 DMG、窗口收回；字体枚举/内置/导入；PDF 与 OOXML 文本预览；右侧固定命令 Dock；跨标签下载队列；链接自动下划线；OSC 133 精确通知；自动 shell 探测；片段标签。

仍不能标记完成：iPad 多窗口、ZMODEM 真实 lrzsz 互操作、Office 原排版渲染、在线字体市场、Linux 输入法、Windows/macOS 双架构、完整进程/端口操作实测，以及 Windows/Apple 真机日用验收。云同步按用户指示仅保留 GitHub，不作为缺口。

## 41. 1.0.48 快捷键设置与完整文本导出（2026-10-31）

- 三端版本 **1.0.48（101）**。
- 新增 `ShortcutSettings` 与 `ShortcutSettingsDialog`；可配置 new/close-tab/prev-tab/next-tab/sessions，绑定随设置同步。
- TerminalPane 先匹配自定义绑定，再处理收藏数字键；Workspace 顶层 CallbackShortcuts 使用同一绑定。
- 分享图片新增完整缓冲区文本导出（.txt），模板图片仍限制 36 行。
- 验证：Flutter **318 项**与 `flutter analyze` 通过；macOS DMG、iOS IPA 完成；Windows CI [41214502777](https://github.com/WuBarlynn/W-term/actions/runs/41214502777) 成功。发布包位于 `build/release-1.0.48/`。

## 40. 1.0.47 实时状态栏与终端外观选项（2026-10-31）

- 三端版本 **1.0.47（100）**。
- TerminalPane 每 10 秒通过独立 exec 通道采样延迟/CPU/内存；`showStatusBar` 可关闭。
- TerminalAppearance 新增 `cursorStyle`、`bottomPadding`、`scrollback`；回滚行数只在创建会话时读取。
- 验证：Flutter **316 项**与 `flutter analyze` 通过；macOS DMG、iOS IPA 完成；Windows CI [41211222082](https://github.com/WuBarlynn/W-term/actions/runs/41211222082) 成功。发布包位于 `build/release-1.0.47/`。

## 39. 1.0.46 分享图片模板（2026-10-31）

- 三端版本 **1.0.46（99）**。
- 新增 `TerminalShareDialog`：终端窗口/渐变卡片/极简纯色，深色/浅色、行号、水印、标题、保存与系统分享。
- 保留原有快速终端截图分享；模板分享读取当前缓冲区文本，最多 36 行。
- 验证：Flutter **316 项**与 `flutter analyze` 通过；macOS DMG、iOS IPA 完成；Windows CI [41209699476](https://github.com/WuBarlynn/W-term/actions/runs/41209699476) 成功。发布包位于 `build/release-1.0.46/`。

## 38. 1.0.45 工作区偏好（2026-10-31）

- 三端版本 **1.0.45（98）**。
- 新增 `WorkspaceSettingsDialog` 与插件设置字段 `compactTabs`、`showFavoritesBar`、`clickTabLocates`、`restoreLayout`；均随设置同步。
- 紧凑标签高度：桌面 30、手机 38；收藏栏隐藏不取消数字快捷键；启动恢复可关闭。
- 验证：Flutter **315 项**、`flutter analyze` 通过；macOS DMG、iOS IPA 完成；Windows CI [41207268718](https://github.com/WuBarlynn/W-term/actions/runs/41207268718) 成功。发布包位于 `build/release-1.0.45/`。

## 37. 1.0.44 新手引导、收藏栏、路径预览与 AI 设置同步（2026-10-31）

- 三端版本 **1.0.44（97）**。
- 新增 `OnboardingStore` 与五步全屏引导，仅在真实保险库首次启动显示；跳过与完成均只写本机标记。
- 主机收藏显示在顶部收藏栏，Cmd/Ctrl+Shift+数字键优先连接收藏，未命中时回退标签切换。
- 终端 `findPathAt` 识别绝对/相对路径，Cmd/Ctrl+点击复用预览流程；路径含空格仍需选中后预览。
- 同步设置新增 `ai` 环境与 API Key，Rust 校验可选字段；Keychain 读取失败时省略该组，不阻塞其余设置。
- 验证：Flutter **315 项**、`flutter analyze` 通过；macOS DMG、iOS IPA 完成；Windows CI [41205690331](https://github.com/WuBarlynn/W-term/actions/runs/41205690331) 成功。发布包位于 `build/release-1.0.44/`。
- 剩余引导差异：快捷键自定义、分享图片模板/行号/水印、工作区密度与收藏栏开关尚未实现。

## 36. 1.0.43 在线字体与跨标签上传队列（2026-10-31）

- 三端版本 **1.0.43（96）**，修正 `appBuild` 与安装包版本号不一致。
- 新增 `lib/features/font_market_dialog.dart` 在线字体库，六个 SIL OFL 字体从上游 GitHub 仓库下载并复用本机字体注册。
- 上传批次提升到 `uploadQueue` 应用级单例；文件面板释放不再取消在途批次，传输循环在面板关闭后继续且不再调用 `setState`/冲突弹窗。
- `exportSynced` 等待在途保存，设置导出读取最新外观/固定命令/高亮。
- 验证：Flutter **310 项**、`flutter analyze` 通过；macOS DMG、iOS IPA 完成；Windows CI [41201797723](https://github.com/WuBarlynn/W-term/actions/runs/41201797723) 成功。发布包位于 `build/release-1.0.43/`。在线字体下载与跨标签上传队列仍需实机验收。

## 35. 1.0.42 设置工作区、设置同步与默认输入字体（2026-10-31）

- 三端版本 **1.0.42（95）**。
- 新增 `lib/features/settings_dialog.dart` 全屏设置工作区，侧栏设置入口打开分类设置页；插件设置改为可滚动。
- 终端字体默认 Menlo；Windows 硬件键盘输入默认开启（`windowsHardwareInput` 缺省为 `Platform.isWindows`）。
- 新增同步 `Kind::Settings` 与保险库 `settings` 记录；`SyncedSettings` 聚合终端外观、插件、固定命令和关键词高亮，所有会发布或接收快照的同步操作前后自动导出/应用。设置不进入仅本机范围。
- 生成无白边圆角图标；iOS 保持不透明。
- 验证：Flutter **305 项**、Rust 同步 **93 项**、`flutter analyze` 通过；macOS DMG、iOS IPA 完成；Windows CI [41199329162](https://github.com/WuBarlynn/W-term/actions/runs/41199329162) 成功。发布包位于 `build/release-1.0.42/`。Windows 实机输入、双设备设置同步与自动更新仍待验收。

## 34. 1.0.41 Windows 终端字体回退（2026-10-31）

- 三端版本 **1.0.41（94）**；本地产物 `build/release-1.0.41/`；发布 https://github.com/WuBarlynn/W-term/releases/tag/v1.0.41 。
- Windows 终端主字体 Cascadia Mono 缺失时，回退顺序改为内置 JetBrains Mono → Consolas → Noto Sans SC → 微软雅黑 UI/微软雅黑；避免比例字体造成列错位。等宽代码回退链也加入 JetBrains Mono。界面主体仍默认微软雅黑。
- 验证：`build/flutter-tests-1.0.41.log` **301 项** Flutter 测试通过，`flutter analyze` 无问题；macOS 自签名 Release + DMG；iOS IPA 1.0.41（94）；Windows CI 41190183254 成功（构建/启动冒烟/Inno Setup/静默安装卸载/Rust 测试）。
- 未执行：Windows 实体机字体/输入/自动更新复测；ZMODEM 合成 PTY 测试在首块后停滞，未作为通过证据。
