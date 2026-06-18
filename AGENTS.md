# Terminal Finder Agent 操作规范

这份文件约束后续 Codex/agent 在仓库根目录级别维护 Terminal Finder 的方式。它不是路线图：当前架构与已实现能力以根目录 `README.md` 为权威描述，后续路线图尚未确定。

## 项目定位

Terminal Finder 是一个 local-first workspace system。

Rust backend 是产品核心和 source of truth。macOS、未来 web、Windows、Linux 客户端都只是连接同一 backend API 的表现层。

当前第一客户端是 `clients/MacOS/`，目标体验接近 Finder，但核心状态和文件系统行为仍由 Rust core 负责。

## 集成架构（权威：README）

- macOS 客户端通过 **UniFFI 进程内 FFI** 直接链接 Rust core 静态库，**不 spawn 独立后端进程、不依赖本地端口或网络**。客户端的 `FFIBackendClient` / `FFIEventClient` / `FFITerminalClient`（`clients/MacOS/MacOS/API/CoreFFIClients.swift`）是默认实现，core 作为进程内状态容器随客户端进程存活。
- core 同时保留一个**可选的 axum HTTP/WebSocket server**（`server` feature，监听 `127.0.0.1:3587`，入口 `/health`、`/rpc`、`/events`、`/terminal`），仅用于联调和未来 Web / 多客户端复用同一份业务逻辑。FFI 接口与 HTTP/RPC 镜像同一套语义。
- 描述客户端与 core 的交互时，默认指**进程内 FFI**；涉及 `/rpc`、`/events`、`:3587`、curl 等只在"可选 server 模式"语境下成立，不要把它们当作客户端与 core 的活契约。

## 现状（已实现 / 未实现）

已实现并需要保持稳定：

- core-owned workspace state 与 `workspace.getState` / `workspace.openDirectory` / `workspace.listDirectory` 语义（FFI 与可选 HTTP 双暴露）。
- 基于 AppKit 重建的 Finder-like 主窗口、sidebar、toolbar、键盘导航，以及图标 / 列表 / 分栏 / 画廊四种显示模式。
- 隐藏文件切换、后退/前进/上级、路径输入、刷新、系统默认应用打开文件等浏览行为。
- backend lifecycle 事件 `backend.ready` / `heartbeat`，经 FFI 回调（或可选 server 模式的 `/events`）送达。进程内模式下 `heartbeat` 由客户端 `FFIEventClient` 按固定间隔合成，用于沿用既有 watchdog 逻辑。
- terminal 最小闭环：`createTerminal` / `sendTerminalInput` / `resizeTerminal` / `closeTerminal`（输出 / 退出 / 错误经事件回调送达），macOS 侧集成 SwiftTerm，窗口内终端面板支持拖拽高度与 viewport resize debounce。

尚未实现（后续阶段，路线图待定，不要因为顺手就提前做）：

- 文件变更操作：delete / move / rename / create。
- file watcher、search / indexing、git awareness、plugins、AI features。
- 文件预览、主题切换（目前仅有设计稿 `PREVIEW_FEATURE_DESIGN.md` / `THEME_DECOUPLING_DESIGN.md`）。
- Web / Windows / Linux 等其他平台客户端。

收敛中的已知后端风险：目录扫描竞争、workspace state 锁中毒恢复、日志路径脱敏、必要的状态并发测试。

## 架构边界

- Core owns workspace state, current directory, directory validation, filesystem facts, process/session lifecycle, protocol semantics, path open/list operations, future file operations, and future search/git/events/plugins/automation.
- Client owns AppKit windows, rendering, selection state, focus, visual/layout state, interaction, platform-native open-file behavior, reusable alerts, connection presentation, and viewport measurement.
- 后端可以暴露平台无关的文件/目录能力；不要让后端依赖 macOS AppKit、Finder 私有体验或某个客户端的 UI 形状。
- 打开文件和系统默认应用是客户端平台行为，但目录导航、路径打开和目录 listing 的事实必须来自core；不要绕过core构造核心状态。
- 当前终端面板 UI：Command+J、压缩目录 view、拖拽高度和 viewport 测量都属于客户端视觉/布局状态,并且具备真实打开终端的能力
- 客户端 resize 只能维护 `isOpen`、`height`、`viewportSize` 等 UI 状态，并 debounce/coalesce viewport 变化；未来 backend 只接受合并后的终端可用尺寸或 rows/cols，不接收原始拖拽事件、AppKit view 尺寸细节或客户端布局高度。

## Workspace 状态语义

- `workspaceRoot` 是当前 workspace 的上下文根，用于表达当前浏览上下文；它不是文件系统访问安全沙箱，也不限制 `listDirectory` 可读取的路径。
- `workspace.openDirectory` 打开当前 root 内的目录时保留 `workspaceRoot`，只更新 `currentDirectory`；打开 root 外目录时，将规范化后的目标目录同时设为新的 `workspaceRoot` 和 `currentDirectory`。
- `workspace.listDirectory` 是无状态查询，只返回指定路径的 listing，不改变 `workspaceRoot` 或 `currentDirectory`。
- `openDirectory` 只有在目录验证和 listing 都成功后才一次性更新 state；失败时不得留下部分状态更新。
- 修改这些语义时，backend 实现、macOS 客户端状态处理、协议文档和测试必须作为同一项改动同步完成。


