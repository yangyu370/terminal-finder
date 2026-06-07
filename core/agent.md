# Core Agent 操作规范

本文件约束后续维护 `core/` Rust backend 时的做法。`DEVELOPMENT_PLAN.md` 是路线图，`protocol/README.md` 是协议说明；本文件只写 agent 在 `core/` 内工作的边界、优先级和习惯。

## 核心定位

- `core/` 是 Terminal Finder 的本地后端，也是长期的 source of truth。
- 后端负责 workspace、file operations、terminal lifecycle、events，以及未来 search、git、automation、plugins 等能力的真实状态和业务规则。
- backend 是 workspace / file-system 业务事实来源：路径合法性、目录是否可打开、当前 workspace 状态、错误分类、排序规则和文件条目字段都以 Rust 后端结果为准。
- macOS、Web、Windows、Linux 客户端都是表现层：它们负责渲染、交互和平台体验，但不应拥有核心业务逻辑。
- 任何会影响文件系统、工作区状态、终端会话或事件流的行为，都优先设计为后端 API，而不是写进客户端。
- 客户端可以缓存、选择、过滤或高亮后端返回的数据来提升体验，但不能用自己的路径推断、目录扫描或状态修补覆盖后端事实。
- 不要把客户端展示逻辑放到 backend：例如 sidebar 分组、图标选择、最近访问 UI、选中态、展开态、空状态文案、视觉排序偏好等应留在客户端；backend 只暴露稳定的业务数据、状态和领域错误。

## 当前阶段

当前仍以 Phase 1 为主，优先把 workspace 基础能力、后端事件通道和下一步 PTY 最小闭环边界做稳。

优先事项：

- 稳定 `workspace.listDirectory` 的行为、错误映射和排序规则。
- 持续守住已实现的 `workspace.getState` 与 `workspace.openDirectory` 语义。
- 让 backend workspace state 继续作为 `workspaceRoot` / `currentDirectory` 的唯一事实来源。
- 保持 `/health`、`POST /rpc`、`core.ping` 可作为连通性基线。
- 保持 `/events` WebSocket 独立于 `/rpc`：它只承载 backend lifecycle / event bus 语义，不做 RPC 分流。
- 稳定 `/events` 的 `backend.ready` 与 `heartbeat` envelope，确保客户端能基于事件通道判活。
- WebSocket 连接必须同时读写 socket，能及时处理客户端 close、读错误和半开连接迹象，而不是只等待下一次发送失败。
- 稳定客户端受管 backend 的 stdin pipe 生命周期和 graceful shutdown 行为。
- 任何新增 workspace 行为，都要先明确它读写的是 backend state、filesystem 事实，还是纯展示派生数据；纯展示派生数据不应进入 core。
- 当前已修复并测试覆盖：打开 root 内目录保留 root，打开 root 外、root 祖先或 root 失效时切换 root/current。
- 当前剩余重大待办：目录扫描竞争只忽略 `NotFound`、`RwLock` 中毒恢复、info/warn 日志路径脱敏、必要时补并发 `openDirectory` 状态测试。
- PTY 尚未接入时，不要在 core 内伪造 shell 行为；后续 PTY 最小闭环由 core 承担真实 session、process、IO 与退出生命周期。

暂时不要提前实现：

- search / indexing
- git awareness
- plugins / automation
- file watcher / event stream 的复杂实现
- 未来 `core/crates/*` workspace 拆分

## 结构约束

- 继续保持当前单 crate 轻量模块结构：`src/api/`、`src/workspace/`、`src/error.rs`、`src/main.rs`、`src/state.rs`。
- `src/api/controllers/workspace.rs` 应保持很薄，只转接到 `src/workspace/` 的 service/DTO；不要再把 filesystem 或业务状态逻辑塞回 controller。
- 不要因为路线图里有未来 `core/crates/*` 就提前拆 crate。
- 只有当后端表面积明显变大、模块职责已经自然稳定、单 crate 内部边界无法清楚表达时，才考虑拆分 workspace。
- 新模块应先服务真实需求，不为“将来可能会用”创建空抽象。
- 所有新增加的代码文件必须由 git 统一管理；新增 Rust 源码、测试、配置或协议相关文件后，要确认它们出现在 `git status` 中，并在交付前说明是否需要纳入版本控制。
- 共享状态应放在后端状态层统一管理，不要散落在 route/controller 的局部静态变量里。
- workspace state 必须集中在 `src/workspace/state.rs` 及 `AppState` 持有的 store 中维护；controller / RPC 分发层只读取或调用 service，不直接改状态。
- backend event sender、connection id、PTY session registry、PTY process handle 等跨请求共享资源必须进入 `AppState` 或明确的 state/store 层。
- route / controller 只能做提取参数、调用 service/state、组装协议响应和少量 tracing；不能持有长期 session、spawn 出无法追踪的任务，或直接成为业务状态容器。
- filesystem 细节应优先隔离在 `src/workspace/fs.rs`，service 负责调度 blocking task、更新状态和组合 response；controller 保持转接职责。

