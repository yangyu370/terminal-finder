# macOS Client Agent 操作规范

这份文件约束后续 agent 维护 macOS 客户端时的做法。它只描述 `clients/MacOS/` 内的客户端工作边界；根目录路线图、backend 规范和协议文档以各自目录的文件为准。

## 核心定位

- macOS client 是 presentation layer，负责把 Rust backend 暴露出的工作区、目录和未来终端能力呈现为原生 macOS 体验。
- Rust backend 是产品行为和数据事实的来源。客户端负责渲染、选择、焦点、布局、交互和用户反馈。
- 客户端不要偷走 backend 业务逻辑：不要在 Swift 侧重新实现 workspace 状态机、目录合法性判断、路径归一化策略、文件类型业务分类、权限语义、排序事实或未来 terminal/search/git/plugins 的核心规则。
- 客户端可以做 presentation transformation，例如图标选择、日期/大小显示文本、选中态、loading/error 文案和原生控件适配；一旦某个判断会影响产品事实或 backend 状态，就必须放回 Rust backend。
- 目录数据必须来自 Rust backend API，而不是把 Swift `FileManager` 当作产品真相。`FileManager` 只能用于临时开发辅助、系统 UI 集成或非产品事实类的本地能力。
- 当前 backend 需要访问真实用户文件系统；macOS client 不应以 App Sandbox 拉起 backend，否则子进程会继承 container 路径和文件访问限制。

## 当前阶段

- 当前优先 Phase 1：workspace、目录浏览体验和窗口内伪终端面板的 UI 外壳。
- 当前已有 `MacOSTests` target、`WorkspaceBrowserViewModelTests`、`BackendConnectionViewModelTests` 和 `PseudoTerminalPanelLayoutStateTests`，后续客户端行为改动必须优先用这些测试锁定。
- 可以继续保留 SwiftUI proof-of-flow，用于验证 backend 通信、目录列表和基础交互。
- Finder-like 主界面应逐步转向更原生的 macOS 结构：AppKit、`NSTableView`、sidebar、toolbar、native behavior。
- 隐藏文件切换、后退/前进/上级目录、路径输入、刷新、打开文件、连接恢复后重新同步、以及不在状态栏/底栏显示项目数量等当前行为都属于 Phase 1 受保护行为。
- WebSocket `/events` 已作为 backend lifecycle/event channel 接入客户端，用于 `backend.ready`、`heartbeat` 和未来低频状态事件；它不是 PTY 数据通道。
- Phase 1 内不要在客户端实现真实 PTY/shell 生命周期、search、git、plugins，也不要为了未来功能提前扩大客户端架构。后续进入 PTY 时先做最小 UI 闭环，不把真实会话事实放进客户端。

## 分层职责

- `Views`：只负责布局、展示、用户交互和原生控件组合。不要直接发 HTTP/RPC，不要启动 `Process`，不要做文件系统事实判断；用户动作应通过闭包或 ViewModel action 传出。
- `ViewModels`：只做 UI state、async actions、API orchestration、任务取消、loading/error/selection/connection 状态管理。不承载 backend 业务规则，不把多个 backend endpoint 的结果改造成新的产品真相。WebSocket 连接状态、heartbeat 超时和 alert 协调可以放在 ViewModel，但 backend 是否 ready、PTY session 是否存在等事实仍以 backend/protocol 为准。
- `API`：负责 HTTP/RPC/WebSocket 调用、请求响应 DTO、错误映射、timeout 和 backend endpoint 适配。API 层不启动 backend，不持有 AppKit/SwiftUI 类型，不决定 UI 展示。
- `EventClient` 属于传输层：只负责连接 `/events`、解析 event envelope、过滤常态 heartbeat info 日志、向上回调事件/错误；不要在 `EventClient` 内更新 SwiftUI 状态、弹 alert、判断 workspace 或 PTY 业务语义。
- `Services`：负责客户端系统集成能力，例如通过 `Process` 启动 bundled backend、定位可执行文件、设置 environment/currentDirectory 和桥接 macOS 平台能力。Services 不应理解 workspace/目录业务语义。
- `Models`：保存客户端视图状态和展示模型，避免复制 backend 领域模型的决策逻辑。DTO 字段应贴近协议；展示模型只能添加 UI 所需的轻量派生值。