## 仓库结构规则

当前仓库结构应保持轻量：

- `core/` 是当前 Rust backend，以库形式提供（`src/lib.rs` + UniFFI scaffolding）；可选的 axum server 是同一份库上的 `server` feature bin（`src/bin/server.rs`）。
- `clients/MacOS/` 是当前 macOS client；它通过 `Vendor/CoreFFI/` 的静态库与 `MacOS/Core/Generated/` 的 UniFFI 绑定进程内链接 core。
- `protocol/` 记录当前协议；FFI facade 与可选 HTTP/RPC 镜像同一套方法语义。

不要提前创建未来目标里的 `core/crates/*` workspace。只有当 backend 真实功能面足够大、拆分可以降低复杂度时，才考虑演进结构。

## 协作规则

- 根目录 `agent.md` 是全局约束。
- 根目录 `agent.md` 是 agent 工作约束文件；默认不要顺手 stage 或 commit，只有用户明确要求更新 agent 规范时才纳入版本控制。
- 子目录内的 `agent.md` 可以补充更具体的 core/client 规则；编辑对应目录时同时遵守更近的规则。
- 子目录内的 `agent.md` 同样是局部工作约束；默认不要顺手 stage 或 commit，只有用户明确要求更新对应规范时才纳入版本控制。
- 所有新增加的代码文件必须由 git 统一管理；新增源码、测试、配置、协议或项目文档后，要确认它们出现在 `git status` 中，并按用户要求 stage/commit，不能留下未跟踪的新文件当作已完成交付,md开发文档除外该类型文档不需要加入git管理。
- 拆分 backend/client commit 时，只 stage 对应边界内的文件；不要把无关文档、另一个子系统或其他 agent 的修改混进同一个 commit。
- 使用 subagent、后台 agent 或并行协作者后，完成对应任务必须确认其已停止/关闭；不要留下继续运行的 subagent、后台会话或未收束的长期任务。
- 多个 subagent 并行修改时，每个 subagent 只编辑被分配的文件或目录；主 agent 负责整合路线图、跨目录一致性和最终验证。
- 不要还原、覆盖、格式化或顺手整理其他 agent/用户的并行改动；如果同一文件已有无关修改，只在必要范围内做最小 patch。
- 修改前先查看相关文件和 `git status`，只改任务需要的文件；交付前再次查看 `git status`，明确哪些改动属于自己、哪些是既有脏工作区。
- 保持改动小而清晰，避免顺手重构无关区域。
- 文档和代码不一致时，优先修正与当前行为直接相关的文档。

## 测试与提交门禁

- 任何生产代码改动都必须配套新增或更新测试代码，或者给出等价的自动化验证；不能只靠手动说明证明行为正确。
- 测试应覆盖被改动行为的失败路径、边界路径和跨层契约，而不只覆盖 happy path。
- 如果确实无法写自动化测试，必须在交付说明中写清原因、手动验证步骤和剩余风险；这应是例外，不是默认路径。
- 修改 backend workspace、filesystem、terminal、FFI facade 或协议语义时，要同步更新 Rust 测试、`core/src/ffi/` 转接与 DTO、重新生成的 Swift 绑定、客户端 DTO/调用、`protocol/README.md` 和相关 agent 文档。
- 修改 macOS ViewModel、API 解码或 UI 状态行为时，要优先更新 `MacOSTests`，至少覆盖对应 action 的状态变化和错误处理。
- 新增测试 target、测试文件、项目配置和协议文档属于项目代码的一部分；除非用户明确排除，否则提交时必须纳入 git。
- 提交前至少运行与改动相关的自动化验证，并报告命令和结果；跨 backend/client 的改动应同时跑 Rust 和 macOS 客户端测试。

## 验证习惯

重大运行环境假设必须先验证再据此行动，包括但不限于当前工作目录、Xcode scheme、Rust toolchain、macOS app bundle 路径、客户端 entitlements / sandbox、`clients/MacOS/Vendor/CoreFFI/` 与 `MacOS/Core/Generated/` 的 FFI 产物是否最新，以及目标文件是否已被其他 agent 修改。不要基于记忆或上一次会话状态直接下结论。

Backend 相关改动优先运行（FFI facade 测试在 `core/src/ffi/`，与业务层一起被 `cargo test` 覆盖）：

```sh
cd core
cargo fmt --check
cargo test
cargo clippy --all-targets -- -D warnings
```

改动了 Rust FFI 接口（`core/src/ffi/`、`CoreHandle` 方法签名或跨边界 DTO）后，必须重新生成绑定再让 Xcode 构建：

```sh
clients/MacOS/scripts/refresh-core-ffi.sh
```

仅当需要联调可选 server 模式时，才用 HTTP 路径验证；默认客户端走进程内 FFI，不依赖该端口：

```sh
cd core
cargo run                # 启动可选 axum server（server feature）
curl http://127.0.0.1:3587/health
curl -X POST http://127.0.0.1:3587/rpc \
  -H 'Content-Type: application/json' \
  -d '{"method":"core.ping","params":{}}'
```

macOS 相关改动优先运行：

```sh
xcodebuild test -project clients/MacOS/MacOS.xcodeproj \
  -scheme MacOS \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .derivedData/codex-tests \
  CODE_SIGNING_ALLOWED=NO
```