## 技术风格

保持现有 Rust 后端风格：

- `tokio`：异步运行时和任务调度。
- `axum`：HTTP 路由和请求处理。
- `serde` / `serde_json`：请求、响应和 DTO 序列化。
- `tracing`：结构化日志，重要请求应记录 method、status、duration 等可诊断字段。
- `thiserror`：可分类的领域/API 错误。
- `anyhow`：进程入口和应用级错误传播。

新增代码应尽量贴近现有模块的命名、错误处理和响应结构。不要引入新的框架、协议层或大型依赖，除非当前 Phase 1 需求确实需要。

## 进程生命周期

- macOS 客户端启动受管 core 时，必须把 core 的 stdin 接到由客户端持有写端的 pipe，不能接到 `/dev/null`。
- core 启动后应在 Tokio task 中异步读取 stdin，直到读到 EOF；stdin EOF 与 Ctrl-C 都必须触发 Axum graceful shutdown。
- stdin pipe 是受管 core 与父客户端之间唯一的生命周期契约：客户端正常退出、崩溃或被 `SIGKILL` 后，操作系统关闭 pipe 写端，core 读到 EOF 后退出。
- 禁止使用父 PID 环境变量、定时 PID 轮询、`process_exists()` 或额外 `libc` 进程探测来管理父子进程生命周期。
- 客户端主动销毁 launcher 时应关闭 pipe 写端，并允许 core 完成 graceful shutdown；不应依赖只在正常退出路径执行的清理逻辑保证 core 退出。
- 手动交互运行 `cargo run` 时，core 从终端 stdin 读取，使用 Ctrl-C 正常退出；输入 Ctrl-D 或以已关闭、`/dev/null`、管道末端等 EOF stdin 启动时，core 立即 graceful shutdown，这是 stdin 生命周期契约的预期边界。
- 生命周期任务不得阻塞 async runtime；shutdown reason 应保留非敏感的结构化 info 日志，便于区分 `ctrl_c` 与 `stdin_eof`。

## WebSocket 边界

- `/events` 是独立 WebSocket event channel，不属于 `/rpc` 分流，也不应复用 RPC request/response 语义。
- `/events` 当前只表达 backend lifecycle / event bus：例如 `backend.ready`、`heartbeat` 和未来低频 backend 状态事件。
- 高频双向业务流不得塞进 `/events`；PTY、文件流、搜索流等应按业务建立独立 session/channel。
- WebSocket handler 必须 split socket，持续读取入站 frame，并同时驱动出站发送；不得只写不读。
- 入站 `Close` 必须尽量发送 close response 并结束连接；读到 EOF、read failure、send failure、receiver lagged 都必须能收敛到干净的连接退出路径。
- 入站 text / binary / ping / pong 若当前业务不消费，也必须被显式处理或记录非敏感摘要，避免协议边界变成隐式丢弃。
- `heartbeat` 是常态判活事件：成功发送/接收默认不打 info 日志，只在断开摘要中保留计数；需要逐条排查时再用 debug。
- WebSocket info/warn 日志只记录 connection id、peer、event type、reason、计数等摘要；完整 payload、详细错误 message 和敏感路径只能进入 debug。
- WebSocket 生命周期测试要覆盖 ready/heartbeat、客户端主动 close、读错误或连接断开后的快速退出，以及不会把 heartbeat 噪声刷满 info 日志。

## PTY 边界

