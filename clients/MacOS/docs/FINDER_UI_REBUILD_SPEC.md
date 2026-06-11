# Finder UI Rebuild Spec（v2 全新重做）

本文档是 macOS 客户端 UI 完全重做的唯一执行依据。目标：app 窗口与真实 Finder（macOS 26.x，Liquid Glass）并排截图时质感无法区分。

**约束与前提（必须遵守）：**

- 这是 UI-only 重做：**不得修改** `ViewModels/`、`API/`、`Services/`、`Models/`、`Core/`、Rust backend、protocol。新 UI 100% 复用现有 ViewModel/API 公开接口。
- **禁止打开/参考 v1 UI 代码**：`Views/ContentView.swift`、`Views/Components/` 下所有文件、`docs/FINDER_UI_SPEC.md`。它们将被删除（见 §7）。
- UI 必须跟随系统外观（浅/深色自适应）。**禁止**强制深色、禁止硬编码颜色；一律使用语义色（`NSColor.labelColor`、`controlBackgroundColor`、`alternatingContentBackgroundColors`、`selectedContentBackgroundColor` 等）与系统材质/原生控件默认渲染。本文档中的 RGB 实测值仅用于**验收比对**，不得写进代码。
- 遵守根目录 `agent.md` 与 `clients/MacOS/agent.md` 的全部边界（分层职责、AppKit/SwiftUI 桥接 guard flag、测试门禁等）。

---

## 1. 基准素材

| 文件 | 内容 |
| --- | --- |
| `/tmp/finder-rebuild/finder-reference-home.png` | 真实 Finder 家目录窗口，列表视图，浅色模式，920×620pt（2x PNG 1840×1240px）。**注意：截图时窗口未激活**（traffic lights 灰色、sidebar 图标灰色、标题灰色）。 |
| `/tmp/finder-rebuild/finder-active-selection.png` | 同尺寸**激活**窗口 + 选中行（蓝色高亮）+ 彩色 traffic lights + 蓝色 sidebar 图标。 |

补充截图方法（如开发中需要更多基准）：`osascript -e 'tell application "Finder" to make new Finder window to home'` 配置 view/bounds，`/tmp/finder-rebuild/winid 访达` 取窗口 id（中文系统 Finder owner 名为“访达”），`screencapture -x -o -l<id> out.png`。System Events/Accessibility 不可用。

---

## 2. 实测度量表（单位 pt，由 2x PNG 实测 ÷2）

实现时优先用原生控件的默认值；下表用于选型校准和 §9 验收比对。标注 ≈ 的为视觉估读（±2pt）。

### 2.1 窗口与全局

| 项 | 实测值 | 实现方式 |
| --- | --- | --- |
| 窗口尺寸（默认） | 920 × 620 | `window.setContentSize` / frame autosave |
| 窗口圆角 | ≈30（alpha 渐变到 x=24pt 处全不透明） | 系统自动（macOS 26 NSWindow），不要自绘 |
| Traffic lights | Ø14，首个圆心 (26, 26)，圆心间距 23 | 系统自动（标准窗口按钮） |
| 工具栏区高度 | 52（y 0–52） | `toolbarStyle = .unified` 自动 |
| 底部 | 无状态栏/路径栏，列表直达窗口底边 | 不做底栏 |

### 2.2 侧栏（Liquid Glass）

| 项 | 实测值 |
| --- | --- |
| 侧栏占位宽（列表区起点） | 186 |
| 玻璃面板可见范围 | x ≈10–175（traffic lights 浮在面板内） |
| 行距（相邻条目中心距） | 32（64px） |
| 条目字号 | ≈13pt regular |
| 分组标题（个人收藏/位置/标签） | ≈11pt semibold，tertiary 灰 |
| 选中 pill | x 18–165.5，高 ≈30，圆角 ≈10，浅色下填充 ≈(238,239,239) |
| 图标 | SF Symbols，激活时 accent 蓝色，约 17pt；标签彩点 Ø≈12.5 |

### 2.3 工具栏项（自左向右，激活态）

| 项 | 实测位置/尺寸 |
| --- | --- |
| 玻璃 capsule 高度 | ≈32 |
| 返回/前进 capsule | x ≈185–257.5（紧贴侧栏分界 186） |
| 窗口标题 “mac” | x ≈270 起，≈15pt semibold，labelColor |
| 视图切换 4 段 capsule | x ≈517–662（每段 ≈36 宽；list 段选中态为深一档圆角填充） |
| 分组菜单按钮（图标+下箭头） | x ≈680–725 |
| 分享/标签/更多 共一 capsule | x ≈752–850 |
| 搜索圆钮 | Ø≈36，右缘距窗口右边 ≈8 |

### 2.4 列表（list view）

