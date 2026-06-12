# 文件预览功能设计文档（Finder-like Content Preview）

> 状态：设计稿（待评审，未开始实现）
> 范围：`clients/MacOS/` 客户端 presentation layer
> 关联文档：[THEME_DECOUPLING_DESIGN.md](THEME_DECOUPLING_DESIGN.md)、`clients/MacOS/agent.md`

## 1. 目标与范围

让 Finder 风格窗口在 gallery / column / icon / list 等视图里，显示文件**真实首页内容**的缩略图与大图预览，替代当前一律使用的文件类型通用图标。

对标效果：

- Gallery 中央大图：可滚动、可交互的真实文档渲染（多页 docx / pdf）。
- Gallery filmstrip、Column 小预览、Icon 网格、List 行图标：异步生成的内容缩略图，失败回退到类型图标。

**不在本期范围**：自定义预览插件、预览内编辑、Quick Look 浮层（空格大窗）不实现。

**多端定位**：本功能为 **macOS 专属能力**，基于 Apple QuickLook 实现。其他客户端（Windows / Linux / Web / terminal）**不实现内容预览**，优雅缺省即可。详见 §12。

## 2. 现状

当前 AppKit Finder 视图都用 `NSWorkspace.shared.icon(forFile:)` 取**文件类型图标**（Word 通用图标），不是内容缩略图。接入点：

| 文件 | 行号 | 用途 |
| --- | --- | --- |
| `clients/MacOS/MacOS/Views/Finder/FinderGalleryView.swift` | 315、518 | 中央大图 + filmstrip 小图 |
| `clients/MacOS/MacOS/Views/Finder/FinderColumnView.swift` | 618 | column 行图标 |
| `clients/MacOS/MacOS/Views/Finder/FinderIconGridView.swift` | 269 | icon 网格 |
| `clients/MacOS/MacOS/Views/Finder/FinderListView.swift` | — | list 行图标（live 列表，预览接入点之一） |

> 历史清理（2026-06-12）：旧 SwiftUI 界面栈 `Views/ContentView.swift` 与整个 `Views/Components/`（`DirectoryTableView` / `BackendStatusView` / `PseudoTerminalPanelView` / `TerminalResizeHandle` / `SwiftTermTerminalView`）已删除——它们仅被从未实例化的 `ContentView` 引用，是 AppKit Finder 重构前的遗留 proof-of-flow。预览功能只覆盖上表的 live `Finder*` 视图，不涉及已删除文件。

## 3. 技术栈选型

全部使用 macOS 原生 **QuickLook** 框架，分两套 API 对应两类需求：

| 需求 | API | 框架 | 性质 |
| --- | --- | --- | --- |
| 缩略图（filmstrip / column / icon / list） | `QLThumbnailGenerator` + `QLThumbnailGenerator.Request` | `QuickLookThumbnailing` | 异步生成静态 `NSImage` 位图 |
| 中央大图（gallery 主预览） | `QLPreviewView` | `QuickLook`（`QuickLookUI`） | 实时、可滚动、可交互渲染 |

要点：

- `QLThumbnailGenerator` 最低 macOS 10.15，可指定 `representationTypes`（`.icon` / `.lowQuality` / `.thumbnail`），支持按需要先快后精的两段回调。
- 生成在系统的 out-of-process 扩展中完成，docx / pdf / 图片 / 文本 / 代码等系统已知类型开箱即用。
- `QLPreviewView` 需要一个 `QLPreviewItem`（用文件 `URL` 即可），切换选中项时复用同一个 view、只换 `previewItem`。

> 进程/沙箱前提：客户端与 backend 当前都**未沙箱化**（见 `clients/MacOS/agent.md` 第 12、49 节），QuickLook 读取真实路径无权限障碍。若未来引入 App Sandbox，需重新评估缩略图扩展的文件访问。

## 4. 分层归属（重要）

按 `clients/MacOS/agent.md` 第 10 行，"图标选择、缩略图"明确属于 **presentation transformation**。因此：

- 预览/缩略图渲染**完全在 Swift 客户端**实现，**不进 Rust core**。
- core 只负责给出 `entry.path` 这一事实（已具备），渲染是客户端职责。
- 缩略图逻辑不放进 Views，抽成独立服务，避免四个视图各写一份异步代码（呼应 agent.md 第 125 行"避免跨层捷径"）。

