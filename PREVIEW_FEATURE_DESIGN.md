# 文件预览功能设计文档（Finder-like Content Preview）

> 状态：实施规格（2026-06-13 已补齐技术细节，可按阶段实现）
> 范围：`clients/MacOS/` 客户端 presentation layer
> 关联文档：[THEME_DECOUPLING_DESIGN.md](THEME_DECOUPLING_DESIGN.md)、`clients/MacOS/agent.md`

## 1. 目标与范围

让 Finder 风格窗口在 gallery / column 视图里，显示文件**真实首页内容**的大图预览，替代当前一律使用的文件类型通用图标。

对标效果：

- Gallery 中央大图：真实首页内容的大图预览，必须按比例完整适配预览窗口，不允许裁掉首页边缘。
- Column 右侧预览栏：只在选中文件后的 preview 槽位显示真实首页内容和元信息；左侧各 column 文件列表行只显示类型图标，不生成内容缩略图，以降低滚动卡顿。
- Gallery filmstrip、Icon 网格、List 行图标：本期保持类型图标，不生成内容缩略图。未来如要扩展再单独评审缓存和性能预算。

**不在本期范围**：自定义预览插件、预览内编辑、Quick Look 浮层（空格大窗）不实现。

**多端定位**：本功能为 **macOS 专属能力**，基于 Apple QuickLook 实现。其他客户端（Windows / Linux / Web / terminal）**不实现内容预览**，优雅缺省即可。详见 §12。

## 2. 现状

当前 AppKit Finder 视图都用 `NSWorkspace.shared.icon(forFile:)` 取**文件类型图标**（Word 通用图标），不是内容缩略图。接入点：

| 文件 | 行号 | 用途 |
| --- | --- | --- |
| `clients/MacOS/MacOS/Views/Finder/FinderGalleryView.swift` | 315、518 | 中央大图 + filmstrip 小图 |
| `clients/MacOS/MacOS/Views/Finder/FinderColumnView.swift` | 618 | column 行图标；右侧预览槽位尚未实现 |
| `clients/MacOS/MacOS/Views/Finder/FinderIconGridView.swift` | 269 | icon 网格 |
| `clients/MacOS/MacOS/Views/Finder/FinderListView.swift` | — | list 行图标（live 列表，预览接入点之一） |

> 历史清理（2026-06-12）：旧 SwiftUI 界面栈 `Views/ContentView.swift` 与整个 `Views/Components/`（`DirectoryTableView` / `BackendStatusView` / `PseudoTerminalPanelView` / `TerminalResizeHandle` / `SwiftTermTerminalView`）已删除——它们仅被从未实例化的 `ContentView` 引用，是 AppKit Finder 重构前的遗留 proof-of-flow。预览功能只覆盖上表的 live `Finder*` 视图，不涉及已删除文件。

## 3. 技术栈选型

全部使用 macOS 原生 **QuickLook** 框架，但本期固定槽位预览优先使用 `QLThumbnailGenerator` 生成“首页完整适配”的静态位图，而不是把可滚动 `QLPreviewView` 嵌进小槽位。这样能精确控制 aspect-fit，避免截图中标注的“预览窗口无法显示完整内容”问题。

| 需求 | API | 框架 | 性质 |
| --- | --- | --- | --- |
| 大槽位首页预览（gallery 中央 / column 右侧） | `QLThumbnailGenerator` + `QLThumbnailGenerator.Request` | `QuickLookThumbnailing` | 异步生成静态 `NSImage` 位图，视图用 `.scaleProportionallyUpOrDown` 完整适配 |
| 未来交互预览（非本期） | `QLPreviewView` | `QuickLook`（`QuickLookUI`） | 可滚动、可交互渲染，适合独立大面板或 Quick Look 浮层 |

要点：