| 项 | 实测值 |
| --- | --- |
| 行高 | 20（40px），无行间距 |
| 交替行背景 | 白 / (244,245,245)（= `alternatingContentBackgroundColors`） |
| 行背景/选中条横向范围 | 左缘 = 内容区左缘 186，右缘距窗口右边 10（= `NSTableView.style = .inset` 行为） |
| 选中高亮 | systemBlue 填充 ≈(0,100,225)，占满行高 20，圆角 ≈9，文本变白 |
| 列头高度 | ≈28（y 52–79.5），底部 hairline ≈(221) |
| 列头字 | ≈11pt；排序列 semibold + labelColor + 列右端排序 chevron（升序 ^）；其余列 regular secondary |
| 列头纵向分隔线 | 仅列头内，≈(230) hairline |
| 列边界（距窗口左缘） | 名称 186–530（344）、修改日期 530–691（161）、大小 691–788（97）、种类 788–920（132，含 10 右 gutter） |
| 列头/单元文本距列左缘 | ≈10 |
| 名称列内部 | disclosure chevron 距内容左缘 ≈5.5；图标 16×16 距 ≈16.5；文件名距 ≈38；图标-文本间隙 ≈6 |
| outline 每级缩进 | ≈16（实测 15–15.5，取 NSOutlineView 默认 16） |
| 行字体 | 13pt system；名称 labelColor，修改日期/大小/种类 secondaryLabelColor；大小列右对齐；名称/种类中部截断（`…` 在中间） |
| 日期格式（zh-CN） | `2026年6月1日 15:16` / `昨天 16:22`（dateStyle .medium + timeStyle .short + relative） |
| 大小格式 | `82 字节`、`20 KB`（ByteCountFormatter .file）；目录显示 `--` |

---

## 3. 总体架构选型

### 3.1 选定方案：AppKit chrome + SwiftUI 局部（推荐，按此实现）

窗口、工具栏、分栏、文件列表全部用 AppKit 原生控件；侧栏内容与终端面板用 SwiftUI 经 `NSHostingController`/`NSHostingView` 嵌入。

理由：

- macOS 26 上 **`NSToolbar`(unified) + `NSSplitViewController` sidebar item** 是拿到真·Liquid Glass 工具栏 capsule、侧栏玻璃材质、traffic-lights-入-侧栏布局的唯一可完全控制路径。SwiftUI `.toolbar` 在 macOS 26 也有玻璃质感，但 item 分组（返回/前进同一 capsule、分享/标签/更多同一 capsule）、`NSSearchToolbarItem` 圆钮形态、四段 segmented 中单段 disable 的控制粒度不足，像素级对齐困难。
- `clients/MacOS/agent.md` 已定调 `NSTableView` 是目录主列表长期方向；列头排序、交替行、`.inset` 圆角选中条、列宽语义都是 `NSTableView`/`NSOutlineView` 原生免费行为，SwiftUI `Table` 不可定制到这个程度。
- 侧栏**内容**用 SwiftUI `List` + `.listStyle(.sidebar)`：在 macOS 26 它输出与系统 app 一致的 source-list 行高、selection pill、accent 图标，代码量远小于 NSOutlineView source list。外层玻璃材质由 `NSSplitViewItem(sidebarWithViewController:)` 提供，两者不冲突。

### 3.2 备选方案（不采用，留作回退）

| 方案 | 优点 | 否决原因 |
| --- | --- | --- |
| B：纯 SwiftUI `NavigationSplitView` + `.toolbar` + `Table`/Representable | 代码少；自动玻璃 | toolbar item 分组/禁用粒度不够；`Table` 无法做到列头排序箭头/列分隔/inset 选中条像素一致；标题+proxy icon 布局不可控 |
| C：纯 AppKit（侧栏也用 NSOutlineView source list） | 单一技术栈 | 侧栏分组/禁用/彩点行为手写成本高，SwiftUI `List(.sidebar)` 视觉相同且更省；若 B 中 List 行高/缩进与基准偏差 >1pt 再回退到 C |

### 3.3 App 入口与生命周期

- `MacOSApp.swift`（允许修改，不在禁改清单内）：保留 `@main struct MacOSApp: App`，加 `@NSApplicationDelegateAdaptor(FinderAppDelegate.self)`；**删除 `.preferredColorScheme(.dark)` 与 `.windowStyle(.hiddenTitleBar)`**。Scene 只留 `Settings {}`（空）占位，主窗口改由 AppDelegate 创建的 `FinderWindowController` 拥有（SwiftUI WindowGroup 无法精确配置 NSToolbar/NSSplitViewController）。
- `FinderAppDelegate`：`applicationDidFinishLaunching` 创建并 show `FinderWindowController`；构建主菜单（§5.7）；`applicationShouldTerminateAfterLastWindowClosed` 返回 true。
- 所有 ViewModel（`WorkspaceBrowserViewModel`、`BackendConnectionViewModel`、`TerminalSessionViewModel`、`PseudoTerminalPanelLayoutState`）由 `FinderWindowController` 持有并向下注入，生命周期与窗口一致。

---

## 4. 窗口与工具栏

### 4.1 NSWindow 配置（`FinderWindowController`）

