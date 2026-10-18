# Finder 组件像素校准记录

本轮以用户提供的 2306×1362 无损 PNG 为唯一图像基准，2 设备像素/pt。**目前没有达到整窗像素一致**。默认功能回归通过与原生像素门禁通过是两件独立的事；`verify-pixels.sh` 当前会因实际残差返回 2，不设置宽松阈值。

## 基准与测量方式

- 原图 SHA-256、窗口区域和各组件 ROI 固定记录在 `internal/finderui/testdata/finder26-dark/provenance.json`。
- 原图的窗口区域是 `(112,76)-(2194,1214)`，逻辑尺寸 1041×569pt。原图在 `reference/finder-dark-original.png` 中作为用户要求的交接参考，不参与产品 UI 绘制。
- 仅保存公共组件的小块参考：导航、显示模式、搜索、Name 表头、Desktop 图标/文字、空白交替行内部。这些测试裁剪不含用户文件名；交接文档另外保留了用户指定的完整原始截图。
- 提取时按原 ICC 转换到 sRGB，随后丢弃设备 profile，保存原尺寸 RGBA PNG。Go 比较器比较这些解码后的通道值，不自行进行色彩管理。
- 参考 PNG 与 MyGo PNG 不自动缩放、平移、模糊、遮罩或容差过滤。比较器保留 16 位通道差异，只有全部 RGB/alpha 相同才标记 `pixelExact=true`。
- 热图只是误差的分析输出，亮度放大用于观察；判断依据是未修改输入的数值。MAE/RMSE 以 0–255 通道单位表示，不是相似度分数。

## AppKit 职责如何映射到 MyGo

以下是对公共 AppKit 组件职责的映射，并非声称掌握 Finder 的私有类和绘制实现。

| 外观/状态 | 对应公共 AppKit 职责 | MyGo 实现与当前差距 |
|---|---|---|
| 工具栏容器 | NSToolbar / NSWindow titlebar | 52pt 工具栏；原生窗口仅承载窗口按钮/拖动，工具栏内容自绘。动作组保留本产品的刷新/终端/配色功能，与 Finder 功能集合不同。 |
| 导航胶囊 | 分组工具栏按钮 / NSButton 状态 | 36pt 胶囊，左右各34pt按钮，1pt分隔；描边使用 Painter，不参与布局。禁用只叠加一次有效透明度。仍有轮廓抗锯齿/颜色残差。 |
| 显示模式 | NSSegmentedControl 的 normal/selected/disabled | 36×34pt分段，选中底形34×28pt，自有SVG。生产环境分栏/画廊继续禁用；参考图这两项可用，主报告保留此状态差异。窄窗口收起这两项。 |
| 搜索按钮 | NSToolbarItem / 搜索入口 | 共享34×34pt按钮与胶囊，探针和 live 使用同一构造函数；展开后仍为本产品的目录名过滤输入框，未声称与 NSSearchField 全状态相同。 |
| 侧栏面板 | NSVisualEffectView + NSOutlineView | 宽176pt，32pt行，13pt文字，内收边缘；圆角22pt属于拟合值。当前用渐变与描边模拟，未实现背景驱动的动态材质。 |
| 侧栏图标 | outline/sidebar symbol 的视觉职责 | 自有SVG重画 Desktop 窗口轮廓、Documents 折角纸张；不调用 SF Symbols。图标光学中心与真实轮廓仍有残差。 |
| 列表 | NSTableView inset style | 表头区28pt、行高20pt、左右10pt内收、首行顶部5pt。交替行底色#262626/#303030。圆角端点、选中状态尚无独立原生对照通过。 |
| 文字 | NSFont / 文本布局 | 正文与侧栏13pt，表头11pt，标题15pt。表头/侧栏基线按本图上移0.5pt；原生文字的抗锯齿、底层材质、字体选择仍有差异。 |
| 文件图标 | NSWorkspace 文件类型图标职责 | 自绘文件夹/纸张/代码等图标，不读取原生文件图标；与 Finder 的每种应用关联图标并不相同，属于明确未完成项。 |
| 路径与状态栏、终端 | NSPathControl 类路径展示 / 产品自有终端 | 复用现有浏览与真实终端行为。本参考没有这些区域，未据此声称像素校准通过。 |

公共资料：[NSFont](https://developer.apple.com/documentation/appkit/nsfont)、[NSTableView inset](https://developer.apple.com/documentation/appkit/nstableview/style-swift.enum/inset?language=objc)、[rowHeight](https://developer.apple.com/documentation/appkit/nstableview/rowheight?changes=_5_1&language=objc)、[NSVisualEffectView](https://developer.apple.com/documentation/appkit/nsvisualeffectview)。材质会结合背景与外观，静态渐变无法保证在不同壁纸/窗口状态下得到同样像素。

## 当前原始像素结果

| 组件 | RGB MAE | 不同像素 | 完全一致 |
|---|---:|---:|---|
| 导航组 | 1.6229 | 20.37% | 否 |
| 搜索按钮 | 3.5298 | 29.31% | 否 |
| Desktop 图标 | 18.3638 | 20.92% | 否 |
| Desktop 文字及其背景 | 0.7479 | 78.95% | 否 |
| Name 表头 | 1.2547 | 16.95% | 否 |
| 交替行内部取样 | 0.0000 | 0.00% | 是，仅此取样区域 |
| 显示模式组 | 10.8397 | 21.87% | 否，含禁用状态差异 |

文字样本的 MAE 很低而不同像素比例高，说明大量像素仍相差少量通道值，不能把它称为一致。交替行只覆盖200×160px内部背景，不包含文字、圆角端点、滚动条，不代表整张列表一致。

本图只能验证深色、所示选中状态和静止画面。浅色、hover、pressed、inactive、键盘焦点、其他缩放比例、不同背景没有原生基准，均记为未验证。Windows 使用不同平台字体/栅格器；交叉编译通过不能证明 Windows 字体像素等同 macOS。

## 重现

```sh
# Pillow 仅用于提取，不是产品运行依赖。
python3 scripts/extract_finder_reference.py '/path/to/original.png' internal/finderui/testdata/finder26-dark
python3 -m unittest discover -s scripts -p 'test_*.py'
./test.sh
./verify-pixels.sh  # 当前预期返回2：像素门禁尚未通过
```

`dist/pixel-audit/` 包含 candidate、diff/report.json、热图与 comparison.png。产品与探针共用 navigationControl、viewModeControl、searchControl、headerLabel、sidebarLabel 和 glyph；测试不会启用生产环境尚未实现的显示模式来降低误差。

## 下一步需要消除的误差

1. 分离轮廓几何误差与文本/材质误差，继续校准矢量角点、线宽及光学位置；不能通过扩大阈值放行。
2. 为圆角行端点、真实选中行、侧栏选中与整段工具栏增加同状态的原生基准。当前截图中的 Recents、Shared、标签等尚非 MVP 的可用导航能力，不伪造可操作入口。
3. 动态材质、文件类型图标及跨平台字形需要独立方案；若继续限定纯自绘和平台无关，当前实现还不能保证这些部分与 AppKit 在所有场景完全一致。