- `QLThumbnailGenerator` 最低 macOS 10.15，可指定 `representationTypes`（`.icon` / `.lowQualityThumbnail` / `.thumbnail`）。本期固定槽位请求 `.thumbnail`，失败再回退类型图标；不在列表行请求内容 thumbnail。
- 本机 Xcode `MacOSX26.5.sdk` 头文件确认旧 `QuickLook/QLThumbnail` C API 已弃用，应使用 `QuickLookThumbnailing/QLThumbnailGenerator`。
- `QLThumbnailGenerator.Request(fileAt:size:scale:representationTypes:)` 的 `size` 是目标 point 尺寸，`scale` 应使用窗口 `backingScaleFactor`。对 gallery / column 预览栏按槽位实际尺寸发起请求。
- 生成请求用 `generateBestRepresentation(for:completion:)` 获取最具代表性的单张图，回调完成后主线程设置 `NSImage`。
- 生成在系统的 out-of-process 扩展中完成，docx / pdf / 图片 / 文本 / 代码等系统已知类型开箱即用。
- `QLPreviewView` 的 `previewItem` 是异步加载；`close()` 后该 view 不再接受新 item。若未来使用，只能在 view 生命周期结束时 close，不能在每次切换选中项时 close。

> 进程/沙箱前提：客户端与 backend 当前都**未沙箱化**（见 `clients/MacOS/agent.md` 第 12、49 节），QuickLook 读取真实路径无权限障碍。若未来引入 App Sandbox，需重新评估缩略图扩展的文件访问。

## 4. 分层归属（重要）

按 `clients/MacOS/agent.md` 第 10 行，"图标选择、缩略图"明确属于 **presentation transformation**。因此：

- 预览/缩略图渲染**完全在 Swift 客户端**实现，**不进 Rust core**。
- core 只负责给出 `entry.path` 这一事实（已具备），渲染是客户端职责。
- 缩略图逻辑不放进 Views，抽成独立服务，避免四个视图各写一份异步代码（呼应 agent.md 第 125 行"避免跨层捷径"）。

放置位置：`clients/MacOS/MacOS/Services/Thumbnail/`（新增）。归 Services 层（系统集成能力），不持有 backend client、不理解 workspace 业务语义。

视图共享一个默认服务实例，避免 gallery / column 各自打满 QuickLook：

```swift
enum ThumbnailProviders {
    static let shared: ThumbnailProviding = QuickLookThumbnailProvider()
}
```

## 5. 接口设计

### 5.1 ThumbnailProvider（缩略图服务）

```swift
import AppKit

/// 缩略图请求的取消句柄。视图在 cell 复用 / 滚动时调用 cancel。
protocol ThumbnailRequestToken: AnyObject {
    func cancel()
}

/// 缩略图生成服务。Services 层，单例或随窗口注入。
protocol ThumbnailProviding: AnyObject {
    /// 同步返回缓存命中的缩略图；未命中返回 nil（调用方应先显示回退图标）。
    func cachedThumbnail(for descriptor: ThumbnailDescriptor) -> NSImage?

    /// 异步请求缩略图。completion 在主线程回调。
    /// - 命中缓存时也可能同步在当前 runloop 之后回调，调用方不要假设同步。
    /// - 返回的 token 用于在 cell 复用时取消。
    @discardableResult
    func thumbnail(
        for descriptor: ThumbnailDescriptor,
        completion: @escaping (NSImage?) -> Void
    ) -> ThumbnailRequestToken
}

/// 描述一次缩略图请求的全部输入。也是缓存键的来源。
struct ThumbnailDescriptor: Hashable {
    let path: String
    let modifiedAt: String?   // 来自 DirectoryEntry.modifiedAt，用于缓存失效
    let size: UInt64?         // 来自 DirectoryEntry.size，辅助失效判断
    let pointSize: CGSize     // 目标像素尺寸（按视图区分：filmstrip / column / icon / 大图）
    let scale: CGFloat        // 屏幕 backingScaleFactor

    init(entry: DirectoryEntry, pointSize: CGSize, scale: CGFloat) {
        self.path = entry.path
        self.modifiedAt = entry.modifiedAt
        self.size = entry.size
        self.pointSize = pointSize
        self.scale = scale
    }
}
```

实际实现新增一个轻量用途维度，避免 column 小槽位和 gallery 大槽位误复用错误尺寸：

```swift
enum ThumbnailPurpose: String, Hashable {
    case galleryPreview
    case columnPreview
}
```

`ThumbnailDescriptor` 最终字段为 `path / modifiedAt / size / pointSize / scale / purpose`。目录不请求内容 preview，调用方直接显示文件夹图标。

