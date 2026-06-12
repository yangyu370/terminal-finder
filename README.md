# Terminal Finder

Terminal Finder 是一个本地优先的 workspace / file browser 原型。项目目标是把文件浏览、终端会话、搜索、Git 状态等能力集中到一个 Rust core 里，再由 macOS、未来 Web 或其他平台客户端负责原生展示。

当前第一客户端是 macOS app。它的体验方向接近 Finder：侧边栏、路径输入、目录列表、后退/前进、上级目录、刷新、隐藏文件切换、多种显示模式（图标 / 列表 / 分栏 / 画廊），以及窗口内终端面板。Rust core 是 source of truth，负责 workspace 状态、目录校验、目录 listing 和 PTY session 生命周期。

macOS 客户端通过 **UniFFI 进程内 FFI** 直接链接 Rust core 静态库（不再 spawn 独立后端进程）。core 同时保留一个可选的 axum HTTP/WebSocket server（`server` feature），留给未来 Web / 多客户端复用同一份业务逻辑。

## 项目亮点

- **Local-first 架构**：core 是产品核心和唯一事实来源，客户端只做表现层。
- **进程内 FFI 集成**：macOS 客户端经 UniFFI 生成的 Swift 绑定，在进程内直接调用 Rust core，无需本地网络、端口或子进程。
- **业务逻辑与传输解耦**：core 业务层（workspace / terminal / state）独立于 axum；HTTP/WebSocket 仅作为可选适配层（`server` feature），可单独 `--no-default-features --lib` 编译。
- **清晰的 backend/client 边界**：Rust core 管文件系统事实和协议语义，Swift 客户端管原生 UI、显示模式、选择态、焦点、alert 和平台打开文件行为。
- **原生 macOS 表现层**：基于 AppKit 重建的 Finder-like 主窗口，支持图标 / 列表 / 分栏 / 画廊四种显示模式，终端集成 SwiftTerm。
- **自动化测试覆盖关键状态流**：core 有 Rust 单元测试，macOS client 有 ViewModel、terminal session 和 Finder 显示模式测试。

## 当前功能

- 连通性检查 `ping`（FFI）/ `core.ping`（HTTP）与 `/health`
- backend-owned workspace state（`workspaceRoot` / `currentDirectory`）
- 打开目录、列目录、目录排序和 symlink 基本处理
- macOS 侧边栏常用目录入口
- 路径输入，支持相对路径和 `~`
- 后退、前进、上级目录、刷新
- 隐藏文件显示/隐藏切换
- 文件双击后用系统默认应用打开
- Finder 显示模式：图标（icon）、列表（list）、分栏（column）、画廊（gallery）
- backend lifecycle 事件：`backend.ready`、`heartbeat`
- terminal 最小闭环：create、input、output、resize、close、exit（macOS 经 FFI 回调送达）
- macOS 窗口内终端面板，支持拖拽调整高度和 viewport resize debounce

## 架构

```text
┌─────────────────────────────┐
│  macOS client (AppKit)      │
│  Views / ViewModels / API   │
└──────────────┬──────────────┘
               │ UniFFI（进程内，Swift ↔ Rust）
┌──────────────▼──────────────┐
│  Rust core（source of truth）│
│  workspace / terminal / state│
└──────────────┬──────────────┘
               │ 可选 `server` feature
┌──────────────▼──────────────┐
│  axum HTTP / WebSocket       │
│  （未来 Web / 多客户端）       │
└─────────────────────────────┘
```

core 以单 crate 提供 `lib` / `staticlib` / `cdylib` 三种产物：

- `lib` + `staticlib`：被 macOS 客户端经 FFI 链接。
- `cdylib`：供 `uniffi-bindgen` 读取元数据、生成 Swift 绑定。
- `bin`（`core`，`server` feature）：可选的本地 HTTP/WebSocket 服务端。

## 仓库结构

