# macOS Client Agent 操作规范

这份文件约束后续 agent 维护 macOS 客户端时的做法。它只描述 `clients/MacOS/` 内的客户端工作边界；根目录路线图、backend 规范和协议文档以各自目录的文件为准。

## 核心定位

- macOS client 是 presentation layer，负责把 Rust core 暴露出的工作区、目录和终端能力呈现为原生 macOS 体验。
- Rust core 是产品行为和数据事实的来源。它**进程内链接、随客户端进程存活**，既不是远程服务也不是子进程。客户端负责渲染、选择、焦点、布局、交互和用户反馈。
- 客户端不要偷走 core 业务逻辑：不要在 Swift 侧重新实现 workspace 状态机、目录合法性判断、路径归一化策略、文件类型业务分类、权限语义、排序事实或 terminal/search/git/plugins 的核心规则。
- 客户端可以做 presentation transformation，例如图标选择、日期/大小显示文本、选中态、loading/error 文案和原生控件适配；一旦某个判断会影响产品事实或 backend 状态，就必须放回 Rust core。
- 目录数据必须来自 core API（默认进程内 FFI），而不是把 Swift `FileManager` 当作产品真相。`FileManager` 只能用于临时开发辅助、系统 UI 集成或非产品事实类的本地能力。
- 因为 core 进程内运行，客户端进程自身的 entitlements / App Sandbox **直接决定 core 能访问的文件系统**：当前 core 需要访问真实用户文件系统，除非已有明确的 security-scoped bookmark / 权限设计，否则不要开启 App Sandbox，否则 core 会被同样的 container 路径和文件访问限制困住。

## 当前阶段

- 当前优先 workspace、目录浏览体验，以及窗口内终端面板。
- 当前已有 `MacOSTests` target，包含 `WorkspaceBrowserViewModelTests`、`BackendConnectionViewModelTests`、`PseudoTerminalPanelLayoutStateTests`、`TerminalClientTests`、`TerminalSessionViewModelTests`、`ThumbnailProviderTests`，以及 Finder UI 测试（`FinderUIRebuildTests`、`FinderColumnViewTests`、`FinderDisplayMethodTests`、`FinderGalleryViewTests`）；后续客户端行为改动必须优先用这些测试锁定。
- 主界面已是 AppKit 结构（`Views/Finder/*`：window/split/list/column/icon/gallery/sidebar/toolbar/terminal）；旧 SwiftUI proof-of-flow 栈已删除，`MacOSApp.swift` 只剩一个 SwiftUI App 外壳，经 `NSApplicationDelegateAdaptor(FinderAppDelegate)` 委托给 AppKit。新增列表/导航能力继续走 AppKit，不要回填 SwiftUI workaround。
- 隐藏文件切换、后退/前进/上级目录、路径输入、刷新、打开文件、连接恢复后重新同步、以及不在状态栏/底栏显示项目数量等当前行为都属于受保护行为。
- 事件通道已接入：`FFIEventClient` 在 connect 时上报 `backend.ready`，并合成 `heartbeat` 维持 watchdog；它不是 PTY 数据通道。
- 终端最小闭环已接入：`TerminalSessionViewModel` + `FFITerminalClient` + `FinderTerminalView`（SwiftTerm）经 FFI 创建/输入/resize/关闭真实 PTY。客户端只做最小 UI 闭环，不拥有 PTY 会话事实。不要为未来 search/git/plugins 提前扩大客户端架构。

## 分层职责

- `Views`（`Views/Finder/*`）：只负责 AppKit 布局、展示、用户交互和原生控件组合。不要直接发 FFI/HTTP 调用，不要启动进程，不要做文件系统事实判断；用户动作应通过闭包或 ViewModel action 传出。
- `ViewModels`：只做 UI state、async actions、API orchestration、任务取消、loading/error/selection/connection 状态管理。不承载 backend 业务规则，不把多个 backend 调用的结果改造成新的产品真相。事件连接状态、heartbeat 超时和 alert 协调可以放在 ViewModel，但 backend 是否 ready、PTY session 是否存在等事实仍以 backend 为准。
- `API`：定义 `BackendClientProtocol` / `EventClientProtocol` / `TerminalClientProtocol` 及其请求响应 DTO。**默认实现是进程内 FFI 客户端 `CoreFFIClients.swift`（`FFIBackendClient` / `FFIEventClient` / `FFITerminalClient`），经全局共享的 `CoreFFI.handle` 调用 `CoreHandle`**；HTTP 版实现（`BackendClient` / `EventClient` / `TerminalClient.swift` + `RpcModels.swift`）只服务可选 server 模式。API 层不持有 AppKit/SwiftUI 类型，不决定 UI 展示。ViewModel 依赖协议而非具体实现，以便在 FFI 与 HTTP 间无感替换。
- FFI 绑定：`Core/Generated/terminal_finder_core.swift` 是 UniFFI 生成产物，不手改；它与 `Vendor/CoreFFI/` 的静态库由 `scripts/refresh-core-ffi.sh` 同步。
- `Services`：负责客户端系统集成能力——`WorkspaceAlertPresenter`（可复用 alert）、`WorkspaceItemOpener`（交 macOS 系统打开文件）、`Thumbnail/*`（缩略图）。Services 不理解 workspace/目录业务语义，也不再负责启动任何 backend 进程。
- `Models`：保存客户端视图状态和展示模型（如 `ConnectionStatus`），避免复制 backend 领域模型的决策逻辑。DTO 字段应贴近协议 / FFI DTO；展示模型只能添加 UI 所需的轻量派生值。