### 5.2 缓存键

```
key = path + modifiedAt + size + roundedPointSize + scale + purpose
```

- `modifiedAt + size`：文件变了就换 key，旧图自然失效，不显示过期内容。
- `pointSize + scale + purpose`：不同视图、不同 Retina 倍率各存一份，避免拉伸糊图或误复用。
- **不含 theme 维度**：文档位图（docx/pdf 页面）在亮/暗下相同，主题无关（详见 [THEME_DECOUPLING_DESIGN.md](THEME_DECOUPLING_DESIGN.md) 第 5 节）。
- 透明类型（PNG with alpha / SVG / 纯文本）的特判见 §8。

实现用 `NSCache<NSString, NSImage>`（自动内存压力回收）+ 轻量并发门控，避免快速切换选择时瞬间打满 QuickLook。建议同时缓存进行中的请求：相同 descriptor 的多个 caller 共享同一个 QuickLook request，完成后分发回调。

### 5.3 视图侧消费模式（复用 / 快速切换安全）

每个预览槽位或未来 cell 持有当前 token，复用 / 切换前取消：

```swift
final class XxxCell: NSCollectionViewItem /* 或 NSView */ {
    private var thumbnailToken: ThumbnailRequestToken?

    func configure(with entry: DirectoryEntry, provider: ThumbnailProviding) {
        thumbnailToken?.cancel()                 // 1) 取消上一次
        imageView.image = fallbackIcon(for: entry) // 2) 先放回退图标，永远有东西显示

        let desc = ThumbnailDescriptor(entry: entry, pointSize: target, scale: window?.backingScaleFactor ?? 2)
        if let cached = provider.cachedThumbnail(for: desc) {
            imageView.image = cached             // 3a) 命中缓存，直接用
            return
        }
        let requested = desc
        thumbnailToken = provider.thumbnail(for: desc) { [weak self] image in
            guard let self, let image else { return }
            // 4) 回调时校验 cell 仍指向同一文件，防止复用串图
            guard self.currentDescriptor == requested else { return }
            self.imageView.image = image
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailToken?.cancel()
        thumbnailToken = nil
    }
}
```

回退链：**加载中 / 失败 / 不支持 → `NSWorkspace.shared.icon(forFile:)`**（保留现有调用作为兜底）。

本期只有 gallery 中央预览和 column 右侧预览栏调用该服务。Column 的 `FinderColumnItemCell`、Gallery filmstrip、Icon grid、List row 继续只用 `NSWorkspace.shared.icon(forFile:)`。

## 6. Gallery 中央大图：完整首页 preview

把 `FinderGalleryView.swift` 中央 `previewArea` 的 `iconView`（`NSImageView`）升级为可显示 QuickLook 首页位图的大预览：

- 选中普通文件：先显示类型图标，再请求 `ThumbnailPurpose.galleryPreview`，请求尺寸取 `previewArea.bounds.insetBy(dx: 32, dy: 28)` 后的可用尺寸，最小不低于 `160x120`。
- `NSImageView.imageScaling = .scaleProportionallyUpOrDown`，并用 `FinderPreviewImageLayout.aspectFitRect(imageSize:container:maximumScale:)` 计算 frame，确保首页完整内容在窗口内可见，不裁切。
- 选中目录、不可预览类型、无选中、生成失败：回退到当前类型图标居中展示。
- 选中变化 / resize 后重新计算大图 frame；若尺寸变化超过 16pt，再发起新 descriptor 请求，避免每次 layout 抖动都重新生成。
- appearance：见 §8 与主题文档，预览位图用固定中性底合成，避免亮暗主题缓存混用后观感突变。

接入点：`clients/MacOS/MacOS/Views/Finder/FinderGalleryView.swift` 第 216–343 行（`previewArea` / `iconView` 区域）。

## 6.1 Column 右侧预览栏

Column 视图需要仿 Finder 分栏右侧 preview pane：