## Backend 启动与连接

- `Process` 拉起 backend 前必须先做 health check：优先请求当前约定的 `/health` endpoint；如果已有健康 backend 在 `127.0.0.1:3587` 响应，就直接复用，不要再启动第二个 backend。
- health check 失败后才允许进入启动流程；启动后要再次等待/轮询 health，直到 backend ready 或明确超时，再让 ViewModel 继续调用 RPC。
- 启动流程必须可重复调用且幂等：已有 `process?.isRunning == true` 或已有外部 healthy backend 时都应快速返回。
- backend 进程所有权必须明确：客户端只拥有并可关闭由当前 launcher 实例启动、且仍持有 stdin 生命周期 pipe 写端的 backend。已有 healthy backend 视为外部进程；客户端只能复用连接，退出或重连时不得关闭它。
- `BackendProcessLauncher` 启动 core 时必须把 core 的 `standardInput` 接到专用 `Pipe`，用 pipe 写端作为客户端持有的生命周期租约：
  - `Process.run()` 成功后，父侧立即关闭 pipe 读端，只保留写端；启动失败时关闭 pipe 两端。
  - 客户端正常关闭受管 backend 时关闭写端；客户端正常退出、崩溃或被 `SIGKILL` 时，由操作系统自动关闭写端。
  - core 以 stdin EOF 作为父客户端生命周期结束信号，并触发 graceful shutdown。
- 禁止通过父 PID 环境变量、PID 存活轮询或定时探测管理 backend 生命周期；也禁止把正确退出仅寄托于 Swift `deinit` 中调用 `Process.terminate()`。`deinit` 可以主动关闭写端，但 EOF/操作系统关闭 pipe 才是覆盖异常退出的生命周期机制。
- 不要假设 `Process.run()` 成功等于 backend 可用；端口绑定失败、sandbox 继承、cwd 错误、环境变量错误都可能让进程存在但 API 不可用。
- backend 地址、health endpoint、RPC endpoint 要集中在 API/Service 边界，避免散落在 Views 或 ViewModels。
- 后端未连接、启动失败、health 超时或 event stream 断开时，客户端不得裸抛或只打印错误；必须通过现有 `WorkspaceAlertPresenter`/`WorkspaceAlertPresenting` 展示用户可理解的 alert，并保留 ViewModel 状态文本用于界面反馈。
- `/events` 连接只能在 backend health 已确认后建立；重连或断开时要清理旧 event task、heartbeat watchdog 和 UI 状态，避免多个 WebSocket 连接同时存活。

## Sandbox 与文件系统语义

- sandbox、entitlements、`HOME`、`PWD`、`Process.currentDirectoryURL`、app bundle 位置和 Xcode 启动方式都会影响 backend 看到的文件系统语义；修改 launcher 或 entitlements 前必须重新验证 Home/Desktop/Downloads/Documents 和任意绝对路径的 backend 响应。
- 需要真实用户 home 时，优先使用 `getpwuid(getuid())` 一类真实账号信息，不要依赖 sandbox 后的 `FileManager.default.homeDirectoryForCurrentUser` 作为 backend 的 `HOME`。
- 拉起 backend 时必须显式设置 `HOME`、`PWD` 和 `currentDirectoryURL`，避免 Rust 侧把 container、DerivedData、`.app/Contents` 或 Xcode 当前目录误判为用户工作目录。
- App Sandbox 默认会传递给子进程并改变文件访问能力；除非 backend 已经有明确的 security-scoped bookmark/权限设计，否则不要打开 sandbox 后再启动 backend。
- entitlements 变更属于高风险维护点：任何改动都必须说明它对子进程、用户文件访问、network localhost、Downloads/Documents 等路径的影响。
- 客户端可以用系统 API 找入口路径或做 UI 集成，但最终目录是否存在、是否可读、如何解析 symlink 和权限错误，都应由 backend 通过 API 返回。

