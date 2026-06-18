# Windows 98 Shell 开发文档

> 状态：架构方向已调整，M0 基础已落地，下一步修正视觉完整性\
> 范围：`clients/MacOS/` macOS 客户端 presentation layer，仅 Windows 98 shell\
> 关联：`clients/MacOS/CLIENT_DEPRECATION_REPORT.md`、`XP_SKIN_DESIGN.md`、`THEME_DECOUPLING_DESIGN.md`\
> 约定：本文件是开发文档，当前不纳入 git。接下来创建和修改的所有源码文件都必须在git上统一管理同时接下来对每进行一个阶段的改造都需要对当前状态进行一次git commit

## 0. 当前结论

Windows 98 不再作为 Finder 内部的 theme token 皮肤实现。

正确方向是：

- Native Finder shell 保持原生 AppKit / SwiftUI 语义色和系统控件。
- Windows 98 作为独立 SwiftUI shell 接入同一组 ViewModel。
- `FinderWindowController` 只负责 shell 切换和窗口级生命周期。
- Windows 98 的视觉控件、调色板、bevel、图标、标题栏和文件列表都应该收口在 `Views/Windows98/`。

已经从 master 移除的错误方向：

- `FinderTheme`
- `FinderThemeProvider`
- `SystemFinderTheme`
- `WindowsClassicFinderTheme`
- Finder 子视图里的 `themeProvider` 注入和 theme 切换入口

## 1. 已完成的 M0 基础

当前分支：`codex/client-shell-architecture`

已完成：

- 新增 `ClientShellModeState`，包含 `.nativeFinder` / `.windows98`。
- `FinderWindowController` 支持在 Native Finder split view 与 `Windows98ShellView` hosting view 之间切换。
- Native Finder 恢复为系统背景色和系统控件，不再依赖 theme token。
- 新增 `Windows98ShellView` 初版，接入共享的：
  - `WorkspaceBrowserViewModel`
  - `TerminalSessionViewModel`
  - `PseudoTerminalPanelLayoutState`
  - `FinderContentViewState`
- 新增 `CLIENT_DEPRECATION_REPORT.md`，记录哪些额外代码只是候选弃用，本轮不删。
- `xcodebuild test -project clients/MacOS/MacOS.xcodeproj -scheme MacOS -destination 'platform=macOS'` 已通过。

当前 Win98 相关源码位置：

- `clients/MacOS/MacOS/Views/Windows98/Windows98ShellView.swift`
- `clients/MacOS/MacOS/Views/Finder/Shell/ClientShellMode.swift`
- `FinderWindowController.swift` 中的 shell 装载与切换
- `FinderToolbarController.swift` / `FinderMainMenuBuilder.swift` 中的 shell 选择入口

## 2. 当前缺口

### 2.1 图标仍是 macOS 原生图标

现状：

- `Windows98ShellView` 的文件列表仍使用 `NSWorkspace.shared.icon(forFile:)`。
- 这会显示 macOS 原生文件夹、文件和 app 图标，视觉上会立刻出戏。

目标：

- Windows 98 shell 内部不得直接使用 Native Finder 的图标视觉。
- 增加 Win98 专属 icon provider，例如：

```swift
protocol Windows98IconProviding {
    func icon(for entry: DirectoryEntry) -> Image
}
```

或先用 AppKit：

```swift
struct Windows98IconProvider {
    func icon(for entry: DirectoryEntry) -> NSImage
}
```

最低要求：

- 文件夹：黄色 Win98 风格 folder。
- 普通文件：白纸 + 小色块/折角。
- symlink / other：独立 fallback。
- 侧栏入口：桌面、下载、文稿、home、磁盘位置不能继续完全沿用 SF Symbol 风格。

资产要求：

- 不直接拷贝微软版权图标。
- 优先使用自绘 pixel-style bitmap / 矢量近似 / 项目内生成资产。
- 图标只影响 Win98 shell，不能替换 Native Finder 的图标来源。

### 2.2 顶部 macOS 标题栏还没有彻底隐藏

现状：

- Win98 shell 内部已经画了 navy 标题栏。
- 但原生 macOS 顶部标题栏 / traffic lights 仍可能可见或占位。

目标：

- 切到 `.windows98` 时，视觉上只能看到 Win98 自己的标题栏。
- 切回 `.nativeFinder` 时，macOS 原生标题栏、toolbar、traffic lights 必须完全恢复。

建议落点：