## Core 连接生命周期

- core 进程内运行：`CoreFFI.handle`（`CoreHandle()`）是全 App 共享的**单例状态容器**（workspace state、terminal registry），必须单例共享，等价旧架构的「单个 backend 进程」。不要在多处各自 new `CoreHandle` 造出多份状态。
- 没有进程、端口、health endpoint 或 stdin pipe 需要管理：「健康」即「库可调用」。`FFIBackendClient.health()` 等价于 `ping()`；`BackendConnectionViewModel.connect()` 调用 `health()` 成功即视为 connected，随后连接事件通道。
- 不要重新引入子进程：禁止用 `Process` 启动 backend、轮询 `127.0.0.1:3587/health`、复用外部 backend 进程，或维护 stdin 生命周期 pipe / PID 探测 / `Process.terminate()` 退出路径。这些都是已删除的旧 HTTP 架构遗留，进程内 FFI 不需要。
- 事件通道：`FFIEventClient.connect` 立即回调 `.backendReady`，并按固定间隔合成 `heartbeat`；`BackendConnectionViewModel` 仍保留 heartbeat watchdog，超时即断开 event client、更新 `eventStatusText` 并走 `WorkspaceAlertPresenter`。
- 失败路径仍需用户可理解的反馈：core 初始化或事件通道异常时，不得裸抛或只打印错误；必须通过现有 `WorkspaceAlertPresenter` / `WorkspaceAlertPresenting` 展示 alert，并保留 ViewModel 状态文本用于界面反馈。
- 可选 server 模式（HTTP 客户端实现）才需要 health endpoint / 进程管理；默认 FFI 路径不涉及。维护时不要把 server 模式的连接假设带进 FFI 路径。

## Sandbox 与文件系统语义

- core 进程内运行，**继承客户端进程自身的 sandbox / entitlements / 文件访问能力**：客户端能读到什么，core 就能读到什么。修改 entitlements、签名或 Xcode 运行方式后，必须重新验证 Home/Desktop/Downloads/Documents 和任意绝对路径经 backend API 的响应。
- 当前 core 需要访问真实用户文件系统：除非已有明确的 security-scoped bookmark / 权限设计，否则不要开启 App Sandbox。
- entitlements 变更属于高风险维护点：任何改动都必须说明它对用户文件访问、Downloads/Documents 等路径，以及（server 模式下）network localhost 的影响。
- 客户端可以用系统 API 找入口路径或做 UI 集成，但最终目录是否存在、是否可读、如何解析 symlink 和权限错误，都应由 backend 通过 API 返回。

## API 与协议

- API DTO 要和 `protocol/`、Rust backend 返回结构（含 `core/src/ffi/` 的跨边界 DTO）保持一致。
- backend / FFI 接口 shape 改变时，先运行 `scripts/refresh-core-ffi.sh` 重新生成绑定，再同步 `API` 层 DTO 和调用点，并提醒更新协议文档。
- 客户端不要猜测 backend 状态；需要状态时通过 backend 方法获取。
- `workspaceRoot` 是 backend 管理的当前上下文根，不是客户端侧的文件系统安全沙箱。客户端不得用 `workspaceRoot` 拒绝路径访问，也不得把它当作权限边界。
- 打开目录后是否保留或切换 `workspaceRoot` 完全由 backend 决定；客户端不得根据字符串前缀、父子目录关系、symlink 目标或用户入口自行推断和改写 root，只消费并呈现 backend 返回的新 state。
- 错误展示可以由客户端决定，但错误含义、文件系统权限、路径有效性等判断应来自 backend。
- 任何为了 UI 方便而新增的字段，如果代表产品事实，应先加到 backend / protocol / FFI DTO；不要只在 Swift DTO 或 ViewModel 中拼出来。

