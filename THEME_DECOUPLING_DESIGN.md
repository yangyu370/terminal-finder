# 主题解耦设计文档（Theme Decoupling & Switching）

> 状态：设计稿（待评审，未开始实现）
> 范围：`clients/MacOS/` 客户端 presentation layer
> 关联文档：[PREVIEW_FEATURE_DESIGN.md](PREVIEW_FEATURE_DESIGN.md)、`clients/MacOS/agent.md`

## 1. 目标与范围

把目前散落在各视图里的颜色 / 字体硬编码收口成一套可切换的 **Theme token**，让 app 外壳（sidebar、toolbar、列表、选中态、预览 chrome）能在运行时切换主题，且：

- **默认主题 = 现状**，接入后视觉零变化；
- 系统亮 / 暗模式继续自动工作；
- 切换主题不需要重启、不残留旧颜色。

**不在本期范围**：让 QuickLook 预览**内容**渲染成任意品牌色（系统只认 `NSAppearance` 的 aqua / darkAqua，无法做任意自定义内容底色，详见 §5）。

**与预览功能的关系**：两者无依赖、可分别回滚。推荐**先预览、后主题**——预览是产品价值且独立，主题是工程基建（理由见 [PREVIEW_FEATURE_DESIGN.md](PREVIEW_FEATURE_DESIGN.md) §11）。

## 2. 现状诊断

**好消息**：代码几乎全部使用**语义系统色**（`.controlBackgroundColor`、`.labelColor`、`.secondaryLabelColor`、`.tertiaryLabelColor`、`.controlAccentColor`、`.alternateSelectedControlTextColor` 等），所以**系统亮 / 暗模式已自动生效**，这层无需改造。

**挡路的四件事**：

1. **无任何 theme 抽象**（全项目 grep `theme/palette/tokens` 零命中）。颜色 / 字体是字面量，铺在约 8 个文件里。
2. **字体硬编码重复**：`.systemFont(ofSize: 13)` 在 7 处各写一遍，`.systemFont(ofSize: 12)` 同理。改字号要全项目扫。
3. **CGColor 陷阱（最隐蔽）**：以下 3 处用 `layer?.backgroundColor = NSColor.X.cgColor`，`cgColor` 在赋值瞬间解析死，appearance 变化**不会自动更新**：
   - `clients/MacOS/MacOS/Views/Finder/FinderColumnView.swift:460`
   - `clients/MacOS/MacOS/Views/Finder/FinderGalleryView.swift:331`
   - `clients/MacOS/MacOS/Views/Finder/FinderGalleryView.swift:358`
4. **AppKit cell 缓存颜色**：cell 的 `textColor` / `backgroundColor` 在配置时写进子控件，主题切换后**必须显式重刷**（重设 + `reloadData`），不会自己变。

`Metrics` 已集中在 enum（`FinderDisplayMode.swift:77`、`FinderColumnView.swift:11`、`FinderGalleryView.swift:11` 等）——这是颜色 / 字体该学的样板。

## 3. 颜色 / 字体调用点清单

| 文件 | 颜色 / 字体相关行 |
| --- | --- |
| `Views/Finder/FinderListView.swift` | 44、60–61、386、388、417、420、456–480 |
| `Views/Finder/FinderColumnView.swift` | 284、460、464–465、546–547、588–589、601–610、625–636、675–687 |
| `Views/Finder/FinderGalleryView.swift` | 331、334–335、358、373–376、393–396、412–413、444–452、479、491、518、548 |
| `Views/Finder/FinderIconGridView.swift` | 52–53、222、237、296 |
| `Views/Finder/FinderTerminalView.swift` | 22–25（终端配色，独立处理） |
| `Views/Finder/FinderSidebarView.swift` | 76、86（SwiftUI 字体） |
| `Views/Finder/FinderContentView.swift` | 186、190、194、224（SwiftUI 字体） |

> 终端配色（`FinderTerminalView.swift:22–25`）建议作为独立的 terminal theme 槽位，不与文件浏览主题混用。

