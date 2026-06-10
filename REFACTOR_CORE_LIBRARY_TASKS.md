# Core 库化重构 Task List（Rust core → Swift 可调用库）

> 目标：把 `core/` 从「独立 axum 进程 + HTTP/WebSocket」重构为「进程内库」，由 macOS Swift 端通过 **UniFFI** 直接调用，消除子进程与本地 socket。现有 axum 服务端降级为可选 `server` feature，保留给未来 Web / 多客户端。

## 决策基线（已确认）

| 决策项 | 选择 | 影响 |
|---|---|---|
| FFI 绑定方案 | **UniFFI**（proc-macro 模式） | 从 Rust 接口自动生成 Swift 绑定，原生支持 async / 回调 / 错误枚举 |
| 旧 HTTP/WS 传输层 | **保留为可选 `server` feature** | 业务逻辑抽成库，FFI 与 axum server 都作为薄适配层 |
| crate 拆分 | **暂不拆 crate**（遵循 `core/agent.md`） | 单 crate 内 `[lib]` + `[[bin]]` 双 target，不提前建 `core/crates/*` |
| PTY 字节传输 | 进程内直接 `Vec<u8>` ↔ Swift `Data` | 不再需要 base64 编码（base64 仅旧 WS 路径使用） |

## 当前架构 → 目标架构

```text
[现状]
Swift App ──spawn子进程──> core(bin, axum) ──监听 127.0.0.1:3587──> HTTP /rpc + WS /events,/terminal
   BackendProcessLauncher / BackendClient / EventClient / TerminalClient(URLSession/WebSocket)

[目标]
Swift App ──UniFFI(进程内)──> libterminal_finder_core (CoreHandle facade)
                                  ├─ workspace service (业务逻辑, 传输无关)
                                  ├─ terminal registry/session (PTY, 传输无关)
                                  └─ AppState (唯一事实来源)
（可选）cargo run --features server  ──> 同一套业务逻辑 + axum 适配层，给未来 Web 客户端
```

## 不变量（重构全程必须守住）

- backend 仍是 workspace / filesystem / terminal 的唯一事实来源（见 `core/agent.md`）。
- 协议语义不回退：`core.ping` / `workspace.getState` / `workspace.openDirectory` / `workspace.listDirectory` 行为与错误分类保持一致。
- workspace state 仍集中在 `src/workspace/state.rs` + `AppState`，FFI/server 层只读取或调用 service。
- Swift 端 `BackendClientProtocol` / 各 ViewModel 接口尽量不变，只换底层实现，降低回归面。
- 新增源码 / 配置 / 生成脚本必须纳入 git 管理。

---

## Phase 0 — 设计固化与集成方案（先纸面，后动码）

> 目的：在改动代码前，把 UniFFI 版本、链接产物、Xcode 集成方式钉死，避免中途返工。

- [ ] **T0.1 选定 UniFFI 版本与模式**
  - 关键改动：确定 `uniffi` 版本（建议 0.28+，proc-macro 模式，不写 `.udl`）；确认其 async + callback interface 支持矩阵。
  - 验收：在文档中记录版本号与所用 feature（`tokio`、`cli`/`bindgen`）。
- [ ] **T0.2 选定链接产物形态**
  - 关键改动：macOS App 嵌入选 `staticlib`（推荐，签名/分发简单）还是 `cdylib`；确定是否打包为 **XCFramework**。
  - 依赖：影响 Phase 5 集成脚本。
  - 验收：一张「Rust 产物 → Xcode target」的链接路径图。
- [ ] **T0.3 接口面盘点（RPC + 事件 + 终端）**
  - 关键改动：列出需要跨 FFI 暴露的全部方法与类型（见下表「FFI 接口草案」），逐项标注 sync/async/callback。
  - 验收：接口清单评审通过，作为 Phase 3/4 的实现依据。
- [ ] **T0.4 写一份轻量 ADR**
  - 关键改动：在 `core/` 或根目录新增 `docs/adr/0001-core-as-uniffi-library.md`，记录方案、取舍、回滚条件。
  - 验收：ADR 入库；`DEVELOPMENT_PLAN.md` 不在本阶段修改（待 Phase 8 统一更新）。

### FFI 接口草案（供 T0.3 评审）

