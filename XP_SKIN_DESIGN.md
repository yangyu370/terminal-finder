# Windows XP Shell 开发文档

> 状态：架构方向已对齐 Win98 shell，等待 M0 接入\
> 范围：`clients/MacOS/` macOS 客户端 presentation layer，仅 Windows XP shell\
> 关联：`WIN98_SKIN_DESIGN.md`（架构基准）、`clients/MacOS/CLIENT_DEPRECATION_REPORT.md`\
> 约定：本文件是开发文档，当前不纳入 git。新增**源码**文件必须纳入 git。

## 0. 当前结论

Windows XP 与 Windows 98 一样，**不是** Finder 内部的 theme token 皮肤，而是一个独立 SwiftUI shell。

正确方向：

- Native Finder shell 保持原生 AppKit / SwiftUI 语义色和系统控件。
- Windows XP 作为独立 SwiftUI shell（`WindowsXPShellView`）接入同一组 ViewModel。
- `FinderWindowController` 只负责 shell 切换和窗口级生命周期。
- XP 的视觉控件、调色板、bevel、图标、标题栏和文件列表都收口在 `Views/WindowsXP/`。

**复制策略（方案 A，已确认）：**

- XP 先照 `Windows98ShellView` 的结构骨架**独立复制**一份 `WindowsXPShellView`，骨架一一对应。
- 本期**不抽象** `WindowsShellScaffold`，两壳零耦合、可各自独立回滚。
- 区别只在 palette / bevel / icon / 圆角 / 字体 / 关键控件画法（见第 5 节）。
- 待 Win98 与 XP 两壳都稳定后，再单独评估是否抽公共脚手架（列为 M4 之后的可选项，避免过早抽象）。

**已经废弃、XP 文档不再采用的旧方向（见 `WIN98_SKIN_DESIGN.md` 第 0/9 节）：**

- `FinderTheme` / `FinderThemeProvider` / `SystemFinderTheme` / `WindowsClassicFinderTheme` / `Windows7AeroFinderTheme`
- `usesWindowsChrome` 布尔开关与 chrome token 槽位
- 把 XP 当作"原生 Finder 视图重新着色"（重绘 `FinderSidebarView`、`NSPathControl` 面包屑、工具栏 tint）——与新边界冲突，禁止复用 Native Finder 的 sidebar/toolbar/list UI。

## 1. 基线与前置（已就绪）

当前分支：`codex/client-shell-architecture`

Win98 落地时已经把 shell 切换基建做好，XP 直接复用：

- `ClientShellModeState` / `ClientShellMode` 枚举（当前含 `.nativeFinder` / `.windows98`）。
  - 源码：`clients/MacOS/MacOS/Views/Finder/Shell/ClientShellMode.swift`
- `FinderWindowController` 支持在 Native split view 与独立 shell hosting view 之间切换；窗口动作以闭包注入；窗口 chrome（隐藏三键 / 透明标题栏）按模式切换。
  - 源码：`clients/MacOS/MacOS/Views/Finder/FinderWindowController.swift`
- shell 选择入口：`FinderToolbarController.swift` / `FinderMainMenuBuilder.swift`。

XP 要做的就是往这套已存在的机制里**加一个 `.windowsXP` 分支**，不需要新机制。

## 2. XP Shell 架构边界

### 2.1 允许共享的东西（与 Win98 一致）

- `WorkspaceBrowserViewModel`
- `TerminalSessionViewModel`
- `PseudoTerminalPanelLayoutState`
- `FinderContentViewState`
- `ClientShellModeState`
- `FinderListFormatters`
- `DirectoryEntry` / `FinderSidebarItem` / `WorkspaceSidebarLocation`
- backend / FFI client 层
- thumbnail / preview 服务（前提是视觉呈现由 XP shell 自己决定）

### 2.2 不应共享的东西

- Native Finder 的 toolbar / sidebar / list / icon / column / gallery view UI
- `NSWorkspace.shared.icon(forFile:)` 原生图标视觉
- macOS traffic lights 视觉
- 已删除的 Finder theme token / provider

### 2.3 可以复用但要包一层的东西