```text
styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
toolbarStyle: .unified
titleVisibility: .visible
title: workspaceVM.currentDirectoryName（订阅 @Published path/workspaceState 更新）
representedURL: URL(fileURLWithPath: terminalCwdPath)（仅 proxy icon 展示用，悬停标题出图标，与真实 Finder 行为一致）
toolbar: NSToolbar(identifier: "FinderToolbar")，displayMode .iconOnly，allowsUserCustomization false
contentViewController: FinderSplitViewController
setContentSize(NSSize(width: 920, height: 620))；setFrameAutosaveName("FinderMainWindow")
minSize ≈ (700, 400)
```

不要设置 `titlebarAppearsTransparent` 或自绘 titlebar——unified toolbar + split view sidebar 在 macOS 26 自动产生基准截图的形态（traffic lights 浮在侧栏玻璃内、全高侧栏）。

### 4.2 NSToolbar 项清单（顺序与基准一致）

| identifier | 控件 | 图标 (SF Symbols) | 行为 |
| --- | --- | --- | --- |
| `.toggleSidebar`（系统） | 系统项 | — | 系统折叠侧栏（基准图中隐藏在侧栏内，保留默认即可） |
| `.sidebarTrackingSeparator`（系统） | 系统项 | — | 让后续项落在内容区上方，**必须加**，否则返回/前进不会贴住侧栏分界 |
| `nav.backForward` | `NSToolbarItemGroup`，2 个 subitem | `chevron.left` / `chevron.right` | `vm.goBack()` / `vm.goForward()`；`validate` 绑定 `canGoBack/canGoForward` |
| （窗口标题由系统插入在此处） | — | — | 显示 `currentDirectoryName` |
| `.flexibleSpace` | — | — | — |
| `view.switcher` | `NSToolbarItem` + `NSSegmentedControl`(4 段, `.selectOne`) | `square.grid.2x2` / `list.bullet` / `rectangle.split.3x1` / `play.square.stack`（找不到合适 gallery 符号时用 `squares.below.rectangle`） | 仅第 2 段（列表）选中且可用；其余 3 段 `setEnabled(false, forSegment:)` 占位。切换不触发任何逻辑 |
| `group.menu` | `NSMenuToolbarItem` | `square.grid.3x1.below.line.grid.1x2` | 菜单仅一项“无分组”（checked、disabled 占位） |
| `item.share` | `NSToolbarItem` | `square.and.arrow.up` | disabled 占位（Phase 1 无分享语义） |
| `item.tag` | `NSToolbarItem` | `tag` | disabled 占位 |
| `more.menu` | `NSMenuToolbarItem` | `ellipsis` | 菜单见 §4.3；**这是 Phase 1 行为主要入口** |
| `item.search` | `NSSearchToolbarItem` | — | 视觉占位：`searchField.isEnabled = false`，placeholder “搜索”，toolTip “搜索将在后续阶段提供”（agent.md 禁止实现 search） |

分组细节：`share`/`tag`/`more` 三项相邻时 macOS 26 unified toolbar 自动合并为一个 capsule（基准如此）；如系统未自动合并，把三者放进一个 `NSToolbarItemGroup`。返回/前进必须用 `NSToolbarItemGroup` 才与基准同 capsule。

### 4.3 “更多 (…)” 菜单内容（连接状态展示落点）

```text
[状态区，disabled menu items，实时更新]
  连接状态：{connectionVM.status.title}        ← ConnectionStatus.title
  {connectionVM.detailText}
  {connectionVM.eventStatusText}
─────────────
重新连接            → connectionVM.reconnect()
─────────────
✓ 显示隐藏文件      ⇧⌘.   → workspaceVM.toggleHiddenFiles()（state 跟随 showsHiddenFiles）
刷新               ⌘R    → workspaceVM.refresh()
前往文件夹…        ⇧⌘G   → 打开 §5.5 sheet
```

设计决策：真实 Finder 窗口 chrome 没有任何状态栏，为保像素一致，连接状态（不显示项目数量）收进 … 菜单 + 失败时 `WorkspaceAlertPresenter` 弹窗（ViewModel 已内建）。验收时打开 … 菜单核对状态文本即可。

---

## 5. 区域实现规格

### 5.1 FinderSplitViewController

- `NSSplitViewController`，两个 item：
  - sidebar：`NSSplitViewItem(sidebarWithViewController: NSHostingController(rootView: FinderSidebarView(...)))`，`minimumThickness = 160`，`maximumThickness = 320`，默认 186（对齐实测），`canCollapse = true`。
  - content：`NSSplitViewItem(viewController: NSHostingController(rootView: FinderContentView(...)))`。
- 不要给 sidebar 包 `NSVisualEffectView`——`sidebarWithViewController` 在 macOS 26 自带 Liquid Glass 材质；额外材质会叠灰。

### 5.2 FinderSidebarView（SwiftUI `List` + `.listStyle(.sidebar)`）

结构与基准完全一致（文案简体中文，图标默认 accent 渲染——**不要**手动染蓝，激活/非激活态由系统处理）：