> 历史清理（2026-06-12）：旧 SwiftUI 界面栈 `Views/ContentView.swift` 与整个 `Views/Components/` 已删除，故不再出现在上表中。主题解耦只覆盖 live 的 `Finder*` 视图。

## 4. Token 层设计

### 4.1 FinderTheme（语义槽位）

```swift
import AppKit

/// 一套主题的全部语义槽位。所有视图只读这里，不再出现颜色 / 字体字面量。
protocol FinderTheme {
    // 背景
    var listBackground: NSColor { get }       // 列表 / column / icon 滚动区底色
    var previewBackground: NSColor { get }     // gallery 中央预览区
    var inspectorBackground: NSColor { get }   // gallery 右侧信息面板
    var tagBackground: NSColor { get }         // 标签输入框底

    // 文字
    var primaryText: NSColor { get }           // 主文件名
    var secondaryText: NSColor { get }         // 副信息 / kind
    var tertiaryText: NSColor { get }          // 占位 / chevron / 更弱
    var selectedText: NSColor { get }          // 选中行文字

    // 强调
    var accent: NSColor { get }                // controlAccent 对应
    var selectionFill: NSColor { get }         // icon / gallery 选中底色填充

    // 字体
    var rowFont: NSFont { get }                // 13pt 行文字
    var captionFont: NSFont { get }            // 12pt 副文字
    var titleFont: NSFont { get }              // 13pt semibold 标题
}
```

### 4.2 SystemFinderTheme（默认主题 = 现状）

每个槽位直接 return 现在用的系统色 / 字号，保证接入零视觉变化、系统亮暗照常：

```swift
struct SystemFinderTheme: FinderTheme {
    var listBackground: NSColor { .controlBackgroundColor }
    var previewBackground: NSColor { .controlBackgroundColor }
    var inspectorBackground: NSColor { .controlBackgroundColor } // 注意：现有 358 行带 0.88 alpha，迁移时保留
    var tagBackground: NSColor { .textBackgroundColor }
    var primaryText: NSColor { .labelColor }
    var secondaryText: NSColor { .secondaryLabelColor }
    var tertiaryText: NSColor { .tertiaryLabelColor }
    var selectedText: NSColor { .alternateSelectedControlTextColor }
    var accent: NSColor { .controlAccentColor }
    var selectionFill: NSColor { .controlAccentColor }
    var rowFont: NSFont { .systemFont(ofSize: 13) }
    var captionFont: NSFont { .systemFont(ofSize: 12) }
    var titleFont: NSFont { .systemFont(ofSize: 13, weight: .semibold) }
}
```

### 4.3 ThemeProvider（单一可观察源 + 切换 + 广播）

```swift
import AppKit
import Combine

final class FinderThemeProvider: ObservableObject {
    @Published private(set) var current: FinderTheme

    static let didChange = Notification.Name("FinderThemeDidChange")

    init(theme: FinderTheme = SystemFinderTheme()) { self.current = theme }

    func apply(_ theme: FinderTheme) {
        current = theme
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
```

- SwiftUI 侧（sidebar / content）用 `@EnvironmentObject` 注入，自动重渲染。
- AppKit 侧订阅 `didChange` 通知，重设缓存颜色 + `reloadData`。
- 该 provider 也是未来"app 主题 → `NSAppearance` 映射"和"缩略图透明类型缓存维度"的收口点（与 `ThumbnailProvider` 平级，见预览文档 §5.2）。

## 5. 缓存维度：为什么不按主题分桶

缩略图缓存的是**文档位图**，docx / pdf 页面白底，**亮 / 暗下相同**——真实 Finder 暗色模式下 docx 缩略图也是白纸。随主题变的是缩略图**周围**的 chrome（预览区底色、选中高亮、文字色），而这些是 AppKit 视图**实时绘制**的，没烤进位图。

