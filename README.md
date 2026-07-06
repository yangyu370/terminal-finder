# Terminal Finder

Terminal Finder 是一个 macOS 上的 workspace browser 实验项目。

它不是一个严肃的 Finder 替代品，也不是要马上做成完整商业产品。更准确地说，它是一个“文件浏览器 + 终端 + 云端 workspace + 复古桌面外壳”的大号玩具：你可以像用 Finder 一样打开本地目录，也可以连到 S3 bucket，把它当作一个可以浏览、改文件、打开终端的工作区来玩。

当前第一客户端是 macOS app。主体验接近 Finder，但它额外做了三件事：

- 把终端放进文件窗口里，文件视图和 shell 可以围绕同一个目录工作。
- 把 S3 / S3-compatible object storage 放进侧边栏，当成 workspace 浏览和操作。
- 提供 Native Finder、Windows 98、Windows XP 三套客户端外壳，切换的不是简单配色，而是不同的窗口 chrome、工具栏、侧栏和文件列表体验。

## 现在能玩什么

### Finder-like 文件浏览

Native Finder 外壳提供一套接近 macOS Finder 的基础体验：

- 侧边栏常用目录入口。
- 路径输入，支持相对路径和 `~`。
- 后退、前进、上级目录、刷新。
- 显示 / 隐藏 dotfiles。
- 双击目录进入，双击本地文件用系统默认应用打开。
- 图标、列表、分栏、画廊四种显示模式。
- 分栏和画廊视图使用 Quick Look 缩略图，适合快速看图片和常见文档。

### 窗口内终端

按 `Command+J` 或 `Command+K` 可以打开 / 关闭窗口底部终端面板。终端是真实 shell，不是模拟输出。

本地 workspace 下，终端和文件浏览器可以双向同步目录：

- 在文件视图里进入目录，终端可以跟随 `cd`。
- 在终端里 `cd` 到新目录，文件视图可以跟随打开。
- 面板里有“锁定 / 同步”状态，想让它们互不影响时可以锁住。
- 终端面板支持拖拽调整高度，并按实际 viewport 合并 resize 请求。

连接型 workspace 也可以打开终端。目前 S3 连接通过 Docker + rclone 暴露为容器内挂载点，再在挂载点里开交互终端。这个方向是 Terminal Finder 目前最有意思的部分：对象存储不只是一个远程列表，而是可以被放进工作现场。

### S3 连接和云端文件操作

侧边栏有 `Connections` 区域，可以添加 S3 / S3-compatible 连接，例如 MinIO、R2 或其他兼容 endpoint。

当前支持：

- 新建、恢复、列出、移除连接。
- 凭据进 macOS Keychain，非敏感配置进 JSON。
- 打开 bucket / prefix 并像目录一样浏览。
- 上传文件、下载文件、新建目录、重命名、删除。
- 远程文件双击后会先下载到本地 cache，再交给系统默认应用打开。
- 传输 / 写操作期间显示底部活动条。
- 对 S3 这类没有原生目录、没有原子 rename 的后端，UI 会在关键操作前提示。

### 三套客户端外壳

Terminal Finder 不是把 Finder 组件简单换颜色，而是把同一套 workspace 操作接到不同的窗口外壳里：

- **Native Finder**：使用 macOS 原生窗口、toolbar、sidebar 和系统控件。
- **Windows 98**：自绘标题栏、菜单栏、地址栏、灰色 3D 控件、像素风图标和文件列表。
- **Windows XP**：Luna 风格标题栏、任务窗格侧栏、XP 风格文件列表和终端面板。

三套外壳共享同一个文件浏览状态、连接状态和终端状态。换外壳不会换一套业务规则，只是换一种操作这个 workspace 的方式。

## 产品方向

这个项目更像一个个人工作台，而不是一个通用文件管理器。

短期最值得打磨的闭环是：

1. 打开本地目录或 S3 bucket。
2. 在文件视图里浏览、上传、下载、改名、删除。
3. 打开窗口内终端。
4. 让终端和文件视图围绕同一个工作目录来回同步。
5. 在 Native / Win98 / XP 外壳之间切换，看同一个 workspace 以不同桌面范式呈现。

它暂时不追求覆盖 Finder 的全部能力，也不急着做插件市场、AI、Git 面板或跨平台客户端。

## 当前限制

这个项目还处在开发阶段，不建议按可分发产品理解。

- PTY 会创建真实 shell 进程，会扩大本地攻击面。
- S3 文件读写当前仍偏原型：部分传输路径有大小和流式能力限制。
- local 删除在 core 内仍缺少 workspace root 限定、软删除 / 回收站等更强护栏；UI 侧已有显式确认，但 core 层还需要收紧。
- 可选 HTTP server 目前没有完整 token 鉴权、Origin/Host 校验和握手保护。
- file watcher、search / indexing、git awareness、plugins、AI features 尚未实现。
- 文件预览面板尚未完整实现；目前已有缩略图、分栏预览和画廊视图。
- Web / Windows / Linux 独立客户端尚未实现。Win98 / XP 是 macOS app 的视觉外壳，不是独立平台版本。
- macOS app 名称、图标、签名、打包和自动更新还没有产品化。

