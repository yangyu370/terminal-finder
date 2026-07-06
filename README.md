# Terminal Finder

Terminal Finder 是一个 macOS 上的 local-first workspace system。它把文件浏览、窗口内终端、S3 对象存储和可切换的桌面外壳放在同一个工作区里。

它的默认体验接近 Finder：打开目录、看文件、切换视图、用系统默认应用打开文件。但 Terminal Finder 的重点不是复制 Finder 的每一个功能，而是把本地目录和远程对象存储变成可以工作的 workspace。你可以在同一个窗口里浏览文件、改文件、打开终端，并让终端和文件视图围绕同一个目录同步。

当前第一客户端是 macOS app。Windows 98 和 Windows XP 是 macOS 客户端里的视觉外壳，不是独立平台版本。

## 适合用来做什么

Terminal Finder 适合这些场景：

- 在本地项目目录里同时看文件和操作 shell。
- 把 S3、MinIO、R2 或其他 S3-compatible storage 当作 workspace 浏览。
- 在对象存储里上传、下载、重命名、删除文件，并保留明确的 UI 提示。
- 在 Native Finder、Windows 98、Windows XP 三种外壳之间切换同一个 workspace。
- 试验一种 Finder-like 文件窗口和终端共处的桌面工作流。

它暂时不是 Finder 的完整替代品，也不是通用同步盘客户端。它更像一个个人工作台：文件视图负责看清 workspace，终端负责进入现场，连接系统负责把远程 bucket 拉进同一套操作模型。

## 主要能力

### Finder-like 文件浏览

Native Finder 外壳提供一套接近 macOS Finder 的基础浏览体验：

- 侧边栏常用目录入口。
- 路径输入，支持相对路径和 `~`。
- 后退、前进、上级目录、刷新。
- 显示或隐藏 dotfiles。
- 双击目录进入，双击本地文件用系统默认应用打开。
- 图标、列表、分栏、画廊四种显示模式。
- 分栏和画廊视图使用 Quick Look 缩略图，适合快速看图片和常见文档。

文件浏览的事实来自 Rust core：目录验证、当前目录、workspace root、listing 和排序都由 core 持有。客户端负责窗口、选择态、菜单、toolbar 和具体渲染。

### 窗口内终端

按 `Command+J` 可以打开或关闭窗口底部终端面板。终端是真实 shell，不是模拟输出。

本地 workspace 下，终端和文件浏览器可以双向同步目录：

- 在文件视图里进入目录，终端可以跟随 `cd`。
- 在终端里 `cd` 到新目录，文件视图可以跟随打开。
- 面板里有“锁定 / 同步”状态，想让它们互不影响时可以锁住。
- 终端面板支持拖拽调整高度，并按实际 viewport 合并 resize 请求。

连接型 workspace 也可以打开终端。目前 S3 连接通过 Docker + rclone 暴露为容器内挂载点，再在挂载点里开交互终端。这样对象存储不只是远程列表，也能进入一个可操作的 workspace runtime。

### S3 连接和云端文件操作

侧边栏有 `Connections` 区域，可以添加 S3 / S3-compatible 连接。

当前支持：

- 新建、恢复、列出、移除连接。
- 凭据保存到 macOS Keychain，非敏感配置保存为 JSON。
- 打开 bucket / prefix 并像目录一样浏览。
- 上传文件、下载文件、新建目录、重命名、删除。
- 远程文件双击后先下载到本地 cache，再交给系统默认应用打开。
- 传输和写操作期间显示底部活动条。
- 对 S3 这类没有原生目录、没有原子 rename 的后端，UI 会在关键操作前提示。

凭据只在创建或恢复连接时经 FFI 传给 core。core 在内存里持有掩码后的连接状态，客户端不会把明文 secret 序列化到磁盘。

### 三套客户端外壳

Terminal Finder 不是给同一个窗口换颜色，而是把同一组 workspace 操作接到不同桌面范式里：

