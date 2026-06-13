//
//  FinderTheme.swift
//  MacOS
//
//  Created by Claude on 2026/6/13.
//

import AppKit

/// 一套主题的全部语义槽位。所有 Finder 视图只读这里的 token，
/// 不再出现颜色 / 字体字面量。详见 `THEME_DECOUPLING_DESIGN.md` §4.1。
///
/// 默认主题（`SystemFinderTheme`）把每个槽位映射回现有系统色 / 字号，
/// 接入后视觉零变化、系统亮 / 暗模式照常工作；其它主题可提供固定皮肤。
protocol FinderTheme {
    /// 稳定标识，用于切换轮换、持久化与测试断言。
    var id: String { get }
    /// 切换入口展示用的人类可读名称。
    var displayName: String { get }

    // MARK: 背景
    /// 列表 / column / icon 滚动区底色。
    var listBackground: NSColor { get }
    /// gallery 中央预览区底色。
    var previewBackground: NSColor { get }
    /// gallery 右侧信息面板底色。
    var inspectorBackground: NSColor { get }
    /// 标签输入框底色。
    var tagBackground: NSColor { get }

    // MARK: 文字
    /// 主文件名。
    var primaryText: NSColor { get }
    /// 副信息 / kind。
    var secondaryText: NSColor { get }
    /// 占位 / chevron / 更弱。
    var tertiaryText: NSColor { get }
    /// 选中行文字。
    var selectedText: NSColor { get }

    // MARK: 强调
    /// controlAccent 对应。
    var accent: NSColor { get }
    /// icon / gallery 选中底色填充。
    var selectionFill: NSColor { get }

    // MARK: 字体
    /// 13pt 行文字。
    var rowFont: NSFont { get }
    /// 12pt 副文字。
    var captionFont: NSFont { get }
    /// 13pt semibold 标题。
    var titleFont: NSFont { get }
}
