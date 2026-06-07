# Terminal Finder

Terminal Finder 是一个本地优先的 workspace / file browser 原型。项目目标是把文件浏览、终端会话、搜索、Git 状态等能力集中到一个 Rust 本地后端里，再由 macOS、未来 Web 或其他平台客户端负责原生展示。

当前第一客户端是 macOS app。它的体验方向接近 Finder：侧边栏、路径输入、目录列表、后退/前进、上级目录、刷新、隐藏文件切换，以及窗口内终端面板。Rust core 是 source of truth，负责 workspace 状态、目录校验、目录 listing、HTTP RPC、WebSocket event stream 和 PTY session 生命周期。

## 项目亮点

- **Local-first 架构**：backend 只监听 `127.0.0.1`，客户端启动并连接本地 core 进程。
- **清晰的 backend/client 边界**：Rust core 管文件系统事实和协议语义，Swift 客户端管原生 UI、选择态、焦点、alert 和平台打开文件行为。
- **可调试的 JSON 协议**：HTTP JSON RPC 处理请求/响应，WebSocket 处理 backend events 和 terminal stream。
- **原生 macOS 表现层**：SwiftUI 组合主界面，文件列表使用 AppKit `NSTableView`，终端集成 SwiftTerm。
- **自动化测试覆盖关键状态流**：backend 有 Rust 单元测试，macOS client 有 ViewModel、WebSocket client 和 terminal session 测试。

## 当前功能

- backend health check 和 `core.ping`
- backend-owned workspace state
- 打开目录、列目录、目录排序和 symlink 基本处理
- macOS 侧边栏常用目录入口
- 路径输入，支持相对路径和 `~`
- 后退、前进、上级目录、刷新
- 隐藏文件显示/隐藏切换
- 文件双击后用系统默认应用打开
- backend lifecycle event WebSocket：`backend.ready`、`heartbeat`
- terminal WebSocket 最小闭环：create、input、output、resize、close、exit
- macOS 窗口内终端面板，支持拖拽调整高度和 viewport resize debounce

## 仓库结构

```text
terminal-finder/
├── core/                  # Rust local backend
│   ├── src/api/           # HTTP/RPC/WebSocket routes and controllers
│   ├── src/workspace/     # workspace state, service, DTOs, filesystem adapter
│   ├── src/terminal/      # PTY session, registry, terminal WebSocket
│   └── Cargo.toml
├── clients/MacOS/         # Swift + SwiftUI/AppKit macOS client
│   ├── MacOS/API/         # backend RPC/WebSocket clients and DTOs
│   ├── MacOS/ViewModels/  # UI state and async orchestration
│   ├── MacOS/Views/       # SwiftUI/AppKit views and components
│   └── MacOSTests/        # macOS client tests
├── protocol/README.md     # current protocol notes
└── DEVELOPMENT_PLAN.md    # roadmap and phase notes
```

## 技术栈

Backend:

- Rust
- tokio
- axum
- serde / serde_json
- tracing
- portable-pty

macOS client:

- Swift
- SwiftUI
- AppKit
- URLSession / URLSessionWebSocketTask
- SwiftTerm
- XCTest

## 运行 backend

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

## 运行 macOS app

用 Xcode 打开：

```text
clients/MacOS/MacOS.xcodeproj
```

选择 `MacOS` scheme 后运行。macOS app 会在构建阶段编译 Rust core，并把 backend binary 放进 app bundle resources。启动后客户端会检查 `/health`，必要时自动启动本地 backend 进程。

## 测试

Backend:

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

当前协议文档在 [`protocol/README.md`](protocol/README.md)。主要入口：

- `GET /health`
- `POST /rpc`
- `GET /events`
- `GET /terminal`

当前 RPC 方法：

- `core.ping`
- `workspace.getState`
- `workspace.openDirectory`
- `workspace.listDirectory`

## 当前限制

这个项目仍处于开发阶段，不建议按可分发产品理解。

- `/terminal` 已经能创建真实 shell/PTY，会显著扩大本地攻击面。
- `/rpc`、`/events`、`/terminal` 目前还没有统一 token 鉴权、Origin/Host 校验和完整握手保护。
- 终端 session 还需要补充更严格的连接归属校验、会话数量上限和尺寸边界处理。
- 文件变更能力尚未实现：删除、移动、重命名、创建等操作仍是后续阶段。
- 文件 watcher、搜索、索引、Git awareness、插件和多平台客户端仍在路线图中。
- macOS app 名称、AppIcon、分发签名和打包体验仍需要 polish。

## 展示建议

如果给懂代码的人展示，建议先讲清楚三件事：

1. Rust backend 是产品核心，client 不直接维护文件系统事实。
2. HTTP RPC 和 WebSocket channel 是跨平台客户端复用的协议边界。
3. 当前 demo 重点是 workspace browsing 和 backend/client 生命周期，不是完整 Finder 替代品。

推荐演示路径：

1. 启动 macOS app，展示自动连接 backend。
2. 打开目录、返回、前进、上级目录、刷新。
3. 输入相对路径或 `~` 路径。
4. 切换隐藏文件。
5. 打开窗口内终端面板。
6. 最后展示测试命令和协议文档。

## Roadmap

当前优先级：

- 补齐本地 API 鉴权和 WebSocket handshake 安全。
- 收敛 terminal session 的归属校验、资源上限和尺寸校验。
- 继续打磨 Finder-like 浏览体验。
- 降低 info/warn 日志里的路径和参数暴露。
- 加强目录扫描竞争、锁中毒恢复和并发状态测试。

更长期的方向：

- 文件 watcher 和自动刷新
- 搜索和索引
- Git 状态集成
- 文件变更操作
- Web / Windows / Linux 客户端
- 插件和自动化能力