| 现 RPC / 通道 | UniFFI 暴露形式 | 同步性 | 备注 |
|---|---|---|---|
| `core.ping` / `/health` | `CoreHandle.ping()` | async | 返回 `PingInfo` record |
| `workspace.getState` | `CoreHandle.workspaceState()` | async | 返回 `WorkspaceStateDto` |
| `workspace.openDirectory` | `CoreHandle.openDirectory(path)` | async | 返回 `OpenDirectoryDto` |
| `workspace.listDirectory` | `CoreHandle.listDirectory(path)` | async | 返回 `DirectoryListingDto` |
| `/events`（backend.ready/heartbeat/error） | `CoreEventListener` 回调接口 | callback | 启动时注册一次 |
| `terminal.create` | `CoreHandle.createTerminal(cwd,cols,rows,shell,listener)` | async → `sessionId` | listener 为该 session 的回调 |
| `terminal.input` | `CoreHandle.sendInput(sessionId, data)` | sync(快) | `data: Vec<u8>`，无 base64 |
| `terminal.resize` | `CoreHandle.resizeTerminal(sessionId,cols,rows)` | async | |
| `terminal.close` | `CoreHandle.closeTerminal(sessionId)` | async | |
| `terminal.output/exit/error` | `TerminalEventListener` 回调接口 | callback | 替代 WS 下行帧 |
| RPC 错误体 | `CoreError`（uniffi error enum） | — | 保留 `code`/`message` 语义 |

---

## Phase 1 — crate 结构改造（lib + 可选 server bin）

> 目的：让同一份业务逻辑既能作为库被链接，又能在 `--features server` 下跑 axum。**此阶段只搬结构，不改业务行为。**

- [ ] **T1.1 改造 `core/Cargo.toml`**
  - 文件：`core/Cargo.toml`：修改
  - 关键改动：
    - 新增 `[lib]`：`name = "terminal_finder_core"`，`crate-type = ["lib", "staticlib", "cdylib"]`。
    - 新增 `uniffi` 依赖（含所需 feature）。
    - 定义 `[features] server = ["dep:axum", "dep:tokio-tungstenite", ...]`，把 `axum` / `tokio-tungstenite` 等仅服务端依赖标为 `optional = true`。
    - 新增 `[[bin]] name = "core"`，`path = "src/bin/server.rs"`，`required-features = ["server"]`。
  - 影响：默认 `cargo build` 只构建库；server 需显式开 feature。
  - 回滚：还原 `Cargo.toml`。
- [ ] **T1.2 新建 `src/lib.rs`，迁移模块声明**
  - 文件：`core/src/lib.rs`：新增；`core/src/main.rs`：删除/搬移
  - 关键改动：把 `mod api/clock/error/state/terminal/workspace` 的声明从 `main.rs` 移到 `lib.rs`；`api` 整体 `#[cfg(feature = "server")]` 门控。
  - 验收：`cargo build`（仅库）通过。
  - 回滚：恢复 `main.rs` 模块声明。
- [ ] **T1.3 server bin 迁移到 `src/bin/server.rs`**
  - 文件：`core/src/bin/server.rs`：新增（原 `main.rs` 内容）
  - 关键改动：`main()` 改为依赖库导出的 `api::routes::router` + `AppState`；保留 stdin EOF / graceful shutdown 逻辑；整文件在 `server` feature 下编译。
  - 验收：`cargo build --features server` 通过，`cargo run --features server` 行为同今天的 `cargo run`。
  - 回滚：删 `bin/server.rs`，恢复 `main.rs`。
- [ ] **T1.4 双构建冒烟**
  - 验收：`cargo build` 与 `cargo build --features server` 均绿；`cargo test` 现有用例全过。

---

## Phase 2 — 业务逻辑与传输层解耦

> 目的：让 `workspace` / `terminal` / `state` 对 axum 零依赖，使其能同时服务 FFI 与 server。

- [ ] **T2.1 拆分 `error.rs`：核心错误 vs axum 适配**
  - 文件：`core/src/error.rs`：修改
  - 关键改动：保留与传输无关的错误类型（`code()` / `message()` / `status` 分类），把 `impl IntoResponse for ApiError` 与 `axum::Json` 相关部分挪到 `#[cfg(feature = "server")]` 适配（如 `src/api/error.rs`）。
  - 影响：FFI 层将基于同一错误类型映射到 `CoreError`（Phase 3）。
  - 回滚：合并回单文件。