- 后续接入 PTY 时，core 拥有 PTY session、shell process、stdin/stdout/stderr stream、working directory、退出状态和资源清理的生命周期。
- 客户端负责终端面板 UI、布局、viewport 像素测量、字体指标测量、系统打开文件等表现层能力；不要把 shell 启动、进程持有、PTY IO 或会话恢复塞进客户端。
- PTY 不得混进 `/events`；应使用独立 session API 与独立 WebSocket channel，例如先发送 `terminal.create`，再用该 session 的 channel 做 `terminal.input` / `terminal.output` / `terminal.resize` / `terminal.close`。
- PTY 最小闭环优先实现：`terminal.create`、`terminal.input`、`terminal.output`、`terminal.resize`、`terminal.close`、`terminal.exit`；不要一开始追求完整 terminal emulator 或复杂恢复协议。
- 终端尺寸边界应由客户端发送合并后的可用尺寸，或发送已按本地字体指标转换后的 `rows` / `cols`；core 负责把最终 `rows` / `cols` 应用到 PTY，不负责测量像素 viewport。
- core 处理 resize 必须容忍连续请求、重复尺寸和乱序附近的快速更新；实现应幂等，并方便调用方节流或合并，不因重复 resize 破坏 session。
- PTY 的 working directory 应由 core 根据 workspace state、请求参数和后端路径规则确定并校验；客户端不能用自己的路径推断覆盖后端事实。
- PTY API 与事件流应表达跨平台业务语义，例如 session id、cwd、rows、cols、data、exit status 和错误 code；不要返回某个客户端面板布局或视觉状态。
- PTY process lifecycle 必须可取消、可关闭、可回收；session close、shell exited、client channel dropped、backend shutdown 都要进入统一清理路径。
- PTY stdout/stderr/output 可能是高频字节流；日志只记录 session id、字节数、方向和错误摘要，禁止在 info/warn 打印完整终端内容。
- 会影响 shell process、PTY session 或 cwd 的行为都必须走后端 API，并配套协议文档和 Rust 测试。

## API 与协议

- RPC 入口保持 `POST /rpc`，方法名继续使用类似 `core.ping`、`workspace.listDirectory` 的 method-style 风格。
- WebSocket event channel 与 RPC 协议分开描述：RPC 负责请求/响应命令，WebSocket 负责连接生命周期和服务端主动事件。
- API 的请求、响应、错误语义发生变化时，必须同步更新根目录下的 `protocol/README.md`。
- 新增或修改 RPC 方法时，要明确：
  - method 名称
  - request params
  - success result
  - error 行为
  - 是否改变后端 workspace state
- 保持协议可读、可 curl 调试、可被 Swift 客户端直接消费。
- 早期继续使用本地 HTTP JSON；不要提前引入 gRPC 或复杂 schema 生成流程。
- WebSocket envelope 字段应表达跨平台事件语义；新增 event type 前先确认它不是某个客户端 UI 状态。
- `heartbeat` envelope 只用于判活和连接质量，不应携带业务状态，也不应成为触发 UI 业务刷新的信号。
- 协议职责必须清楚区分：
  - `workspace.getState`：只返回 backend 当前持有的 workspace state；不扫描目录、不修补客户端路径、不产生文件系统副作用。
  - `workspace.openDirectory`：验证请求 path 存在且是目录，规范化目标和当前 root，根据目标是否位于 root 内决定保留或切换 `workspaceRoot`，原子更新 backend state，并返回新 state 和该目录的非递归 listing，方便客户端立即重绘。
  - `workspace.listDirectory`：按请求 path 返回非递归 listing；不改变 `workspaceRoot` 或 `currentDirectory`，也不应偷偷更新 backend state。
- `workspaceRoot` / `currentDirectory` 语义必须稳定：
  - `workspaceRoot` 是当前 workspace 的稳定上下文根，不是文件系统访问沙箱；Phase 1 允许访问进程权限范围内的任意可访问目录。
  - `currentDirectory` 是 backend 认为当前被打开 / 浏览的目录，是客户端展示“当前位置”的事实来源。
  - `openDirectory` 必须在 blocking 文件系统区域规范化目标目录和当前 `workspaceRoot`，通过 symlink 打开目录时按规范化后的真实目标判断归属。
  - 目标位于规范化后的当前 root 内时，保留规范化后的 root，只将 `currentDirectory` 更新为规范化目标。
  - 目标位于当前 root 外、当前 root 无法规范化、或打开的是 root 的祖先目录时，将规范化目标同时设为新的 `workspaceRoot` 和 `currentDirectory`。
  - 目录验证和 listing 全部成功后，才在同一次写锁中原子更新 root/current；任何失败都不得修改原 state。
  - `listDirectory(path)` 的 `path` 只表示本次 listing 目标，不等同于 current directory。
  - `listDirectory` 可列举当前 root 外的任意可访问目录，但始终保持无状态，不修改 root/current。
