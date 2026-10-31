# W Term

W Term 是一个基于 Flutter + Rust 的跨平台 SSH / SFTP 工作区，支持 macOS、iOS / iPadOS 与 Windows。界面使用 Flutter，连接、认证、终端流、传输与本地保险库由 Rust 核心处理。

当前版本：**1.0.55 (108)**。

## 功能

### 连接与认证

- SSH 密码、加密私钥、键盘交互 / MFA、持久交互式身份。
- SSH 证书导入与登录。
- 主机指纹在认证前确认，指纹变化默认阻断。
- 多级跳板路由，逐跳指纹、MFA、取消与整链清理。
- 命名 HTTP CONNECT / SOCKS5 代理，支持继承、指定与直连。
- 本地 `-L`、远程 `-R`、动态 SOCKS5 `-D` 端口转发与设备本地规则。
- 主机文件夹、标签、收藏、搜索、备注、启动命令与环境变量。
- CSV/TSV、PuTTY、SecureCRT、MobaXterm、Xshell、Excel 主机导入。

### 终端与工作区

- 多标签、重命名、排序、关闭隔离。
- 标签拖拽分屏、嵌套分屏、双窗格与四宫格布局。
- 窗格标题拖动重排，分隔条自由缩放，双击恢复均分。
- 窗格拆回标签、拆分全部窗格、关闭单个窗格。
- 会话 / 视图分离，断线原位重连，布局恢复。
- 输入广播：当前标签或全部已连接会话。
- 终端搜索、复制 / 粘贴、右键菜单、选中即复制。
- 关键字高亮、链接自动下划线与 Cmd/Ctrl+点击打开。
- 终端 AI 助手，支持 OpenAI 兼容端点与只读命令工具。
- tmux 管理、系统监控、进程与端口查看。
- 命令补全、命令历史、固定命令条与宽屏右侧 Dock。
- 本地 PTY 终端。
- macOS / Windows 独立终端窗口与收回。

### 文件与传输

- SFTP 浏览、路径编辑、上传、下载、重命名、删除、权限管理。
- 拖拽上传开关、单文件大小上限、覆盖 / 自动重命名 / 跳过冲突策略。
- 多选与目录递归下载，跨标签下载队列。
- 文本编辑与文本、图片、Markdown、PDF、OOXML 文档预览。
- 目录跟随终端 OSC 7 上报，支持 bash / zsh / fish 与自动探测。
- ZMODEM `rz` / `sz` 传输入口。

### 效率与扩展

- 加密命令片段、标签筛选、内置精选命令与在线市场。
- 固定命令按主机或主机标签绑定。
- 全屏设置工作区，终端外观、插件、固定命令、关键词高亮与 AI 环境随 GitHub 加密同步。
- 首次启动五步引导、收藏栏与数字快捷键、终端路径 Cmd/Ctrl+点击预览。
- 工作区偏好：紧凑标签栏、收藏栏开关、点击标签定位连接、启动恢复布局。
- 分享为图片支持终端窗口、渐变卡片、极简纯色模板，以及行号、水印和自定义标题。
- 顶部实时状态栏显示 SSH 延迟、CPU 与内存；终端可设置光标样式、底部留白与回滚行数。
- 快捷键页可录制/禁用/恢复连接、标签、搜索、文件面板、片段、历史、设置、本地终端、清空与字号快捷键；分享图片支持完整终端文本导出。
- 界面主题可跟随终端配色；提供深色/浅色/浅色+深色终端预设；右键直接粘贴可开关。
- Office 文本预览提供系统应用打开入口，用原应用查看原始排版。
- ZMODEM rz/sz 与真实 lrzsz 双向互操作通过，使用本地修补的协议流控。
- 系统监控支持停止/重启 Docker 容器、复制 PID 与端口协议/回环筛选；顶栏显示 GitHub 同步状态。
- 工作区可显示底部撰写栏，编辑多行命令并发送到当前输入目标。
- 上传/下载队列显示字节级进度与百分比。
- 在线字体库安装开源编程字体；上传队列跨标签保留。
- 终端字体默认 Menlo，Windows 默认启用硬件键盘输入。
- 命令完成通知，支持 OSC 133 精确完成标记与系统通知。
- 外观设置：内置配色、自定义终端 16 色主题、字号、界面 / 终端 / CJK 字体。
- 内置 JetBrains Mono、Noto Sans SC，支持系统字体枚举、本地字体导入与 URL 安装。
- 插件开关：JSON 格式化、IP 归属查询、文件预览、命令补全、任务通知。
- `wterm://connect` 深链接、桌面托盘、全局显示快捷键。

### 安全与同步

- SQLCipher 加密保险库，主密码解锁，支持 Touch ID / Face ID 快速解锁。
- 加密身份、主机、片段与文件夹统一存储。
- 本机自动加密备份与手动导出 / 恢复。
- GitHub 私有仓库端到端加密同步，支持冲突审阅、密钥轮换与自动同步。

### 平台与发布

- macOS：自签名 Release、DMG。
- iOS / iPadOS：未签名 IPA。
- Windows：Inno Setup 安装程序与便携包，静默安装 / 卸载。
- 桌面端 GitHub Release 更新检查。
- Windows 界面使用微软雅黑，终端与代码区域使用等宽字体回退链。
- MIT License。

## 下载

最新三端安装包与校验文件位于 GitHub Releases：

- macOS：`wterm-macos-<version>.dmg`（Apple Silicon）、`wterm-macos-<version>-intel.dmg`（Intel）
- iOS：`wterm-ios-<version>-unsigned.ipa`
- Windows：`wterm-windows-<version>-setup.exe`、`wterm-windows-<version>-portable.zip`

## 构建

工具链：

- Flutter 3.47.4 / Dart 3.13.3
- Rust 1.98.1
- flutter_rust_bridge 2.13.0
- Xcode（Apple 平台）
- macOS 14+ / Apple Silicon 或 Intel，iOS / iPadOS 17+

项目内工具链：

```bash
source scripts/env.sh
flutter pub get --enforce-lockfile
flutter run -d macos
```

Apple 构建：

```bash
scripts/build-macos-signed.sh
scripts/package-macos-dmg.sh
scripts/package-ios-unsigned.sh
```

Windows 通过 GitHub Actions 构建，安装程序配置位于 `installer/wterm.iss`。

## 架构

- `lib/`：Flutter UI、工作区、终端视图、文件面板、设置与同步界面。
- `rust/src/api/`：SSH、SFTP、转发、认证、保险库与同步接口。
- `lib/src/rust/`：flutter_rust_bridge 生成绑定。
- `macos/`、`ios/`、`windows/`：平台工程与原生通道。
- `docs/`：功能审计、状态、专题文档与交接记录。

修改 `rust/src/api/` 后重新生成绑定：

```bash
flutter_rust_bridge_codegen generate
```

## 文档

- [功能审计](docs/CLOUDTERM_FEATURE_AUDIT.md)
- [项目状态](docs/STATUS.md)
- [工作区与分屏](docs/WORKSPACE_TABS.md)
- [跳板路由](docs/SSH_ROUTES.md)
- [交互式认证](docs/SSH_INTERACTIVE_AUTH.md)
- [SSH 代理](docs/SSH_PROXY.md)
- [端口转发](docs/SSH_FORWARDING.md)
- [同步冲突](docs/SYNC_CONFLICTS.md)
- [同步配置](docs/SYNC_SETUP.md)
- [保险库](docs/VAULT.md)

## License

MIT