## 事件通道（FFI 回调）

- 事件通道默认是进程内 FFI 回调（`FFIEventClient`），不是 HTTP/WebSocket；只有可选 server 模式下 transport 才是 `/events` WebSocket。两种 transport 的事件语义一致：独立于命令调用，不承载高频 PTY 字节流。
- 客户端当前只消费 `backend.ready`、`heartbeat` 和可诊断的 unknown event；新增事件前必须先确认协议归属，避免在 Swift 侧发明隐式契约。
- `heartbeat` 是常态判活事件：收到时可以更新内部时间戳和必要的连接状态，但 info 日志必须过滤，避免被高频常态消息淹没。
- 客户端必须有自己的判活策略：event channel connected 后启动 heartbeat watchdog；超过约定时间未收到 heartbeat 时主动断开 event client、更新 `eventStatusText`，并走 `WorkspaceAlertPresenter`。
- event channel 不可用只说明事件流断了；不要据此在客户端推断 workspace、目录或 PTY session 的事实状态。需要事实时重新通过 backend API 查询。
- ViewModel 负责把 event 回调折叠成 UI 可观察状态，例如 `eventStatusText`、连接中/断开提示和 alert；Views 只展示这些状态，不直接持有事件任务。

## 导航与打开边界

- 路径打开、目录事实判断、目录切换和列目录必须走 Rust backend（默认 FFI）；客户端不得用 `FileManager`、字符串前缀或本地 stat 结果决定路径是否为目录、是否存在或是否可进入。
- `WorkspaceItemOpener` 只负责把文件交给 macOS 系统打开。目录导航不属于 opener 职责；用户双击目录、输入路径、点击 sidebar 或执行上级/刷新，都应回到 ViewModel/API/backend 链路。
- 无效、缺失或不可进入目录的导航错误应通过可复用 `WorkspaceAlertPresenter` 展示。失败时保持当前目录事实不变，并刷新当前 listing，避免 UI 停留在半切换状态。
- 刷新行为只重新 list 当前目录；不要为了恢复 UI 状态而额外调用 openDirectory 或在客户端重新推断当前路径。

## 终端面板边界

- 终端面板是主窗口内部布局，不使用外部 `NSPanel`、child window 或附着窗口。Command+J 或 Command+K 切换面板；打开时主窗口大小保持不变，由窗口内 directory browser 让出空间；面板保留关闭按钮，关闭时通过 `TerminalSessionViewModel` 发送 `terminal.close` 销毁 session，并在协议事件收尾后收起当前窗口内终端 UI。
- 客户端只管理纯 UI 状态：panel open/closed、面板高度（`PseudoTerminalPanelLayoutState`）、拖拽分割条（`FinderTerminalResizeHandle`）、viewport 像素测量（`FinderTerminalView` / 表面 metrics）、focus 和动画。
- viewport 变化要 debounce/coalesce，只把合并后的尺寸转换成 backend `terminal.resize` 请求。不要把每次 layout 抖动都直接当作 terminal 业务事件。
- PTY、shell、进程生命周期、terminal cwd、命令执行、环境变量、buffer/backscroll 或 resize 语义归 core：客户端经 `FFITerminalClient`（`create` / `sendInput` / `resize` / `close`）驱动，输出/退出/错误经 `TerminalEventListener` 回调送达。不要在客户端创建 PTY session 权威状态，也不要从终端文本里解析 shell 是否退出、当前 cwd、命令成功失败等事实。
- 终端通道随 `FFITerminalClient.disconnect()` 关闭其拥有的 session（镜像 WebSocket 断开语义）；server 模式下 PTY 走独立 WebSocket，不混入 `/events`，同样需要客户端侧 heartbeat/超时/断开策略。

## 原生体验方向

- macOS 客户端应接近 Finder 的使用手感：稳定的 sidebar、目录表格、键盘导航、双击进入目录、toolbar 操作和系统惯用反馈。
- 目录主列表已使用 `NSTableView` / AppKit；继续保持，避免在复杂文件列表上堆叠 SwiftUI workaround。
- 当某个原生行为无法自然表达时，优先引入 AppKit 包装或直接使用 AppKit 控件。
- sidebar 应优先承载 Home、Desktop、Downloads、Documents 和当前 workspace 等入口。

## AppKit 桥接