## Process I/O 规则

- core 的 stdin 必须专用于生命周期 pipe，不得接到 `/dev/null`、终端输入或会被其他对象长期持有写端的共享 pipe。launcher 在受管 backend 存活期间只保留该 pipe 的写端，确保客户端消失后 core 能可靠读到 EOF。
- 生命周期 pipe 只表达“启动者仍存活”，不承载命令、业务数据或健康状态；连接可用性仍由 `/health` 和 RPC 响应判断。
- 不要使用无人消费的 `Pipe` 连接 `standardOutput` 或 `standardError`。如果 nobody reads pipe，backend 日志量稍大就可能阻塞子进程。
- 如果需要丢弃输出，使用 `/dev/null` 或等价的持续可写 sink；如果需要展示/诊断日志，就必须有明确的 reader、生命周期管理和 backpressure 策略。
- 不要在 Services 里悄悄吞掉启动错误；错误要映射成用户可理解的连接状态，同时保留足够的诊断信息给开发者定位。

## API 与协议

- API DTO 要和 `protocol/`、Rust backend 返回结构保持一致。
- backend API shape 改变时，优先同步 `API` 层 DTO 和调用点，并提醒更新协议文档。
- 客户端不要猜测 backend 状态；需要状态时通过 backend 方法获取。
- `workspaceRoot` 是 backend 管理的当前上下文根，不是客户端侧的文件系统安全沙箱。客户端不得用 `workspaceRoot` 拒绝路径访问，也不得把它当作权限边界。
- 打开目录后是否保留或切换 `workspaceRoot` 完全由 backend 决定；客户端不得根据字符串前缀、父子目录关系、symlink 目标或用户入口自行推断和改写 root，只消费并呈现 backend 返回的新 state。
- 错误展示可以由客户端决定，但错误含义、文件系统权限、路径有效性等判断应来自 backend。
- 任何为了 UI 方便而新增的字段，如果代表产品事实，应先加到 backend/protocol；不要只在 Swift DTO 或 ViewModel 中拼出来。

## WebSocket 事件通道

- `/events` 是独立于 `/rpc` 的 backend lifecycle/event channel，不走 RPC 分流，也不承载高频 PTY 字节流。
- 客户端当前只消费 `backend.ready`、`heartbeat` 和可诊断的 unknown event；新增事件前必须先确认协议归属，避免在 Swift 侧发明隐式契约。
- `heartbeat` 是常态判活事件：收到时可以更新内部时间戳和必要的连接状态，但 info 日志必须过滤，避免 debug 时被高频常态消息淹没。
- 客户端必须有自己的半开连接判活策略。event channel connected 后启动 heartbeat watchdog；超过约定时间未收到 heartbeat 时主动断开 event client、更新 `eventStatusText`，并走 `WorkspaceAlertPresenter`。
- WebSocket error、close 或 watchdog timeout 都只能说明 event stream 不可用；不要据此在客户端推断 workspace、目录或未来 PTY session 的事实状态。需要事实时重新通过 backend API/protocol 查询。
- ViewModel 负责把 event client 回调折叠成 UI 可观察状态，例如 `eventStatusText`、连接中/断开提示和 alert；Views 只展示这些状态，不直接持有 WebSocket task。

## 导航与打开边界

- 路径打开、目录事实判断、目录切换和列目录必须走 Rust backend RPC；客户端不得用 `FileManager`、字符串前缀或本地 stat 结果决定路径是否为目录、是否存在或是否可进入。
- `WorkspaceItemOpener` 只负责把文件交给 macOS 系统打开。目录导航不属于 opener 职责；用户双击目录、输入路径、点击 sidebar 或执行上级/刷新，都应回到 ViewModel/API/backend 链路。
- 无效、缺失或不可进入目录的导航错误应通过可复用 `WorkspaceAlertPresenter` 展示。失败时保持当前目录事实不变，并刷新当前 listing，避免 UI 停留在半切换状态。
- 刷新行为只重新 list 当前目录；不要为了恢复 UI 状态而额外调用 openDirectory 或在客户端重新推断当前路径。