- 文件打开、路径导航、隐藏文件切换：直接调用 ViewModel。
- 终端面板：短期复用 `FinderTerminalPanelView` + `FinderTerminalResizeHandle` + `FinderTerminalSurfaceMetrics`，长期可加 `WindowsXPTerminalPanelChrome` 包一层 Luna bevel。
- "前往文件夹"：复用 `FinderGoToFolderSheet`。
- 侧栏可访问目录过滤：`Windows98SidebarItemFilter` 本质 shell 无关（只判定目录是否存在/可读）。本期按方案 A 复制为 `WindowsXPSidebarItemFilter`，或后续抽成 `WindowsShellSidebarItemFilter` 共享——二选一，先复制不阻塞。

## 3. 组件拆分方向

对照 `Windows98ShellView.swift` 的现有结构，XP 新建 `Views/WindowsXP/`：

```text
clients/MacOS/MacOS/Views/WindowsXP/
  WindowsXPShellView.swift        // 组装布局 + 注入 ViewModel（对应 Windows98ShellView）
  WindowsXPTitleBarView.swift     // Luna 蓝渐变标题栏 + Native 切换 + 玻璃三键（关闭为红）
  WindowsXPToolbarView.swift      // Back/Forward/Up/Refresh/Dotfiles/Terminal（Luna 按钮）
  WindowsXPSidebarView.swift      // 蓝色任务窗格（task pane）
  WindowsXPFileListView.swift     // details 视图（蓝色列头 + #316AC5 选区）
  WindowsXPStatusBarView.swift    // 米色细状态栏 + 柔和 sunken cell
  WindowsXPIconProvider.swift     // XP 风格彩色图标（文件夹/文件/symlink/侧栏）
  WindowsXPPalette.swift          // 收口所有 Luna 颜色
  WindowsXPBevel.swift            // 唯一柔和 3D 边框原语（raised/inset/field）
```

拆分原则（同 Win98）：

- `WindowsXPShellView` 只负责组装布局和注入 ViewModel。
- `WindowsXPBevel` 是唯一 3D 边框绘制原语，禁止各处临时手写不同 bevel。
- `WindowsXPPalette` 收口所有 XP 颜色。
- `WindowsXPIconProvider` 负责所有 XP 图标。

> 注意：Win98 当前是单文件（`Windows98ShellView.swift` 内含 palette/bevel/button style）。XP 直接从拆分后的多文件结构起步即可，**不要**回退成一个巨型文件。

## 4. 布局骨架（与 Win98 一一对应）

`WindowsXPShellView.body` 自上而下复制 Win98 的纵向堆叠，逐段换成 XP 样式：

| 区域 | Win98 现状 | XP 对应 | 行为（共享 ViewModel，不变） |
| --- | --- | --- | --- |
| titleBar | navy→蓝渐变 + 灰方三键 | Luna 蓝玻璃渐变 + 红色关闭 + 蓝玻璃最小/最大 | `onMinimize/onZoom/onClose/onSwitchToNative` 闭包 |
| menuBar | File/Edit/View/Go/Help | File/Edit/View/Favorites/Tools/Help | 暂为视觉占位（与 Win98 一致，不做真菜单） |
| toolbar | Back/Forward/Up/Refresh/Dotfiles/Terminal | 同结构，Luna 按钮 | `goBack/goForward/goUp/refresh/toggleHiddenFiles/terminal` |
| addressBar | Address 标签 + 路径框 + Go | 同结构，XP 字段边框 `#7F9DB9` | `updatePathInput/openCurrentPath` |
| sidebar | "Explorer" + 灰列表 | 蓝色任务窗格（白色圆角分组） | `sidebarLocations` + 可访问过滤 + `open(location)` |
| fileList | 灰列头 + navy 选区 | 蓝色 details 列头 + `#316AC5` 选区 | `entries`/`selectEntry`/`open`/单击选中、双击打开 |
| terminal panel | `FinderTerminalPanelView` | 同（可后续包 Luna 外壳） | `panelLayout` |
| statusBar | 灰 + sunken cell | 米色 + 柔和 sunken cell | `entries.count`/选中项/`shellMode.displayName` |

布局常量（`WindowsXPLayout`）：侧栏 task pane 比 Win98 略宽，建议 `sidebarWidth ≈ 200`（XP 任务窗格本身偏宽）；其余沿用 Win98 `Windows98ListColumns` 的自适应列宽逻辑，复制为 `WindowsXPListColumns`。

## 5. 视觉规则（XP Luna —— 详细样式区分）

这是 XP 与 Win98 的核心差异区。**Win98 = 冷灰、硬边、无圆角、方角 3D**；**XP Luna = 暖米色 + Luna 蓝、柔和高光、有圆角、玻璃质感**。