- 不要为了兼容单个客户端把协议 response 变成 UI model；字段应表达跨平台稳定业务含义，而不是某个客户端控件的临时需要。

## 文件系统规则

- 阻塞文件系统操作必须使用 `tokio::task::spawn_blocking`，避免阻塞 async runtime worker。
- 所有可能阻塞的 filesystem 访问都属于 blocking 区域，包括但不限于 `metadata`、`canonicalize`、`read_dir`、逐条 entry metadata / symlink metadata、未来文件读写和目录创建删除；不要在 async handler / service 的 async 上下文直接执行这些调用。
- `spawn_blocking` 内应只做同步 filesystem 工作和必要的数据转换；状态更新、tracing response summary、协议组合等仍应回到 async service 侧完成。
- blocking task 的 join error 必须映射成可诊断的 API error，并带上 operation 名称，例如 `workspace.openDirectory` 或 `workspace.listDirectory`。
- directory scan 应保持非递归，除非 API 明确要求递归。
- 目录列表应保持稳定、可预测的排序：目录优先，再按名称排序。
- 目录扫描必须使用显式循环处理逐条 entry 结果：仅跳过扫描期间条目消失产生的 `NotFound`，并以 debug 日志记录该竞争。
- `PermissionDenied` 及其他 entry/metadata 错误必须使 listing 明确失败，不能把不完整结果伪装为完整成功，也不新增 `partial` 或 `warnings` 字段。
- 悬空 symlink 应继续作为 symlink 条目返回；`symlink_metadata` 读取链接本身，不能把目标 metadata 不存在误判为应跳过的条目。
- 错误映射要清楚区分 invalid params、path not found、permission denied、not directory 等情况。
- 不要让客户端直接替代后端完成产品级文件系统逻辑；客户端可以发起动作，但真实行为和校验应在后端。
- 路径处理规则要由后端统一执行：是否 canonicalize、何时保留用户传入 path、symlinked directory 是否可打开、错误中的 path 指向哪个输入，都需要在 Rust 测试中锁定。
- 后端返回的 `DirectoryEntry` 应保持跨平台稳定字段：`name`、`path`、`kind`、`isDirectory`、`size`、`modifiedAt`；新增字段前先确认它是业务事实而不是 UI 装饰。

## 状态与日志规则

- workspace state 继续使用标准库 `RwLock`，不要仅为中毒恢复引入 `parking_lot`。
- 读锁或写锁中毒时必须记录 warning，并通过 `poisoned.into_inner()` 获取锁内状态继续服务；中毒恢复不能吞掉诊断信号。
- root/current 更新必须集中在单个 store 方法中，并在同一次写锁内完成，不能由 service 分两步更新。
- info/warn 请求日志不得包含完整请求 params、完整路径或详细错误 message。
- info 日志保留 method、status、elapsed time、结果类型及 entries 等非敏感数量摘要；warn 日志保留 method、status、elapsed time 和错误 code。
- 完整 params、目标路径、详细错误 message 和扫描竞争路径只允许记录到 debug；API 返回给客户端的路径和错误 message 不受该日志级别规则影响。
- heartbeat、PTY output chunk、重复 resize 等常态高频事件默认不进入 info；只记录连接建立、断开、错误、状态转移和聚合计数。
- WebSocket / PTY warn 日志不得打印完整 payload、终端输出、请求 params、完整路径或详细错误 message；需要诊断时用 debug 并保持字段化。

## 测试与验证

任何 Rust 生产代码变更都必须配套新增或更新 Rust 测试，或者提供协议级自动化验证；不能只靠手动 curl 或描述证明行为正确。

测试必须锁定 backend 事实语义，而不只是证明当前实现能跑通：