| 分组 | 条目 | SF Symbol | 行为 |
| --- | --- | --- | --- |
| （顶部无标题组） | 最近使用 | `clock` | **disabled 占位**（无 backend 能力；灰显、不可选中） |
| | 共享 | `folder.badge.person.crop` | disabled 占位 |
| 个人收藏 | 桌面 | `menubar.dock.rectangle` | `vm.open(desktopLocation)` |
| | 文稿 | `doc` | `vm.open(documentsLocation)` |
| | 下载 | `arrow.down.circle` | `vm.open(downloadsLocation)` |
| 位置 | iCloud云盘 | `cloud` | disabled 占位 |
| | {home 目录名，如 mac} | `house` | `vm.open(homeLocation)` |
| | 隔空投送 | `wave.3.right.circle`（无更贴近符号时可用 `dot.radiowaves.left.and.right`） | disabled 占位 |
| | 网络 | `globe` | disabled 占位（基准窗口未滚到该项，按本表补齐） |
| | 废纸篓 | `trash` | disabled 占位（不映射 `~/.Trash`，避免引入废纸篓语义） |
| 标签 | 红/橙/黄/绿/蓝/紫/灰色 | `circle.fill` 染 `Color(nsColor: .systemRed)` 等系统色，Ø≈12.5pt | disabled 占位 |

实现要点：

- 路径**只能**来自 `workspaceVM.sidebarLocations`（Home/Desktop/Downloads/Documents 四个真实入口，title 为英文）。新建 `FinderSidebarItem` 展示模型（独立文件，可单测）把四个 location 映射到中文标题/图标/分组；disabled 项不持路径。**不得**在视图里用 `FileManager` 拼路径。
- home 条目标题 = `URL(fileURLWithPath: homeLocation.path).lastPathComponent`（纯展示派生）。
- 选中态：`List(selection:)` 绑定派生值——当 `workspaceState?.currentDirectory == location.path` 时该行选中；点击行调用 `vm.open(location)`，**不在本地先行切换选中**（等 backend state 回来驱动，失败时选中自然回弹，符合 agent.md“客户端不维护目录真相”）。
- disabled 项用 `.selectionDisabled(true)` + `.foregroundStyle(.secondary)`；点击无动作（不弹提示，与真实 Finder 不可用项一致性更好）。
- 分组标题用 `Section("个人收藏")` 等，系统样式即与基准一致；顶部“最近使用/共享”放无标题 Section。

### 5.3 FinderContentView（内容区容器，SwiftUI）

```text
VStack(spacing: 0) {
    FinderListView(...)            // NSViewRepresentable，伸展
    if panelLayout.isOpen {
        FinderTerminalResizeHandle(...)   // 拖拽分割条
        FinderTerminalPanelView(...).frame(height: panelLayout.height)
    }
}
.background(Color(nsColor: .controlBackgroundColor)) // 仅兜底，列表自身有背景
```

- 整个容器外层 `GeometryReader`/`onGeometryChange` 取 `availableContentHeight`，传给 `panelLayout.resize(byVerticalDrag:availableContentHeight:)`，保证目录区 ≥160pt（`minimumDirectoryHeight` 已在 LayoutState 内建）。
- `workspaceVM.fileOpenErrorText` 非 nil 时挂 `.alert`（确定按钮调用 `vm.dismissFileOpenError()`）。
- `errorText` 非 nil 且 listing 为空时，列表区中央显示 secondary 小字错误文案（空态覆盖层）；其余错误路径 ViewModel 已走 `WorkspaceAlertPresenter`。

### 5.4 FinderListView（NSViewRepresentable → NSScrollView + NSOutlineView）

**这是质感核心，逐条照做：**

- `NSOutlineView`，`style = .inset`（产生实测的右 10pt 内缩 + 圆角 ≈9 选中条），`usesAlternatingRowBackgroundColors = true`，`rowHeight = 20`，`intercellSpacing = NSSize(width: 17, height: 0)`（默认值附近，验收时以列文本起点 ≈10pt 校准），`allowsMultipleSelection = false`（Phase 1 单选，与 `selectedEntryPath: String?` 对齐），`autosaveTableColumns = false`。
- `headerView` 保留默认 `NSTableHeaderView`；**不要**自绘列头。
- 4 列（identifier / 标题 / 宽度 / resizing）：
  - `name` “名称”：初始 344，`autoresizingMask = .autoresizingMask`（吃掉窗口缩放差量），minWidth 200
  - `dateModified` “修改日期”：161，user-resizable
  - `size` “大小”：97，右对齐（包括列头），user-resizable
  - `kind` “种类”：122（+10 gutter 由 inset style 提供），user-resizable