- [ ] **T2.2 核查 workspace service 无 axum 依赖**
  - 文件：`core/src/workspace/{service,fs,state,dto}.rs`：核查/微调
  - 关键改动：`service.rs` 已是 `&AppState → DTO/ApiError` 形态，确认无 `axum::` 引用；若有则下沉到 controller。
  - 验收：`workspace` 模块在仅库构建下编译通过。
- [ ] **T2.3 核查 terminal 层无 axum 依赖**
  - 文件：`core/src/terminal/{session,registry}.rs`：核查；`core/src/terminal/websocket.rs`：门控
  - 关键改动：`session.rs`（PTY + tokio mpsc）与 `registry.rs` 保持传输无关；`websocket.rs` 与 `api/terminal.rs` 整体 `#[cfg(feature = "server")]`。
  - 验收：terminal 业务逻辑在仅库构建下编译通过。
- [ ] **T2.4 api 层全部门控为 server feature**
  - 文件：`core/src/api/**`：加 `#[cfg(feature = "server")]`
  - 关键改动：`routes/rpc/controllers/events/terminal/websocket` 仅在 server 下编译。
  - 验收：仅库构建不再链接任何 `api::*`。

---

## Phase 3 — UniFFI facade：RPC 方法

> 目的：用一个 `CoreHandle` 对象承载进程内 API，内部持有 `AppState` 与 tokio 运行时。

- [ ] **T3.1 新建 `src/ffi/mod.rs`（UniFFI 接口层）**
  - 文件：`core/src/ffi/mod.rs`：新增；`core/src/lib.rs`：挂载 + `uniffi::setup_scaffolding!()`
  - 关键改动：定义 `#[derive(uniffi::Object)] CoreHandle`，内部 `Arc<AppState>` + `Arc<tokio::runtime::Runtime>`（multi-thread）。`#[uniffi::constructor] fn new()`。
  - 验收：`CoreHandle::new()` 可构造并被 uniffi 识别。
- [ ] **T3.2 定义跨边界 DTO（uniffi Record/Enum）**
  - 文件：`core/src/ffi/dto.rs`：新增
  - 关键改动：为 `PingInfo` / `WorkspaceStateDto` / `DirectoryListingDto` / `DirectoryEntryDto` / `EntryKind` 定义 `#[derive(uniffi::Record/Enum)]`，并写 `From<workspace::dto::*>` 转换；字段命名按 Swift 习惯（UniFFI 自动 camelCase）。
  - 决策点：复用现有 serde DTO 还是新建 uniffi DTO —— 推荐**新建 uniffi DTO + From 转换**，避免给业务 DTO 叠加 FFI 派生。
  - 验收：DTO 编译通过，转换有单测。
- [ ] **T3.3 定义 `CoreError`（uniffi error）**
  - 文件：`core/src/ffi/error.rs`：新增
  - 关键改动：`#[derive(uniffi::Error)] enum CoreError { ... }`，携带 `code: String` + `message: String`；写 `From<ApiError>`，保持 `unknown_method` / `invalid_params` / `not_directory` / `filesystem_read_failed` / `background_task_failed` 语义。
  - 验收：错误码与 `protocol/README.md` 一致。
- [ ] **T3.4 暴露异步 RPC 方法**
  - 文件：`core/src/ffi/mod.rs`：修改
  - 关键改动：`#[uniffi::export(async_runtime = "tokio")]` impl 内实现 `ping` / `workspace_state` / `open_directory(path)` / `list_directory(path)`，内部直接调用现有 `workspace::service::*`。
  - 关键技术点：UniFFI async 需绑定 tokio executor；确认 `uniffi` 开启 `tokio` feature 且 runtime 在 `CoreHandle` 生命周期内常驻。
  - 验收：可在 Rust 集成测试里 `block_on` 调用这些方法并断言结果。

---

## Phase 4 — UniFFI facade：事件流与终端流（callback interface）

> 目的：用回调接口替代 `/events` 与 `/terminal` 两条 WebSocket 下行流。

- [ ] **T4.1 定义 `CoreEventListener` 回调接口**
  - 文件：`core/src/ffi/events.rs`：新增
  - 关键改动：`#[uniffi::export(callback_interface)] trait CoreEventListener { fn on_ready(..); fn on_heartbeat(); fn on_error(code,message); }`；`CoreHandle` 提供 `register_event_listener(listener)`。
  - 关键技术点：回调由 Swift 实现，Rust 侧从 `AppState.events` broadcast 桥接到回调；回调内不可阻塞。
  - 验收：注册后能收到一次 `on_ready` 与周期 `on_heartbeat`。