- **Native Finder**：macOS 原生窗口、toolbar、sidebar 和系统控件。
- **Windows 98**：自绘标题栏、菜单栏、地址栏、灰色 3D 控件、像素风图标和文件列表。
- **Windows XP**：Luna 风格标题栏、任务窗格侧栏、XP 风格文件列表和终端面板。

三套外壳共享同一个文件浏览状态、连接状态和终端状态。切换外壳不会切换业务规则，只是换一种操作同一个 workspace 的方式。

## 一条典型工作流

1. 打开本地目录，或从 `Connections` 打开一个 S3 bucket。
2. 用图标、列表、分栏或画廊视图浏览内容。
3. 上传、下载、重命名、新建目录或删除条目。
4. 按 `Command+J` 打开窗口内终端。
5. 让终端和文件视图围绕同一个目录同步，或者锁定它们各自独立工作。
6. 在 Native Finder、Windows 98、Windows XP 外壳之间切换，看同一个 workspace 以不同桌面体验呈现。

## 当前限制

Terminal Finder 仍处在开发阶段，不建议按可分发产品理解。

- PTY 会创建真实 shell 进程，会扩大本地攻击面。
- S3 文件读写仍偏原型：部分传输路径有大小和流式能力限制。
- local 删除在 core 内仍缺少 workspace root 限定、软删除 / 回收站等更强护栏；UI 侧已有显式确认，但 core 层还需要收紧。
- 可选 HTTP server 目前没有完整 token 鉴权、Origin / Host 校验和握手保护。
- file watcher、search / indexing、git awareness、plugins、AI features 尚未实现。
- 文件预览面板尚未完整实现；目前已有缩略图、分栏预览和画廊视图。
- Web、Windows、Linux 独立客户端尚未实现。
- macOS app 名称、图标、签名、打包和自动更新还没有产品化。

## 技术架构

Terminal Finder 的产品事实由 Rust core 持有，macOS 客户端负责窗口和交互。默认运行路径是进程内 FFI，不启动独立后端进程，也不依赖本地端口或网络。

```text
┌─────────────────────────────┐
│  macOS client (AppKit)      │
│  Views / ViewModels / API   │
└──────────────┬──────────────┘
               │ UniFFI（进程内，Swift ↔ Rust）
┌──────────────▼──────────────┐
│  Rust core                  │
│  workspace / vfs / terminal │
└──────────────┬──────────────┘
               │ 可选 `server` feature
┌──────────────▼──────────────┐
│  axum HTTP / WebSocket      │
│  dev / future clients only  │
└─────────────────────────────┘
```

Core 负责 workspace state、目录验证、listing、local / S3 provider 路由、connection registry、文件变更操作、PTY session、workspace-bound terminal、cwd 同步和 Docker workspace runtime。macOS 客户端负责 AppKit / SwiftUI 窗口、外壳、布局、选择态、菜单、alert、Keychain、系统默认应用打开文件、终端面板高度和 viewport 测量。

可选 axum HTTP/WebSocket server 只用于联调和未来非 macOS 客户端。默认 macOS app 走 UniFFI；FFI facade 与可选 HTTP/RPC 镜像同一套语义。

## 开发入口

仓库里最重要的目录：

- `core/`：Rust core，以库形式提供，带可选 `server` feature。
- `clients/MacOS/`：Swift + AppKit macOS 客户端，进程内链接 `Vendor/CoreFFI/`。
- `protocol/README.md`：可选 HTTP server 的协议说明。

用 Xcode 打开：

```text
clients/MacOS/MacOS.xcodeproj
```

修改 Rust core 后，刷新 vendored FFI 产物：

```sh
clients/MacOS/scripts/refresh-core-ffi.sh
```

只有需要联调可选 server mode 时才运行：

```sh
cd core
cargo run
```

## 验证

Core:

```sh
cd core
cargo fmt --check
cargo test
cargo clippy --all-targets -- -D warnings
```

macOS client:

```sh
xcodebuild test -project clients/MacOS/MacOS.xcodeproj \
  -scheme MacOS \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .derivedData/codex-tests \
  CODE_SIGNING_ALLOWED=NO
```

## License

MIT License. See [`LICENSE`](LICENSE).