- 单元格：`NSTableCellView` 复用（`makeView(withIdentifier:)`）。名称列 = 16×16 `imageView`（`NSWorkspace.shared.icon(forFile: entry.path)`，`icon.size = NSSize(width: 16, height: 16)`；coordinator 内按 path 做 NSCache 短期缓存）+ 13pt `labelColor` 文本，`lineBreakMode = .byTruncatingMiddle`。其余列 13pt `secondaryLabelColor`；种类列同样 `.byTruncatingMiddle`。
- 数据源：`vm.entries`（已按 `showsHiddenFiles` 过滤）。outline 子级用 `vm.loadChildren(path:)` 异步拉取：`isItemExpandable` 对 `entry.isDirectory == true` 返回 true；展开时先插入占位（空数组），Task 拉回后 `reloadItem(_:reloadChildren: true)`；拉取失败折叠该项并交由 ViewModel 既有错误语义（不弹自定义错误）。展开状态是纯 UI 临时状态，目录数据仍 100% 来自 backend。
- 排序（客户端**视觉排序**，agent.md 明确允许）：默认 `name` 升序（与基准列头一致：名称列 semibold + ^）。每列设 `sortDescriptorPrototype`；`sortDescriptorsDidChange` 里用 `FinderListSortComparator`（独立纯函数，可单测）对**展示数组**重排：name 用 `localizedStandardCompare`，date 按解析后时间，size 目录排前/按字节，kind 按本地化种类字符串。不回写 backend，不改 `vm` 状态。
- 交互桥接（严格按 agent.md 桥接规则）：
  - coordinator 持 `isApplyingSelection` guard flag；`updateNSView` 应用 `selectedEntryPath` → row 选中前先比较现选中，无变化不调 `selectRowIndexes`。
  - `outlineViewSelectionDidChange` 在非 guard 期间把选中行的 `entry.path`（或 nil）传 `vm.selectEntry(path:)`。
  - `doubleAction` → 命中行 `vm.open(entry)`（目录→backend 导航；文件→系统打开，VM 内已分流）。
  - 键盘：Return/⌘O/⌘↓ 触发 `vm.openSelectedItemOrCurrentPath()`；⌘↑ `vm.goUp()`（菜单 key equivalent 承担，view 不再截获）。
  - reload 时机：监听 `vm.entries` 标识变化（listing path + entries 数组 + showsHiddenFiles）才 `reloadData`，避免 selection 抖动；reload 后按 `selectedEntryPath` 恢复选中。
- 格式化（`FinderListFormatters.swift`，纯展示，独立可单测）：
  - 日期：`modifiedAt: String?` 先按 ISO8601（带/不带小数秒两个 formatter）解析；成功 → `DateFormatter`（`dateStyle = .medium`，`timeStyle = .short`，`doesRelativeDateFormatting = true`，locale/timeZone 跟随系统）输出（zh-CN 下即 `2026年6月1日 15:16` / `昨天 16:22`）；解析失败或 nil → `--`。
  - 大小：`entry.isDirectory` → `--`；否则 `ByteCountFormatter`（`countStyle = .file`，跟随系统语言 → `82 字节` / `20 KB`）；size nil → `--`。
  - 种类：目录 → `UTType.folder.localizedDescription`（zh “文件夹”）；文件按扩展名 `UTType(filenameExtension:)?.localizedDescription`，取不到 → “文稿”；symlink → “替身”。这是展示文本，不是产品事实，不回传 backend。

### 5.5 前往文件夹 sheet（路径输入入口，⇧⌘G）

- `FinderGoToFolderSheet`：SwiftUI sheet（挂在 FinderContentView），样式仿 Finder：标题“前往文件夹”，一个大圆角 `TextField`（默认填 `vm.terminalCwdPath`，全选），Return 提交、Esc 取消。
- 提交：`vm.updatePathInput(text)` → `vm.openCurrentPath()`，然后关 sheet。相对路径/`~`/文件路径/非法路径的全部语义已在 ViewModel（相对路径基于当前目录解析、文件走系统打开、失败走 alert + 刷新），UI 不做任何路径判断。

### 5.6 终端面板（⌘K，窗口内伪终端）

复用既有 API，不引入新状态：

- `PseudoTerminalPanelLayoutState`：开/关/高度/viewport（默认高 184，min 120，max 420，目录区最少 160——常量已内建）。
- `FinderTerminalResizeHandle`：新写的细分割条（高 ~5pt，`onHover` 出 `resizeUpDown` 光标），`DragGesture` 把 `translation.height` 增量传 `panelLayout.resize(byVerticalDrag:availableContentHeight:)`。
- `FinderTerminalPanelView`：顶条（左侧 `terminal.cwd ?? vm.terminalCwdPath` 的 13pt secondary 文本 + 右上角关闭按钮 `xmark.circle.fill`）+ `FinderTerminalSurfaceView`。背景用 `Color(nsColor: .textBackgroundColor)` + 顶部 hairline `Divider()`，不抢 Finder 主体视觉。
- `FinderTerminalSurfaceView`：`NSViewRepresentable` 包 SwiftTerm `TerminalView`（SPM 依赖已在工程）。职责：
  - 实现 `TerminalRendering`（`write(_:)` feed 字节、`reset()` 清屏）并 `session.attachRenderer(self_coordinator)`。
  - 用户键入 → `session.sendInput(bytes)`（`TerminalViewDelegate.send`）。
  - 尺寸变化 → `panelLayout.noteViewportSize(size)`（debounce 已内建 60ms）；`panelLayout.onViewportResize` 闭包里换算 `cols = floor(width / cellWidth)`、`rows = floor(height / cellHeight)`（cell 尺寸取 SwiftTerm 字体度量，字体 `NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)`）→ `session.resize(cols:rows:)`（VM 内再 50ms 合并）。**只上报合并后的 cols/rows，不传像素细节**。
  - 不解析终端输出、不存 session 事实（agent.md 边界）。