- 左侧各 column 仍是固定宽度列表，行高 / 16px 类型图标保持不变，不生成内容 thumbnail。
- 当选中目录：行为保持现状，继续追加下一列子目录，不显示 preview pane。
- 当选中文件：在最后一个列表 column 后追加一个 preview pane。preview pane 是固定槽位而不是 table row，包含：
  - 顶部大图：`ThumbnailPurpose.columnPreview` 的首页完整适配图，失败时显示类型图标。
  - 标题：文件 display name，13-14pt semibold，长文件名 middle truncation。
  - 副标题：kind + size。
  - 信息区：修改时间、大小；未来可补创建时间/标签，但本期不伪造 backend 未提供的事实。
  - 底部“更多...”占位，匹配当前 gallery inspector 风格。
- Layout 自适应：
  - `FinderColumnDocumentView` 中 column 总宽 = `columns.count * columnWidth + previewPaneWidthIfNeeded`。
  - `previewPaneWidth = max(FinderColumnMetrics.previewMinWidth, visibleWidth - columnsWidth)`，同时 `min(previewMaxWidth, ...)` 只作为舒适上限；若窗口很宽，preview pane 应占满剩余空间，不留空白。
  - 若 columns 已经超过可视宽度，preview pane 宽度使用 `previewMinWidth`，横向滚动到末尾时可见。
  - preview pane 高度始终等于 documentView 高度，内部顶部图随宽高重排，不能因为内容尺寸撑大/压缩主布局。
- 预览栏只依赖 `DirectoryEntry`，不触发 backend list/open；路径事实仍来自 ViewModel/core。

## 7. Core / 协议改动

**推荐方案（QuickLook）：core 与协议零改动。** 现有 `DirectoryEntry` 已提供渲染所需的 `path / modifiedAt / size`（见 `core/src/workspace/dto.rs:44`、`protocol/README.md` entries 字段）。

### 可选增强（非本期，需先动协议再动 core）

仅当未来要让 **backend 驱动"是否可预览 / 内容类型"** 这类**产品事实**时才做，按 agent.md 第 74 行"代表产品事实的字段应先加到 backend/protocol"：

| 字段 | 位置 | 用途 | 必要性 |
| --- | --- | --- | --- |
| `uti` / `contentType` | `DirectoryEntry` | 客户端据此决定预览策略、特判透明类型 | 可选；客户端也能用 `UTType(filenameExtension:)` 自行推断 |
| `previewable: bool` | `DirectoryEntry` | backend 统一判定可预览性 | 不推荐；可预览性是渲染层能力，宜留在客户端 |

若真要加，改动链：`core/src/workspace/dto.rs`（`DirectoryEntry`）→ `core/src/ffi/dto.rs`（`DirectoryEntryDto`）→ 重新生成 UniFFI → `protocol/README.md` entries 表 → Swift `RpcModels.swift:127` `DirectoryEntry`。

**结论：本期不动 core，纯客户端实现。**

## 8. 透明 / 无固定底色类型的特判

文档（docx/pdf）页面白底，主题无关。但以下类型 QuickLook 会合成到亮/暗背景，位图会随 appearance 变：

- 透明 PNG / 带 alpha 图标、SVG、纯文本 / 代码文件。

处理：

1. **统一渲染到固定中性底**：这类缩略图用固定底色合成，缓存键不动。最省事。

判断类型用 `UTType`（`conforms(to: .image)` 且含 alpha / `.svg` / `.plainText` / `.sourceCode`）。该判断收口在 `ThumbnailProvider` 内部，视图不感知。

## 9. 测试要求

按 `clients/MacOS/agent.md` 第 129 行，生产代码须配套 `MacOSTests`：

- **必须单测**：
  - `ThumbnailDescriptor` 缓存键的相等/失效逻辑（同路径不同 mtime → 不同 key；同输入 → 同 key；不同 purpose / pointSize / scale → 不同 key）。
  - `ThumbnailRequestToken.cancel()` 后 completion 不再回调；相同 descriptor 的请求共享结果时，取消单个 token 不影响其他 caller。
  - `FinderPreviewImageLayout.aspectFitRect`：横图 / 竖图 / 正方图 / 空尺寸都完整落在 container 内，不裁切、不产生 NaN。
  - `FinderColumnMetrics`：preview min width 与 column width 的关系固定，列表行 icon size 仍为 16。