## 开发架构

Terminal Finder 的产品事实由 Rust core 持有，macOS 客户端负责窗口和交互。

默认运行路径是进程内 FFI：

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
│  axum HTTP / WebSocket       │
│  dev / future clients only   │
└─────────────────────────────┘
```

macOS app 通过 UniFFI 直接链接 Rust core 静态库。默认不 spawn 独立后端进程，不依赖本地端口或网络。core 同时保留一个可选 axum HTTP/WebSocket server，只用于联调和未来客户端复用同一套语义。

core 负责：

- workspace state。
- 目录验证、打开、listing 和排序。
- local / S3 provider 路由。
- S3 connection registry 和 provider capabilities。
- 文件上传、下载、删除、新建目录、重命名。
- PTY session、workspace-bound terminal、cwd 同步和 runtime 生命周期。

macOS 客户端负责：

- AppKit / SwiftUI 窗口、外壳、布局和视觉状态。
- 选择态、焦点、菜单、toolbar、alert 和 sheet。
- 系统默认应用打开文件。
- Keychain 凭据保存和连接配置展示。
- 终端面板高度、viewport 测量和 resize debounce。

## 仓库结构

```text
terminal-finder/
├── core/                       # Rust core（业务核心 + 可选 server）
│   ├── src/lib.rs              # 库入口与 UniFFI scaffolding
│   ├── src/ffi/                # UniFFI facade：暴露给 Swift 的接口与 DTO
│   ├── src/workspace/          # workspace state、service、Docker/rclone runtime
│   ├── src/vfs/                # local / S3 provider 抽象
│   ├── src/connection/         # S3 连接与凭据容器
│   ├── src/terminal/           # PTY session、cwd binding、terminal websocket
│   ├── src/api/                # 可选 axum HTTP/RPC/WebSocket 适配层
│   └── Cargo.toml
├── clients/MacOS/              # Swift + AppKit macOS 客户端
│   ├── MacOS/API/              # FFI / 可选 HTTP client 与 DTO
│   ├── MacOS/Core/Generated/   # UniFFI 生成的 Swift 绑定
│   ├── MacOS/ViewModels/       # workspace、terminal、connection 状态
│   ├── MacOS/Views/Finder/     # Native Finder 外壳与终端面板
│   ├── MacOS/Views/Windows98/  # Windows 98 外壳
│   ├── MacOS/Views/WindowsXP/  # Windows XP 外壳
│   ├── MacOS/Services/         # Keychain、thumbnail、alert、打开文件等服务
│   ├── Vendor/CoreFFI/         # vendored Rust 静态库与头文件
│   └── MacOSTests/             # macOS 客户端测试
├── protocol/README.md          # 可选 HTTP server 的协议说明
├── WIN98_SKIN_DESIGN.md        # Win98 外壳开发文档
├── XP_SKIN_DESIGN.md           # XP 外壳开发文档
└── AGENTS.md                   # agent 操作规范
```

## 技术栈

Core:

- Rust 2024
- UniFFI
- tokio
- portable-pty
- OpenDAL
- serde / serde_json
- thiserror / anyhow
- tracing
- axum（可选 `server` feature）

macOS client:

- Swift
- AppKit + SwiftUI
- SwiftTerm
- QuickLookThumbnailing
- XCTest

## 构建并运行 macOS app

用 Xcode 打开：

```text
clients/MacOS/MacOS.xcodeproj
```

选择 `MacOS` scheme 后运行即可。

macOS 客户端链接的是 `clients/MacOS/Vendor/CoreFFI/` 里的 Rust 静态库。修改 Rust core 后，需要刷新 vendored FFI 产物：

```sh
clients/MacOS/scripts/refresh-core-ffi.sh
```

这个脚本会重编 core 静态库，并重新生成 Swift 绑定。接口没变时，生成出的绑定通常不会变化，但 `.a` 仍需要更新，app 才会链接到新的 core 逻辑。

## 运行可选 HTTP server

默认 macOS app 不走 HTTP server。只有需要联调 server mode 或未来客户端协议时才运行：

```sh
cd core
cargo run
```

默认监听：

```text
http://127.0.0.1:3587
```

手动检查：

```sh
curl http://127.0.0.1:3587/health
curl -X POST http://127.0.0.1:3587/rpc \
  -H 'Content-Type: application/json' \
  -d '{"method":"core.ping","params":{}}'
```

## 测试

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

## 协议

可选 HTTP server 的协议文档在 [`protocol/README.md`](protocol/README.md)。默认 macOS 客户端走 FFI，但 FFI 与 HTTP/RPC 尽量镜像同一套方法语义。

常用能力包括：

- `workspace.getState` / `workspace.openDirectory` / `workspace.listDirectory`
- `connection.create` / `restore` / `list` / `remove` / `capabilities`
- `workspace.uploadFile` / `downloadFile` / `deleteEntry` / `createRemoteDirectory` / `renameEntry`
- `terminal.create` / `createWorkspace` / `createConnection` / `input` / `resize` / `close`
- terminal cwd update / compare / controlled directory change

## License

MIT License. See [`LICENSE`](LICENSE).