- 生命周期接线（`FinderWindowController` 或 ContentView 一处完成）：
  - ⌘K：面板关→ `panelLayout.open()` + `session.start(cwd: vm.terminalCwdPath, cols:, rows:)`；面板开→ 关闭按钮同路径。
  - 关闭按钮：`session.close()`（发 terminal.close）；`session.onSessionEnded = { panelLayout.close() }`（协议收尾后才收 UI，agent.md 要求）。
  - `session.status == .error` 时面板内显示 `errorText`（13pt secondary）+“关闭”按钮走同样 close 流程。
  - 主窗口尺寸不变：面板空间由列表让出（§5.3 VStack 已保证）。

### 5.7 主菜单（FinderMainMenuBuilder，AppDelegate 装配）

最小集（保证快捷键可达 + 验收）：

```text
App 菜单: 关于/退出（默认）
文件:   打开 ⌘O → openSelectedItemOrCurrentPath；关闭窗口 ⌘W
显示:   ✓显示隐藏文件 ⇧⌘. ；刷新 ⌘R ；显示/隐藏终端面板 ⌘K
前往:   后退 ⌘[ ；前进 ⌘] ；上层文件夹 ⌘↑ ；前往文件夹… ⇧⌘G
窗口:   最小化 ⌘M（默认）
```

`validateMenuItem` 绑定 `canGoBack/canGoForward/canGoUp/canOpen`、`showsHiddenFiles`（菜单勾选态）、`panelLayout.isOpen`（⌘K 文案切换）。

---

## 6. Phase 1 受保护行为 → 新 UI 入口映射（能力一项不丢）

| 行为 | 新入口 | 调用 |
| --- | --- | --- |
| 隐藏文件切换 | …菜单 / 显示菜单 ⇧⌘. | `toggleHiddenFiles()` |
| 后退/前进 | toolbar capsule / ⌘[ ⌘] | `goBack()` `goForward()` |
| 上级目录 | 前往菜单 ⌘↑ | `goUp()` |
| 路径输入 | ⇧⌘G 前往文件夹 sheet | `updatePathInput` + `openCurrentPath()` |
| 刷新 | …菜单 / ⌘R | `refresh()` |
| 双击打开目录/文件 | 列表 doubleAction / ⌘O / Return | `open(entry)` / `openSelectedItemOrCurrentPath()` |
| 选中 | 列表单击 | `selectEntry(path:)` |
| 子目录展开 | outline disclosure | `loadChildren(path:)` |
| 连接状态展示（无项目数量） | …菜单状态区 + 重新连接 | `status/detailText/eventStatusText` / `reconnect()` |
| ⌘K 伪终端面板（拖拽高度/viewport 测量/关闭） | §5.6 | `PseudoTerminalPanelLayoutState` + `TerminalSessionViewModel` 全量既有 API |
| 无效目录弹窗 | 自动（VM 内置 `WorkspaceAlertPresenter`） | 不需 UI 代码，但不得拦截 |
| 启动流程 | 窗口出现时 | `connectionVM.connect()` + `workspaceVM.loadInitialState()` |
| 文件打开失败提示 | ContentView `.alert` | `fileOpenErrorText` / `dismissFileOpenError()` |

---

## 7. 文件落点

### 7.1 删除（v1 全部移除，同一 commit 内完成替换）

```text
clients/MacOS/MacOS/Views/ContentView.swift
clients/MacOS/MacOS/Views/Components/BackendStatusView.swift
clients/MacOS/MacOS/Views/Components/DirectoryTableView.swift
clients/MacOS/MacOS/Views/Components/PseudoTerminalPanelView.swift
clients/MacOS/MacOS/Views/Components/SwiftTermTerminalView.swift
clients/MacOS/MacOS/Views/Components/TerminalResizeHandle.swift
clients/MacOS/docs/FINDER_UI_SPEC.md
```

### 7.2 新增（全部放 `clients/MacOS/MacOS/Views/Finder/`，命名避开 v1 心智）

| 文件 | 内容 |
| --- | --- |
| `FinderAppDelegate.swift` | NSApplicationDelegate；创建 WindowController；装配主菜单 |
| `FinderMainMenuBuilder.swift` | §5.7 菜单 |
| `FinderWindowController.swift` | NSWindow/NSToolbar 配置；ViewModel 持有与注入；标题/representedURL 订阅 |
| `FinderToolbarController.swift` | NSToolbarDelegate + 全部 item（§4.2/§4.3）+ validation |
| `FinderSplitViewController.swift` | §5.1 |
| `FinderSidebarView.swift` | §5.2 SwiftUI 侧栏 |
| `FinderSidebarItem.swift` | 侧栏展示模型 + sidebarLocations 映射（可单测） |
| `FinderContentView.swift` | §5.3 容器 + sheet/alert 挂载 |
| `FinderListView.swift` | §5.4 NSOutlineView representable + coordinator |
| `FinderListFormatters.swift` | 日期/大小/种类格式化（可单测） |
| `FinderListSortComparator.swift` | 视觉排序比较器（可单测） |
| `FinderGoToFolderSheet.swift` | §5.5 |
| `FinderTerminalPanelView.swift` | §5.6 面板 chrome |
| `FinderTerminalResizeHandle.swift` | 拖拽分割条 |
| `FinderTerminalSurfaceView.swift` | SwiftTerm 桥 + TerminalRendering |