- [ ] **T4.2 定义 `TerminalEventListener` 回调接口**
  - 文件：`core/src/ffi/terminal.rs`：新增
  - 关键改动：`trait TerminalEventListener { fn on_output(data: Vec<u8>); fn on_exit(code: Option<i32>, signal: Option<i32>); fn on_error(code,message); }`。
  - 验收：trait 被 uniffi 识别，可在 Rust 侧持有并调用。
- [ ] **T4.3 终端生命周期方法**
  - 文件：`core/src/ffi/terminal.rs`：修改；桥接 `terminal::registry`/`session`
  - 关键改动：
    - `create_terminal(cwd, cols, rows, shell, listener) -> SessionId`
    - `send_input(session_id, data: Vec<u8>)`（高频、同步、快返回）
    - `resize_terminal(session_id, cols, rows)`
    - `close_terminal(session_id)`
    - 在 runtime 上把现有 `TerminalEvent`（tokio mpsc）转发到对应 `TerminalEventListener`。
  - 关键技术点：每个 session 绑定一个 listener；`Uuid` 经 FFI 用 `String` 表示；字节直接 `Vec<u8>`，删去 base64。
  - 验收：创建 session → 输入 `ls\n` → 收到 `on_output` → `close` → 收到 `on_exit`。
- [ ] **T4.4 关停与资源回收**
  - 关键改动：`CoreHandle` Drop 时优雅关闭所有 session 与 runtime；确认无悬挂线程（PTY reader thread / exit poll）。
  - 验收：反复 create/close 无 fd / 线程泄漏。

---

## Phase 5 — 生成绑定与 Xcode 集成

- [ ] **T5.1 接入 uniffi-bindgen 生成 Swift**
  - 文件：`core/build.rs` 或独立 `uniffi-bindgen` bin：新增；生成脚本 `scripts/gen-bindings.sh`：新增
  - 关键改动：生成 `TerminalFinderCore.swift` + `*FFI.modulemap` + header。
  - 验收：脚本一键产出绑定文件，纳入 git 或纳入构建产物策略明确。
- [ ] **T5.2 产出链接产物（按 T0.2 决策）**
  - 关键改动：`cargo build --release` 产出 `libterminal_finder_core.a`（或 XCFramework）；脚本封装多架构（arm64 / x86_64）。
  - 验收：产物可被 Xcode 链接，符号可见。
- [ ] **T5.3 接入 MacOS target**
  - 文件：`clients/MacOS/MacOS.xcodeproj`、生成的桥接文件
  - 关键改动：把静态库 + modulemap + 生成的 Swift 加入 target；配置 Library Search Paths / 链接系统库。
  - 验收：Swift 端能 `import` 生成模块并 `CoreHandle()` 成功初始化。

---

## Phase 6 — Swift 端切换到 FFI

> 目的：在不动 ViewModel 协议的前提下，替换底层传输实现。

- [ ] **T6.1 用 FFI 实现 `BackendClientProtocol`**
  - 文件：`clients/MacOS/MacOS/API/BackendClient.swift`：新增 FFI 实现（或替换）
  - 关键改动：新建 `FFIBackendClient: BackendClientProtocol`，内部持有 `CoreHandle`，把 `health/ping/getState/openDirectory/listDirectory` 接到 FFI 异步方法。
  - 验收：现有 `BackendConnectionViewModel` / `WorkspaceBrowserViewModel` 测试无需改协议即可跑通。
- [ ] **T6.2 用回调实现事件与终端客户端**
  - 文件：`clients/MacOS/MacOS/API/{EventClient,TerminalClient}.swift`：改造
  - 关键改动：实现 `CoreEventListener` / `TerminalEventListener`，把回调桥接到现有事件/终端数据流（注意切回主线程更新 UI）。
  - 验收：终端面板可输入输出、resize、退出；事件通道 ready/heartbeat 正常。
- [ ] **T6.3 移除子进程启动逻辑**
  - 文件：`clients/MacOS/MacOS/Services/BackendProcessLauncher.swift`：删除或改为 server 模式专用；`ContentView`/启动流程：去掉 `/health` 轮询门槛
  - 关键改动：进程内库无需 spawn 与健康轮询，启动即 `CoreHandle()`；如保留 server 调试模式则隔离到 debug flag。
  - 验收：App 冷启动不再 fork core 子进程，无 3587 端口占用。