- 在 `FinderWindowController.applyShellMode(_:)` 中集中处理 window chrome。
- `.windows98`：
  - `window.titleVisibility = .hidden`
  - `window.titlebarAppearsTransparent = true`
  - `window.toolbar = nil`
  - 隐藏 `standardWindowButton(.closeButton/.miniaturizeButton/.zoomButton)`
  - 如需拖动，设置 `window.isMovableByWindowBackground = true` 或明确实现自绘标题栏拖动区域。
- `.nativeFinder`：
  - 恢复 `titleVisibility = .visible`
  - 恢复 `titlebarAppearsTransparent = false`
  - 恢复系统三键显示
  - 恢复 Native Finder toolbar

约束：

- 不改 `NSWindow` 的初始 frame、content size、min size、autosave name。
- shell 切换不能重建 window，也不能偷偷改变窗口大小。

### 2.3 Win98 自绘三键还没接入

现状：

- 标题栏右侧只有 `Native` 切回按钮。
- 缺少 Win98 风格的 `_` / `□` / `X` 三个窗口控制按钮。

目标：

- 在 `Native` 按钮旁边增加 Win98 风格三键。
- 三键必须是灰色 3D raised 方按钮，按下时变 sunken。
- 动作映射：
  - `_` → `window.miniaturize(nil)`
  - `□` → `window.zoom(nil)`
  - `X` → `window.performClose(nil)`

建议组件：

```swift
struct Windows98TitleBarView: View {
    let title: String
    let onSwitchToNative: () -> Void
    let onMinimize: () -> Void
    let onZoom: () -> Void
    let onClose: () -> Void
}
```

`Windows98ShellView` 不应该自己知道 `NSWindow` 细节。窗口动作由 `FinderWindowController` 注入闭包。

### 2.4 初始窗口大小不能被顺手改动

当前约束：

- 不允许为了 shell 切换修改初始窗口尺寸。
- 不允许 Win98 shell 因为自己的布局需求改变 `NSWindow` 初始大小。
- 不允许切换 shell 时调用 `setContentSize`、`setFrame`、`center`。

应保持现有窗口初始化语义：

- `contentRect`
- `window.minSize`
- `window.setContentSize(...)`
- `window.setFrameAutosaveName(...)`

除非单独任务明确要求调整窗口大小，否则这些值不能动。

建议补测试或审计：

- 在窗口 controller 改动中单独检查 diff，确认未改初始 size。
- 若后续加 UI 测试，验证 `.windows98` / `.nativeFinder` 切换前后 frame 不变。

## 3. Win98 Shell 架构边界

### 3.1 允许共享的东西

Win98 shell 可以共享：

- `WorkspaceBrowserViewModel`
- `TerminalSessionViewModel`
- `PseudoTerminalPanelLayoutState`
- `FinderContentViewState`
- `FinderListFormatters`
- `DirectoryEntry`
- backend / FFI client 层
- thumbnail / preview 服务，前提是视觉呈现由 Win98 shell 自己决定

### 3.2 不应共享的东西

Win98 shell 不应共享：

- Native Finder 的 toolbar UI
- Native Finder 的 sidebar UI
- Native Finder 的 list/icon/column/gallery view UI
- `NSWorkspace` 原生图标视觉
- macOS traffic lights 视觉
- Finder theme token / provider

### 3.3 可以复用但要包一层的东西

- 文件打开、路径导航、隐藏文件切换：直接调用 ViewModel。
- 终端面板：短期可复用 `FinderTerminalPanelView`，长期可以加 `Windows98TerminalPanelChrome` 包一层灰色 bevel。
- 预览能力：可复用 `ThumbnailProvider`，但 Win98 shell 的 preview pane 要自己画外壳。

## 4. 组件拆分方向

当前 M0 为了快速立住架构，Win98 视觉代码集中在 `Windows98ShellView.swift`。

随着修复进入 M1/M2，建议拆成：

```text
clients/MacOS/MacOS/Views/Windows98/
  Windows98ShellView.swift
  Windows98TitleBarView.swift
  Windows98ToolbarView.swift
  Windows98SidebarView.swift
  Windows98FileListView.swift
  Windows98StatusBarView.swift
  Windows98IconProvider.swift
  Windows98Palette.swift
  Windows98Bevel.swift
```

拆分原则：

- `Windows98ShellView` 只负责组装布局和注入 ViewModel。
- `Windows98TitleBarView` 负责标题栏、Native 切换按钮、三键。
- `Windows98IconProvider` 负责所有 Win98 图标。
- `Windows98Bevel` 是唯一 3D 边框绘制原语，禁止各处临时手写不同 bevel。
- `Windows98Palette` 收口所有 Win98 颜色。