修改：`MacOS/MacOSApp.swift`（§3.3，删强制深色与 hiddenTitleBar）。

### 7.3 Xcode 工程注册结论（已核实）

`MacOS.xcodeproj/project.pbxproj` 为 `objectVersion = 77`，`MacOS/` 与 `MacOSTests/` 均为 **`PBXFileSystemSynchronizedRootGroup`（文件系统同步组）**：新增/删除 `.swift` 文件**无需手动登记 pbxproj**，放进目录即入 target。注意：v1 文件物理删除即可；新增目录 `Views/Finder/` 自动同步。SwiftTerm 为既有 `XCRemoteSwiftPackageReference`，无需改动。所有新文件必须出现在 `git status` 并纳入提交（agent.md 要求）。

---

## 8. 测试计划（agent.md 测试门禁）

既有测试不得回归：`WorkspaceBrowserViewModelTests`、`BackendConnectionViewModelTests`、`PseudoTerminalPanelLayoutStateTests`、`TerminalSessionViewModelTests`、`TerminalClientTests`（ViewModels/API 未动，应全绿）。

新增（`clients/MacOS/MacOSTests/`，文件系统同步组自动入 test target）：

| 文件 | 覆盖 |
| --- | --- |
| `FinderListFormattersTests.swift` | ISO8601 两种精度解析、nil/坏字符串 → `--`；目录/`size==nil` → `--`；字节/KB 量级；种类映射（folder/md/txt/无扩展名/symlink）；relative 日期开关存在性（用固定 locale 注入测试，产品代码默认跟随系统） |
| `FinderSidebarItemTests.swift` | 四个可用项 path 来自 `sidebarLocations`；disabled 项无 path 不可选中；home 标题取 lastPathComponent；分组归属正确 |
| `FinderListSortComparatorTests.swift` | name localizedStandardCompare、date/size 排序、nil 值兜底、升降序反转 |

UI chrome（toolbar/玻璃材质）无法自动化的部分：在交付说明中写手动验证步骤（§9 截图比对）+ 剩余风险，符合 agent.md 例外条款。

构建/测试命令（仓库根目录执行）：

```sh
xcodebuild test -project clients/MacOS/MacOS.xcodeproj \
  -scheme MacOS \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .derivedData/codex-tests \
  CODE_SIGNING_ALLOWED=NO
```

App 截图核对方法：启动 app 后用 `/tmp/finder-rebuild/winid <app名>` + `screencapture -x -o -l<id>`（Accessibility 不可用，勿走 osascript UI scripting）。

---

## 9. §验收（逐条截图核对 checklist）

与 `/tmp/finder-rebuild/finder-reference-home.png`、`finder-active-selection.png` 并排比对（app 窗口同设 920×620、浅色模式、家目录、列表视图）。每条 ±1pt 内视为通过；标 ≈ 的 ±2pt。

**窗口/工具栏**
- [ ] 窗口 920×620，系统大圆角（≈30pt），无自绘 titlebar，无底部状态栏/路径栏
- [ ] traffic lights 浮在侧栏玻璃面板内，激活时红黄绿、非激活灰色（系统行为，不得自绘）
- [ ] 工具栏区高 52pt，Liquid Glass capsule 质感（与真实 Finder 同屏对比无平涂感）
- [ ] 返回/前进共处一个 capsule，紧贴侧栏分界（x≈185），不可用时变灰（首屏两者都灰）
- [ ] 标题显示当前目录名（家目录显示用户名，如 “mac”），≈15pt semibold；悬停标题出现 proxy icon
- [ ] 视图切换为 4 段 segmented capsule，仅“列表”段选中可用，其余 3 段灰显占位
- [ ] 依次出现：分组菜单钮（带下箭头）、分享、标签、更多(…) 共 capsule、最右搜索圆钮（Ø≈36，右距 ≈8）
- [ ] 搜索框禁用占位，placeholder “搜索”
- [ ] … 菜单含连接状态三行文本 + 重新连接 + 显示隐藏文件(勾选态) + 刷新 + 前往文件夹…；**任何位置都不显示项目数量**

**侧栏**
- [ ] 结构与顺序：最近使用、共享 ／ 个人收藏：桌面、文稿、下载 ／ 位置：iCloud云盘、{home}、隔空投送、网络、废纸篓 ／ 标签：红橙黄绿蓝紫灰彩点
- [ ] 默认宽 186pt；行距 ≈32pt；条目 13pt；分组标题 11pt 灰
- [ ] 激活窗口下图标为 accent 蓝（系统渲染），彩点用系统 tag 色
- [ ] 当前目录命中侧栏项时该项出灰 pill 选中（圆角 ≈10，左右 inset ≈9）；进入无关目录时无选中
- [ ] 点击桌面/文稿/下载/{home} 实际导航（数据来自 backend）；最近使用/共享/iCloud云盘/隔空投送/网络/废纸篓/标签灰显不可选

