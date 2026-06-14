# Client Deprecation Report

Date: 2026-06-14
Branch: `codex/client-shell-architecture`

## Decision

当前方向应从“Finder 内部样式 token 切换”改为“客户端 shell 切换”：

- Native Finder shell 保持系统 AppKit / SwiftUI 语义色、系统控件和 Finder-like 结构。
- Windows 98 shell 作为独立 SwiftUI 外壳接入同一组 ViewModel。
- 文件浏览、路径导航、隐藏文件、终端面板等状态继续共享，不复制业务状态。

因此，已合入 master 的 `FinderTheme` / `FinderThemeProvider` / `SystemFinderTheme` / `WindowsClassicFinderTheme` 这条基础设施不再需要。它把 Windows 风格伪装成 Finder 视图内部的样式替换，方向上会持续扩大 Native Finder 的耦合面。

## Removed In This Branch

- `clients/MacOS/MacOS/Views/Finder/Theme/*`
- `clients/MacOS/MacOSTests/FinderThemeProviderTests.swift`
- `FinderWindowController` 中的 theme provider 注入和 `switchThemeAction`
- `FinderToolbarController` / main menu 中的“切换主题”入口
- `FinderListView` 对 theme provider、theme change notification 和 token 字体/颜色的依赖

替代方案是 `ClientShellModeState`，由 window controller 在 Native Finder split view 和 Windows 98 shell hosting view 之间切换。

## Candidate Deprecations Not Removed Yet

### 1. Theme design documents

候选：

- `THEME_DECOUPLING_DESIGN.md`
- `XP_SKIN_DESIGN.md`
- `WIN98_SKIN_DESIGN.md`

判断：这些文档仍在描述 token/provider/chrome token 方案，已经与当前 shell 方案冲突。建议先保留作为历史记录，但后续应改写为 shell 架构文档，或移动到 archive。

不要本轮删除的原因：其中仍包含 Win98/XP 视觉细节、验收点和截图方向，后续重写独立 shell 时还能借用。

### 2. Optional HTTP/WebSocket client path

候选：

- `clients/MacOS/MacOS/API/BackendClient.swift`
- `clients/MacOS/MacOS/API/EventClient.swift`
- `clients/MacOS/MacOS/API/TerminalClient.swift`
- `clients/MacOS/MacOS/MacOS.entitlements` 中网络相关权限

判断：macOS 默认已经走 `FFIBackendClient` / `FFIEventClient` / `FFITerminalClient`。如果产品确认不再支持可选 server 模式，这套 HTTP/WebSocket client 可以进入弃用流程。

不要本轮删除的原因：`agent.md` 明确把 server mode 定义为联调和未来 Web / 多客户端复用入口。删除它会影响协议镜像和测试策略，不属于本次 shell 架构修正。

### 3. RPC compatibility decode aliases

候选：

- `clients/MacOS/MacOS/API/RpcModels.swift` 中 `currentPath` / `path` / `cwd`、`rootPath` / `root`、`revision` 等兼容字段。

判断：如果 core/FFI/HTTP DTO 已稳定为单一字段命名，可以收紧这些兼容别名。

不要本轮删除的原因：这些别名不影响 shell 架构，也降低历史协议变动带来的破坏面。应等协议文档和 core DTO 一起确认。

### 4. Native Finder toolbar placeholders

候选：

- `FinderToolbarController` 中 disabled 的 share / tag / search / grouping placeholders。

判断：它们目前是 Finder-like UI 的占位能力，不是 theme 耦合。若产品不打算做 Finder parity，可以删除或移到后续 feature branch。

不要本轮删除的原因：这些控件属于 Native Finder shell 的功能路线，不会污染 Windows 98 shell。

### 5. Preview-specific infrastructure

候选：

- `ThumbnailProvider`
- Column / Gallery preview pane code
- `PREVIEW_FEATURE_DESIGN.md`

判断：这些代码与 theme token 方案没有结构依赖，仍是文件浏览产品能力。当前不应弃用。

不要本轮删除的原因：新 shell 架构可以选择复用或不复用 preview 能力；Native Finder shell 仍需要它。

## Follow-up Recommendation

下一步应新增一份 `CLIENT_SHELL_ARCHITECTURE.md`，把 Native Finder shell、Windows 98 shell、共享 ViewModel、窗口级切换、测试策略写清楚。之后再把旧 theme 文档改为历史设计或直接 archive。