放置位置：`clients/MacOS/MacOS/Services/Thumbnail/`（新增）。归 Services 层（系统集成能力），不持有 backend client、不理解 workspace 业务语义。

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

### 5.2 缓存键

```
key = path + modifiedAt + size + roundedPointSize + scale
```

- `modifiedAt + size`：文件变了就换 key，旧图自然失效，不显示过期内容。
- `pointSize + scale`：不同视图、不同 Retina 倍率各存一份，避免拉伸糊图。
- **不含 theme 维度**：文档位图（docx/pdf 页面）在亮/暗下相同，主题无关（详见 [THEME_DECOUPLING_DESIGN.md](THEME_DECOUPLING_DESIGN.md) 第 5 节）。
- 透明类型（PNG with alpha / SVG / 纯文本）的特判见 §8。

实现用 `NSCache<NSString, NSImage>`（自动内存压力回收）+ 一个并发上限的串行调度，避免滚动时瞬间打满 QuickLook。

### 5.3 视图侧消费模式（cell 复用安全）

每个 cell 持有当前 token，复用前取消：

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

## 6. Gallery 中央大图：QLPreviewView

把 `FinderGalleryView.swift` 中央 `previewArea` 的 `iconView`（`NSImageView`）替换/补充为 `QLPreviewView`：

- 选中项变化时，复用同一个 `QLPreviewView`，只赋值 `previewView.previewItem = url as NSURL`。
- 目录、不可预览类型、无选中：隐藏 `QLPreviewView`，回退到当前 `iconView`（folder symbol 等）。
- 注意生命周期：`QLPreviewView(frame:style:.normal)`，在视图移除时调用 `close()`。
- appearance：见 §8 与主题文档，预览内容跟随 `NSAppearance`。

接入点：`clients/MacOS/MacOS/Views/Finder/FinderGalleryView.swift` 第 216–343 行（`previewArea` / `iconView` 区域）。

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

- **可单测**：`ThumbnailDescriptor` 缓存键的相等/失效逻辑（同路径不同 mtime → 不同 key；同输入 → 同 key）；透明类型判定分支；token 取消后 completion 不回调。
- **难自动化**：QuickLook 实际出图、QLPreviewView 渲染 → 写明手动验证步骤（见 §10）与剩余风险。
- 用 mock `ThumbnailProviding` 验证 cell 在复用 / 快速滚动时的取消与防串图。

## 10. 风险与手动验证

风险：

- 滚动时大量并发请求 → 用并发上限 + cell 取消缓解。
- cell 复用串图 → completion 回调校验 descriptor（§5.3 第 4 步）。
- `QLPreviewView` 生命周期 / 选中抖动 → 复用单实例、只换 `previewItem`、移除时 `close()`。
- 大文件 / 损坏文件生成慢或失败 → 超时 + 回退图标。

手动验证：

1. 打开含 docx / pdf / png / 大图 / 代码文件的目录，切到 gallery，确认中央大图显示真实内容、可滚动。
2. 快速上下滚动 filmstrip / icon 网格，确认无错位串图、无明显卡顿。
3. 切到 column，确认选中文件右侧 / 行内出现内容缩略图。
4. 切系统暗色，确认文档缩略图仍正常（白底文档不应变形），透明 png 背景合理。
5. 选中目录 / 不支持类型，确认回退到类型图标，无崩溃。

## 11. 分阶段实施

```
commit 1  Services/Thumbnail/ThumbnailProvider + 缓存/取消 + 单测
commit 2  filmstrip / column / icon / list 接入缩略图（保留回退）
commit 3  Gallery 中央大图替换为 QLPreviewView
commit 4  透明类型特判 + 手动验证清单过一遍
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

- 预览相关代码（`Services/Thumbnail/`、`QLPreviewView` 接入）天然只存在于 macOS client target，**不进 `core/`、不进 `protocol/`**。
- `ThumbnailProviding` 协议仅为 macOS 内部测试 / 解耦服务，**无需**为"可替换 backend 数据源"预留设计；它就是 QuickLook 的本地封装。
- 未来若某个新端确实要预览，再单独评审，**不被本设计约束**——届时是新决策，不是回填本文档。