**列表**
- [ ] 4 列：名称 / 修改日期 / 大小 / 种类；初始宽 ≈344/161/97/132；名称列随窗口伸缩
- [ ] 列头高 ≈28pt、11pt 字；默认按名称升序：“名称” semibold + 列右端 ^ 箭头；点其他列头可视觉重排并迁移箭头
- [ ] 列头列间有 hairline 竖线，列头底部 hairline 横线；行区无竖线
- [ ] 行高 20pt；交替行背景（白/浅灰，跟随系统 `alternatingContentBackgroundColors`）；行背景右侧内缩 10pt
- [ ] 选中行：accent 蓝圆角条（半径 ≈9，占满行高），行内全部文本变白；非激活窗口选中条变灰（系统行为）
- [ ] 名称列：disclosure 箭头（仅目录）→ 16pt 真实文件图标（NSWorkspace，文件夹为系统蓝色文件夹图标）→ 13pt 文件名；展开子级缩进 16pt/级
- [ ] 修改日期/大小/种类 13pt secondary 灰；大小列右对齐；目录大小 `--`
- [ ] zh-CN 下日期 `2026年6月1日 15:16`、昨天显示 `昨天 16:22`；大小 `82 字节`/`20 KB`；种类 `文件夹`/`JSON`/`Markdown 文本文件`（超宽中部截断 `Markdo…本文件`）
- [ ] 浅/深色切换（系统设置）即时正确，无硬编码颜色残留

**行为（能力回归）**
- [ ] 双击目录进入、双击文件系统打开；⌘O/Return 等效
- [ ] ⌘[ ⌘] ⌘↑ 导航且菜单/工具栏 enable 状态正确；新导航清前进栈（点按验证）
- [ ] ⇧⌘G sheet：支持绝对/相对/`~` 路径与文件路径；无效路径弹 NSAlert（含 Reason/Next Step 面板）且当前目录不变、列表已刷新
- [ ] ⇧⌘. 切换隐藏文件，菜单勾选态同步
- [ ] ⌘K 打开窗口内终端面板：窗口尺寸不变、列表让位；拖分割条 120–420pt 内调高且目录区 ≥160pt；关闭按钮发 close、会话收尾后面板收起；面板内可输入输出（echo 验证）；拖窗口大小触发合并后的 resize（无高频抖动）
- [ ] 断开 core/事件超时出现 alert 与 … 菜单状态文本变化；重新连接可恢复
- [ ] `xcodebuild test` 全绿（含新格式化/侧栏/排序测试与全部既有测试）

---

## 10. 实现顺序建议

1. `MacOSApp.swift` + AppDelegate + WindowController + SplitViewController 骨架（空内容跑起来，先核窗口/工具栏/侧栏玻璃形态）
2. Toolbar 全部 item + … 菜单 + 主菜单（接 ViewModel action）
3. FinderListView（列/格式化/排序/选中/双击/展开）→ 第一次并排截图校准度量
4. 侧栏内容 + 选中映射
5. ⇧⌘G sheet、隐藏文件、刷新、错误 alert 链路
6. 终端面板三件套（⌘K 全链路）
7. 删除 v1 文件 + 新测试 + `xcodebuild test` + §9 全量验收截图

---

## 11. 已知坑（开发前必读）

1. **不要手绘 chrome**：玻璃材质、选中 pill、行选中圆角、窗口圆角全部来自系统控件默认行为（`sidebarWithViewController`、`NSTableView.style = .inset`、unified toolbar）。任何 `NSVisualEffectView` 叠加、自定义背景色都会在并排对比中露馅，且破坏深色模式。
2. **`.sidebarTrackingSeparator` 必须存在**，否则返回/前进 capsule 不会停靠在侧栏分界处，标题也不会对齐基准位置。
3. **NSOutlineView selection 回环**：`updateNSView` 应用选中/reload 时必须用 `isApplyingSelection` guard，且先 diff 再 `selectRowIndexes`，否则 SwiftUI ↔ AppKit 互触发刷新抖动（agent.md 桥接规则）。
4. **异步展开竞态**：`loadChildren` 返回时用户可能已折叠/导航走；apply 前核对仍处于同一 listing path，否则丢弃结果。
5. **基准截图是非激活窗口**：比对配色（traffic lights、侧栏图标灰）时以 `finder-active-selection.png` 为激活态基准，勿照非激活图把图标做成灰色。
6. **终端 resize 只传 cols/rows**：viewport 像素 → `noteViewportSize`（已 debounce）→ 换算 cols/rows → `session.resize`；不要把 SwiftUI layout 抖动直接打到 session（VM 内还有 50ms 合并，链路勿短路）。
7. **测试门禁**：本次有生产代码变更，必须带 §8 新测试且既有测试全绿后才可提交；新文件全部入 git（文件系统同步组不等于免提交）。