### 5.1 调色板（Luna Blue，hex 为近似值，实现时对参考图微调）

```text
// 控件面（XP 标志性暖灰，区别于 Win98 #C0C0C0 冷灰）
surface          #ECE9D8   // ButtonFace / 工具栏 / 状态栏底
surfaceLight     #F1EFE2   // 高光面
toolbarTop       #FBFBF9   // 工具栏渐变上端
toolbarBottom    #ECE9D8   // 工具栏渐变下端

// 标题栏（Luna 蓝玻璃竖向渐变）
titleActiveTop   #2A8EF4
titleActiveMid   #1E78E6
titleActiveBot   #003FC8
titleGloss       #FFFFFF   // 上沿玻璃高光带（低透明度）
titleText        #FFFFFF

// 任务窗格（蓝色 Explorer 侧栏）
taskPaneTop      #7DA2E3   // 侧栏背景渐变上端
taskPaneBottom   #4F73C3   // 侧栏背景渐变下端
taskPanelFill    #FFFFFF   // 白色圆角任务分组底
taskHeaderText   #0A246A   // 蓝色粗体组头
linkText         #0A246A   // 链接行
linkHover        #1F5BB5

// 选区 / 文本
selection        #316AC5   // 经典 XP 高亮蓝
selectedText     #FFFFFF
text             #000000
contentBg        #FFFFFF

// 控件描边 / bevel（柔和暖灰，区别于 Win98 黑/灰硬边）
fieldBorder      #7F9DB9   // XP 输入框/列表外框标志性蓝灰
buttonBorder     #003C74   // 按钮外圈深蓝
highlight        #FFFFFF   // raised 左上高光
light            #F1EFE2
shadow           #ACA899   // ButtonShadow 暖灰
darkShadow       #716F64

// 标题三键（玻璃按钮）
captionBlue      #3C81F3   // 最小/最大 玻璃蓝
captionBlueGloss #BBD6FF
closeRed         #C75050   // 关闭 红
closeRedGloss    #F3C0C0
```

### 5.2 Bevel（柔和，非 Win98 硬边）

`WindowsXPBevel` 提供三种原语：

- **raised**（按钮、列头、状态栏 cell 凸起）：左/上 `highlight`，右/下 `shadow`（`#ACA899`），最外圈可叠 1px `darkShadow`。比 Win98 更柔，阴影是暖灰不是纯黑。
- **inset / field**（地址栏、列表外框、状态栏 sunken）：外框用单色 `fieldBorder #7F9DB9`（XP 字段就是一圈 1px 蓝灰描边），内侧 1px `highlight`。**不要**照抄 Win98 的双层黑/白凹陷。
- **groove**（任务窗格白色分组外框）：1px `fieldBorder` + 圆角。

所有按钮、输入框、列表外框、状态栏 cell 统一走这套，不得各处手写。

### 5.3 圆角（与 Win98 的关键规则差异）

Win98 文档第 5.4 节"默认无圆角"**不适用于 XP**，XP 显式允许圆角：

```text
captionButtonRadius   3   // 标题三键
buttonRadius          3   // 工具栏/对话按钮
taskPanelRadius       6   // 侧栏白色任务分组
selectionRadius       3   // 图标/选区柔角（details 行可保持直角或 2px）
fieldRadius           0~2 // 输入框轻微圆角
```

标题栏顶部圆角交给 macOS 原生窗口本身（保留原生 `NSWindow`），自绘标题栏背景与之贴合即可，不自接管窗口圆角。

### 5.4 标题栏与三键（最显眼的差异）

- 背景：`titleActiveTop → titleActiveMid → titleActiveBot` 竖向三段渐变，顶部叠一条低透明 `titleGloss` 玻璃高光带。
- 左侧：当前目录标题文字（`workspaceVM.currentDirectoryName`），白色，可加 1px 深蓝投影。
- 右侧：`Native` 切回按钮（Luna 按钮样式）+ 三键。
- 三键画法（区别于 Win98 灰方块）：
  - 最小化 `_`、最大化 `□`：玻璃蓝（`captionBlue` + `captionBlueGloss` 高光），圆角 3px。
  - 关闭 `X`：**红色**（`closeRed` + `closeRedGloss`），圆角 3px，hover 更亮。
  - 动作映射不变：`_ → miniaturize`、`□ → zoom`、`X → performClose`，全部走注入闭包，View 不感知 `NSWindow`。

