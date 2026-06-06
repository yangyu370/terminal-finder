# Terminal Finder Agent 操作规范

这份文件约束后续 Codex/agent 在仓库根目录级别维护 Terminal Finder 的方式。它不是路线图；路线图以 `DEVELOPMENT_PLAN.md` 为准。

## 项目定位

Terminal Finder 是一个 local-first workspace system。

Rust backend 是产品核心和 source of truth。macOS、未来 web、Windows、Linux 客户端都只是连接同一 backend API 的表现层。

当前第一客户端是 `clients/MacOS/`，目标体验接近 Finder，但核心状态和文件系统行为仍由 Rust backend 负责。

## 当前阶段

当前处于 Phase 1: Workspace And Directory Browsing。

Phase 1 的边界要收紧：本阶段只证明 workspace state、目录打开、目录列表、macOS Finder-like 浏览体验和 backend/client 协议可以稳定工作。不要因为相邻功能看起来顺手，就扩大到搜索、真实 shell/PTY 会话、文件监听、文件变更、git、插件、AI、索引或多平台客户端实现。

优先完成：

- 继续稳定 backend workspace state、`workspace.getState`、`workspace.openDirectory` 和 `workspace.listDirectory`
- 继续完善 macOS Finder-like 主窗口、sidebar、toolbar、文件列表和键盘行为
- 保持隐藏文件切换、导航历史、路径输入、打开文件、刷新和状态栏展示等 Phase 1 行为可测试
- 收敛已知后端风险：目录扫描竞争、workspace state 锁中毒恢复、日志路径脱敏、必要的状态并发测试

暂时不要做：

- real shell/PTY sessions
- search / indexing
- git awareness
- plugins
- AI features
- file watching / event stream
- delete / move / rename 等文件变更操作

## 架构边界

- Core owns workspace state, current directory, directory validation, filesystem facts, path open/list operations, future file operations, and future search/git/events/plugins/automation.
- Client owns AppKit windows, rendering, selection state, focus, visual/layout state, interaction, platform-native open-file behavior, alerts, and viewport measurement.
- 文件数据、目录状态、路径打开/列目录和未来文件操作必须通过 backend API 表达，不要把产品核心逻辑搬进客户端。
- 客户端可以做 UI 临时状态、视觉排序、焦点、选择和窗口内伪终端面板布局；不要在客户端私自维护与 backend 冲突的 canonical workspace state、目录栈或文件系统真相。
- 后端可以暴露平台无关的文件/目录能力；不要让后端依赖 macOS AppKit、Finder 私有体验或某个客户端的 UI 形状。
- 打开文件和系统默认应用是客户端平台行为，但目录导航、路径打开和目录 listing 的事实必须来自 backend；不要绕过 backend 构造核心状态。
- 无效或缺失目录导航失败时，客户端负责呈现可复用 AppKit alert，并保持当前目录语义；需要刷新 listing 时仍通过 backend 查询当前目录。
- 当前伪终端面板只是窗口内 UI：Command+K、压缩目录 view、拖拽高度和 viewport 测量都属于客户端视觉/布局状态，不代表已有 shell/PTY runtime。
- PTY 接入前，不要把 shell process、PTY session、命令执行生命周期或终端状态机塞进客户端；需要接入时先定义 backend 协议、core 生命周期和跨层测试。
- 客户端 resize 只能维护 `isOpen`、`height`、`viewportSize` 等 UI 状态，并 debounce/coalesce viewport 变化；未来 backend 只接受合并后的终端可用尺寸或 rows/cols，不接收原始拖拽事件、AppKit view 尺寸细节或客户端布局高度。
- API 优先保持简单可调试：本地 HTTP JSON RPC 先行，WebSocket 事件后置。
- 修改 API 行为或 workspace state 语义时，必须同步更新 backend、客户端调用、测试和 `protocol/README.md`，不要让任一层保留旧规则。

## Workspace 状态语义

- `workspaceRoot` 是当前 workspace 的上下文根，用于表达当前浏览上下文；它不是文件系统访问安全沙箱，也不限制 `listDirectory` 可读取的路径。
- `workspace.openDirectory` 打开当前 root 内的目录时保留 `workspaceRoot`，只更新 `currentDirectory`；打开 root 外目录时，将规范化后的目标目录同时设为新的 `workspaceRoot` 和 `currentDirectory`。
- `workspace.listDirectory` 是无状态查询，只返回指定路径的 listing，不改变 `workspaceRoot` 或 `currentDirectory`。
- `openDirectory` 只有在目录验证和 listing 都成功后才一次性更新 state；失败时不得留下部分状态更新。
- 修改这些语义时，backend 实现、macOS 客户端状态处理、协议文档和测试必须作为同一项改动同步完成。

## Backend 生命周期

