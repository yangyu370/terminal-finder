//
//  SystemFinderTheme.swift
//  MacOS
//
//  Created by Claude on 2026/6/13.
//

import AppKit

/// 默认主题 = 现状：每个槽位直接返回现在使用的语义系统色 / 字号，
/// 保证接入后视觉零变化、系统亮 / 暗模式继续自动生效。
/// 详见 `THEME_DECOUPLING_DESIGN.md` §4.2。
struct SystemFinderTheme: FinderTheme {
    let id = "system"
    let displayName = "系统（默认）"

    var listBackground: NSColor { .controlBackgroundColor }
    var previewBackground: NSColor { .controlBackgroundColor }
    // 注意：gallery inspector 现有实现带 0.88 alpha，迁移该视图时在调用点保留。
    var inspectorBackground: NSColor { .controlBackgroundColor }
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