## 5. 视觉规则

### 5.1 颜色

经典 Win98 基础色：

```text
surface        #C0C0C0
highlight      #FFFFFF
light          #DFDFDF
shadow         #808080
darkShadow     #404040
titleBlue      #000080
titleBlueLight #1084D0
selection      #000080
text           #000000
selectedText   #FFFFFF
contentBg      #FFFFFF
```

### 5.2 Bevel

Raised：

- 左/上：highlight + light
- 右/下：darkShadow + shadow

Sunken：

- 左/上：darkShadow + shadow
- 右/下：highlight + light

所有按钮、输入框、列表外框、状态栏 cell 都要使用同一套 bevel 规则。

### 5.3 字体

优先级：

1. `MS Sans Serif`，如果系统存在。
2. `Tahoma`。
3. `.systemFont(ofSize:)` fallback。

不内置微软原始字体文件。

### 5.4 圆角

Win98 shell 默认无圆角。

例外只允许在 macOS 系统控件不可控时接受系统默认，但 Win98 自绘组件不得主动加圆角。

## 6. 分阶段计划

### M0 Shell foundation（已完成）

- 移除 Native Finder theme-token 基建。
- 新增 `ClientShellModeState`。
- `FinderWindowController` 支持 Native / Win98 shell 切换。
- 新增 `Windows98ShellView` 初版。
- 单测通过。

### M1 当前问题修复（下一步）

目标：让 Win98 shell 从“结构像”进入“第一眼不像 macOS”。

任务：

- 隐藏 macOS 原生标题栏和 traffic lights，并保证切回 Native 时恢复。
- 在 `Native` 按钮旁边添加 Win98 风格 `_` / `□` / `X` 三键。
- 三键接入真实 window action。
- 保证 shell 切换前后窗口 frame / content size 不变。
- 增加 Win98 icon provider，替换文件列表和侧栏里的原生图标。
- 去除 MacOS 侧栏原生相关的dot颜色分类。只保留能够访问到的目录

验收：

- 切到 Windows 98 后，顶部只能看到 Win98 navy 标题栏。
- 右上角有 `Native` + `_` / `□` / `X`，按钮为灰色 3D 风格。
- 文件夹和文件图标不再是 macOS 原生图标。
- 应用初始启动窗口大小没有变化。
- Native Finder shell 不受 Win98 视觉代码污染。

### M2 组件拆分

- 从 `Windows98ShellView.swift` 拆出 title bar / toolbar / sidebar / file list / status bar。
- 收口 palette、bevel、icon provider。
- 减少单文件体积，避免后续继续堆在一个 SwiftUI 文件里。
- 所有新创建的源码文件都必须加入git统一管理

### M3 文件浏览体验补齐

- 文件列表支持更完整的 Win98 column header。
- 地址栏、状态栏、加载态、错误态打磨。
- 目录双击、文件打开、隐藏文件切换继续共享 ViewModel。

### M4 视觉打磨

- 16px / 32px 图标资产精修。
- 工具栏按钮图标替换为 Win98 风格。
- 终端面板外壳加灰色 bevel。

## 7. 测试策略

自动化：

- `ClientShellModeState` 默认值和 raw value 稳定性。
- shell 切换不改变 window frame。
- Win98 三键闭包被正确触发。
- `Windows98IconProvider` 对 directory/file/symlink/other 返回非 Native fallback。

手动验证：

- 启动默认仍是 Native Finder。
- 切到 Win98 后 macOS 标题栏不可见。
- `Native` 按钮可切回原生 Finder。
- `_` / `□` / `X` 行为符合窗口控制。
- 切换 shell 多次无 toolbar/titlebar 残留。
- 初始窗口大小不被修改。

## 8. 回滚策略

Win98 shell 相关代码应集中在：

- `Views/Windows98/`
- `Views/Finder/Shell/ClientShellMode.swift`
- `FinderWindowController` 的 shell 装载逻辑
- toolbar/main menu 的 shell 选择入口

回滚时应能删除 Win98 shell 和 shell 选择入口，而不影响 Native Finder 的文件浏览、终端、预览和 FFI 业务路径。

## 9. 旧文档处理

`THEME_DECOUPLING_DESIGN.md`、`XP_SKIN_DESIGN.md`、旧版 `WIN98_SKIN_DESIGN.md` 中关于 `FinderThemeProvider` / token / `usesWindowsChrome` 的方案已经不再作为当前实现路线。

这些文档仍可作为历史记录或视觉参考，但不能继续指导 Win98 的实现。