## 伪终端面板边界

- 伪终端面板是主窗口内部布局，不使用外部 `NSPanel`、child window 或附着窗口。Command+K 打开时主窗口大小保持不变，由窗口内 directory browser 让出空间；面板保留右上角关闭按钮，真实 PTY 接入后该按钮必须发送 `terminal.close` 销毁 session，并在协议事件收尾后收起当前窗口内伪终端 UI。
- 客户端可以管理纯 UI 状态：panel open/closed、面板高度、拖拽布局、viewport 像素测量、focus 和动画。
- `PseudoTerminalPanelLayoutState` 应保持为独立 UI 状态；`TerminalResizeHandle` 应保持为独立拖拽分割条；`PseudoTerminalPanelView` 通过 `onViewportChanged` 测量可用尺寸。
- viewport 变化要 debounce/coalesce，后续只把合并后的尺寸转换成 backend 需要的 resize 请求。不要把每次 SwiftUI layout 抖动都直接当作 terminal 业务事件。
- 客户端不得实现 PTY、shell、进程生命周期、terminal cwd、命令执行、环境变量、buffer/backscroll 或 resize 语义。真实 terminal 会话事实和生命周期归 Rust backend/protocol 所有。
- 下一阶段 PTY 客户端只做最小闭环 UI：输入、输出展示、resize 上报和 close action。不要在客户端创建 PTY session 权威状态，也不要把 shell 是否退出、当前 cwd、命令成功失败等事实从终端文本里解析出来。
- PTY WebSocket 必须是独立通道，例如后续约定的 terminal/pty endpoint，不得混入 `/events`。PTY 通道同样需要客户端侧 heartbeat/超时/断开策略，避免半开连接让 UI 误以为终端仍可用。

## 原生体验方向

- macOS 客户端应接近 Finder 的使用手感：稳定的 sidebar、目录表格、键盘导航、双击进入目录、toolbar 操作和系统惯用反馈。
- 当 SwiftUI 组件无法自然表达 Finder-like 行为时，优先引入 AppKit 包装或直接使用 AppKit 控件。
- `NSTableView` 是目录主列表的长期方向，避免在复杂文件列表上堆叠过多 SwiftUI workaround。
- sidebar 应优先承载 Home、Desktop、Downloads、Documents 和当前 workspace 等入口。

## AppKit / SwiftUI 桥接

- `NSViewRepresentable` / AppKit coordinator 必须把 SwiftUI state -> AppKit update 和 AppKit delegate -> SwiftUI state change 分开处理，避免 selection update loop。
- 当 `updateNSView` 正在应用 selection、reload 或 programmatic scroll 时，要用明确的 guard flag（例如 `isApplyingSelection`）屏蔽 delegate 回调；用户真实选择变化再调用 `onSelect`。
- selection 更新必须先比较现有 selection 与目标 selection，只有变化时才调用 `selectRowIndexes` / `deselectAll`，避免重复触发 SwiftUI render。
- AppKit coordinator 可以持有控件弱引用和短期 UI 缓存，但不要持有 backend client、启动 service 或业务状态机。
- 双击、键盘导航、上下文菜单等原生事件只负责识别用户意图；打开目录、刷新列表等动作仍交给 ViewModel/API/backend 链路。

## 维护边界

- 不要修改根目录 `agent.md` 或 `core/agent.md`，除非用户明确要求。
- 不要还原其他 agent 或用户的改动；如果遇到并发编辑，先读清楚现状，再在 macOS 客户端范围内继续。
- 修改客户端行为时，优先保持 backend API 调用路径清晰、可测试、可替换。
- 所有新增加的代码文件必须由 git 统一管理；新增 Swift 源码、资源、测试或工程配置文件后，要确认它们出现在 `git status` 中，并在交付前说明是否需要纳入版本控制。
- 新增 UI 能力前先确认是否属于 Phase 1；如果属于未来 terminal/search/git/plugins 范围，先留接口位置或 TODO，不要实现真实功能。
- 任何看起来能在客户端快速修好的 backend 行为问题，都先停下来确认归属；属于产品事实、协议、文件系统、terminal/search/git/plugins 语义的问题，应修 backend 或协议，而不是让 macOS client 产生第二套规则。
- 维护 Services/API/ViewModels/Views 时，避免跨层捷径：Views 不碰 API，API 不碰 UI，Services 不碰 workspace 业务，ViewModels 不直接读真实文件系统当事实来源。