- AppKit 控件与状态同步必须把「state -> AppKit update」和「AppKit delegate -> state change」分开处理，避免 selection update loop。
- 当正在应用 selection、reload 或 programmatic scroll 时，要用明确的 guard flag（例如 `isApplyingSelection`）屏蔽 delegate 回调；用户真实选择变化再调用 `onSelect`。
- selection 更新必须先比较现有 selection 与目标 selection，只有变化时才调用 `selectRowIndexes` / `deselectAll`，避免重复触发 render。
- coordinator / controller 可以持有控件弱引用和短期 UI 缓存，但不要持有 backend client、`CoreHandle` 或业务状态机。
- 双击、键盘导航、上下文菜单等原生事件只负责识别用户意图；打开目录、刷新列表等动作仍交给 ViewModel/API/backend 链路。

## 维护边界

- 不要修改根目录 `agent.md` 或 `core/agent.md`，除非用户明确要求。
- 不要还原其他 agent 或用户的改动；如果遇到并发编辑，先读清楚现状，再在 macOS 客户端范围内继续。
- 修改客户端行为时，优先保持 backend 调用路径清晰、可测试、可替换（FFI 与 HTTP 实现可互换）。
- 所有新增加的代码文件必须由 git 统一管理（开发用 `*.md` 文档除外）；新增 Swift 源码、资源、测试或工程配置文件后，要确认它们出现在 `git status` 中，并在交付前说明是否需要纳入版本控制。
- 新增 UI 能力前先确认是否属于当前阶段；如果属于未来 terminal 扩展/search/git/plugins 范围，先留接口位置或 TODO，不要实现真实功能。
- 任何看起来能在客户端快速修好的 backend 行为问题，都先停下来确认归属；属于产品事实、协议、文件系统、terminal/search/git/plugins 语义的问题，应修 backend 或协议，而不是让 macOS client 产生第二套规则。
- 维护 Services/API/ViewModels/Views 时，避免跨层捷径：Views 不碰 API，API 不碰 UI，Services 不碰 workspace 业务，ViewModels 不直接读真实文件系统当事实来源。

## 测试要求

- 任何 Swift 生产代码变更都必须配套新增或更新 `MacOSTests`，或者给出明确的自动化验证；不能只依赖手动点击。
- ViewModel 行为改动优先写单元测试，使用 mock client/opener 锁定 state、history、selection、loading、error text 和 backend 调用顺序。
- API/DTO 解码改动要覆盖兼容字段、错误 code/message、缺失字段和 backend 返回 shape 变化。
- 事件客户端改动要覆盖 connect/disconnect、`backend.ready`、`heartbeat`、unknown event、error callback、heartbeat timeout 和 alert presenter 调用；不要只用手动启动 app 验证。
- 终端改动要覆盖 `create` / `sendInput` / `resize` / `close`、output/exit/error 回调、断开时关闭自有 session，以及激活前事件入队补发（见 `FFITerminalSessionListener`）；用 `TerminalClientTests` / `TerminalSessionViewModelTests` 锁定。
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

- 确认 ViewModel 默认走进程内 FFI 客户端（`FFIBackendClient` / `FFIEventClient` / `FFITerminalClient`），且共享同一个 `CoreFFI.handle`。
- 确认没有重新引入 `Process` 启动 backend、`127.0.0.1:3587` 轮询、stdin 生命周期 pipe 或 PID 探测。
- 验证 `health()` 成功即视为 connected；事件通道 connect 后收到合成的 `backend.ready` 与周期 `heartbeat`，watchdog 超时能断开并提示。
- 验证目录列表、目录切换和错误展示都来自 backend 响应；打开 root 内外目录及 symlink 后，客户端均直接采用 backend 返回的 `workspaceRoot` / `currentDirectory`，不在 Swift 侧推断或覆盖 root 切换结果。
- 验证终端：打开面板创建 session，输入/输出/resize/关闭走 FFI，关闭面板或断开后 session 被销毁、无残留。
- 确认 core 进程内访问的文件系统语义符合预期（真实用户 Home/Desktop/Downloads/Documents 与任意绝对路径），未被 sandbox container 限制。
- 改动了 Rust FFI 接口后，先运行 `clients/MacOS/scripts/refresh-core-ffi.sh` 重新生成绑定再构建。
- 涉及 `NSTableView` selection 时，验证点击选择、清空选择、reload 后保留选择、双击打开目录都不会出现循环刷新或选中态抖动。
- 客户端代码改动优先运行：

```sh
xcodebuild test -project clients/MacOS/MacOS.xcodeproj \
  -scheme MacOS \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .derivedData/codex-tests \
  CODE_SIGNING_ALLOWED=NO
```

- 涉及 API DTO 或方法名变化时，同时检查 backend、`core/src/ffi/` 与 `protocol/README.md` 是否需要更新。