- 修改 `workspace/state.rs` 时，必须覆盖 root/current 原子更新、失败不改状态、锁中毒恢复或并发相关行为。
- 修改 `workspace/fs.rs` 时，必须覆盖路径规范化、目录/文件/symlink 分类、错误映射、排序、扫描竞争和权限失败。
- 修改 `workspace/service.rs` 或 API controller 时，必须覆盖 endpoint 是否改变 state、blocking task 错误映射、response shape 和协议约定。
- 修改 `/events` 时，必须覆盖 WebSocket close/read/send/lifecycle 行为，尤其是客户端主动断开后能快速退出，而不是等 heartbeat 发送失败。
- 修改 `AppState` 时，必须覆盖新增共享状态在 clone 后仍保持同一 backend state，例如 event connection id、event sender 或未来 PTY session registry。
- 接入 PTY 时，必须覆盖 `terminal.create` / `terminal.input` / `terminal.output` / `terminal.resize` / `terminal.close` / `terminal.exit`、client disconnect 清理、process exited 清理和 backend shutdown 清理。
- 修改错误 code、response 字段或 workspace 语义时，必须同步更新 `protocol/README.md` 和客户端 DTO/测试。
- 如果行为影响 macOS 客户端状态展示，还要确认或补充对应 `MacOSTests`。

修改后端后，优先运行：

```sh
cd core
cargo fmt --check
cargo test
cargo clippy --all-targets -- -D warnings
```

需要手动交互验证服务时：

```sh
cd core
cargo run
```

保持该终端 stdin 打开，并在验证结束后使用 Ctrl-C 触发 graceful shutdown。不要使用
`cargo run </dev/null` 作为持久运行方式，因为 EOF 会按生命周期契约立即关闭服务。

再用：

```sh
curl http://127.0.0.1:3587/health
curl -X POST http://127.0.0.1:3587/rpc \
  -H 'Content-Type: application/json' \
  -d '{"method":"core.ping","params":{}}'
```

涉及 workspace API 时，也要用 `workspace.listDirectory`、`workspace.getState` 或 `workspace.openDirectory` 的实际请求确认协议行为。

测试需要覆盖路径 / 状态语义，而不只是 happy path：

- `workspace.getState` 返回 backend 初始 state，且不会触发 directory listing 或状态变更。
- `workspace.openDirectory` 打开 root 内目录时保留规范化 root，只更新 current；打开 root 外目录、root 祖先目录或 root 已失效时，将规范化目标设为新的 root/current。
- `workspace.openDirectory` 的目标验证或 listing 失败时，root/current 均保持不变；状态成功更新必须验证为原子行为。
- `workspace.listDirectory` 返回指定 path 的 listing，包括 root 外目录，但不改变 `currentDirectory` 或 `workspaceRoot`。
- path canonicalization、相对 / 绝对路径、symlink directory、指向 root 外的 symlink、not directory、missing path、permission denied 等行为应有针对性覆盖。
- 目录扫描期间条目消失产生 `NotFound` 时返回其余条目；`PermissionDenied` 和其他错误仍明确失败；悬空 symlink 仍作为 symlink 条目返回。
- 排序规则、entry kind、`isDirectory`、size、modified time 格式等文件系统 DTO 字段需要保持测试覆盖，避免客户端依赖被无意破坏。
- `RwLock` 中毒后 `state()` 与 root/current 原子更新仍可工作，并记录 warning。
- info/warn 日志不包含完整 params、路径或详细错误 message；debug 日志保留必要诊断细节。
- 受管 core 在 stdin pipe 写端关闭时 graceful shutdown；客户端正常退出、崩溃和 `SIGKILL` 后均不残留 core 进程或监听端口。
- 手动交互运行可用 Ctrl-C 退出；已关闭 stdin 或 `/dev/null` 产生 EOF 时立即 graceful shutdown。
- 如果修改 RPC response 形状或错误 code/message/status，测试和 `protocol/README.md` 要一起更新。

## 并行协作

- 你不是独自在代码库里工作。其他 agent 可能同时编辑根目录 `agent.md` 或 `clients/MacOS/agent.md`。
- 维护 `core/agent.md` 时，不要修改根目录 agent 文件或 macOS 客户端 agent 文件。
- 不要还原、覆盖或清理其他 agent / 用户的无关改动。
- 如果发现并行改动影响当前任务，先读清楚再衔接；只有确实无法继续时才询问用户。