### 5.5 任务窗格 sidebar（区别于 Win98 灰列表）

- 整体背景：`taskPaneTop → taskPaneBottom` 竖向蓝渐变。
- 分组：白色圆角面板（`taskPanelFill` + `taskPanelRadius` + groove 边框），组头蓝色粗体（`taskHeaderText`）+ 可选展开 chevron。
- 行：`linkText` 蓝色链接风格，hover `linkHover`，图标走 `WindowsXPIconProvider.sidebarIcon`。
- 结构不变：仍是 `workspaceVM.sidebarLocations` → 可访问目录过滤 → `open(location)`。

### 5.6 文件列表（details 视图）

- 列头：浅蓝/米色平面、可点击观感（本期不做真排序，仅样式），底部 1px `fieldBorder`。
- 行选中：`selection #316AC5` 填充 + `selectedText` 白字（Win98 是 navy `#000080`）。
- 列表外框：`field` 风格（`#7F9DB9` 单线），白色内容底。
- 列宽自适应复制 Win98 `Windows98ListColumns` 逻辑。

### 5.7 按钮样式

- `WindowsXPButtonStyle`：面 `surfaceLight → surface` 轻渐变，外圈 `buttonBorder #003C74` 圆角 3px，按下时整体下沉 + 反向渐变。比 Win98 的纯灰凸起更"玻璃"。
- compact 变体用于标题栏 `Native`、地址栏 `Go`。

### 5.8 字体

优先级（XP 时代 = Tahoma）：

1. `Tahoma`，如果系统存在。
2. `Verdana` / `.systemFont(ofSize:)` fallback。

不内置微软原始字体文件。正文 12pt，组头/标题加粗。

### 5.9 图标（`WindowsXPIconProvider`）

- 不直接拷贝微软版权图标；优先自绘矢量近似 / 项目内生成资产。
- 文件夹：XP 玻璃质感的暖黄/米色文件夹（带浅蓝高光），区别于 Win98 扁平黄。
- 普通文件：白纸 + 折角 + 彩色类型条。
- symlink / other：独立 fallback。
- 侧栏入口（桌面/下载/文稿/home/磁盘）：XP 风格彩色小图标，不沿用 SF Symbol。
- 只影响 XP shell，不替换 Native Finder 图标来源。

### 5.10 Win98 ↔ XP 样式对照速查

| 维度 | Windows 98 | Windows XP (Luna) |
| --- | --- | --- |
| 控件面色 | 冷灰 `#C0C0C0` | 暖米 `#ECE9D8` |
| 标题栏 | navy `#000080`→`#1084D0` 实色 | Luna 蓝三段玻璃渐变 + 高光带 |
| 关闭键 | 灰方块 `X` | 红色玻璃圆角 `X` |
| 最小/最大键 | 灰方块 | 蓝色玻璃圆角 |
| 侧栏 | 浅灰列表 | 蓝渐变任务窗格 + 白色圆角分组 |
| 选区色 | navy `#000080` | Luna 蓝 `#316AC5` |
| 字段/外框 | 黑/白双层硬凹陷 | 单线蓝灰 `#7F9DB9` |
| bevel 阴影 | 纯黑/中灰、硬边 | 暖灰 `#ACA899`/`#716F64`、柔和 |
| 圆角 | 无（默认禁止） | 按钮/分组/选区均有圆角 |
| 字体 | MS Sans Serif → Tahoma | Tahoma → 系统 |
| 图标 | 扁平 16/32 pixel | 彩色玻璃 32px 近似 |

## 6. 集成点清单

| 文件 | 改动 | 性质 |
| --- | --- | --- |
| `Views/Finder/Shell/ClientShellMode.swift` | 加 `case windowsXP = "windows-xp"` + `displayName = "Windows XP"` | 扩展 |
| `Views/Finder/FinderWindowController.swift` | `applyShellMode` 加 `.windowsXP` 分支；新增 `makeWindowsXPContentViewController()`、`applyWindowsXPChrome(to:)`；注入 min/zoom/close/switchToNative 闭包 | 扩展 |
| `Views/Finder/FinderToolbarController.swift` | shell 选择器多一项 XP | 扩展 |
| `Views/Finder/FinderMainMenuBuilder.swift` | shell 选择菜单多一项 XP | 扩展 |
| `Views/WindowsXP/WindowsXPShellView.swift` 等 9 个文件 | 新增 XP shell（见第 3 节） | 新增（须纳入 git） |
| `MacOSTests/*` | shell 切换不改 window frame；XP 三键闭包触发；`WindowsXPIconProvider` fallback；`ClientShellMode` raw value 稳定性 | 测试 |

