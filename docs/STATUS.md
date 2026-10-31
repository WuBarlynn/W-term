# 开发与验证记录

更新日期：2026-10-31。当前版本：1.0.32 (85) 三端开发预览。继续补齐 Cloud Term：Windows 输入兼容与 PDF 预览适配。**云同步已按用户要求暂缓，仅保留 GitHub 同步**。**仍不是已通过 P2 真机日用验收的最终版**，iPad 与 Windows 收回尚未交付。

## 1.0.32 Windows 输入兼容与 PDF 预览适配（2026-10-31）

- Windows：新增“Windows 硬件键盘输入”兼容开关（默认关闭）。开启后 TerminalView 走 `hardwareKeyboardOnly`，绕过 Flutter 文本输入/IME；用于输入法异常时恢复打字，中文组字可能不可用。
- PDF：预览窗口按屏幕尺寸自适应，手机/iPad 不再使用固定 920×720。
- 沿用 1.0.30/1.0.31：IME 原生切换已回退，自动更新走退出后独立安装器，Windows CI 含静默安装/卸载冒烟。
- 验证：Flutter 全量 **289 项**通过（`build/flutter-tests-1.0.32.log`）；macOS 自签名 Release/DMG、iOS IPA 完成；Windows CI [41175238616](https://github.com/WuBarlynn/W-term/actions/runs/41175238616) 成功（构建/启动冒烟/静默安装卸载冒烟/Rust 测试）。Windows 实体机输入仍需复测。

## 1.0.31 PDF 内嵌预览与 Windows 安装 CI（2026-10-31）

- 文件：SFTP 选中 PDF 时下载到临时文件并用 pdfrx/PDFium 内嵌渲染，限制 100 MB，关闭预览后删除临时文件；Markdown/文本/图片预览保留。
- Windows 安装：CI 新增 `scripts/test-windows-installer.ps1`，实际静默安装到临时目录、校验 wterm.exe 并卸载，覆盖 Inno Setup 静默安装路径。
- 沿用 1.0.30 的 Windows 输入回退与退出后独立安装器流程。
- 验证：Flutter 全量 **289 项**通过（`build/flutter-tests-1.0.31.log`）；macOS 自签名 Release/DMG、iOS IPA 完成；Windows CI [41173520983](https://github.com/WuBarlynn/W-term/actions/runs/41173520983) 成功，并首次通过静默安装冒烟（安装到临时目录、校验 wterm.exe、卸载）。PDF 真机渲染与 Windows 输入/自动更新仍需实体机复测。

## 1.0.30 Windows 输入与自动更新热修复（2026-10-31）

- 输入：回退 1.0.27 的 Windows IME 原生切换（该实现会阻断 Flutter Windows 文本输入），Windows 重新使用 Flutter 默认输入法行为；macOS 输入法自动切换保留。
- 更新：Windows 下载并校验后不再由应用直接启动安装器；先拉起独立 PowerShell 助手，应用退出 2 秒后由助手静默安装，安装器 `[Run]` 在静默安装完成后启动新版本。安装参数改为 `/VERYSILENT /SUPPRESSMSGBOXES /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS`。
- 验证：Flutter 全量 **288 项**通过（`build/flutter-tests-1.0.30.log`）；macOS 自签名 Release/DMG、iOS IPA 完成；Windows CI [41170799293](https://github.com/WuBarlynn/W-term/actions/runs/41170799293) 成功（移除 IME 原生代码后构建、启动冒烟、Inno Setup、Rust 测试）。Windows 输入与自动安装仍未在真实 Windows 桌面点击验收。

## 1.0.29 精确命令完成通知（2026-10-31）

- 终端菜单新增“命令完成通知钩子”，可选择 bash/zsh/fish 注入 OSC 133;D；完成通知在命令结束时立即触发并显示退出码，空闲启发式保留为回退。同时补上原本缺失的“目录上报（文件跟随）”菜单入口。
- 验证：Flutter 全量 **288 项**通过（`build/flutter-tests-1.0.29.log`）；macOS 自签名 Release/DMG、iOS IPA 完成；Windows CI [41169000225](https://github.com/WuBarlynn/W-term/actions/runs/41169000225) 成功。真实 shell 钩子与通知未在真机验收。

## 1.0.28 多选下载队列（2026-10-31）

- 文件：桌面端多选下载改为可见队列，逐项显示等待/下载中/完成/失败/取消；支持取消剩余任务，当前文件完成后再停；下载期间文件面板仍可浏览，可随时重新打开队列。
- 验证：Flutter 全量 **285 项**通过（`build/flutter-tests-1.0.28.log`）；macOS 自签名 Release/DMG、iOS IPA 完成；Windows CI [41167515357](https://github.com/WuBarlynn/W-term/actions/runs/41167515357) 成功。并发浏览与真实远端下载未验收。

## 1.0.27 Windows 输入法自动切换与广播回归修复（2026-10-31）

- Windows：终端聚焦时通过 `ImmSetConversionStatus` 切到 ASCII，离开时恢复进入前状态；可在插件设置关闭。
- 广播：移除窗格 dispose 中重置 `terminal.onOutput` 的遗留逻辑，新增组件测试确保窗格销毁后输入仍走会话路由。
- 验证：Flutter 全量 **283 项**通过（`build/flutter-tests-1.0.27.log`）；macOS 自签名 Release/DMG、iOS IPA 完成；Windows CI [41165695844](https://github.com/WuBarlynn/W-term/actions/runs/41165695844) 成功（Windows IME 编译、启动冒烟、安装包、Rust 测试）。Windows 输入法未在真实桌面点击验收。

## 1.0.26 字体导入与 URL 安装（2026-10-31）

- 字体：外观对话框新增“导入字体文件”和“从 URL 安装”；支持 TTF/OTF/TTC，大小上限 32 MB，校验字体文件头，忽略控制字符/超长名称；字体复制到应用支持目录并通过 `FontLoader` 注册，重启自动加载；可删除已导入字体。
- 范围：云同步/云账号/团队协作/Web 端按用户指示暂缓，GitHub 加密同步仍是唯一同步后端。
- 验证：Flutter 全量 **282 项**通过（`build/flutter-tests-1.0.26.log`）；macOS 自签名 Release/DMG、iOS IPA 完成；Windows CI [41164117553](https://github.com/WuBarlynn/W-term/actions/runs/41164117553) 成功。字体导入未在真实设备选择文件/URL 下载验收。

## 1.0.25 Windows 独立窗口收回（2026-10-31）

- 收回：Windows 独立窗口通过 `desktop_multi_window` 单向通道把会话交还主窗口；主窗口校验 payload、恢复当前工作区标签并聚焦，Rust 连接不中断、不重连。收回失败会在原窗口重新接回并提示。
- 同窗口多引擎共用 Rust 连接状态；主窗口未解锁或未注册通道时安全拒绝并回滚。
- 验证：Flutter 全量 **280 项**通过（`build/flutter-tests-1.0.25.log`）；macOS 自签名 Release/DMG、iOS IPA 完成；Windows CI [41162577816](https://github.com/WuBarlynn/W-term/actions/runs/41162577816) 成功（构建/启动冒烟/安装包/Rust 测试）。Windows 收回交互未在真实 Windows 桌面点击验收。

## 1.0.24 按主机标签绑定固定命令（2026-10-31）

- 固定命令：在带标签的主机上固定选中命令时，可选择全局、仅当前主机或某个主机标签；命令条按当前主机的标签动态过滤，标签固定不显示在其它主机。
- 验证：Flutter 全量 **278 项**通过（`build/flutter-tests-1.0.24.log`）；macOS 自签名 Release/DMG、iOS IPA 完成；Windows CI [41160793313](https://github.com/WuBarlynn/W-term/actions/runs/41160793313) 成功。标签绑定未在真机点击验收。

## 1.0.23 fish 目录上报与 Markdown 预览（2026-10-31）

- 目录上报：启用时可选 bash/zsh 或 fish；fish 使用 `--on-event fish_prompt` 注入 OSC 7，不修改远程启动文件。
- 文件预览：`.md/.markdown/.mdown` 默认 Markdown 渲染，可切换源码；链接仅允许 http/https 外部打开；其它文本保持原预览。
- 验证：Flutter 全量 **277 项**通过（`build/flutter-tests-1.0.23.log`）；macOS 自签名 Release/DMG、iOS IPA 完成；Windows CI [41158687700](https://github.com/WuBarlynn/W-term/actions/runs/41158687700) 成功。fish 远端与 Markdown 真机点击未验收。

## 1.0.22 分屏、广播、桌面更新与字体（2026-10-31）

- 分屏：每个窗格标题可拖动重排/合并到其他窗格或标签；分隔条可按像素自由拖动，双击恢复均分；新增“拆分所有窗格为标签”，不再需要断开连接。
- 广播：输入路由移到 `TerminalSession`，窗格重建、拆分、移动或关闭都不会再丢失广播目标。
- 更新：仅桌面端显示/执行检查；启动后自动查询 GitHub Release，解析 DMG/EXE 资产，SHA256 校验后 macOS 打开 DMG、Windows 静默安装并重启；移动端隐藏入口。
- 字体：枚举 macOS/iOS/Windows 系统字体，内置 JetBrains Mono 与 Noto Sans SC；界面、终端、CJK 回退均可搜索选择，Windows 终端默认 Cascadia Mono，界面默认微软雅黑。
- 验证：Flutter 全量 **275 项**通过（`build/flutter-tests-1.0.22-final.log`）；macOS 自签名 Release 构建与 DMG、iOS 无签名 IPA 完成；Windows CI [41157390012](https://github.com/WuBarlynn/W-term/actions/runs/41157390012) 通过（构建、启动冒烟、安装包、Rust 测试）。窗格拖拽、广播真实多会话、GitHub 更新升级与 Windows 安装器交互仍未在真机/真实网络验收。

## 1.0.21 macOS 独立窗口收回（2026-10-30）

- macOS 独立终端窗口新增“收回主窗口”：子窗口先反向 handoff 输出，再通过原生通道把连接 ID/快照交回主引擎；主工作区重新 attach 为新标签，不重连、不断线。
- 收回成功后子窗口关闭；主引擎拒绝或通道失败时子窗口重新接入会话并提示失败，不丢失终端。
- 原生主/子 Flutter 引擎通过 `dev.wterm/biometrics` 的 `attachTerminalWindow` 中继；Windows 独立窗口暂不提供收回。
- 验证：Flutter 全量 267 项通过（`build/flutter-tests-1.0.21.log`）；macOS 自签名构建通过；Windows/iOS 构建与 CI 结果见发布证据。收回交互未在真机点击验证。

## 1.0.20 macOS 终端输入法切换（2026-10-30）

- macOS 插件设置新增“终端自动切英文输入”（默认关闭）：终端获得焦点时通过 Carbon TIS 切到 ASCII 键盘布局，离开时恢复原输入法。
- 拆分为显式开关，避免影响其他应用或用户偏好；Windows/Linux 不显示该开关，仍使用系统输入法。
- 在线图标、目录上报、静默更新、自动同步、本地终端、证书等能力续用。
- 验证：Flutter 全量 267 项通过（`build/flutter-tests-1.0.20.log`）；macOS 自签名构建通过；Windows/iOS 构建与 CI 结果见发布证据。输入法切换未在真机交互验证。

## 1.0.19 在线图标与目录上报（2026-10-30）

- 主机图标支持 Iconify 在线搜索：选择在线 PNG 后保存为 `url:https://...`，仅允许 https；主机列表/编辑器在线图标加载失败回退默认图标；内置 59 项搜索保留。
- 终端菜单新增“启用目录上报”：向当前 bash/zsh 会话注入 OSC 7 提示符钩子，使文件面板可跟随目录；不修改 `.bashrc/.zshrc`，新会话需重新启用，fish/其他 shell 不支持。
- 验证：Flutter 全量 267 项通过（`build/flutter-tests-1.0.19.log`）；macOS/Windows 构建与 CI 结果见发布证据；在线图标网络搜索与 shell 注入未在真实环境验证。

## 1.0.18 静默更新与自动同步（2026-10-30）

- Windows 检查更新后可“下载并安装”：确认后校验 SHA256，启动 Inno Setup `/SILENT /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS`，应用退出并由安装器重启；macOS 仍下载并打开 DMG，iOS 仍不提供自动安装。
- 可选自动加密同步（默认关闭，设置菜单切换）：配置并初始化 GitHub 同步后最多每 15 分钟运行一次；存在待处理批次、未保存令牌或未初始化时跳过。
- 自动同步发现冲突只提示并提供“审阅”，绝不自动选择本机/远端版本；同步失败显示错误。
- 验证：Flutter 全量 263 项通过（`build/flutter-tests-1.0.18.log`）；macOS/Windows 构建与 CI 结果见发布证据；Windows 静默安装与自动同步未在真实 Windows/GitHub 环境执行。

## 1.0.17 桌面本地 Shell（2026-10-30）

- 设置菜单新增“本地终端”（macOS/Windows/Linux）：使用 flutter_pty 启动系统 shell（Windows `%COMSPEC%`，macOS/Linux `$SHELL` 登录模式），真实 PTY 支持交互程序、ANSI 与窗口缩放。
- 本地终端与 SSH 会话共用终端视图、命令历史、关键字高亮、任务通知与布局标签；不显示 SFTP 文件面板，远程监控/tmux/AI 工具在本地终端中提示不支持。
- 本地终端不写入布局恢复文件，退出即结束；不参与弹窗交接。
- 验证：Flutter 全量 261 项通过（`build/flutter-tests-1.0.17.log`）；macOS 自签名构建通过；Windows/iOS 构建与 CI 结果见发布证据。PTY 本地交互未在真实桌面自动化验证。

## 1.0.16 OpenSSH 证书认证（2026-10-30）

- 身份编辑与快速连接支持导入 OpenSSH 用户证书（`*-cert.pub`），与私钥合并加密保存；校验 PEM 边界与 32 KiB 上限。
- Rust 认证拆分私钥/证书，使用 russh `authenticate_openssh_cert`；先校验证书公钥与私钥匹配，再发起认证；公钥导出仅读取私钥部分。
- 无证书时保持原有公钥登录路径；RSA/Ed25519 等由 russh 处理。证书认证未与真实 CA/服务器互操作验证。
- 验证：Flutter 全量 261 项通过（`build/flutter-tests-1.0.16.log`）；Rust 证书拆分单元测试通过；macOS/Windows 构建与 CI 结果见发布证据。

## 1.0.15 在线片段市场（2026-10-30）

- 片段对话框新增“在线市场”标签：从仓库发布目录拉取 128 条分类命令，支持刷新、缓存离线读取、搜索和一键加入加密片段库。
- 远程目录校验：256 KiB 上限、最多 200 条、名称/分类长度、单行命令、拒绝重定向/命令替换/串联等高风险形式（放行常见 `2>/dev/null`、`</dev/null`）。
- 市场失败时显示错误并可重试，不阻塞“我的片段”和本地精选。
- 验证：Flutter 全量 259 项通过（`build/flutter-tests-1.0.15.log`）；macOS/Windows 构建与 CI 结果见发布证据；在线目录未在真实网络环境验证抓取。

## 1.0.14 关键字高亮与全局快捷键（2026-10-30）

- 终端关键字高亮：最多 20 个关键字，大小写不敏感、非重叠匹配、五种颜色，针对最近 3000 行缓冲；设置持久化，可在终端菜单开启与编辑。
- 原生全局显示快捷键，无需第三方插件：macOS `⌘⇧Space`、Windows `Ctrl+Alt+Space`；显示并聚焦主窗口。快捷键在托盘菜单中有说明；Linux 暂不支持。
- 修复第三方 hotkey 插件依赖 macOS Pod 导致离线构建失败的问题，改为 Carbon/Win32 原生实现。
- 验证：Flutter 全量 255 项通过（`build/flutter-tests-1.0.14.log`）；macOS 自签名构建通过；Windows CI 结果见发布证据。全局快捷键未在真实桌面按压验证。

## 1.0.13 系统通知与连接效率（2026-10-30）

- 任务完成通知升级为系统级：在长命令空闲完成时同时发送 macOS/iOS/Windows/Linux 系统通知（沿用任务通知插件开关），无权限或初始化失败时静默回退到应用内 SnackBar；Windows 安装器为快捷方式写入 AUMID 以支持 Toast。
- 主机列表多选新增“连接”：按选择顺序逐个打开快速连接对话框；同时新增设置菜单“临时终端”，直接唤起不落库的快速连接。
- 自动加密备份、CSV 密码导入、深链接、托盘、独立窗口等能力续用。
- 验证：Flutter 全量 252 项通过（`build/flutter-tests-1.0.13.log`）；macOS/Windows 构建与 CI 结果见发布证据；系统通知未在真机点击验证。

## 1.0.12 本机自动加密备份（2026-10-30）

- 本机自动备份：每次启动最多一次（24 小时间隔），保留最近 5 份加密 `.wterm-backup`，随机密钥保存在系统安全存储；保险库设置内可立即备份、查看时间/大小并恢复。
- 自动备份失败静默不阻塞工作区；自动备份密钥丢失时明确拒绝恢复，不尝试弱化加密。
- 验证：Flutter 全量 252 项通过（`build/flutter-tests-1.0.12.log`）；macOS/Windows 构建与 CI 结果见发布证据。

## 1.0.11 深链接快速连接（2026-10-30）

- 新增 `wterm://connect?host=...&port=...&username=...&name=...` 深链接：校验主机/端口/用户，唤起已预填的快速连接对话框，不自动连接。
- 深链接不接受密码/私钥参数；URL 中的额外凭据字段被忽略并仍需在对话框中输入。
- macOS/iOS 注册 `wterm` URL Scheme；Windows 安装器写入 HKCU `Software\Classes\wterm` 协议项（卸载清理）；便携版需手动注册。
- 应用启动时及运行中接收链接；工作区未就绪时保留待处理链接，已有连接进行中时提示稍后重试。
- 验证：Flutter 全量 250 项通过（`build/flutter-tests-deeplinks.log`）；Windows CI 41120348331 构建/冒烟/Rust 测试通过；macOS 自签名构建通过。深链接未在真实三端点击验证。

## 1.0.10 密码导入与桌面托盘（2026-10-30）

- CSV 密码列导入：`password/passwd/密码` 表头自动识别，导入时创建加密密码身份并绑定主机；密码不写入标签/分组，也不显示在导入预览。无身份库的连接继续只导入主机。
- 修复带密码列 CSV 的列回退：缺少 `group/tags` 表头时不再把密码列误当作分组或标签。
- 桌面托盘/菜单栏：显示/聚焦主窗口、新建连接（唤起快速连接）、退出 W Term；Windows 使用 ICO，macOS 使用 PNG；托盘不可用时静默跳过。
- 验证：Flutter 全量 247 项通过（`build/flutter-tests-tray.log`）；macOS 自签名构建通过；Windows CI 41115977184 构建/冒烟/Rust 测试通过。托盘与 Windows 多窗口未在真实桌面交互验证。

## 1.0.9 Windows 独立终端窗口（2026-10-30）

- Windows 独立窗口：`desktop_multi_window` 创建新 Flutter 引擎，传入连接 ID、主机、用户和滚屏快照；SSH 输出仍由 Rust handoff 交接，不重连。
- Windows 子引擎插件：在 runner 中注册 `DesktopMultiWindowSetWindowCreatedCallback` 并为每个新窗口注册全部生成插件；关闭按钮使用 `window_manager` 关闭窗口，`WindowListener` 在窗口关闭时断开该会话。
- 主窗口/子窗口初始化解耦：普通窗口没有多窗口定义时仍进入工作区；Windows 独立窗口无法建立时回退主窗口重新接入。
- 验证：Windows CI 41111237179 构建、启动冒烟、Rust 测试通过；macOS 自签名构建通过。Windows 多窗口的实际交互未在 Windows 桌面验证。

## 1.0.8 独立终端窗口与更新校验（2026-10-30）

- macOS 独立终端窗口：标签右键“在新窗口打开”把活动 SSH 会话交给第二个 Flutter 引擎；Rust 输出订阅通过 handoff 版本交接，不重连、不中断连接；滚屏快照随 payload 恢复。
- 修复关闭已交接会话时输出订阅等待确认导致的挂起：先断开 Rust 通道再取消 Dart 输出订阅；真实 detach 桥接测试 30 秒内通过。
- 独立窗口“断开并关闭”会结束自己的 SSH 会话；失败时主窗口自动重新接回并保留终端。
- 更新安装包下载后校验 GitHub Release 的 `SHA256SUMS.txt`，校验缺失/不匹配时拒绝打开。
- PDF、视频、音频、Office 文件选中预览时下载到临时文件并用系统应用打开，iOS 走系统分享。
- 验证：Flutter 全量 246 项通过（含独立窗口 payload），真实 detach 桥接测试通过；三端构建与 Windows CI 结果见发布证据。

## 1.0.7 ZMODEM、Excel 与效率补充（2026-10-30）

- ZMODEM 文件传输：使用 xterm ZModemMux 复用 SSH 字节流，支持远端 `sz` 接收（保存/分享）和 `rz` 发送（选择本地文件），菜单入口与说明；实际远端 lrzsz 互操作仍待真机验证。
- Excel `.xlsx` 导入：内置 ZIP/XML 解析共享字符串和首个工作表，转换为 CSV 主机表；支持表头别名、分组和端口。
- 精选片段扩展到 103 条（系统、网络、容器、日志、进程、包管理、Git、服务、证书等），保持只读/诊断为主。
- 命令历史新增主机下拉与今天/近 7 天/近 30 天/自定义日期筛选。
- 验证：Flutter 全量 243 项通过（`build/flutter-tests-1.0.7.log`）；三端构建与 Windows CI 结果见发布证据。

## 1.0.6 AI 流式、通知与终端增强（2026-10-30）

- AI 助手：OpenAI 兼容 SSE 流式输出，增量显示；支持 `run_command` 工具自动多轮（最多 4 轮），只读命令按权限执行，其余命令仍逐条确认；工具结果回填对话并显示在聊天中。
- 任务完成通知插件：长命令输出停止后提示完成并可定位标签；编辑器、分页器、`tail -f`、远程 shell 等交互命令排除；可在插件设置关闭。
- tmux：对话框每 5 秒自动刷新会话/窗口状态，支持勾选批量结束。
- 系统监控：进程按 CPU/内存重新排序、关键字筛选、确认后向指定 PID 发送 SIGTERM；端口页支持筛选。
- 终端：macOS `⌘`、Windows/Linux `Ctrl` + 点击终端内的 http/https 链接直接打开；仍缺自动下划线绘制。
- 验证：Flutter 全量 242 项通过（`build/flutter-tests-1.0.6.log`）；三端构建与 Windows CI 结果见发布证据。

## 1.0.5 主题、补全与监控增强（2026-10-30）

- 自定义终端主题编辑器：16 色 + 背景/前景/光标/选区，HSV 取色、内置配色起点、持久化；7 套内置配色与 8 套皮肤续用。
- 终端效率：选中即复制开关；右键菜单新增存为命令片段、分享终端为图片、预览选中文件、打开选中链接。
- 工作区：F11/设置菜单聚焦模式隐藏侧栏、标签栏和文件面板；标签右键可定位当前连接的主机；主机图标改为可搜索的 59 项图标库。
- SFTP：多选可包含目录并递归下载，跳过符号链接、1 万文件保护、跳过不安全路径名；iOS 批量分享仍只支持文件。
- 插件：命令补全基于内置 git/docker/compose/kubectl/systemd/包管理器等命令表，在终端底部显示可点击参数提示；可在插件设置关闭。
- 导入与命令条：新增 Xshell `.xsh` 与 `.xts` 备份导入（ZIP 中央目录解析、目录即分组、忽略加密密码）；固定命令自动绑定当前主机并只在该主机的命令条显示。
- 系统监控：每 5 秒采样，保留最近 5 分钟延迟历史；新增资源页展示 CPU/内存百分比折线与 60 点历史。
- 验证：Flutter 全量 237 项通过（`build/flutter-tests-1.0.5-final.log`）；三端构建与 Windows CI 结果见发布证据。

## 1.0.4 预览、分享与更新增强（2026-10-30）

- 文件预览插件：选中远程路径后预览文本或图片，可在插件设置关闭；缺自动下划线点击和媒体/PDF。
- iOS 多选批量下载：下载到临时目录后一次系统分享；桌面仍选择目录批量下载。
- 系统监控新增 10 次 SSH 往返延迟采样与折线/极值；终端工具栏显示活动会话延迟。
- 选中 http/https 链接后可从右键菜单打开。
- 更新检查可选择下载对应 DMG/EXE 并调用系统打开；仍不自动安装或重启。

## 1.0.3 外观、AI 与效率补充（2026-10-30）

- 多 AI 环境：可保存并切换多个 OpenAI 兼容配置，API Key 存系统安全存储；支持启动/手动更新检查并打开 Release。
- 8 套内置渐变皮肤，联动界面明暗和终端配色；自定义皮肤按用户要求不实现。
- 活动终端工具栏显示 SSH 命令往返延迟；续用 1.0.2 的监控、tmux、插件、导入、SFTP 跟随/批量下载、主题字体、片段市场与固定命令条。

## 1.0.2 Cloud Term 功能扩展（2026-10-30）

- 终端 AI 助手：OpenAI 兼容接口、终端上下文、API Key 安全存储、命令权限（每次询问/只读自动/完全访问）、发送到终端或独立 SSH 通道执行；当前为单环境、非流式。
- 插件开关：JSON 格式化与 IP 归属查询可在设置中启停；IP 查询调用第三方接口并显示国家/城市/运营商；命令补全、文件预览、任务通知仍未实现。
- 主机导入：CSV/TSV、PuTTY `.reg`、SecureCRT/MobaXterm `.ini`；缺 Xshell/Excel 和逐行密码导入。
- 外观：7 套终端配色、跟随系统/深/浅界面主题、界面/终端/CJK 字体和字号持久化；缺内置皮肤和自定义主题编辑器。
- 片段：内置 32 条官方精选命令可搜索并加入加密库；固定命令条跨会话持久化，支持一键发送和取消固定。
- 终端：分享终端视图为 PNG、选中 JSON 格式化、全选复制、打开文件面板；缺模板/行号/水印。
- SFTP：解析 OSC 7 跟随终端目录；桌面多选批量下载到目录、同名自动改名；缺自动配置 PROMPT_COMMAND、ZMODEM 和 iOS 目录批量下载。
- 验证：本批复用 1.0.2 的 219 项 Flutter、118/19/7 Rust 与保险库桥接结果，并新增主题/皮肤/更新/AI 配置测试；本轮构建与 Windows CI 结果见日志/产物。真实设备交互仍未验收。

## 1.0.1 Windows 字体、安装包、DMG 与图标（2026-10-30）

- Windows 界面主题与终端文字统一使用 Microsoft YaHei（终端回退 Cascadia Mono/Consolas/monospace）；Apple 保持 Menlo。
- 新应用图标：深青渐变圆角方形 + 终端提示符 + 安全节点；已生成 iOS/macOS 全尺寸 PNG 和 Windows 256 ICO。
- Windows 安装程序：新增 `installer/wterm.iss`（Inno Setup，按用户安装到 `%LOCALAPPDATA%`，含开始菜单/可选桌面快捷方式），CI 构建安装包并校验 exe 版本。
- macOS DMG：新增 `scripts/package-macos-dmg.sh`，把自签名 App、Applications 链接和 LICENSE 打成 UDZO DMG，可用同一签名身份签署 DMG。
- 新增 [CLOUDTERM_FEATURE_AUDIT.md](CLOUDTERM_FEATURE_AUDIT.md)，按公开 Cloud Term 指南逐项标注已有/部分/缺失；排除自定义皮肤和彩蛋，但列出其余全部差距。
- 新增连接启动命令与环境变量：主机编辑器可配置单行启动命令和最多 64 条 `KEY=VALUE`；连接成功后以行首空格执行/导出，避免污染 shell 历史，值使用 shell 单引号转义。环境注入暂用 `export` 回落，尚未使用 SSH env 请求。
- 新增服务器 Wiki、连接图标、主机 Shift/Ctrl 批量收藏/删除、标签关闭左侧/右侧/已断开、命令历史（本地保存、搜索、复制、清空）。
- 新增独立 SSH 通道远端命令与系统监控面板（概览/进程/端口/Docker/tmux 原始输出）和 tmux 会话管理（列表/新建/进入/分离/重命名/结束），限制命令 16 KiB、输出 1 MiB、30 秒超时。
- 验证：Flutter 全量 204 项、Rust 118 项通过；macOS 1.0.1 自签名与 DMG 构建成功；iOS 1.0.1 IPA 构建成功；Windows CI 的安装说明、exe 启动冒烟和 Inno Setup 安装包构建成功。真实 Windows 输入、安装和雅黑显示仍需人工验收。

## 1.0.0 三端构建（2026-10-30）

- 版本号统一：`pubspec.yaml` 为 `1.0.0+53`；macOS/iOS 的短版本/构建号为 `1.0.0 (53)`，Windows Runner 资源由 Flutter 注入并校验为 `1.0.0 (53)`。
- 范围：P1 连接闭环、MFA/代理/跳板/三类转发、P1.5-A/B 标签与分屏、P1.5-D 广播输入、P1.5-E 快捷键/终端选择器、P1.5-F 原位重连/布局恢复、macOS 关窗保活、MIT 协议。
- Windows：`.github/workflows/windows.yml` 在 Windows runner 上构建 Release；使用 runner 自带 OpenSSL 并把 `libcrypto`/`libssl` DLL 放入产物；校验 exe 版本；产物以 Actions artifact 为准。macOS 本机不能直接编译 Windows。
- 仍未完成/未验收：P1.5-C 的独立弹出/拖出窗口与跨窗口迁移（当前单 Flutter 引擎 + 单输出订阅架构无法安全迁移活动 SSH 会话）；P2 的真实 Apple 设备、Touch ID/Face ID、真实 GitHub 双设备、弱网/后台和四周日用验收；Windows 安装包/实际运行输入未人工验收。不得把本次构建称为已验收的日用 V1.0。
- 发布证据：Flutter 203 项、Rust 118/19/7 项、Apple 双端签名/未签名构建；GitHub Actions `Windows preview` 41050390017 构建、版本校验、Rust 测试与 artifact 上传均通过。发布包位于 `build/release-1.0.0/`：`wterm-macos-1.0.0-53.zip`、`wterm-ios-1.0.0-53-unsigned.ipa`、`wterm-windows-1.0.0-53.zip`、`SHA256SUMS.txt`。

## 断线窗格手动重连（2026-10-30）

- 已断开的终端工具栏和窗格菜单显示“重新连接”；使用原保存主机配置和身份重新建立连接，成功后替换原窗格会话，保留标签、分屏结构与比例、自定义标签名，不需要重新创建标签。
- 服务器指纹变化仍会阻断认证；MFA/仅交互式身份仍按原流程询问。临时连接不保存凭据，提示改用“新建连接”，不自动重放密码。
- **布局恢复**：标签/分屏结构、比例、标签名和当前标签写入应用支持目录的 `workspace-layout.json`（仅主机 ID/地址/用户名，不含密码或私钥）。重启后恢复为已断开的占位窗格，逐个“重新连接”即可回到原布局；含临时连接的标签不写入，避免下次恢复后误连到错误目标。
- **macOS 保活**：关闭最后一个窗口不再退出进程，窗口隐藏、SSH 会话保持；点击 Dock 图标重新显示同一窗口。仍可通过应用菜单“退出”结束进程。没有实现独立弹出窗口或跨窗口迁移。
- 限制：没有自动重连、退避重试或网络恢复监听；布局文件不包含凭据，不会自动重放认证；弹出/拖出独立窗口仍受当前单 Flutter 引擎架构限制，尚未实现。连接失败时旧窗格保持断开状态。
- 验证：Flutter 全量 **203 项**（新增离线占位会话与布局 JSON 往返）、Flutter analyze 与定向布局测试通过；Rust 核心 118/19/7 项沿用 0.1.50 本轮代码（0.1.51 未改 Rust）。**布局文件真实重启恢复、macOS 关窗保活和原位重连仍需签名设备手动复核。**
- 产物：macOS 自签名 Release **0.1.51 (52)**，严格签名通过；iOS 未签名 Release IPA **0.1.51 (52)**，ZIP 完整性通过；Windows 版本资源已改为与 Apple 相同的“短版本 (构建号)”，最终 Windows 产物以 CI 为准。

## 广播输入、快捷键与终端选择器（2026-10-30）

- **广播输入**：终端工具栏“广播输入”默认关闭，可明确选择“当前标签内广播”或“全部已连接会话”；全部会话会先确认。标题持续显示“广播 N”并使用醒目底色；断线会话自动从目标剔除，关闭广播立即恢复单会话输入。移动端辅助键、粘贴和命令片段都走同一广播路径。
- **快捷键**（终端聚焦时）：macOS/iOS 外接键盘 `Cmd+T` 新建连接、`Cmd+W` 关闭当前标签、`Cmd+1..9` 切换标签、`Cmd+Shift+[`/`]` 前后切换、`Cmd+Shift+O` 打开终端选择器；Windows/Linux 使用 `Ctrl+Shift` 组合，避免覆盖终端 `Ctrl+W` 等编辑键。搜索仍为 `Cmd+F`/`Ctrl+Shift+F`。
- **已打开终端选择器**：设置菜单新增“已打开终端”，列出主机、所属标签、连接状态，选择后切到对应标签并聚焦该窗格。
- **Windows 构建**：Windows 目标改用 `bundled-sqlcipher-vendored-openssl`，避免依赖主机 OpenSSL；Apple 目标仍使用原 SQLCipher 构建。Windows CI 在 `.github/workflows/windows.yml` 中编译并运行 Rust 测试，结果以 Actions 为准。
- 验证：Flutter 全量 **200 项**、Rust **118 项**普通测试、1 项保险库桥接通过；Rust 格式/Clippy 与 Flutter 静态检查无问题。真实键盘组合、触控辅助键和广播目标仍需签名设备验收。
- 产物：macOS 自签名 Release **0.1.50 (51)**，严格签名身份仍为 `W Term Vault Code Signing`；iOS 未签名 Release IPA **0.1.50 (51)**，ZIP 完整性、iPhoneOS 平台标志、包内原生库与构建目录 SHA256 一致，均晚于本轮源码。产物位于 `build/macos-signed/Build/Products/Release/W Term.app` 和 `build/ios/wterm-ios-0.1.50-51-unsigned.ipa`。

## 标签拖动、右键菜单与双/四分屏（2026-10-30）

- **拖动分屏**：整张标签（左侧排序手柄除外）都可拖动，拖动时经过窗格显示高亮；落点按窗格最近边缘决定上下左右，不再只有窄边缘条可接收。拖到另一个标签上可直接把整棵窗格树合并过去；把当前标签拖到自己的窗格时，改为选择另一个已打开会话分屏，避免把标签与自身合并。
- **标签菜单**：右键（触屏长按）标签打开菜单，包含重命名、分屏子菜单、拆回当前窗格、关闭当前窗格、关闭标签、关闭其他标签、新建连接。分屏子菜单提供左右双分屏、上下双分屏与四宫格分屏。
- **四宫格**：从其他标签选择缺少的已打开会话（已有 2/3 个窗格时自动补足到 4 个），将当前标签按 2×2 重排；会话只移动视图，不重连、不复制终端缓冲区。
- 验证：Flutter 全量 **199 项**、Rust **118 项**、19 项 fixture、7 项真实桥接、1 项保险库桥接通过；Rust 格式/Clippy 与 Flutter 静态检查无问题。**真实鼠标/触控拖动、右键菜单位置与四宫格选择仍需要在签名设备手动复核**。
- 产物：macOS 自签名 Release **0.1.49 (50)**，`codesign --verify --deep --strict` 通过；iOS 未签名 Release IPA **0.1.49 (50)**，ZIP 完整性、iPhoneOS 平台标志、包内原生库与构建目录一致，Dart Framework/原生库均晚于源码。产物位于 `build/macos-signed/Build/Products/Release/W Term.app` 和 `build/ios/wterm-ios-0.1.49-50-unsigned.ipa`。
- Windows：已加入 `windows/` Runner 与 `.github/workflows/windows.yml`，由 Windows CI 编译；macOS 主机不能直接产出或验证 Windows 二进制，结果以 CI 产物为准（当前轮次见 Actions 记录）。

## 标签关闭、面板与解锁体验修复（2026-10-30）

- **关闭标签**：先移除该标签的视图/标签并从工作区状态移除其会话，再按会话关闭 SSH；关闭一个标签不会再触发其他标签的视图重建或断链。确认框列出将断开的 `用户名@主机`。新增真实 fixture：同时打开两个会话，关闭其一后另一终端仍能输出。
- **左侧栏**：可拖动分隔条调宽（200–480），可收起为 48px 窄栏；窄栏保留展开主机列表、新建连接、设置菜单和锁定按钮。左下角设置项（片段、同步、代理、保险库、指纹、锁定）收进“设置与工具”弹出菜单，不再占用侧栏一半高度。
- **右侧文件面板**：可拖动调宽（240–560）；收起后保留显示文件、上传文件、刷新列表三个小按钮，终端区域占用剩余空间；窄屏仍用整页切换。
- **启动自动生物识别**：检测到保险库已启用 Touch ID/Face ID 时，首帧后自动调用系统认证，不再需要手动点按钮；取消后不循环重试，主密码入口保留。
- **iOS 遮罩**：锁屏状态不再叠加隐私遮罩；Face ID/Touch ID 系统弹窗期间不触发遮罩；成功解锁立即清除 `hidden` 与全局遮罩，`resumed` 也统一清除，避免解锁后残留 1–2 秒。
- 验证：Flutter 全量 197 项、Rust 118 项、19 项 fixture（新增独立会话关闭回归）、7 项真实桥接、1 项保险库桥接通过；Rust 格式/Clippy 与 Flutter 静态检查无问题。**自动生物识别的真实弹窗、iOS 后台/解锁遮罩残留与面板拖动手势仍需要在签名真机复核**，自动化只能验证状态和布局逻辑。
- 产物：macOS 自签名 Release **0.1.48 (49)**，`codesign --verify --deep --strict` 通过，签名身份仍为 **W Term Vault Code Signing**；iOS 未签名 Release IPA **0.1.48 (49)**，ZIP 完整性、iPhoneOS 平台标志、包内原生库与构建目录字节一致，Dart Framework 与 `wterm_core` 均晚于本轮源码。产物位于 `build/macos-signed/Build/Products/Release/W Term.app` 和 `build/ios/wterm-ios-0.1.48-49-unsigned.ipa`；未安装或启动业务 App。

## 标签、会话视图分离与分屏 P1.5-A/B（2026-10-28）

- 新增 `TerminalSession` 持有 xterm 模型、SSH 输出/ACK、输入队列、resize 与结束状态；`TerminalPane` 只是可移动视图。切换标签、重排或移动窗格不再断链，终端缓冲保留。关闭标签/窗格或工作区销毁才释放会话与转发/SFTP 资源。
- 标签支持拖动排序、双击/长按重命名、关闭；每个标签独立窗格树，标签显示窗格数量。关闭标签会断开其中全部会话。
- 窗格支持水平/垂直/嵌套分屏，分隔条调整比例，点击切换焦点（主色细线标识活动窗格），窗格菜单可拆回标签或关闭窗格。分屏从其他已打开会话中选择并移动，不复制终端/cwd。
- 标签栏“拖到窗格边缘分屏”手柄可拖到窗格四边，显示落点高亮；松开后合并整个标签树，源标签移除。
- 标签工具栏对当前活动窗格提供 SFTP/端口转发；小窗格工具栏自动折叠到菜单，避免分屏后溢出。
- 已知边界：尚未实现弹窗独立窗口/保活收回（P1.5-C）、广播输入（D）、基础全局快捷键/统一选择器（E）、手动重连/布局保存恢复（F）；移动窗格时终端缓冲保留，但选中区/滚动位置可能重置；分屏选择移动现有会话，不提供“分屏时新建连接”。iOS 后台仍断开 SSH。
- 验证：新增布局模型单测 4 项（会话收集/四边插入/嵌套/移除折叠）；完整 Flutter 196 项测试、静态检查、macOS 自签名与 iOS 未签名 IPA 构建见下方产物。**未在模拟器/真机实际操作连接后的标签拖动、分屏点击和拖拽落点**；真实手势、键盘焦点与多窗验收仍待人工完成，不能据此宣称 P1.5 整体完成。
- 产物：macOS 自签名 Release **0.1.47 (48)**，`codesign --verify --deep --strict` 通过；iOS 未签名 Release IPA **0.1.47 (48)**，ZIP 完整性、iPhoneOS 平台标志、包内原生库与构建目录字节一致；Dart Framework 晚于本轮源码。产物位于 `build/macos-signed/Build/Products/Release/W Term.app` 和 `build/ios/wterm-ios-0.1.47-48-unsigned.ipa`；未安装或启动业务 App。

## 远程/动态转发与保存规则 P1-C（2026-10-28）

- 会话“端口转发”统一支持本地 -L、远程 -R 和动态 SOCKS5 -D。本地监听默认 `127.0.0.1`，目标由 SSH 服务器连接；远程在 SSH 服务器监听、目标由本机连接；动态在本机提供无认证 SOCKS5（仅 CONNECT/TCP），客户端自选目标。监听地址不再局限于回环；非回环必须勾选确认，启动已保存的非回环规则会再次确认。
- 远程 -R 通过服务器 `tcpip-forward` 建立监听，服务器回传的 `forwarded-tcpip` 通道由客户端连接本机目标；停止时取消远端监听、中止活动中继；服务器拒绝、端口冲突和连接错误显示在规则上。
- 当前会话最多 8 条活动转发，每条最多 32 个并发连接，目标连接 15 秒超时。断开会话、上游中断、锁库或工作区销毁会停止全部监听并清理活动中继；停止后本地端口可重新绑定。
- 规则按主机保存在本机 SQLCipher（最多 64 条），支持名称、类型、监听/目标、搜索、编辑、删除和手动启动/停止；保存规则不自动启动，不进入 GitHub 同步，也不由当前业务恢复导入。临时连接不显示规则保存入口。
- 验证：118 项普通 Rust 测试、18 项 ignored 真实 fixture（新增本地/远程/动态往返、端口冲突、远端取消、断链清理）、7 项真实 SSH 桥接（转发×3、MFA×2、代理、跳板路线）及 1 项真实保险库桥接通过；Rust 格式/Clippy 与 Flutter 静态检查通过；192 项 Flutter 全量测试通过。
- 产物：macOS 自签名 Release **0.1.46 (47)**，`codesign --verify --deep --strict` 通过，签名身份仍为 **W Term Vault Code Signing**；iOS 未签名 Release IPA **0.1.46 (47)**，ZIP 完整性、iPhoneOS 平台标志、包内 `wterm_core` 与构建目录字节一致，原生库包含 `start_forward`、`forward_save_rule` 等新接口。产物位于 `build/macos-signed/Build/Products/Release/W Term.app` 和 `build/ios/wterm-ios-0.1.46-47-unsigned.ipa`；未安装或启动业务 App。
- 限制：真实 OpenSSH 转发/GatewayPorts、签名真机、弱网与端口压力仍待验收；动态 SOCKS5 无认证、仅 TCP；规则不跨设备同步；未实现自动启动/保活、Web 网关转发、UDP/VPN 和 ZMODEM（后者属暂停的 P5）。

## 持久交互式身份、命名代理与分层测试 P1-B（2026-10-28）

- 身份新增“仅交互式”：只保存名称和用户名，不保存密码/私钥/口令。每次连接（包括跳板）由服务器在打开终端前询问，锁定重开或重新连接会重新询问；回答不落库、不同步、不自动重放。入口：身份与密钥 → 添加/编辑身份 → 仅交互式。
- 连接代理新增设备本地命名 HTTP CONNECT/SOCKS5 配置：名称、端点、可选用户名密码；读取只返回“密码已保存”，修改端点/用户名后必须重新输入。默认代理保留为“继承”目标，旧全局设置无需迁移。
- 主机编辑器新增“连接代理（仅第一跳）”：继承默认、直连或指定命名代理。指定的命名代理在此设备缺失时拒绝连接，不回退默认或直连；代理只作用于直连第一跳。删除仍被主机使用的代理会被阻止；失效主机绑定会在后续代理操作中清理。
- 分层连通测试：分别显示代理 TCP 可达、代理认证通过、目标 TCP 可达；支持默认、指定、草稿和全部代理顺序测试，目标可留空只测 TCP，HTTP 为 8+10 秒上限，不发送 SSH 凭证。
- 安全与范围：命名代理与主机绑定只在本机 SQLCipher 中保存，不进入 GitHub 同步快照，也不由当前业务记录恢复导入；恢复后需重新配置。代理失败不回退直连，显式直连是唯一绕过方式。加密库文件中检查不出现代理密码明文。
- 验证：118 项普通 Rust 测试、15 项 ignored 真实 fixture（新增持久交互式身份锁定重开后再认证）、5 项真实 SSH 桥接（转发、MFA×2、代理、跳板路线）及 1 项真实保险库桥接通过；Rust 格式/Clippy 与 Flutter 静态检查通过；188 项 Flutter 全量测试通过。
- 产物：macOS 自签名 Release **0.1.45 (46)**，`codesign --verify --deep --strict` 通过，签名身份仍为 **W Term Vault Code Signing**；iOS 未签名 Release IPA **0.1.45 (46)**，ZIP 完整性、iPhoneOS 平台标志、包内 `wterm_core` 与构建目录字节一致，原生库包含 `proxy_test_draft` 等新接口。产物位于 `build/macos-signed/Build/Products/Release/W Term.app` 和 `build/ios/wterm-ios-0.1.45-46-unsigned.ipa`；未安装或启动业务 App。
- 限制：真实代理产品、真实 OpenSSH/PAM/TOTP、企业认证、弱网和签名真机仍待验收；命名代理不跨设备同步；无 HTTPS/Digest/NTLM/GSSAPI/SOCKS4/UDP/系统代理自动发现；全部代理测试为顺序执行。

## 多级跳板 P1-A（2026-10-28）

- 主机编辑器新增“跳板路线”：添加、上移、下移、移除已保存主机，顺序即连接顺序，最多 4 台跳板。跳板主机必须已有保存身份；目标仍可使用保存身份或临时凭证。删除仍被引用的跳板会列出依赖主机并阻止；删除文件夹同样受核心校验保护。入口：主机菜单 → 编辑 → 跳板路线。详见 [SSH_ROUTES.md](SSH_ROUTES.md)。
- 连接按“第 x/y 跳”显示进度。每跳独立核对 SHA256 指纹：首跳沿用 `host:port` 信任键，后续跳使用“跳板端点 > … > 当前端点”的路线作用域键，不自动复用直连或另一路线的信任。指纹获准后才认证，每跳支持多轮 keyboard-interactive/MFA；跳板只认证，不申请 PTY/Shell，只有目标建立终端。
- 第一跳沿用本机全局 HTTP CONNECT/SOCKS5 代理；后续跳在上一跳已认证传输上打开 `direct-tcpip` 通道。通道拒绝、上游断开或目标不可达直接报错，不回退直连；不执行本地 `ssh`/ProxyCommand。
- 探测接受 operation id，可在 TCP/代理/SSH 握手或跳板通道建立阶段即时取消（早于注册的取消也会生效）。每个 Pending/Live 记录父连接；断开任一跳、取消、120 秒未批准、保险库锁定、iOS 后台和工作区销毁都会级联清理整条链。
- 数据与引用：Host 新增可选 `jumpHostIds`；Rust 在单主机保存、整表写入、文件夹删除和备份恢复时校验最多 4 台、缺失、自引用、重复和循环。备份恢复为新主机 ID 并重映射路线，引用不在备份内则拒绝。同步将跳板主机设为仅本机时排除依赖它的主机；远端删除或悬空引用进入冲突审阅或阻止发布。空路线不写出该字段，含路线的数据旧版会拒绝而非静默丢弃。
- 验证：112 项普通 Rust 测试、14 项 ignored 真实 fixture（新增双跳终端、第二跳错误指纹、跳板拒绝时不回退直连、父链断开级联清理、握手即时取消、跳板 MFA 不创建终端）、4 项真实 SSH 桥接（转发、MFA、代理、两台跳板到目标的三层路线含逐跳错误密码）及 1 项真实保险库桥接通过；Rust 格式/Clippy 与 Flutter 静态检查通过；184 项 Flutter 全量测试通过。
- 产物：macOS 自签名 Release **0.1.44 (45)**，`codesign --verify --deep --strict` 通过，签名身份仍为 **W Term Vault Code Signing**；iOS 未签名 Release IPA **0.1.44 (45)**，ZIP 完整性、iPhoneOS 平台标志、包内 `wterm_core` 与构建目录字节一致。产物位于 `build/macos-signed/Build/Products/Release/W Term.app` 和 `build/ios/wterm-ios-0.1.44-45-unsigned.ipa`；未安装或启动业务 App。
- 未验收：真实 OpenSSH 多跳、PAM/TOTP、真实网络弱网/上游中断、签名真机多跳输入与取消。跳板必须使用已保存身份，尚无逐跳临时凭证；命名/逐主机代理、远程/动态转发仍属 P1-B/P1-C。

## 日常终端工作流优先级纠正（2026-10-24，仅规划）

- 用户指出分屏、弹出窗口、广播输入、多标签拖动分屏是基本使用能力。前一版虽有条目却全部排P4、晚于Windows，优先级不合理；203条需求索引和文档校验通过不表示日常功能齐全或已实现。
- 新增P1.5，位于P1连接闭环后、P2 Apple V1.0验收及Windows前：先会话/视图分离，再多标签拖动/嵌套分屏、macOS弹窗/保活迁移收回、明确目标广播、基础搜索/快捷键/重连/布局恢复。加入按打开/组织/输入/迁移/断线/关闭的日用组合清单；P4仅保留效率增强。
- 这些能力当前仍为未实现或部分实现，不因改优先级变成完成；iPad/iPhone按平台验收，不虚称桌面多窗等价。SFTP暂停不变，本次仍只改文档，不编译、不实施业务功能。下方同日早先规划中与此冲突的排期以本节及最新ROADMAP为准。

## Cloud Term对标计划补充（2026-10-24，仅文档）

- 重读交接文档、当前路线及指南完整正文，核对工作区与主机/代理/同步模型；保留全部原有未提交、未跟踪成果。更新[对标计划](CLOUDTERM_PLAN.md)与[执行路线](ROADMAP.md)，修正交接入口中的旧规划摘要。
- 公开研究覆盖8个内容页、24个日志章节、3个匿名资源目录和发布清单。日志HTML仍为0.3.3，发布清单已为0.3.5（2026-10-23）；补充云主题/鼠标包、公开资源目录、数字提示、现有终端选择器及Redis分组REPL，保留旧编号后共203条跟踪项。资源包/图片未全部验证，主题包样本HEAD遭TLS失败，不能视作格式或下载实测。
- 下一批仍为多级跳板/逐跳指纹与MFA，随批完成取消和整链资源清理；再补认证/代理缺口、远程/动态转发与规则保存。Apple真实验收先于Windows；SFTP仍暂停，P5只是待恢复授权的候选阶段；账号/组织/托管Web单独立项。
- 本次不修改业务代码、不升级版本、不运行业务测试/构建、不安装/启动应用、不访问真实保险库/SSH/GitHub或提交/推送。历史自动化和产物证据仍属下方原交付记录，不因文档更新重新计为通过。

## SSH 连接代理（2026-10-09）

- 左侧增加“连接代理”，支持 HTTP CONNECT / SOCKS5 和可选用户名密码认证。本机保存一次后，新建及已保存主机连接共用；已有会话不变，GitHub 不使用该代理。设置/密码保存在 SQLCipher 元数据中，不进入同步快照；更换地址、协议、端口或用户名时不自动复用旧密码。详见 [SSH_PROXY.md](SSH_PROXY.md)。
- 目标域名交由代理解析，支持 IPv4/IPv6；失败不回退直连。代理隧道后仍在同一 SSH 传输核验指纹，再进行 SSH 认证。限制协商时间、响应大小和凭证长度，拒绝认证降级、无效响应及地址注入；读取 HTTP 响应不吞掉紧随其后的 SSH banner。完整侧栏在低高度窗口可滚动，保留主机列表空间。
- 109 项普通 Rust 测试（108 项全量 + 后补取消测试）、10 项协议/独立加密 fixture、22 项相关 Flutter 测试及 4 项真实桥接（保险库、转发、交互式认证、代理）通过；Rust 格式/Clippy、Flutter 静态检查通过。代理桥接实际验证两种认证、错误密码拒绝、配置锁定重开、域名交由代理处理、错误指纹阻断和终端往返。
- macOS 自签名 Release 和 iOS 未签名 Release IPA 均已完成，核对 **0.1.43 (44)**、macOS 完整签名、两端包内最新代理核心、完整源码依赖、iPhoneOS 原生库、IPA 完整性及原生库字节一致；沿用用户 **W Term Vault Code Signing** 身份和原脚本。产物：`build/macos-signed/Build/Products/Release/W Term.app`、`build/ios/wterm-ios-0.1.43-44-unsigned.ipa`。
- 真实代理产品、签名设备网络切换/后台取消仍待验收；当前为本机全局代理，不含逐主机代理配置、TLS 代理或企业认证。没有连接用户真实服务器、读取用户保险库、安装或启动业务 App。后续推进多级跳板与逐跳指纹校验，SFTP 新功能继续暂停。

## SSH 交互式认证与 MFA（2026-10-09）

- 已保存密码/私钥认证后，服务器要求 keyboard-interactive 时可继续多轮问答；纯交互式可从新建连接留空密码临时连接。显示服务器标题/说明与逐项 echo 标记，零输入轮次显式确认。回答不保存、不同步、不自动重放，认证结束自动关闭问题窗口。详见 [SSH_INTERACTIVE_AUTH.md](SSH_INTERACTIVE_AUTH.md)。
- 保持原连接指纹审批，不重新建链。问题绑定连接及随机轮次 ID，限制轮数、字段数、文本/回答长度及网络/用户等待超时；拒绝过期和重复回答，取消/错误清理登记并断开。初始凭证发送后尽早清除本层副本，完整认证和终端启动后才登记可用会话。
- 新增核心状态测试、本地真实 SSH 协议测试、5 项 Flutter 测试及实际交互式桥接测试。102 项普通 Rust 测试、10 项 SSH/SFTP/转发/独立加密 fixture、16 项相关 Flutter 回归及 3 项真实桥接（保险库、转发、交互式认证）通过；Rust 格式/Clippy 与 Flutter 静态检查通过。
- macOS 自签名 Release 与 iOS 未签名 Release IPA 构建成功，核对 **0.1.42 (43)**、macOS 完整签名、两端包内最新问答实现、完整源码依赖、iPhoneOS 原生库、IPA 完整性及原生库字节一致。沿用用户 **W Term Vault Code Signing** 身份和既有脚本。产物：`build/macos-signed/Build/Products/Release/W Term.app`、`build/ios/wterm-ios-0.1.42-43-unsigned.ipa`；没有安装或启动业务 App。
- 真实 OpenSSH/PAM/TOTP、签名 macOS/iOS 输入及后台取消仍待验收；纯交互式持久主机模式尚未接入。后续推进多级跳板/连接代理，SFTP 新功能继续暂停。没有连接用户真实服务器或访问用户保险库。

## 仓库断开与更换（2026-10-08）

- 新增“断开 / 更换同步仓库”：显示旧目标、恢复/历史密钥边界、勾选确认及输入“断开”。成功后清空旧设置和临时凭证，可设置另一仓库并创建或接入；取消不修改数据。见 [SYNC_DISCONNECT.md](SYNC_DISCONNECT.md)。
- 核心在单一 SQLCipher 事务核对预览版本、待处理状态，保留业务及仅本机依赖闭包，移除本机仓库令牌、同步检查点、绑定、回执与密钥历史。所有未决批次/发件箱/发布日志/候选/冲突阻断；未知元数据拒绝。没有网络调用，不删除 GitHub 数据或撤销令牌授权。
- 新增独立本机范围元数据；初始化新空间、重新接入旧空间及重新生成未确认恢复码时保留规则，修复 0.1.40 的恢复码重建会重置范围的问题。当前恢复码不等于全部旧密钥备份，备份恢复界面不会自动恢复同步密钥历史。
- 新增 5 项 Rust 流程测试、4 项 UI 测试，101 项普通 Rust 测试、30 项同步 UI 回归、1 项真实 Dart/Rust 保险库桥接（含已配置仓库断开成功、错误确认拒绝及清除后重配）通过；Rust 格式/Clippy 与 Flutter 静态检查通过。9 项依赖独立 SSH/SFTP/加密 fixture 的测试未重跑，相关协议未修改。
- macOS 自签名 Release 与 iOS 未签名 Release IPA 构建成功，核对 **0.1.41 (42)**、完整 macOS 签名、包内最新断开/范围保留实现、hook 源码依赖、iPhoneOS 原生库、IPA 完整性及原生库字节一致。沿用用户 **W Term Vault Code Signing** 身份与原构建脚本。产物：`build/macos-signed/Build/Products/Release/W Term.app`、`build/ios/wterm-ios-0.1.41-42-unsigned.ipa`。没有安装或启动业务 App。
- 同步进入真实 GitHub 与签名双设备验收，尚未验收完成；后续代码开发转向 keyboard-interactive/MFA。SFTP 新功能继续暂停；未操作用户实际仓库或保险库。

## 仅本机范围管理（2026-10-08）

- GitHub 同步页增加“管理仅本机范围”，创建/接入空间后、首次同步前即可选择主机、身份和片段。搜索保留隐藏选择，预览区分直接选择与关联排除，确认后才保存；取消不写入。文件夹树继续参与同步，已删除记录的显式规则仍可查看和移除。详见 [SYNC_SCOPE.md](SYNC_SCOPE.md)。
- 沿用核心主机/身份关联闭包；已确认同步的记录及其关联依赖不允许直接撤回。待处理发布、轮换、发件箱和冲突审阅阻断保存。预览只返回安全摘要，保存事务重新核对业务数据、同步状态及拟选规则，拒绝过期窗口或临时更换选择；失败全部回滚。本轮保存不访问网络。
- 新增 4 项 SQLCipher 核心测试与 5 项界面测试；96 项普通 Rust 测试、26 项同步 UI 回归、1 项真实 Dart/Rust 保险库桥接（含新增接口失败路径）通过；Rust 格式/Clippy 与 Flutter 静态检查通过。9 项需要独立 SSH/SFTP/加密 fixture 的测试未重跑，相关协议未修改。
- macOS 自签名 Release 与 iOS 未签名 Release IPA 构建成功，核对 **0.1.40 (41)**、macOS 深度严格签名、包内最新范围管理实现、源码依赖、iPhoneOS 原生库、IPA 完整性及原生库字节一致。沿用用户 **W Term Vault Code Signing** 身份及现有构建脚本。产物：`build/macos-signed/Build/Products/Release/W Term.app`、`build/ios/wterm-ios-0.1.40-41-unsigned.ipa`。
- 后续补仓库断开/更换，再完成真实 GitHub 与签名设备的双端验收。SFTP 新功能继续暂停；本轮没有访问用户实际仓库或保险库、安装或启动业务 App。

## 本机同步密钥轮换界面（2026-10-08）

- GitHub 同步页增加“轮换 / 恢复同步密钥”：新口令二次输入、恢复码展示一次及实际核验、单独发布、关闭重开恢复。停止操作保留候选；明确未发布时才可显式丢弃重建，未知结果仅允许恢复核对。详见 [SYNC_ROTATION.md](SYNC_ROTATION.md)。
- 新增 Flutter/Rust 调用链及本机状态读取，不提供恢复码读回。生成前核对仓库 ID、远端版本、信封及认证快照与已确认基线；核验/发布/丢弃绑定批次编号。丢弃事务保持旧活动密钥及业务记录，发布读回成功后才激活新密钥，后续编辑继续普通同步。
- 新增 2 项 HTTP/SQLCipher 服务流程测试与 5 项界面测试；92 项普通 Rust 测试、21 项同步 UI 回归及 1 项实际 Dart/Rust 保险库桥接通过；Rust 格式/Clippy 与 Flutter 静态检查通过。9 项需独立 SSH/SFTP/加密 fixture 的测试本轮未重跑，相关协议未修改。
- macOS 自签名 Release 和 iOS 未签名 Release IPA 构建成功，核对 **0.1.39 (40)**、macOS 深度严格签名、包内最新 Rust 实现、源码构建依赖、iPhoneOS 原生库、IPA 完整性及原生库字节一致。沿用用户 **W Term Vault Code Signing** 身份与构建脚本。产物：`build/macos-signed/Build/Products/Release/W Term.app`、`build/ios/wterm-ios-0.1.39-40-unsigned.ipa`。
- 后续补仅本机范围选择及仓库断开/更换，然后推进真实仓库与签名双设备验收；SFTP 新功能继续暂停。没有访问用户真实 GitHub、保险库或启动业务 App。

## 已绑定设备接入新同步密钥（2026-10-08）

- GitHub 同步页增加“接入新同步密钥”：选择新同步口令/恢复码、显式确认、输入即时清除、失败重试与取消。已有待处理批次和未保存设置时阻断。接入仅更换本机密钥，不自动上传或合并业务数据；下一次手动同步仍走三方合并/冲突审阅。
- Rust 验证仓库 ID、提交祖先、同步空间、信封与密文，解密后复核远端未变化。事务内归档旧密钥、安装新密钥、设置持久 `key_revision` 读取下限并失效旧审阅；保留原合并基线与本机业务编辑，普通同步确认后再推进检查点。拒绝恢复历史旧密钥、有待处理发布时切换，以及接入后未同步就再次轮换。
- 新增 Flutter/Rust 完整调用链和 4 项核心、4 项界面测试。90 项普通 Rust 测试、16 项同步 UI 回归、1 项真实 Dart/Rust 保险库桥接（含新接口失败路径）通过；Rust 格式/Clippy 与 Flutter 静态检查通过。9 项需独立 SSH/SFTP/加密 fixture 的测试本轮未重跑，相关协议未修改。详见 [SYNC_KEY_ADOPTION.md](SYNC_KEY_ADOPTION.md)。
- macOS 自签名 Release 和 iOS 未签名 Release IPA 构建成功，核对 **0.1.38 (39)**、完整 macOS 签名、iPhoneOS 原生库、hook 源码依赖、包内新接口/读取下限实现及 IPA 完整性/原生库字节。产物：`build/macos-signed/Build/Products/Release/W Term.app`、`build/ios/wterm-ios-0.1.38-39-unsigned.ipa`；保留用户自签名脚本、Touch ID 实现与工具链设置，没有安装或启动业务 App、访问用户真实仓库。
- 下一步补本机发起轮换的界面，真实 GitHub/签名双设备验收仍未完成；发布结果未知且远端已换钥的批次继续保留，不提供强制覆盖。SFTP 新功能继续暂停。

## 同步竞争后的可验证恢复（2026-10-08）

- 接入现有“恢复待处理同步”按钮：从未更新远端分支，或首次 PATCH 明确被 409/422 拒绝的普通批次，在远端变更后核对仓库身份、祖先关系、密钥及密文，原子清理旧发布记录/发件箱/待处理状态，然后保留本机当前数据重新合并。后续编辑不回滚，有冲突继续保留双方进入现有审阅界面。
- 新增持久化 `ref_update_started`，必须在 PATCH 前写入；写入失败不发送。网络不明、5xx、响应丢失和旧版缺字段日志保守保留，后续拒绝不能抹去此前的不确定性。轮换批次不自动取消；不强推、不无限重试、不提供忽略未知结果的清理按钮。详见 [SYNC_RECOVERY.md](SYNC_RECOVERY.md)。
- 新增 5 项 HTTP/SQLCipher 场景，18 项 GitHub 专项、86 项普通 Rust 测试、22 项 Flutter 同步/冲突/保险库/快速解锁回归和 1 项真实 Dart/Rust 保险库桥接通过；Rust 格式/Clippy 与 Flutter 静态检查通过。本轮未改 SSH/SFTP 协议，9 项需独立 fixture 的测试未重跑。
- macOS 自签名 Release 与 iOS 未签名 Release IPA 构建成功，已核对 **0.1.37 (38)**、macOS 深度严格签名、iPhoneOS 原生库、构建依赖包含本轮源码、包内发布标记实现及 IPA ZIP/原生库字节完整性。产物：`build/macos-signed/Build/Products/Release/W Term.app`、`build/ios/wterm-ios-0.1.37-38-unsigned.ipa`。沿用用户自签名身份，未安装或启动业务 App。
- 下一步其他设备换钥接入，随后真实仓库双设备验收。SFTP 新功能继续暂停；本轮未访问用户真实 GitHub 或凭证，自动化不能代替真机验收。

## macOS 自签名 Touch ID 的 -34018 修复（2026-10-07）

- 用户实测证实 0.1.35 的签名放行未解决 Data Protection Keychain 权限拒绝。本轮 macOS 快速解锁改为 Secure Enclave P-256 + ECDH/HKDF-SHA256/AES-256-GCM 加密信封，不再通过旧 Keychain 项读写或删除。硬件私钥保留 `biometryCurrentSet`；成功恢复并解密后才保存启用记录。认证取消不先删除旧登记。
- 按用户要求取消默认 designated requirement 相等检查，保留 unsigned/ad-hoc、证书、标识和完整性检查。iOS Keychain/Face ID 逻辑未改；macOS 升级需用主密码解锁后重新启用，旧 Keychain 项不迁移、不回退读取，详细说明见 [MACOS_SIGNING.md](MACOS_SIGNING.md)。
- 10 项原生加密/文件检查通过；带 App Sandbox、无 Apple Keychain 权限的真实自签名测试 App 成功创建和恢复硬件密钥，禁止交互时解密明确返回 LAError.notInteractive (-1004)，非 -34018。此测试仅使用临时随机凭证，不访问用户保险库、不弹认证窗口。
- 10 项 Flutter 快速解锁/保险库回归和静态检查通过；签名样本回归通过。真实指纹成功/取消/变化、退出重开及跨版本读取仍待真机交互验证。
- 用户自签名脚本构建 **0.1.36 (37), arm64** 成功，产物 `build/macos-signed/Build/Products/Release/W Term.app`；完整签名、新预检、版本和原生代码包含情况已核对。未安装或启动业务 App，未构建 iOS。

## macOS 稳定自签名与 Touch ID 预检（2026-10-07）

- 保留用户已修改成功的自签名构建脚本。新增原生 `BiometricSigningPolicy`，移除 Team ID / Apple Keychain entitlement 的签名类型门槛，允许默认稳定证书身份的 Apple Development、Developer ID 和自签名版本。拒绝 unsigned、ad-hoc、错误标识、签名篡改及非默认 designated requirement；完整性检查在后台队列执行。
- 启用与读取快速解锁均执行签名预检；检查不可用时不放行。继续使用 Data Protection Keychain 和 `biometryCurrentSet`，不降低凭证保护。修正替换旧凭证时 `-34018` 未被捕获的问题，明确区分签名准入和系统钥匙串授权。
- 自签名与 Apple Development 的实际临时程序测试通过：unsigned/ad-hoc 拦截、稳定身份与更新版本放行、错误标识/弱 requirement/篡改拒绝、当前运行进程验证；跨构建 requirement 相同。10 项快速解锁/保险库回归与 Flutter 静态检查通过。本机无 Developer ID 证书，未做该类型的真实签名测试。
- 使用用户脚本成功构建 **0.1.35 (36), arm64**，身份 **W Term Vault Code Signing**，产物 `build/macos-signed/Build/Products/Release/W Term.app`，`codesign --verify --deep --strict` 通过。签名预检通过不代表系统一定准许自签名 App 访问受保护钥匙串；真实 Touch ID 启用/取消/退出重开/跨版本复用待用户真机验收。本轮未安装、启动 App 或访问用户保险库，未构建 iOS。
- 详细规则与操作见 [MACOS_SIGNING.md](MACOS_SIGNING.md)。下方个人团队构建为历史记录，当前产物已由自签名版本替换。

## macOS 个人团队签名构建（2026-10-07）

- 按用户已保存的 Xcode 个人团队配置修改 `scripts/build-macos-signed.sh`：默认读取 Runner 的团队、Release/当前 Mac 架构、Apple Development 自动签名；可用环境变量选择 Debug 或其他已有团队。Flutter 只做配置生成，再执行一次 Xcode 构建，产物位于独立 `build/macos-signed`。
- 初次 generic Mac 目标无法生成带钥匙串权限的描述文件；改为当前 Mac，并允许 Xcode 自动开发设备注册和 provisioning 后成功。新增 Debug/Release 生物识别 entitlement 文件，Release 不带 JIT；保留 bundle ID 和用户 Xcode 团队配置。
- 脚本加入签名类型、TeamIdentifier、沙盒/文件/网络/Keychain 权限校验。实际完整脚本成功，`codesign --verify --deep --strict` 通过；额外核对四个内嵌框架均为同团队 Apple Development 签名、应用标识与嵌入描述文件一致、Rust 库晚于源码。语法与 entitlement plist 校验通过；此轮只调整构建配置，未重跑业务测试。
- 签名产物：`build/macos-signed/Build/Products/Release/W Term.app`，0.1.34 (35)，arm64。个人团队开发描述文件有效至 2026-10-14 19:12:32（北京时间）。未进行 Developer ID 公证、安装、启动或真实 Touch ID 测试；签名权限通过不等同于生物识别验收。说明见 [MACOS_SIGNING.md](MACOS_SIGNING.md)。

## 本轮同步冲突选择（2026-10-07）

- GitHub 同步页新增“处理同步冲突”：本机/远端摘要、变化字段、逐项选择、明确删除标签和最终确认，没有预选值。密码/私钥/私钥口令及命令正文不返回 Flutter，文件夹仍按整棵树选择。确认前保留双方；确认后用选择版本替换未选版本，不自动复制记录。详见 [SYNC_CONFLICTS.md](SYNC_CONFLICTS.md)。
- 新增 SQLCipher 冲突审阅记录，关闭重开可继续；本机数据、操作版本或远端提交变化拒绝旧选择。身份删除涉及主机时补全依赖条目，禁止保留悬空身份引用。应用、保存待处理批次及清除审阅同事务；失败整体回滚，成功后旧编号不能重放。
- 发布复用既有发件箱；响应丢失时恢复待处理批次，不重新应用选择。用户关闭/取消窗口不会自动选择任何一方。未提交的界面选择不持久化；已解决的旧版本不独立归档，可在确认前使用加密备份。
- Rust 格式/Clippy、81 项普通 Rust 测试、9 项 SSH/SFTP 协议与独立加密互操作、146 项 Flutter 回归（含构建依赖测试）、2 项真实 Dart/Rust 桥接及 Flutter 静态检查通过。新增 4 项冲突核心测试与 5 项界面测试，扩展已有 HTTP 双库测试覆盖远端变更、刷新审阅、响应丢失和收敛；既有部分界面点击命中提示不影响断言。
- macOS Debug 与 iOS 未签名 Release IPA 构建成功，核对 0.1.34 (35)、MacOSX/iPhoneOS、包内 Rust 库晚于本轮源码、hook 包含新增 review 模块，以及 IPA 完整性和原生库字节。产物：`build/macos/Build/Products/Debug/W Term.app`、`build/ios/wterm-ios-0.1.34-35-unsigned.ipa`。未安装或启动应用，未访问用户真实仓库。
- 真实 GitHub、签名双端和四周日用仍未验收；竞争后的取消/重新合并、其他设备换钥接入和仅本机范围 UI 仍待完成。继续暂停 SFTP 新功能。

## 本轮 GitHub 权限与 404 诊断（2026-10-07）

- 用户确认创建同步空间的 404 源于令牌权限未配置。旧版把所有 HTTP 失败都显示为“未确认发布，待处理状态已保留”，无法区分初始化读取和实际发布，本轮已移除此误导提示。
- 错误现在标明读取仓库、分支、提交、目录、文件或发布阶段。仓库 404 提示仓库名称、Resource owner、Repository access 和组织授权；分支 404 提示大小写、Contents 权限及空仓库首次提交；401/403/409/422/429/服务端错误分别给出检查方向。错误继续屏蔽服务端正文及令牌。
- 设置页增加“检查仓库与分支”，无需同步口令，只读取远端，不生成密钥、不合并、不提交、不清除待处理数据。未保存设置时禁用，支持取消；成功不宣称已验证令牌的 Contents 写入权限。补充分支和令牌字段说明。
- 新增 HTTP 测试覆盖不同阶段的 404/409/401/403、初始化无残留、修正权限后直接创建、已有空间检测、检查无写入及实际待处理批次保留；新增界面检查/失败/重试/未保存设置测试和真实桥接无配置错误路径。Rust 格式/Clippy、13 项 GitHub 专项、11 项同步/工作区界面测试、1 项真实保险库桥接和 Flutter 静态检查通过。本轮未重跑与改动无关的全部 SSH/SFTP 测试，上一轮完整回归记录见下文。
- macOS Debug 与 iOS 未签名 Release 构建成功，核对 0.1.33 (34)、iPhoneOS、包内 Rust 库晚于本轮源码、hook 输入及 IPA 完整性。产物：`build/macos/Build/Products/Debug/W Term.app`、`build/ios/wterm-ios-0.1.33-34-unsigned.ipa`。未安装或启动应用，未访问用户真实仓库；用户修正权限后的实际同步结果待确认。

## 本轮 GitHub 手动同步入口（2026-10-07）

- 侧栏新增“GitHub 同步”：已有私有仓库/分支配置、令牌 SQLCipher 保存与替换、创建/接入空间、范围授权、恢复码实际核验及手动同步。令牌不回填，不加入快照；设置有未保存改动时禁止初始化和同步。详见 [SYNC_SETUP.md](SYNC_SETUP.md)。
- 新增 Rust `sync::service` 和完整 Flutter/Rust 接口。同步状态、密钥与仓库数字 ID 绑定原子安装；错误口令、损坏文件或保存失败不留下部分设置。新建空间核验恢复码前禁止发布；未确认且未发布时可重新生成丢失的恢复码。接入后点击同步才合并业务数据。
- 手动流程串联读取、认证解密、三方合并、持久化批次、发布与核对回执。失败重试优先完成原批次；双端冲突保留双方并停止，远端换钥停止。同步后侧栏主机/身份刷新；命令片段下次打开读取新数据。
- 网络操作临时借用 SQLCipher 连接，不在等待网络期间持有全局保险库互斥锁；取消/锁定会通知结束，过期任务不会重新挂接旧数据库。同步期间其他保险库操作返回忙碌。生成代码、接口、Flutter 设置窗口均已接入，非单独底层模块。
- Rust 格式/Clippy、76 项普通 Rust 测试、9 项 SSH/SFTP 与独立加密互操作、140 项 Flutter 测试（含构建依赖测试）及 2 项真实 Dart/Rust 桥接通过。新增测试覆盖双库合并/冲突、口令/恢复码接入、事务回滚、恢复码替换限制、连接借用和取消/锁定重开；界面覆盖令牌保密、未保存设置、范围授权、恢复码核验、失败重试、取消和小屏键盘布局。既有部分 Flutter 测试仍有非致命点击命中提示，断言通过。
- macOS Debug 与 iOS 未签名 Release IPA 构建成功，已核对 0.1.32 (33)、MacOSX/iPhoneOS、arm64、ZIP 完整性及 IPA 内 Rust 库字节。两个平台 hook 均登记新增 Rust 源文件与 Cargo.lock，包内原生库时间晚于本轮源码，避免旧库复用。产物：`build/macos/Build/Products/Debug/W Term.app`、`build/ios/wterm-ios-0.1.32-33-unsigned.ipa`。没有安装/启动用户应用，没有连接真实用户 GitHub 或上传用户数据。
- 当前限制：真实 GitHub 与签名设备未验收；冲突选择、竞争后重新合并、其他设备换钥接入、仅本机范围开关与解除绑定尚未提供。REST 快进不是严格 CAS，不能声称外部管理员强推竞态已解决。下一轮优先补同步冲突/恢复，继续暂停 SFTP 新功能，Windows/Android 顺序不变。

## 本轮 GitHub HTTPS 传输核心（2026-10-06）

- 新增 `sync::github`，使用 reqwest 0.12.28/rustls 访问固定 GitHub.com API；验证私有仓库、写权限、稳定仓库 ID 和指定分支。两份加密文件通过同一个 tree/commit 发布，保留其他根目录文件，分支更新固定 `force: false`。
- 首次网络写入前保存发布记录，推进分支前必须保存候选提交号；读取分支祖先及同提交两份文件，核对父版本、blob 摘要和发件箱字节后才确认。确认同时清除发布记录、处理发件箱/检查点及密钥轮换，失败整体回滚。响应丢失可在关闭重开后仅核对原提交，包含后续子提交时也不重复发布。
- 流式限制响应容量、固定文件类型和数量；拒绝截断 tree、半套文件、符号链接、错误 blob、错误仓库 ID 和回退历史。禁重定向/隐式请求重试；错误不带服务端正文或令牌。每请求 30 秒、整次操作 120 秒，祖先遍历上限 64。
- 新增 10 项回环 HTTP 测试，覆盖发布/读取、竞争、响应丢失、权限及错误状态、篡改、日志先于发布、SQLCipher 回滚、固定仓库、回退、文件类型和轮换。Rust 格式/Clippy、73 项普通 Rust 测试、8 项 SSH/SFTP 协议测试、1 项独立加密互操作及真实转发桥接通过。最后补充首次上传的目录容量预留保护，再次通过 Clippy 和全部 10 项 GitHub 专项测试。
- Flutter 静态检查、133 项回归及真实保险库桥接通过；含转发共 2 项真实 Dart/Rust 桥接通过。既有目录历史/排序测试仍有非致命点击命中提示，断言通过。最终 macOS Debug 与 iOS 未签名 Release IPA 均构建成功，已核对 0.1.31 (32)、iPhoneOS/arm64、Rust framework 与 ZIP 完整性。未启动或替换用户应用。产物：`build/macos/Build/Products/Debug/W Term.app`、`build/ios/wterm-ios-0.1.31-32-unsigned.ipa`。
- 最终产物复核发现上游 Cargo dep-info 解析按空格拆开路径，`W term` 路径导致部分原生源码改动未触发增量构建。新增项目级 `hook/rust_inputs.dart` 显式登记源码文件/目录、Cargo 清单/锁文件和编译配置，保持用户 Clang 17 配置不变；新增含空格路径、新模块和排除生成目录的测试通过，静态分析通过。修复后重新构建并检查依赖清单及库文件时间，避免只凭构建命令成功交付旧库。Flutter 为此前 133 项应用回归加此轮 1 项构建钩子专项。
- 尚无账户/同步 UI、令牌持久化、空仓库初始化、竞争后的自动取消/重新合并或其他已绑定设备换钥。没有访问真实用户仓库；本地 HTTP 测试不能当作 GitHub 线上或真机验收。REST 快进保护不是严格 CAS，外部强推竞态及分支策略仍待处理。详见 [SYNC_GITHUB.md](SYNC_GITHUB.md)。下一步账户配置和手动同步闭环；继续暂停 SFTP 扩展。

## 本轮本机分阶段同步密钥轮换（2026-10-05）

- 新增 `sync::crypto::rotation`：生成独立候选密钥/信封及新恢复码，候选与轮换批次共同持久化；核验恢复码后才能由发件箱生成可发送内容。暂存时活动密钥保持不变；操作版本过期、尚未完成首次同步或已有待处理操作时均不能开始轮换。
- 发件箱内容核对成功后，同事务保存旧密钥、切换活动密钥、删除候选、确认检查点及回执。连续换钥后的历史密文可通过本机保留密钥读取，之后普通上传使用新活动密钥。最多保留 16 把旧密钥，不自动淘汰。
- 轮换只重加密已确认快照，保留后续业务编辑。未知发布结果继续保留候选与原密文；候选丢失/损坏不会退回旧密钥上传。取消、归档、活动密钥或回执保存失败时事务整体回滚。
- 沿用 SQLCipher schema 3 和密文 v1。待处理记录增加轮换标记，旧记录缺失此标记按普通批次解释；新候选/历史 metadata 受容量、空间、编号和信封认证检查。恢复码不写入候选记录。
- 新增 7 项专项测试；修正测试临时目录生命周期后，Rust 格式/Clippy、63 项普通 Rust 测试、8 项 SSH/SFTP 协议测试、1 项独立加密互操作及真实转发桥接通过。
- Flutter 静态检查、133 项回归及真实保险库桥接通过；含转发共 2 项真实 Dart/Rust 桥接通过。既有目录历史/排序测试有非致命点击命中提示，断言通过。macOS Debug 和 iOS 未签名 Release IPA 构建成功，已核对 0.1.30 (31)、iPhoneOS/arm64、Rust framework 与 ZIP 完整性。未启动或替换用户应用。产物：`build/macos/Build/Products/Debug/W Term.app`、`build/ios/wterm-ios-0.1.30-31-unsigned.ipa`。
- 当前仅本机发起的核心流程，无应用入口、GitHub 或其他已绑定设备的自动换钥。旧仓库历史与旧备份不会因换钥失效，新恢复码也不能恢复另一台设备从未保存的历史密钥。真实远端发布、跨设备换钥、进程终止/断电、真机资源和独立安全审查仍待验收。详见 [SYNC_ROTATION.md](SYNC_ROTATION.md)。下一步 GitHub 传输；继续暂停 SFTP 扩展。

## 本轮同步密文发件箱（2026-10-05）

- 新增 `sync::outbox`：将首次生成的密文包和密钥信封保存到 SQLCipher 后才返回，重试及关闭/重开复用原字节；每次读取重新核对操作版本、仅本机依赖、密钥信封、认证快照和待处理候选。
- 远端读回内容必须与原密文/信封逐字节一致，批次及父版本匹配，才能原子推进检查点、清理发件箱和保存内容摘要回执。重复确认幂等，旧回执不确认下一批，之后的本机编辑不被覆盖。存在发件箱时普通确认入口拒绝，避免绕过内容核对。
- 首次保存失败不返回待发送字节；确认或取消失败整体回滚，保留原批次。未知网络结果不能自动取消；只有已确认未发布才可取消并重新合并。若本机隐私依赖变化，阻止继续发送；已被远端接受的在途批次仍允许记录真实发布结果。
- 新增 8 项测试，覆盖稳定字节、持久回执、后续编辑、错误内容/父版本、有效但不同快照替换、损坏/过期/超大记录、保存/确认/取消回滚、隐私依赖变化、仅拉取和过旧确认。Rust 格式/Clippy、56 项普通 Rust 测试、8 项 SSH/SFTP 协议测试、1 项独立加密互操作及真实转发桥接通过。
- Flutter 静态检查、133 项回归及真实保险库桥接通过；与上述转发桥接共 2 项真实 Dart/Rust 桥接测试。既有目录历史/排序测试仍有非致命点击命中提示，断言通过。macOS Debug 和 iOS 未签名 Release IPA 构建成功，已核对 0.1.29 (30)、iPhoneOS/arm64、Rust framework 和 ZIP 完整性。未运行或替换用户应用。产物：`build/macos/Build/Products/Debug/W Term.app`、`build/ios/wterm-ios-0.1.29-30-unsigned.ipa`。
- schema 3 不变；无新增应用入口、真实 GitHub 传输或用户数据迁移。提交来源/分支/祖先核对、远端并发写入、密钥轮换、真实进程终止/断电和真机验收仍待完成。详见 [SYNC_OUTBOX.md](SYNC_OUTBOX.md)。继续暂停 SFTP 扩展。

## 本轮同步加密与恢复核心（2026-10-05）

- 新增 Rust `sync::crypto`：独立随机同步密钥、Argon2id 同步口令派生、AES-256-GCM/HKDF 快照封装、带校验的随机恢复码，以及两条解锁路径共同校验的密钥信封。空间、密钥编号、批次和父提交参与认证；固定 KDF 参数及有界解码避免外部参数无限放大资源使用。
- 同步密钥在 SQLCipher `metadata.sync_key_v1` 内托管，恢复码/同步口令不存入该记录；拒绝覆盖现有密钥或跨越待处理批次安装。加密待处理候选前重新检查仅本机依赖。沿用 schema 3，不自动开启用户同步，不新增 Flutter 明文凭证读取接口。
- 新增 8 项普通加密测试和 1 项独立 Python `cryptography` 双向互操作测试，覆盖口令/恢复码、密文和头部篡改、另一解锁槽损坏、容量、随机化、关闭重开及另一保险库恢复、仅本机排除。仅用合成数据，无真实用户凭证。
- Rust 格式、Clippy、48 项普通 Rust 测试、8 项既有 SSH/SFTP 协议测试和 1 项独立加密互操作测试通过；Flutter 静态检查、133 项回归及 2 项真实 Dart/Rust 桥接测试通过。既有目录历史/排序点击命中提示未影响断言。
- macOS Debug 与 iOS 未签名 Release IPA 构建成功；已核对 0.1.28 (29)、iPhoneOS/arm64、Rust framework 与 IPA 完整性。产物：`build/macos/Build/Products/Debug/W Term.app` 和 `build/ios/wterm-ios-0.1.28-29-unsigned.ipa`。未替换或启动用户应用，未签名部署。
- 本轮是底层原型：无同步/恢复界面、GitHub 传输、密钥轮换或密文发件箱。有效历史密文仍可通过认证，远端版本核对和防回滚待实现；未完成真机 KDF 性能、多设备验收或独立安全审查。格式及后续边界见 [SYNC_CRYPTO.md](SYNC_CRYPTO.md)。继续暂停 SFTP 新功能。

## 本轮持久化同步状态与仅本机规则（2026-10-04）

- 新增 Rust `sync::state`，将设备 ID、同步空间、操作版本、远端/本机检查点、待处理批次和回执保存到 SQLCipher `metadata`。保险库 schema 3 不变。当前仍为 Rust 底层实现，应用没有同步入口，也不会自动初始化用户数据。
- 准备批次将业务合并、已读取的远端基线及待处理候选原子提交；候选只有通过匹配的远端回执才成为新基线。重开保险库恢复同一批次；重复确认幂等且不覆盖准备后的本机编辑。仅拉取可以确认已有远端版本。
- 主机、身份及片段支持仅本机策略，主机与凭证双向关联排除。远端同 ID 的现存数据冲突时拒绝，删除标记不能删除本机专用记录；已发布的现存记录暂不允许直接切换为仅本机。文件夹树不提供独立排除；UI 开关、范围预览和远端撤回流程仍待接入。
- 已确认远端未接受批次时，可取消后重新合并，保留收到的数据和用户编辑；重试基于已接收的远端版本，避免伪冲突。错回执、过期操作、远端数据丢失、同版本不同内容或缺失状态字段均拒绝，保留原数据。
- 新增 16 项测试，覆盖持久化恢复、私有凭证/关联主机隔离、回执、后续编辑、检查点失败整体回滚、远端冲突/删除、依赖变更、仅拉取、恢复参与同步、提交竞争及损坏状态保护。加上既有 13 项，同步专项共 29 项。
- 本轮静态检查、Rust 格式/Clippy、40 项普通 Rust 测试、8 项 SSH/SFTP 协议测试、133 项 Flutter 回归及 2 项真实桥接测试通过。最终缺字段保护后重新执行全部普通 Rust 测试；既有历史/排序测试有非致命点击命中提示。
- 最终 macOS Debug 与 iOS 未签名 Release IPA 均构建成功，已核对 0.1.27 (28) 版本、iPhoneOS/arm64、Rust framework 与 IPA 完整性。网络认证加密、恢复码、GitHub 传输、账户授权及真实进程中断/真机验收均未完成；本轮模拟回执不能当作真实 GitHub 发布验证。

## 本轮同步协议与合并核心（2026-10-04）

- 新增 `rust/src/sync`，实现版本化快照、稳定记录 ID、设备计数版本、显式删除标记、三方合并及 SQLCipher 适配器。沿用保险库 schema 3；捕获使用单个读取事务，应用合并使用 IMMEDIATE 事务及本机快照复核。
- 单端变化自动接受；两端不同修改、修改/删除、密码冲突保留双方完整内容并阻止整个计划写入。合并后身份引用失效、旧计划、无效密钥、协议/空间/版本/容量不符均拒绝；写入失败整体回滚。
- 文件夹暂作为整棵树的固定记录处理，双端修改会整体冲突。当前没有冲突选择界面、同步检查点持久化、“仅本机保存”规则、网络加密封装、恢复码或 GitHub 传输；应用没有新增同步按钮，不改变用户保险库。详见 [SYNC.md](SYNC.md)。
- 新增 13 项 Rust 同步测试：两个独立加密库首次导入与收敛、独立/相同编辑、密码及编辑/删除冲突、删除标记、身份引用保护、旧计划拒绝、无效密钥回滚、加密软件私钥解析，以及协议与合并后容量边界。测试使用生成的密钥及合成密码。
- 本轮静态检查、Rust 格式/Clippy、24 项普通 Rust 测试、8 项 SSH 协议测试、133 项 Flutter 回归及 2 项真实 Dart/Rust 桥接测试通过。最终一致性读取修改另执行全部 13 项同步专项测试；既有历史/排序界面测试仍有非致命点击命中提示。
- macOS Debug 与 iOS 未签名 Release IPA 已按最终代码构建成功，核对 0.1.26 (27) 版本、iPhoneOS/arm64、Rust framework 与 ZIP 完整性。本轮底层测试不代表跨设备同步已可用或真机验收完成。

## 本轮路线调整与本地 SSH 转发（2026-10-04）

- 执行路线以 [ROADMAP.md](ROADMAP.md) 为准：完成本地转发后优先实现 GitHub 加密同步，再补齐 SSH 连接能力、Apple 稳定化和 Windows。暂停 SFTP 新功能，保留缺陷修复。
- 会话顶部新增“端口转发”。可指定目标主机/端口和本地端口，`0` 自动分配；只监听 `127.0.0.1`，可刷新查看目标连接错误、单独停止。窗口关闭继续运行，停止、远端终端退出和会话断开均释放资源；iOS 切后台仍按现有策略断开。
- 每会话最多 8 条，每条最多 32 个并发连接；目标 SSH 通道建立超时 15 秒。规则暂不保存、不自动恢复；远程转发与动态 SOCKS 尚未实现。
- 启动/停止成功后立即反映结果，即使后续列表刷新失败也保留已确认状态。macOS Release 沙盒补充网络监听权限。
- 新增真实 Dart/Rust 隧道测试，覆盖 65,537 字节双向传输、TCP 半关闭、列表/停止、端口重新绑定、远端终端退出自动释放，以及已结束会话拒绝创建。协议测试还覆盖端口占用、服务端拒绝、活动连接关闭和显式断开释放。
- Flutter 静态检查和 133 项测试通过；Rust 11 项普通测试、8 项协议测试通过；真实转发桥接 1 项通过；保险库桥接 1 项沿用 2026-10-03 本轮代码验证结果。既有目录历史和文件排序测试出现非致命点击命中提示，断言通过。
- 上次被中断的目录上传隐藏项过滤改动已完成回归并保留，此后不继续扩展 SFTP。
- macOS Debug 与 iOS 未签名 Release IPA 均构建成功，已核对 0.1.25 (26) 版本、IPA 完整性、iPhoneOS/arm64、Rust framework 及 macOS Debug 监听权限；真实 OpenSSH、签名 macOS 沙盒、iOS 真机/后台和长连接压力验证仍待完成。

## 本轮 SFTP 目录导航历史（2026-10-03）

- 文件面板提供后退、前进和目录历史菜单，使用服务器返回的规范路径；只有目录读取成功才提交历史位置，失败保留原目录并恢复路径栏。
- 刷新当前目录不重复记录、不丢失前进历史；后退后进入新目录截断旧前进分支。每个面板最多 100 条，关闭会话清除，不同步或持久化，不保存滚动位置。
- 加载/传输时禁用导航。126 项 Flutter 全量测试与静态检查通过，新增历史分支、边界、成功提交及 320px 导航测试。既有排序菜单测试仍有非致命命中提示，断言通过。Rust 协议未修改；实际目录删除/权限变化后的导航与真机操作仍待人工验收。

- macOS Debug 与 iOS 未签名 Release IPA 均构建成功，已核对 0.1.24 (25) 版本、IPA 平台、Rust framework 与 ZIP 完整性。

## 本轮上传任务搜索与筛选（2026-10-03）

- 上传任务窗口增加文件名/相对路径搜索、六种状态筛选、匹配数量与全批状态汇总；随任务状态实时更新，支持清除搜索和空结果提示。
- 过滤不修改任务集合、顺序及操作范围；重试按钮明确为“重试全部失败项”，取消仍作用于全批剩余任务。手机键盘出现时窗口内容可滚动。
- 122 项 Flutter 全量测试与静态检查通过，新增组合过滤、实时状态变化和手机键盘下重试范围测试。既有排序菜单测试仍有非致命命中提示，断言通过。Rust 与平台授权未修改；真实大批量上传和原生键盘交互仍待人工验收。

- macOS Debug 与 iOS 未签名 Release IPA 均构建成功，已核对 0.1.23 (24) 版本、IPA 平台、Rust framework 与 ZIP 完整性。

## 本轮跳过同名文件（2026-10-03）

- 同名文件冲突新增“跳过”，继续后续任务，保持服务器已有内容；支持本批后续冲突复用，不跨失败重试或新批次记忆。
- 任务模型新增 skipped，列表与汇总单独显示；跳过不计为成功/失败，不进入重试失败项。目录创建冲突仍拒绝，不合并已有目录。
- 119 项 Flutter 全量测试及静态检查通过，新增跳过选择、策略复用和失败重试隔离测试。已有排序菜单测试仍有非致命命中提示，断言通过。Rust 核心未修改；真实服务器批量冲突/跳过和真机交互仍待人工验收。

- macOS Debug 与 iOS 未签名 Release IPA 均构建成功并核对 0.1.22 (23) 版本、IPA 平台、Rust framework 与 ZIP 完整性。

## 本轮批量上传冲突选择（2026-10-02）

- 同名文件弹窗增加默认关闭的“对本批后续冲突使用相同选择”。仅在明确选择替换/保留两个后记忆，未勾选时逐个询问，取消仍停止剩余任务。
- 选择对象每次 uploadFiles 调用独立创建，不跨会话、批次或失败重试继承覆盖授权。每项仍先 reject，发生冲突才使用已选策略；策略执行失败直接记为失败，避免循环重试。
- 目录上传冲突显示相对路径，目录创建拒绝与核心原子替换限制保持不变。
- 116 项 Flutter 全量测试及静态检查通过，新增策略作用域、重试隔离与手机选择测试。既有排序菜单测试仍有非致命命中提示，断言通过。Rust 核心未修改；真实服务器连续重名上传、替换拒绝及真机交互待人工验收。

- macOS Debug 与 iOS 未签名 Release IPA 均构建成功并核对 0.1.21 (22) 版本、IPA 平台、Rust framework 与 ZIP 完整性。

## 本轮上传目标目录名称（2026-10-02）

- macOS/iOS 文件夹上传预览可编辑目标根目录名称，实时显示新的相对路径；只调整远程路径，不改本地名称、子目录结构、父任务索引或文件大小统计。
- 拒绝空名称、点目录、路径分隔符和控制字符；上传核心仍拒绝已有目标根目录。失败重试使用已确认的目标名称。
- 预览支持整窗内容滚动，手机键盘显示时仍可确认/取消。113 项 Flutter 全量测试及静态检查通过，新增目录映射、非法名称与手机键盘验证。Rust 和原生授权代码未修改；原生键盘与服务器上传仍待实机验收。

- macOS Debug 与 iOS 未签名 Release IPA 均构建成功并核对 0.1.20 (21) 版本、IPA 平台、Rust framework 与 ZIP 完整性。

## 本轮 macOS 文件夹拖放（2026-10-02）

- Finder 单个目录拖入当前活动文件面板后，复用扫描、可取消进度、明细预览与确认，随后进入现有任务列表。多文件仍可一起拖入；混合文件/目录或多个目录整体拒绝，避免部分上传。
- 扩展 FolderAccess 以持有 desktop_drop 的 Apple bookmark 授权；扫描前申请，供本批次和重试复用，取消/替换/关闭时释放，正在传输时延迟释放。无 bookmark 的容器项目不请求额外授权，实际访问失败仍报告错误。
- 110 项 Flutter 全量测试与静态检查通过，新增 4 项拖放分类、授权拒绝、在途保留和无 bookmark 路径测试。既有排序测试有非致命命中提示，断言通过。测试使用平台通道模拟；真实 Finder 授权、云盘目录和跨会话拖放隔离仍待人工验收。
- iOS 继续使用原生目录选择器；Rust 协议和目录上传规则未变。

- macOS Debug 与 iOS 未签名 Release IPA 均构建成功，已核对版本 0.1.19 (20)、IPA 平台、Rust framework 和 ZIP 完整性。

## 本轮目录上传明细预览（2026-10-02）

- macOS/iOS 共用上传预览窗口，显示文件数、目录数（含根目录）、扫描总大小及滚动的相对路径列表；各文件显示扫描大小。
- 扫描仅读取文件长度元数据，不读取内容；总大小不承诺文件系统快照一致性。支持 B/KiB/MiB/GiB/TiB 显示，保留明确确认及取消。
- 106 项 Flutter 全量测试与静态检查通过，新增 3 项大小标签和手机确认/取消测试，并扩展真实临时文件的统计断言。原有排序测试仍有非致命命中提示，断言通过。Rust 与原生授权代码未修改，实际云盘授权、原生预览与整批上传仍待真机验收。

- macOS Debug 与 iOS 未签名 Release IPA 均已构建并核对版本 0.1.18 (19)，IPA 平台、Rust framework 和 ZIP 完整性已验证。

## 本轮目录扫描取消（2026-10-02）

- 目录扫描显示已扫描项目数，提供取消按钮；遍历前后、目录枚举及生成最终计划前检查取消信号，关闭面板也停止后续遍历。
- 取消不返回部分计划，不触发远程目录创建或文件上传，并释放新获取的 iOS 目录授权。取消要等待正在进行的系统文件读取返回，不能强制终止云提供方的阻塞调用。
- 103 项 Flutter 全量测试及静态检查通过，新增扫描前取消、进度回调中取消与重新扫描测试。已有排序菜单测试仍有非致命命中提示，断言通过。编译结果见下表。原生目录授权和跨云盘端到端流程仍待真机验收。
- 补核对上轮 0.1.16 (17) iOS IPA 的版本和 ZIP 完整性，上轮 Swift 原生目录选择器已编译成功。

- macOS Debug 与 iOS 未签名 Release IPA 均已构建，版本 0.1.17 (18)，IPA 平台、Rust framework 和 ZIP 完整性已验证。

## 本轮 iOS 目录授权与上传（2026-10-01）

- iPhone/iPad 上传菜单提供“上传文件夹”，通过原生 UIDocumentPicker 的 folder/open 模式获取目录，复用现有扫描、确认、任务列表和失败重试。
- 原生以随机令牌保存当前会话 security-scoped URL；Dart 引用计数覆盖当前批次和正在执行的传输。取消选择/确认、扫描失败、新批次替换和关闭面板时释放；正在执行的传输结束前不提前关闭授权。
- 授权不持久化、不进入备份或同步；未新增后台上传。云文件尚未下载、提供方离线或权限失效时显示读取错误。原有 2,000 项/32 层、链接拒绝和不合并已有根目录规则保持一致。
- 101 项 Flutter 全量测试与静态检查通过；新增 5 项平台通道模拟测试覆盖取消、拒绝、只释放一次、重试复用及在途保留。测试不等同于原生授权实测；“文件”/iCloud/第三方提供方、旋转、选择器取消及整批上传仍待签名真机验收。Rust 协议核心未修改。

## 本轮 macOS 文件夹上传预览（2026-10-01）

- macOS 上传菜单支持选择目录；完整扫描后确认再上传，保留根目录、子目录、空目录、中文和隐藏文件，最多 2,000 项、32 层。拒绝链接和特殊文件。
- 根目录及子目录均使用服务器创建目录操作，不合并同名已有目录；父目录未成功创建时子项不上传。目录与文件进入同一任务列表，支持取消剩余项、重试失败项和原目标目录复用。
- 每项上传前重新检查本地项目及其父目录类型。扫描不是文件系统快照，不保证并发修改一致性；不复制权限/时间戳。取消或失败保留已创建的服务器内容。
- 本轮只接入 macOS 按钮选择，未支持拖入目录；iOS 当前 file_selector 仅提供文件导入，目录授权需要后续原生适配，暂不展示此入口。共享扫描及任务逻辑可复用，但尚未达成最终平台一致性。
- 静态检查、96 项 Flutter 全量测试通过（新增 5 项真实临时目录测试：层级/中文/空目录/隐藏文件、文件与目录链接、扫描上限、无效来源）。原有排序菜单测试仍有非致命命中提示，断言通过。Rust 与协议未修改；macOS 沙盒目录授权、服务器重名阻断和中断后重试的整批端到端验收待人工完成。

- macOS Debug 与 iOS 未签名 Release IPA 均构建成功并核对版本 0.1.15 (16)；已验证 IPA 平台、Rust framework 和 ZIP 完整性。

## 本轮下载结果与重试（2026-10-01）

- 文件面板“传输任务”菜单统一进入上传列表与最近下载记录。下载显示原路径、接收字节、保存/分享阶段与最终结果；可重新下载服务器当前内容并重新选择保存或分享。
- 修复取消桌面保存仍提示完成的问题。iOS 分别显示分享完成、取消或结果未确认，不将分享完成当成本地已保存。
- 下载和保存失败均执行临时目录清理，清理异常独立保留且不会遮盖原错误或让界面停留在忙碌状态。正在下载时禁止重复执行。
- 仅保存当前会话最近一次下载状态，不提供下载队列、字节进度、中途取消、断点续传或跨重启恢复。
- 91 项 Flutter 全量测试及静态检查通过，新增 8 项下载状态/失败/重试/清理/手机界面测试。全量测试中已有排序菜单测试产生一次非致命命中提示，断言通过。Rust 和协议未修改，沿用此前结果；真实文件选择、分享回调、清理失败及网络故障端到端流程待真机验收。

- macOS Debug 与 iOS 未签名 Release IPA 均构建成功并核对版本 0.1.14 (15)；已验证 IPA 的 iPhoneOS 平台、Rust framework 和 ZIP 完整性。

## 本轮失败上传重试（2026-10-01）

- 上传任务列表在批次完成后提供“重试失败项”，只重新排队失败记录；成功及主动取消的记录不变，同名条目按索引分别处理。
- 重试固定使用原始目标目录，重新读取原文件、重新申请 macOS 拖入文件权限，并重新确认服务器同名冲突；不复用上次替换授权，不自动重试。
- 仅保留原始文件引用，不额外持久化文件内容；文件变化时上传新内容，文件删除或权限失效时仍显示失败。新批次替换旧记录，关闭会话后不能恢复。
- 批次结束状态在目录刷新完成后发布，避免刷新期间提前重试。83 项 Flutter 全量测试与静态检查通过；Rust 和传输协议未修改，沿用此前结果。真实设备文件授权失效、网络故障后重试和同名冲突端到端验证仍待人工验收。

- macOS Debug 与 iOS 未签名 Release IPA 均已构建并核对 0.1.13 (14) 版本；IPA 的 iPhoneOS 平台、Rust framework 与 ZIP 完整性验证通过。

## 本轮批量上传任务管理（2026-10-01）

- SFTP 文件面板新增“上传任务”，实时列出本批次的等待、上传中、完成、失败和取消状态；成功记录实际路径及字节总量，失败显示错误原因。
- 支持取消剩余任务，不中断正在执行的原子上传；同名冲突选择取消时，当前项和后续项均标记取消。失败项保留结果并继续后续文件。
- 文件面板跨宽窄布局切换使用同一 GlobalKey，保留列表及进行中的批次；关闭会话停止后续排队文件。当前原生传输仍由连接生命周期管理。
- 任务仅存于会话内存，下一批替换；尚无字节进度、自动重试、下载队列、递归上传、断点续传或重启恢复。
- 80 项 Flutter 全量测试通过，覆盖任务取消边界、失败继续、同名任务独立结果和手机实时列表；静态检查通过。Rust 和协议实现未变，沿用此前验证。新增上传界面、真实传输中取消及窗口缩放仍待人工端到端验收。

- macOS Debug 与 iOS 未签名 Release IPA 构建成功，版本均为 0.1.12 (13)；已核对 IPA 平台、Rust framework 与 ZIP 完整性。布局状态调整后另重跑 9 项布局/任务测试通过。

## 本轮离线命令片段管理（2026-10-01）

- 桌面左侧与手机主机抽屉增加“命令片段”，无需 SSH 会话即可管理；管理模式点击条目编辑，终端入口仍预览确认后插入。
- 菜单增加复制命令，列表支持刷新。保存期间禁用字段、按钮和返回；失败保留名称及命令，显示错误后可以重试。
- Flutter 73 项全量测试通过，另补充桌面/手机离线入口 2 项并重跑布局测试（4 项通过），合计 75 项测试覆盖；静态分析通过。Rust/桥接沿用 0.1.10，SSH/SFTP 协议沿用 0.1.9，本轮未修改原生核心或保险库格式。
- macOS Debug 和 iOS 未签名 Release IPA 均构建成功，已核对 0.1.11 (12) 版本；IPA 已验证 iPhoneOS 平台、Rust framework 和 ZIP 完整性。新增交互仍待真机验收。

## 本轮命令片段（2026-09-29）

- 终端工具栏增加命令片段入口，支持新增、编辑、删除、名称/命令搜索及预览确认后插入。插入追加到当前终端输入，不附加回车；当前版本仅支持单行命令，不含控制字符，最多 16 KiB，每个保险库最多 1000 条。
- 片段由 Rust 在 SQLCipher 内保存，跨会话复用、加密备份和恢复。保存/删除在核心锁内读取当前集合后更新，避免不同会话覆盖整个列表；编辑已删除片段会失败。
- 保险库与备份 `user_version` 升至 3；已认证的 schema 1/2 自动升级，旧应用拒绝打开 schema 3，新应用仍可恢复旧备份。恢复片段分配新 ID 并标注“恢复”，保留双方。
- 70 项 Flutter 测试、10 项 Rust 普通/保险库测试、静态分析和 Clippy 通过。7 项 SSH/SFTP 协议测试沿用 0.1.9；本轮连接核心未改变。真实桥接测试通过（片段增删改、保险库持久化及系统 OpenSSH 私钥验证）；macOS 0.1.10 (11) Debug 已构建并核对版本，iOS 0.1.10 (11) 真机 Release 未签名 IPA 构建成功，已核对版本、iPhoneOS 平台、Rust framework 和 ZIP 完整性。
- 用户已修复并编译 iOS 0.1.9；本轮保留其 `.cargo/config.toml` 的 Clang 17 修复，不改动构建路径。

## 本轮 SFTP 远程文本编辑（2026-09-28）

- 普通文件菜单增加“编辑文本”，支持最多 256 KiB 的 UTF-8；拒绝空字符、无效 UTF-8、链接和文件夹。提供 Cmd/Ctrl+S、复制编辑内容和未保存关闭确认；保存失败保留缓冲。
- 纯 CRLF 文件在编辑时显示为普通换行，保存时还原 CRLF；UTF-8 字节大小在界面和核心双重校验。
- 保存前比较原文、权限、属主、用户组和修改时间，写完远程临时文件后再次检查，再通过服务器 POSIX rename 扩展原子替换。不支持或拒绝替换时保留原文件，尝试清理临时文件。
- 临时文件写入前设为 0600，完成后恢复并验证原有权限及 uid/gid，无法保留则拒绝提交。扩展属性/ACL 与硬链接关系不保留；读取检查与最终替换不是服务器事务，仍存在极短的并发修改窗口。仅适合普通配置文本的轻量编辑。
- Rust Clippy、9 项普通测试和 7 项 SSH/SFTP 协议测试通过，覆盖中文与 CRLF、原文冲突、超限拒绝、权限/属主保留、服务器拒绝替换和临时文件清理。67 项 Flutter 测试与静态检查通过；macOS 0.1.9 (10) Debug 构建成功，已核对 bundle 版本。
- 当轮复查确认 iOS 平台组件已恢复，随后发现旧 Clang 路径问题；用户于下一轮确认已修复并编译 iOS 新版。原生编辑器交互和真实多用户并发场景尚待人工验证。

## 本轮 OpenSSH 配置导入（2026-09-26）

- 主机栏增加导入入口：选择配置文件或粘贴内容，填写可选默认用户名，预览并勾选后保存到“OpenSSH 导入”分类。
- 支持具体 Host 别名、HostName、User、Port，应用 Host 的 `*`/`?` 和 `!` 排除规则，按首次匹配取值；支持等号、双引号及行末注释。通配规则本身不生成主机。
- IdentityFile 只作提示，不读取或关联私钥；不支持的选项阻止对应主机导入。Include、Match、反斜杠转义或续行暂不支持，整份文件报错，绝不执行命令或加载引用文件。
- 最多 64 KiB、2000 行、500 个具体主机；用户名、地址和端口验证后才可选。精确相同的名称/地址/端口/用户名跳过，已有身份、收藏和分类保持不变；同名但不同连接配置新增。
- 本轮 63 项 Flutter 测试（含系统 OpenSSH 对照）及静态分析通过；macOS 0.1.8 (9) Debug 构建成功并核对 bundle 版本。Rust 核心未改变，沿用 0.1.7 的 9 项普通测试和 6 项协议测试。iOS 平台组件阻塞未解除，未生成新版 IPA。
- 解析规则参考 [OpenSSH ssh_config 手册](https://man.openbsd.org/ssh_config)，测试包含系统 `ssh -G` 对照；原生文件选择与 iOS 真机交互尚待验收。

## 本轮 SFTP 权限管理（2026-09-26）

- 普通文件和文件夹菜单增加“权限”，实时读取服务器权限，支持三位八进制输入及所有者/用户组/其他人的读、写、执行勾选。
- 仅修改普通权限位 000–777，保留读取到的特殊权限位；不递归修改子项目，不支持符号链接或特殊文件。
- 保存前再次读取并比较原权限，发现变更时拒绝提交；保存后读取并验证结果。上述检查不是服务端事务，不能排除其他程序在检查与写入间修改路径或权限的竞争。
- Rust Clippy、9 项普通测试及 6 项真实 SSH/SFTP 协议测试通过，新增覆盖权限写后读取、冲突拒绝、非法权限拒绝和链接拒绝。56 项 Flutter 测试和静态分析通过；macOS 0.1.7 (8) Debug 构建成功并核对 bundle 版本。
- iOS 仍沿用已确认的缺少 iOS 26.2 平台组件阻塞，本轮未生成新版 IPA；原生权限窗口完整交互待人工验收。

## 本轮 SFTP 查找与排序（2026-09-26）

- 文件面板增加当前目录名称搜索（不区分大小写）、隐藏点文件开关、名称/大小/修改时间排序，以及升降序切换。默认保留显示隐藏文件，与旧版一致。
- 文件夹始终在前，缺少修改时间的项目排在同类末尾；显示设备本地时区的修改时间。无匹配项目时提示调整筛选，不误报目录为空。
- 筛选状态随当前会话保留，刷新和切换目录继续应用；不会递归搜索服务器或修改远程文件。
- 53 项 Flutter 测试、9 项 Rust 普通测试、6 项 SSH/SFTP 协议测试、静态分析和 Clippy 均通过。macOS 0.1.6 (7) Debug 构建成功，已核对 bundle 版本；完整原生界面交互仍待人工验证。iOS 仍沿用已确认的缺少 iOS 26.2 平台组件阻塞；本轮未生成 IPA。

## 本轮 SFTP 项目管理（2026-09-26）

- 文件列表右侧增加操作菜单：文件下载、文件/文件夹重命名和删除。删除前明确确认，操作结束刷新当前目录。
- 重命名保留所在目录，支持中文名称；检查同名目标（含链接），使用 SFTP 不覆盖重命名。拒绝根目录、路径穿越和无效名称。
- 删除使用 lstat 判断项目类型；链接只删除链接本身，文件夹仅允许删除空目录，不进行递归删除。
- 本轮 49 项 Flutter 测试、9 项 Rust 普通测试及 6 项真实 SSH/SFTP 协议测试通过。新增协议测试验证同名冲突、中文重命名、非空目录保护、链接目标保留、文件及空目录删除；静态分析通过。
- macOS 0.1.5 (6) Debug 构建成功，已核对 bundle 版本。iOS 仍沿用上轮已确认的缺少 iOS 26.2 平台组件阻塞；本轮未生成 IPA。真实设备文件操作交互尚待人工验收。

## 本轮独立加密私钥导出（2026-09-26）

- 私钥身份菜单新增“导出加密私钥”，使用独立口令（至少 12 个字符），不更改保存的身份或原登录口令。
- Rust 解密已保存私钥后，用 OpenSSH 格式重新加密。临时文件只包含密文，原生写入不覆盖既有目标，完成或取消平台保存后清理临时目录。私钥明文不进入 Dart 界面或剪贴板。
- macOS 使用系统保存面板，iOS 使用系统分享面板；导出期间防止重复提交，取消和失败均可重试。
- 46 项 Flutter 测试、9 项 Rust 普通/保险库测试、Clippy 和静态分析通过。真实桥接导出的文件由系统 `/usr/bin/ssh-keygen` 成功读取并验证公钥一致；另有核心测试覆盖错误口令、已有文件保护、重新导入、更换导出口令与锁定拒绝。
- macOS 0.1.4 (5) Debug 已构建成功并核对 bundle 版本；本轮复查 iOS 仍缺少 iOS 26.2 平台组件，未生成新版 IPA。系统保存/分享面板的完整人工交互尚未验收。

## 本轮软件密钥生成（2026-09-26）

- 左侧“身份与密钥”增加“生成 SSH 密钥”，填写身份名称和用户名后生成 Ed25519 身份。
- Rust 使用密码学随机源生成私钥，直接写入 SQLCipher 保险库；生成接口仅返回身份 ID，私钥不经过 Flutter 界面和剪贴板。
- 密钥身份菜单增加“查看 / 复制公钥”，兼容已导入的口令保护私钥。公钥窗口给出服务器 authorized_keys 配置说明；选择身份连接复用已有认证流程。
- 8 项 Rust 测试与 Clippy、43 项 Flutter 测试、1 项真实 Dart/Rust 桥接测试通过。覆盖不同密钥生成、持久化后重开、锁定访问拒绝、表单校验、取消、失败重试和公钥复制。
- macOS 0.1.3 (4) Debug 已编译成功并核对 bundle 版本；本轮复查 iOS 目标仍提示缺少 iOS 26.2 平台组件，未生成新版 IPA。新增功能的原生设备交互仍待人工验收。
- 本轮只提供 Ed25519 生成；独立私钥加密导出、其他算法、硬件密钥和证书仍待后续实现。生成身份可随现有加密保险库备份保存。

## 本轮文件夹管理与安装包更新（2026-09-22）

- 主机列表已恢复鼠标悬停和单击选中高亮；单击不连接，双击连接，主机菜单独立。
- 新增文件夹重命名：右侧菜单 → 重命名。数据库事务内同时更新整个子树和主机归属；保留主机 ID、身份引用、收藏与折叠状态。同名分类（含隐式父分类）拒绝合并。
- 已确认用户看到的 iOS“上传文件（不会覆盖同名文件）”属于旧版界面；本地旧 IPA 均为 `0.1.0 (1)`。上一轮 `0.1.1 (2)` 真机 IPA 已生成，本轮继续使用独立版本名 `0.1.2 (3)`。
- 解锁页和侧栏显示从实际安装 bundle 读取的版本号，用于区分源码更新与安装包更新。
- 提供 `scripts/package-ios-unsigned.sh`，生成带版本号的 iPhoneOS Release IPA；未签名，需要用户签名后安装。旧 IPA 保留。
- 本轮 Rust Clippy 与 7 项普通/保险库测试通过，包含重命名冲突、中文路径和 ID 保留；5 项 SSH/SFTP 协议测试本轮未重跑。Flutter 静态检查、40 项 Flutter 测试和 1 项真实桥接测试已通过；macOS Debug `0.1.2 (3)` 构建成功。iOS 新版构建受环境阻塞：Xcode 26.3 报告缺少 iOS 26.2 平台；尝试下载返回 Download failed，执行首次启动组件修复成功后仍缺少该平台。新版 IPA 尚未生成，现有 `0.1.1 (2)` IPA 为上一轮产物。

## 本轮上传与 Touch ID 修正（2026-09-18）

- 上传同名文件提供替换、保留两个文件、取消。保留副本在服务器端选取序号并使用不覆盖的重命名提交；取消会停止本批剩余上传。
- 替换先传到独立临时文件，再使用 `posix-rename@openssh.com` 原子提交；服务器不支持或拒绝时，不删除原文件。仅允许替换普通文件，保留普通权限位。
- macOS 可向当前文件面板拖入单个或多个文件，上传目标固定为开始时的当前目录；申请并释放沙盒文件书签授权。隐藏会话、隐藏文件面板和弹窗后的面板不接收拖放。
- 文件夹递归上传仍未实现，拖入文件夹会明确提示。
- Touch ID 增加签名权限预检与具体错误提示。当前机器没有有效签名身份，临时签名不具备所需权限；提供独立签名 entitlements 与构建脚本，不降级凭证保护。配置见 [MACOS_SIGNING.md](MACOS_SIGNING.md)。
- Rust 格式、Clippy、11 项核心/协议测试通过，包含替换成功、拒绝替换后原内容保留、连续同名副本、目录保护与临时文件清理。Flutter 静态检查、38 项 Flutter 测试、1 项真实桥接测试均通过；macOS Debug 与 iOS 模拟器 Debug 已构建成功。Finder 实际拖放和有效签名后的 Touch ID 仍待人工验收。

## 上一轮终端与解锁更新（2026-09-17）

上一轮完成 `flutter analyze --no-pub`、35 项 Flutter 测试、1 项真实 Dart/Rust 保险库桥接测试，以及 macOS Debug、iOS 模拟器 Debug 构建。Rust 核心未修改，底层协议测试沿用上一轮结果。生物识别测试使用模拟通道，不能代替实际设备的系统认证与 Keychain 验收。

- iOS inactive/hidden/paused 仅启用隐私遮罩，保留已打开的保险库；返回不重复认证。手动锁定、进程退出或系统终止后仍需解锁。SSH 后台断开策略保持独立，不承诺后台保活。
- 解锁页可勾选启用 Touch ID / Face ID：主密码验证成功后，写入仅本设备、绑定当前生物识别集合的 Keychain 条目。后续启动可点击生物识别按钮；取消/失败后保留主密码入口。
- 设置中支持关闭快速解锁；更改主密码前删除旧的快速解锁凭证，之后需要重新启用。生物识别集合变化可能使条目失效，使用主密码重新设置。
- macOS 使用 Data Protection Keychain，不降级到不受生物识别保护的存储；是否具备可用设备、正确签名和 Keychain 权限，需要后续实机验证。
- 终端历史搜索：工具栏入口、Cmd+F / Ctrl+Shift+F、中文文本、大小写筛选、快照刷新和选中复制。仅搜索当前内存缓冲，不保存终端记录。
- 生命周期、生物识别取消/回退/后台返回、历史搜索、手机键盘布局回归均已通过。
- 新增终端外观：深灰、纯黑、浅色配色，字号 10–28；保存后更新所有会话，并在本机持久化。验证覆盖重启恢复、并发保存顺序、损坏设置和失败重试。

## 已实现

- macOS、iOS/iPadOS Flutter 工程及 Rust 原生构建、flutter_rust_bridge 调用链；未创建 Windows 或 Android 工程。
- 真实 SSH 密码及加密 OpenSSH 私钥认证；首次指纹确认、Keychain 保存信任、指纹变化阻断；确认与认证绑定同一连接。
- 多会话终端、增量 UTF-8 输出、窗口尺寸同步、复制粘贴及移动端辅助按键。
- 本机主机管理直接展示在桌面左侧；支持可折叠文件夹、新建空文件夹、按文件夹添加和编辑归类；保留标签、收藏、搜索及 SQLCipher 持久化。原有分组直接映射为文件夹。
- 会话移至右侧顶部横向标签栏，桌面高度 36 px；手机顶部 44 px，并通过左侧抽屉展示主机。关闭前面的标签时保留当前活动会话。
- 支持多层子文件夹和整棵分类树删除；删除时可选择保留全部主机到未分类，或删除全部主机；身份/密钥保留。主机随父文件夹层级缩进。文件夹重命名已实现；文件夹拖放移动待实现。
- 密码、私钥及私钥口令加密保存；左侧身份/密钥管理可复用用户名与凭证。单击主机无操作、双击直接连接，编辑为独立配置表单。
- 已实现主密码修改，以及独立密码的加密备份导出与保留现有数据的恢复。
- SFTP 目录浏览、新建目录、UTF-8 文本预览、文件上传下载；支持多文件上传、冲突选择、macOS 拖放、流式传输及临时文件保护。
- 连接取消、认证超时、输出背压及安全断开；iOS 进入后台时主动断开 SSH，不自动重放命令；保险库保持解锁。
- 多级跳板 P1-A：已保存主机有序路线（≤4 台跳板）、逐跳指纹/MFA、路线作用域信任键、握手即时取消、父链级联清理；保存/删除/备份/同步引用校验。跳板必须使用已保存身份。
- 身份支持“仅交互式”（不保存密码/私钥，每次由服务器询问）；默认与命名 HTTP/SOCKS5 代理、主机继承/直连/指定、分层 TCP/认证/目标测试。命名代理与绑定仅本机保存，不进入同步或业务恢复。
- 会话级本地 -L、远程 -R、动态 SOCKS5 -D 转发及本机保存规则；默认回环监听、非回环确认，断链清理与手动启停。
- 会话/视图分离的标签与嵌套分屏：标签拖动/重命名/关闭，水平/垂直/嵌套窗格、比例调整、焦点、拆回/关闭、拖拽落点合并。
- 主密码创建/解锁/锁定、本地 SQLCipher 保险库、旧 Keychain 主机和文件夹事务迁移；旧记录保留，不重复覆盖导入后的数据。
- iOS 后台保留保险库会话、覆盖导航弹窗的隐私遮罩；真机效果待验收。
- Apple CI 配置、固定依赖、构建说明和自动化测试。

## 本轮问题修复（2026-09-17）

- iOS 终端启用 xterm 软键盘删除检测，发送标准终端退格；真机键盘验证仍待完成。
- 备份操作按钮高度至少 48 px，按钮之间留 12 px，弹窗内容支持滚动。
- 备份恢复/导出与 SFTP 上传/下载先递归创建缓存父目录，再创建独立临时目录，修复首次使用或系统清理缓存后的 PathNotFoundException。
- 删除文件夹在 SQLCipher 事务中更新文件夹及主机；覆盖子文件夹，同时保留相似前缀的其他分类。

## 已执行的验证（标注本轮及沿用结果）

> 下表是 2026-09 至 2026-10-04 的历史汇总，数字与产物版本不代表当前 0.1.44；本轮结果见顶部“多级跳板 P1-A”。

| 项目 | 结果与范围 |
| --- | --- |
| `flutter analyze` | 本轮通过，无问题 |
| `flutter test` | 本轮 133 项全量通过，包含转发界面、操作成功/刷新失败状态及窄屏键盘测试；既有历史/排序测试有非致命点击命中提示 |
| Rust 格式检查、Clippy | 本轮通过；Clippy 使用 `--all-targets --locked -- -D warnings` |
| Rust 测试 | 本轮 40 项普通测试（含 29 项同步专项）、8 项真实 SSH/SFTP fixture 协议测试通过；最终字段完整性校验后重新执行全部普通测试 |
| 真实 Dart/Rust 转发桥接 | 本轮 1 项通过，65,537 字节半关闭往返、列表/停止/端口释放、远端 shell 退出和断开后拒绝创建 |
| 真实 Dart/Rust 保险库桥接 | 本轮 2026-10-04 的 1 项通过结果：片段增删改、导出私钥并使用系统 OpenSSH 验证、加载动态库、生成身份和提取公钥、身份关联保存、文件夹子树重命名与冲突保护、两种删除方式及相似前缀隔离、加密备份恢复、主密码修改、锁定和重新打开；使用独立临时数据库 |
| 本机 SSH 互通 | 临时 AsyncSSH 服务：错误指纹拒绝、错误密码、取消、加密私钥、保险库保存的密码/私钥直接认证、中文终端输入输出、尺寸调整 |
| 本机 SFTP 互通 | 1,048,577 字节二进制往返、内容一致、默认不覆盖、保留两次副本、原子替换、服务器拒绝替换后原内容保留、无残留 `.part`、断开 |
| `flutter build macos --debug --no-pub` | 本轮 0.1.27 (28) 成功，产物 `build/macos/Build/Products/Debug/W Term.app` |
| macOS 界面启动 | 前一版已启动并观察欢迎页、连接表单、宽屏侧栏；新增保险库原生界面尚待人工验证 |
| `cargo check --target aarch64-apple-ios` | 通过，iOS 设备目标核心交叉编译 |
| `flutter build ios --simulator --debug --no-pub` | 沿用 2026-09-18 成功结果；本轮未构建模拟器版本 |
| iOS 真机 Release IPA | 本轮 0.1.27 (28) 成功，产物 `build/ios/wterm-ios-0.1.27-28-unsigned.ipa`，需签名后安装；真机交互未验收 |

协议测试使用临时目录、生成密钥及本机测试凭证，没有读取用户 SSH 私钥或启用系统远程登录。协议测试通过不等同于完整 UI 或真实 OpenSSH 服务器兼容性验收。

## 尚未完成的验证

- macOS 界面完整“认证—终端—浏览—上传下载—断开”流程、Finder 拖放与沙盒文件书签、跨会话拖放隔离的原生 UI 验证；Keychain 持久化及重启后信任校验。
- 真实用户 Keychain 迁移及原生界面重启解锁、iOS 隐私遮罩、后台免解锁和生物识别的真机验证；Keychain 测试使用模拟实现。SQLCipher 的真实 Rust 和 Dart 桥接持久化测试已通过。
- iOS 模拟器启动后的交互验证、iPhone/iPad 真机签名部署和验证。
- 中文输入法组合输入、vim/tmux、触摸选择、外接键盘、旋转、分屏、后台前台切换。
- 多种 OpenSSH 版本、弱网、大文件、长连接、取消竞争及资源释放压力测试。
- 新增身份管理及备份的原生文件选择/保存/分享流程、窗口重启与真机交互验证。
- Release 构建、签名、公证、分发、远程 CI 实际运行。
- 至少四周日用验证。尚未开始，不能由自动化测试替代。

## 后续实施顺序

当前执行路线见 [ROADMAP.md](ROADMAP.md)，优先级为：

1. P1 连接闭环（多级跳板、认证/代理、三类转发与规则）代码已完成；真实 OpenSSH/代理/转发、签名真机与弱网验收列入 P2。
2. GitHub 加密同步：在协议、合并及持久化规则核心上实现密钥/恢复码、认证加密、冲突/仅本机界面、远端并发与回执核对，最后完成双端恢复。
3. SSH 连接能力：MFA、连接代理、多级跳板 P1-A、持久交互式身份与命名/逐主机代理 P1-B、三类转发与规则 P1-C 已交付；P1.5-A/B 标签与分屏已交付，下一批为 P1.5-C/D。
4. Apple 平台输入、Keychain、生命周期、性能、迁移和四周日用验证，验收后再进入 Windows。
5. Windows 复用同一核心与同步协议；完成增强计划后单独评估 Android。

SFTP 新功能暂停，递归下载/续传不在当前排期。当前原型尚未达到完整 V1.0；远程/动态转发、SFTP 增强、真实 OpenSSH/GitHub/双设备验收、真机输入与四周日用仍待完成。

保险库格式、迁移及当前限制详见 [VAULT.md](VAULT.md)。