```text
terminal-finder/
├── core/                       # Rust core（业务核心 + 可选 server）
│   ├── src/lib.rs              # 库入口与 UniFFI scaffolding
│   ├── src/ffi/               # UniFFI facade：进程内暴露给 Swift 的接口与 DTO
│   ├── src/workspace/         # workspace state、service、DTO、filesystem 适配
│   ├── src/terminal/          # PTY session、registry、terminal WebSocket
│   ├── src/api/               # 可选 axum HTTP/RPC/WebSocket 适配层（server feature）
│   ├── src/bin/server.rs      # 可选 HTTP/WebSocket 服务端入口
│   ├── src/bin/uniffi-bindgen.rs  # Swift 绑定生成工具（bindgen feature）
│   ├── scripts/gen-bindings.sh    # 生成 Swift 绑定
│   └── Cargo.toml
├── clients/MacOS/              # Swift + AppKit macOS 客户端
│   ├── MacOS/API/             # core 客户端实现（FFI）与 DTO
│   ├── MacOS/Core/Generated/  # uniffi-bindgen 生成的 Swift 绑定
│   ├── MacOS/ViewModels/      # UI 状态与异步编排
│   ├── MacOS/Views/Finder/    # AppKit Finder 主窗口、工具栏、各显示模式与终端面板
│   ├── MacOS/Services/        # alert、打开文件等平台服务
│   ├── Vendor/CoreFFI/        # 已 vendoring 的 Rust 静态库与头文件 / module map
│   ├── scripts/refresh-core-ffi.sh  # 重建并 vendoring core FFI 产物
│   └── MacOSTests/            # macOS 客户端测试
├── protocol/README.md          # 可选 HTTP server 的协议说明
├── PREVIEW_FEATURE_DESIGN.md   # 文件预览功能设计稿（未实现）
├── THEME_DECOUPLING_DESIGN.md  # 主题解耦设计稿（未实现）
└── agent.md                    # agent 操作规范（根 / core / clients 各一份）
```

## 技术栈

Core (Rust):

- Rust（edition 2024）
- UniFFI（生成 Swift 绑定）
- tokio
- portable-pty
- serde / serde_json
- thiserror / anyhow
- tracing
- axum（可选，`server` feature）

macOS client:

- Swift
- AppKit
- SwiftTerm
- XCTest

## 构建并运行 macOS app

macOS 客户端在进程内链接预先 vendoring 的 Rust 静态库（`clients/MacOS/Vendor/CoreFFI/`），不再在构建阶段编译 core，也不 spawn 后端进程。

用 Xcode 打开：

```text
clients/MacOS/MacOS.xcodeproj
```

选择 `MacOS` scheme 后运行即可。

修改 Rust core 接口后，需要重新生成绑定并刷新 vendoring 产物：

```sh
clients/MacOS/scripts/refresh-core-ffi.sh
```

该脚本会：

1. `cargo build --release` 产出 `libterminal_finder_core.a`；
2. 用 `uniffi-bindgen` 生成 Swift 绑定；
3. 拷贝静态库、头文件、module map 到 `Vendor/CoreFFI/`，并把 Swift 绑定放进 `MacOS/Core/Generated/`。

完成后再用 Xcode 构建。

## 运行可选 HTTP server

core 同时提供一个可选的本地 HTTP/WebSocket 服务端（`server` feature，默认开启），用于联调和未来 Web 客户端：

```sh
cd core
cargo run
```

默认监听：

```text
http://127.0.0.1:3587
```

可以手动检查：

```sh
curl http://127.0.0.1:3587/health
curl -X POST http://127.0.0.1:3587/rpc \
  -H 'Content-Type: application/json' \
  -d '{"method":"core.ping","params":{}}'
```

只编译业务库（不带 server 适配层）：

```sh
cd core
cargo build --no-default-features --lib
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

可选 HTTP server 的协议文档在 [`protocol/README.md`](protocol/README.md)。FFI 接口镜像同一套语义。

入口：

- `GET /health`
- `POST /rpc`
- `GET /events`
- `GET /terminal`

当前 RPC / FFI 方法：

- `core.ping` / `ping`
- `workspace.getState` / `workspaceState`
- `workspace.openDirectory` / `openDirectory`
- `workspace.listDirectory` / `listDirectory`
- terminal：`createTerminal`、`sendTerminalInput`、`resizeTerminal`、`closeTerminal`（输出 / 退出 / 错误经事件回调送达）

## 当前限制

这个项目仍处于开发阶段，不建议按可分发产品理解。

- PTY 会创建真实 shell 进程，会显著扩大本地攻击面。
- 可选 HTTP server（`/rpc`、`/events`、`/terminal`）目前还没有统一 token 鉴权、Origin/Host 校验和完整握手保护。
- 终端 session 仍需补充更严格的会话数量上限和尺寸边界处理。
- 文件变更能力尚未实现：删除、移动、重命名、创建等操作仍是后续阶段。
- 文件 watcher、搜索、索引、Git awareness、插件和多平台客户端仍在路线图中。
- 文件预览、主题切换目前仅有设计稿（见 `PREVIEW_FEATURE_DESIGN.md`、`THEME_DECOUPLING_DESIGN.md`），尚未实现。
- macOS app 名称、AppIcon、分发签名和打包体验仍需要 polish。

## License

MIT License. See [`LICENSE`](LICENSE).