因此缩略图缓存键**默认不含 theme 维度**（见 [PREVIEW_FEATURE_DESIGN.md](PREVIEW_FEATURE_DESIGN.md) §5.2），只有透明 / 无固定底色类型需特判（预览文档 §8）。这降低了主题切换对预览的影响：切主题只重画 chrome，位图直接复用。

**概念澄清**：QuickLook 渲染**内容**只认系统 `NSAppearance`（aqua / darkAqua），不认自定义品牌色。所以"主题"分两层：

- **App 外壳主题**（本文档处理）：sidebar / toolbar / 列表 / 选中色，自由定义；
- **预览内容主题**：只能通过给预览视图设 `NSAppearance` 影响亮 / 暗，无法做任意品牌色。

## 6. 改造步骤

### ① 建 token 层（新文件，纯 presentation）

```
clients/MacOS/MacOS/Views/Finder/Theme/
  FinderTheme.swift          // 协议 + 槽位定义
  FinderThemeProvider.swift  // current + apply + 广播
  SystemFinderTheme.swift    // 默认主题：映射回现有系统色 / 字体（零视觉变化）
```

### ② 机械替换字面量 → token

按 §3 清单逐文件把 `.controlBackgroundColor` → `theme.listBackground`、`.systemFont(ofSize:13)` → `theme.rowFont` 等。每处都有现成行号，逐文件提交、逐文件人工核对。

**此步为纯重构、低风险、应独立成 commit**，完成后视觉零变化、测试全过。

### ③ 修两类刷新机制（决定"能不能随时切"）

- **CGColor 三处**（`FinderColumnView.swift:460`、`FinderGalleryView.swift:331`、`:358`）：改成在 `updateLayer()` / `viewDidChangeEffectiveAppearance()` 里重新 `theme.X.cgColor`，而不是一次性赋值。
- **AppKit 视图订阅广播**：收到 `FinderThemeProvider.didChange` → 重设缓存颜色 + `reloadData`。注意 selection 重刷不要触发抖动 / 循环（`clients/MacOS/agent.md` 第 112–113 行专门警告 `NSTableView` selection loop，重刷前先比较再设）。

**此步为高风险点，单独成 commit，便于回滚。**

## 7. 测试要求

按 `clients/MacOS/agent.md` 第 129 行：

- **可单测**：`FinderThemeProvider.apply` 后 `current` 更新且发出 `didChange`；`SystemFinderTheme` 各槽位映射正确（锁定"默认 = 现状"）。
- **难自动化**：实际视觉刷新 / CGColor 重解析 / selection 不抖动 → 写明手动验证步骤与剩余风险。
- selection 相关改动须验证：点击选中、清空、reload 后保留选中、双击进目录均无循环刷新 / 选中抖动（agent.md 验证建议倒数第 2 条）。

## 8. 风险

- **CGColor 漏刷**：第 ③ 步若漏处理某处 layer，会出现切主题后局部底色不变。→ 以 §3 清单逐项核对。
- **selection 重刷抖动 / 循环**：AppKit reload 与 selection 回调互相触发。→ 重设前先比较、用 guard flag 屏蔽 programmatic 回调（agent.md 第 112 行）。
- **遗漏字面量**：机械替换漏掉某处 → 替换完再跑一次 §3 的 grep 收尾确认零残留。
- **终端配色混用**：勿把 `FinderTerminalView.swift:22–25` 并入文件浏览主题，单独槽位处理。

## 9. 分阶段实施

```
commit 1  Theme/ token 层 + SystemFinderTheme（默认主题，零视觉变化）+ provider 单测
commit 2  §3 清单机械替换字面量 → token（纯重构，逐文件核对，视觉零变化）
─────────  以上可独立交付：结构已解耦，仍是单一系统主题 ──────────
commit 3  CGColor 三处改为动态重解析 + AppKit 订阅广播 + selection 防抖
commit 4  接入第二套主题 + 切换入口（菜单 / 设置）+ 手动验证清单
```

新增文件须纳入 git（agent.md 第 122 行）。建议本工作在预览功能落地之后进行（见 §1）。