## 测试要求

- 任何 Swift 生产代码变更都必须配套新增或更新 `MacOSTests`，或者给出明确的自动化验证；不能只依赖手动点击。
- ViewModel 行为改动优先写单元测试，使用 mock backend/opener 锁定 state、history、selection、loading、error text 和 backend 调用顺序。
- API/RPC 解码改动要覆盖兼容字段、错误 code/message、缺失字段和 backend 返回 shape 变化。
- WebSocket 客户端改动要覆盖 event connect/disconnect、`backend.ready`、`heartbeat`、unknown event、error callback、heartbeat timeout 和 alert presenter 调用；不要只用手动启动 app 验证。
- UI 状态改动如果难以直接测试，应至少通过 ViewModel 可观察状态或轻量组件边界测试覆盖；无法自动化时必须说明手动验证步骤和剩余风险。
- 当前 `WorkspaceBrowserViewModelTests` 至少应持续覆盖：
  - 隐藏文件过滤与显示切换。
  - 后退、前进、上级目录和新导航清空 forward history。
  - 目录打开失败不改变当前路径或历史。
  - 相对路径输入和非目录文件路径打开。
  - 刷新只 list 当前目录，不误调用 openDirectory。
  - 加载期间再次请求初始状态会在当前加载结束后重新同步。
  - 若重新引入状态栏/底栏文案，必须覆盖其不展示项目数量或“可见数量 of 总数量”。
- 新增测试文件、test target、project 配置和 test helper 都必须纳入 git，除非用户明确要求排除。

## 验证建议

- 确认客户端仍然调用 `http://127.0.0.1:3587/rpc` 或当前约定的 backend 地址。
- 确认启动 backend 前会先检查 `http://127.0.0.1:3587/health` 或当前约定的 health endpoint，且已有 healthy backend 时不会重复启动。
- 验证已有 healthy 外部 backend 时，客户端不会创建生命周期 pipe、不会获得该进程所有权，并且客户端退出后该 backend 继续运行。
- 验证客户端自行启动 backend 时，core stdin 接到专用生命周期 pipe；启动后父侧读端已关闭，客户端仅持有写端；受控关闭写端后 core 读到 EOF 并释放监听端口。
- 分别验证客户端正常退出、崩溃和被 `SIGKILL` 后，自行启动的 backend 都因 stdin EOF 自动退出，且 `127.0.0.1:3587` 没有残留监听进程。
- 检查 launcher 与 core 生命周期实现中不存在父 PID 环境变量、PID 存活轮询或依赖 `Process.terminate()` 才能退出的路径。
- 确认目录列表、目录切换和错误展示都来自 backend 响应。
- 验证打开 root 内外目录及 symlink 后，客户端均直接采用 backend 返回的 `workspaceRoot` / `currentDirectory`，不在 Swift 侧推断或覆盖 root 切换结果。
- 确认 backend 子进程看到的 `HOME`、`PWD` 和 cwd 是真实用户语义，不是 sandbox container、DerivedData 或 app bundle 内部路径。
- 确认 backend stdout/stderr 没有接到无人消费的 `Pipe`。
- 涉及 `NSViewRepresentable` / `NSTableView` selection 时，验证点击选择、清空选择、reload 后保留选择、双击打开目录都不会出现循环刷新或选中态抖动。
- 客户端代码改动优先运行：

```sh
xcodebuild test -project clients/MacOS/MacOS.xcodeproj \
  -scheme MacOS \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .derivedData/codex-tests \
  CODE_SIGNING_ALLOWED=NO
```

- 涉及 API DTO 或方法名变化时，同时检查 backend 与 `protocol/README.md` 是否需要更新。