- macOS 客户端启动受管 core 时，必须把 core 的 stdin 接到专用 pipe，并在客户端进程中持有写端；core 读取 stdin，收到 EOF 后触发 graceful shutdown。
- 客户端正常销毁时应主动关闭 pipe 写端；客户端正常退出、崩溃或被 `SIGKILL` 后，由操作系统关闭写端，core 通过 EOF 收束生命周期。
- 禁止使用父 PID 环境变量、PID 轮询或定时检查父进程是否存在，作为客户端与 core 的生命周期方案。
- 受管启动和手动启动必须明确区分：受管启动依赖客户端持有 stdin pipe；手动运行 core 时必须保持 stdin 打开，并可通过 Ctrl-C 退出。不要用 `/dev/null`、已关闭的 pipe 或会立即 EOF 的 stdin 启动需要持续运行的 core。
- 修改 core 启停行为时，必须同时检查 macOS launcher、core shutdown 流程和手动运行说明，确保正常退出、崩溃和强制终止场景都不会留下残留 backend。

## 仓库结构规则

当前仓库结构应保持轻量：

- `core/` 是当前 Rust backend。
- `clients/MacOS/` 是当前 macOS client。
- `protocol/` 记录当前协议。
- `DEVELOPMENT_PLAN.md` 记录路线图和阶段状态。

不要提前创建未来目标里的 `core/crates/*` workspace。只有当 backend 真实功能面足够大、拆分可以降低复杂度时，才考虑演进结构。

## 协作规则

- 根目录 `agent.md` 是全局约束。
- 根目录 `agent.md` 是 agent 工作约束文件；默认不要顺手 stage 或 commit，只有用户明确要求更新 agent 规范时才纳入版本控制。
- 子目录内的 `agent.md` 可以补充更具体的 backend/client 规则；编辑对应目录时同时遵守更近的规则。
- 子目录内的 `agent.md` 同样是局部工作约束；默认不要顺手 stage 或 commit，只有用户明确要求更新对应规范时才纳入版本控制。
- 所有新增加的代码文件必须由 git 统一管理；新增源码、测试、配置、协议或项目文档后，要确认它们出现在 `git status` 中，并在交付前说明是否需要纳入版本控制。
- 使用 subagent、后台 agent 或并行协作者后，完成对应任务必须确认其已停止/关闭；不要留下继续运行的 subagent、后台会话或未收束的长期任务。
- 不要还原或覆盖其他 agent/用户的并行改动。
- 修改前先查看相关文件和 `git status`，只改任务需要的文件。
- 保持改动小而清晰，避免顺手重构无关区域。
- 文档和代码不一致时，优先修正与当前行为直接相关的文档。

## 测试与提交门禁

- 任何生产代码改动都必须配套新增或更新测试代码，或者给出等价的自动化验证；不能只靠手动说明证明行为正确。
- 测试应覆盖被改动行为的失败路径、边界路径和跨层契约，而不只覆盖 happy path。
- 如果确实无法写自动化测试，必须在交付说明中写清原因、手动验证步骤和剩余风险；这应是例外，不是默认路径。
- 修改 backend workspace、filesystem、API 或协议语义时，要同步更新 Rust 测试、客户端 DTO/调用、协议文档和相关 agent 文档。
- 修改 macOS ViewModel、API 解码或 UI 状态行为时，要优先更新 `MacOSTests`，至少覆盖对应 action 的状态变化和错误处理。
- 新增测试 target、测试文件、项目配置和协议文档属于项目代码的一部分；除非用户明确排除，否则提交时必须纳入 git。
- 提交前至少运行与改动相关的自动化验证，并报告命令和结果；跨 backend/client 的改动应同时跑 Rust 和 macOS 客户端测试。

## 验证习惯

重大运行环境假设必须先验证再据此行动，包括但不限于端口、当前工作目录、服务是否已运行、Xcode scheme、Rust toolchain、macOS app bundle 路径、sandbox 权限、网络可用性和目标文件是否已被其他 agent 修改。不要基于记忆或上一次会话状态直接下结论。

Backend 相关改动优先运行：

```sh
cd core
cargo fmt --check
cargo test
cargo clippy --all-targets -- -D warnings
```

需要人工检查服务时：

```sh
cd core
cargo run
```

然后检查：

```sh
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

至少确认客户端仍通过 `http://127.0.0.1:3587/rpc` 与 backend 通信，目录列表数据来自 backend。

## 决策原则

- Phase 1 先把 workspace/directory browsing 做扎实。
- Phase 1 不外扩；如果发现后续阶段能力是当前任务的前置条件，先记录依赖或提出最小接口，不要直接实现完整后续功能。
- 优先复用当前项目已有模式，而不是引入新框架或大抽象。
- Rust backend 的业务边界要稳，Swift 客户端的体验可以逐步变得更 native。
- 每次改动都应该让项目更接近当前阶段目标，而不是提前跳到后续阶段。