窗口 chrome（`applyWindowsXPChrome`）与 Win98 完全一致：`titleVisibility=.hidden`、`titlebarAppearsTransparent=true`、`toolbar=nil`、隐藏三键、`isMovableByWindowBackground=true`；切回 `.nativeFinder` 时全部恢复。**禁止**为 XP 改窗口初始 size / `setContentSize` / `setFrame` / `center`。

## 7. 分阶段计划

### M0 Shell 接入（XP 立住）

- `ClientShellMode` 加 `.windowsXP`。
- `FinderWindowController` 加 XP 分支 + 工厂 + chrome。
- shell 选择入口（toolbar/menu）加 XP。
- 新建 `WindowsXPShellView` 初版：先用 Luna palette 跑通整套布局（可暂用占位图标）。
- 单测通过：切换不改 frame；shell 选择 raw value 稳定。

### M1 视觉立住（"第一眼是 XP，不是 Win98 也不是 macOS"）

- 标题栏 Luna 蓝玻璃渐变 + 红色关闭 + 蓝玻璃最小/最大，接真实 window action。
- 任务窗格蓝渐变 + 白色圆角分组。
- details 列表 `#316AC5` 选区 + 蓝列头。
- `WindowsXPIconProvider` 替换原生图标（文件夹/文件/symlink/侧栏）。
- 去除原生侧栏 dot 分类，只保留可访问目录。

验收：

- 切到 Windows XP，顶部只见 Luna 蓝标题栏；红色关闭键、蓝色最小/最大键。
- 控件面是暖米色 `#ECE9D8`，不是 Win98 冷灰。
- 侧栏是蓝色任务窗格。
- 文件夹/文件图标不是 macOS 原生图标。
- 应用初始窗口大小不变；切回 Native 完全恢复原生 chrome。

### M2 组件拆分收口

- 确认 `Views/WindowsXP/` 九文件结构成形，palette/bevel/icon 收口。
- 所有新建源码文件纳入 git。

### M3 文件浏览体验补齐

- details 列头、地址栏、状态栏、加载态/错误态打磨。
- 目录双击、文件打开、隐藏文件切换继续共享 ViewModel。

### M4 视觉打磨（可选含脚手架评估）

- 16/32px XP 图标资产精修、玻璃质感细化。
- 终端面板包 Luna bevel 外壳。
- 评估是否把 Win98/XP 公共骨架抽成 `WindowsShellScaffold`（仅在收益明确时做）。

## 8. 测试策略

自动化：

- `ClientShellMode` 默认值与 `.windowsXP` raw value 稳定性。
- shell 在 native / win98 / winxp 之间切换不改变 window frame。
- XP 三键闭包被正确触发（mock/spy）。
- `WindowsXPIconProvider` 对 directory/file/symlink/other 返回非 Native fallback。
- `WindowsXPSidebarItemFilter` 只放行存在且可读的目录。

手动验证：

- 启动默认仍是 Native Finder。
- 切到 XP 后 macOS 标题栏不可见，呈 Luna 观感。
- `Native` 可切回；`_ / □ / X` 行为正确，关闭键为红。
- 多次切换无 toolbar/titlebar 残留；初始窗口大小不变。

## 9. 回滚策略

XP shell 相关代码集中在：

- `Views/WindowsXP/`
- `ClientShellMode.swift` 的 `.windowsXP` case
- `FinderWindowController` 的 XP 分支/工厂/chrome
- toolbar / main menu 的 XP 选择入口

回滚时删除以上即可，不影响 Native Finder 与 Windows 98 shell 的文件浏览、终端、预览和 FFI 业务路径。

## 10. 与旧文档 / 旧架构的关系

本文件早期版本（Route C 混搭：`FinderTheme` token + `FinderThemeProvider` + `usesWindowsChrome` + 重绘原生 `FinderSidebarView` + `NSPathControl` 面包屑）所依赖的主题解耦基建已从 master 移除，**不再作为实现路线**。`THEME_DECOUPLING_DESIGN.md` 与旧版本仅作历史/视觉参考，不指导 XP 实现。XP 的唯一架构基准是 `WIN98_SKIN_DESIGN.md` + 本文件。