- **可用 mock 服务测试**：
  - Gallery 中央预览切换文件时取消旧 token，旧回调不会串到新文件。
  - Column 选中文件时 document width 包含 preview pane；选中目录时不显示 preview pane、继续加载下一列。
- **难自动化**：QuickLook 实际出图、系统预览扩展质量 → 写明手动验证步骤（见 §10）与剩余风险。
- 测试 agent 只运行并评审本次新增/修改的测试样例；仓库中既有、与本功能无关的旧测试失败不得作为本次功能阻塞，但要在报告中标出。

## 10. 风险与手动验证

风险：

- 滚动时大量并发请求 → 用并发上限 + cell 取消缓解。
- cell 复用串图 → completion 回调校验 descriptor（§5.3 第 4 步）。
- 选中抖动 / 旧回调串图 → descriptor 校验 + token 取消 + 相同 descriptor 请求合并。
- 大文件 / 损坏文件生成慢或失败 → 超时 + 回退图标。

手动验证：

1. 打开含 pdf / png 或 jpg / 代码文件的目录，切到 gallery，确认中央大图显示真实首页内容且完整适配窗口。
2. 快速切换 gallery 选中项，确认旧预览不会串图，失败时回退类型图标。
3. 切到 column，选中普通文件，确认右侧 preview pane 显示首页完整内容；左侧列表行只显示 16px 类型图标。
4. 在 column 中选中目录，确认仍追加下一列子目录，不显示文件 preview pane。
5. 缩放窗口宽度，确认 column preview pane 占满剩余空间；当列很多时横向滚动到末尾能看到最小宽度 preview pane。
6. 选中未知扩展或损坏/不可预览文件，确认回退到类型图标，无崩溃。
7. 切系统暗色，确认文档缩略图仍正常，透明 png 背景合理。

## 11. 分阶段实施

```
commit 1  文档补齐：明确 gallery / column 本期范围、QuickLook API 约束、测试验收标准
commit 2  Services/Thumbnail/ThumbnailProvider + 布局 helper + 缓存/取消 + 单测
commit 3  Gallery 中央大图接入首页完整 preview（保留类型图标回退）+ 测试
commit 4  Column 右侧 preview pane + 自适应剩余空间布局 + 测试
commit 5  透明类型固定底合成 / 未知类型回退 + 手动验证清单过一遍
```

新增文件须纳入 git（agent.md 第 122 行）。预览功能与主题解耦相互独立，可先于主题落地（见 [THEME_DECOUPLING_DESIGN.md](THEME_DECOUPLING_DESIGN.md) §1 节奏说明）。

## 12. 多端兼容立场（明确决策）

QuickLook（`QLThumbnailGenerator` / `QLPreviewView`）是 Apple 独占框架，仅 macOS / iOS 可用。各端能力如下：

| 客户端 | QuickLook | 内容预览 |
| --- | --- | --- |
| macOS | ✅ | 实现（本文档） |
| Windows / Linux / Web / terminal | ❌ | **不实现，优雅缺省** |

**决策**：内容预览定性为 macOS 平台专属能力，**不做跨端缩略图抽象，不引入协议级 / core 级缩略图生成能力**。其他端不展示内容预览，回退到文件类型图标（或各自平台的等价类型图标）即可。

**理由**：

- 跨端缩略图（backend/core 生成位图下发）会把"缩略图生成"从 presentation 上升为共享产品能力，违背 `clients/MacOS/agent.md` 第 10 行"缩略图属 presentation、留客户端"的定位，且为一个非核心体验引入 core/protocol 复杂度，不划算。
- Web / headless / terminal 本就难以承载真实文档渲染体验，强行对齐收益低。

**这给实现带来的约束（简化项）**：

- 预览相关代码（`Services/Thumbnail/`、gallery / column 预览栏接入）天然只存在于 macOS client target，**不进 `core/`、不进 `protocol/`**。
- `ThumbnailProviding` 协议仅为 macOS 内部测试 / 解耦服务，**无需**为"可替换 backend 数据源"预留设计；它就是 QuickLook 的本地封装。
- 未来若某个新端确实要预览，再单独评审，**不被本设计约束**——届时是新决策，不是回填本文档。