- [ ] **T6.4 清理 base64 / URLSession / WebSocket 残留**
  - 文件：`RpcModels.swift` 等：精简
  - 关键改动：删除仅 HTTP/WS 路径需要的编解码与 URL 端点常量（或下沉到 server 调试客户端）。
  - 验收：FFI 路径下无 `URLSession` / `URLSessionWebSocketTask` 依赖。

---

## Phase 7 — 测试与验证

- [ ] **T7.1 Rust 库级集成测试**
  - 文件：`core/tests/ffi_facade.rs`：新增
  - 关键改动：覆盖 ping / getState / openDirectory（含错误码）/ listDirectory / terminal 全生命周期。
  - 验收：`cargo test`（仅库）全绿。
- [ ] **T7.2 server feature 回归**
  - 验收：`cargo test --features server` + `cargo run --features server` 行为与重构前一致（HTTP/WS 协议不回退）。
- [ ] **T7.3 Swift 测试更新**
  - 文件：`clients/MacOS/MacOSTests/*`：按需更新 mock
  - 关键改动：协议保持不变，主要更新依赖注入与 listener mock。
  - 验收：`xcodebuild test` 通过。
- [ ] **T7.4 端到端手测脚本**
  - 验收：浏览目录 / 打开目录错误路径 / 新建终端 / `vim` 等全屏程序 / resize / 退出，全部正常。

---

## Phase 8 — 文档与收尾（用户确认后再改项目文档）

> `core/agent.md` 规定：非用户要求不改项目文档。以下在重构落地、用户确认后统一更新。

- [ ] **T8.1 更新 `protocol/README.md`**：标注 FFI 为主传输，HTTP/WS 为 `server` feature 备用；同步接口表。
- [ ] **T8.2 更新 `DEVELOPMENT_PLAN.md`**：架构图改为库内嵌模式；记录 server feature 用途。
- [ ] **T8.3 更新 `core/agent.md`**：补充 lib/server 双 target 结构约束与 FFI 层职责边界。
- [ ] **T8.4 更新 `README.md` 构建说明**：新增「生成绑定 / 链接静态库」步骤。

---

## 任务依赖关系

```text
Phase 0 ──> Phase 1 ──> Phase 2 ──> Phase 3 ──> Phase 4 ──> Phase 5 ──> Phase 6 ──> Phase 7 ──> Phase 8
                            │            └──────────┴──> (T3/T4 可在 T2 完成后并行推进)
                            └──> server feature 回归(T7.2) 贯穿 Phase 1~7
```

## 风险与回滚

| 风险 | 等级 | 缓解 / 回滚 |
|---|---|---|
| UniFFI async + tokio 运行时桥接细节 | 中 | Phase 3 先用最小方法验证 executor 绑定，再铺开；失败可退回「同步方法 + 内部 block_on」 |
| 回调接口跨线程与 UI 主线程 | 中 | Swift listener 内统一 `DispatchQueue.main` 派发；Rust 回调不阻塞 |
| 静态库多架构 / 签名 / 链接 | 中 | T0.2 先定 XCFramework 方案；保留 `server` feature 作为可降级的子进程后路 |
| 协议语义回退 | 高 | T7.2 server 回归 + Swift 协议不变，逐方法对照 `protocol/README.md` |
| PTY 线程 / fd 泄漏 | 中 | T4.4 专项验证 create/close 循环 |

## 整体回滚策略

- 全程在功能分支进行；每个 Phase 一组提交，单独可回滚。
- `server` feature 全程保留可用：任何阶段卡住，都能退回「子进程 + HTTP/WS」旧路径继续交付。
- Swift 端通过 `BackendClientProtocol` 抽象切换实现，可在 FFI 实现与旧 HTTP 实现间快速回退。

## 验证清单（合并前）

- [ ] `cargo build` / `cargo build --features server` 均通过
- [ ] `cargo test` / `cargo test --features server` 均通过
- [ ] `xcodebuild test`（MacOS target）通过
- [ ] App 冷启动无子进程、无 3587 端口监听（FFI 模式）
- [ ] 终端全生命周期手测通过（输入/输出/resize/退出）
- [ ] 协议语义对照 `protocol/README.md` 无回退
- [ ] 新增文件全部纳入 git
