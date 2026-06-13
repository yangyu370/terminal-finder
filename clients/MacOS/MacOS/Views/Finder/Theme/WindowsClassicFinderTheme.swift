//
//  WindowsClassicFinderTheme.swift
//  MacOS
//
//  Created by Claude on 2026/6/13.
//

import AppKit

/// 第二套主题：参考 Windows XP / 经典资源管理器观感的固定浅色皮肤。
/// 仅作为「主题可切换」的技术验证（`THEME_DECOUPLING_DESIGN.md` §9 commit 4）。
///
/// 与默认主题不同，这是一套**固定**配色，不随系统亮 / 暗自适应——
/// 经典 Windows 资源管理器本身就是固定浅色外观，这样切换时对比最明显。
struct WindowsClassicFinderTheme: FinderTheme {
    let id = "windows-classic"
    let displayName = "Windows 经典"

    // 经典资源管理器：纯白列表 + 浅灰信息面板
    var listBackground: NSColor { .white }
    var previewBackground: NSColor { .white }
    var inspectorBackground: NSColor { Self.controlGray }
    var tagBackground: NSColor { .white }

    var primaryText: NSColor { .black }
    var secondaryText: NSColor { Self.darkGray }
    var tertiaryText: NSColor { Self.midGray }
    // 选中行：经典蓝底白字
    var selectedText: NSColor { .white }

    // XP "Luna" 选区蓝 ~#316AC5
    var accent: NSColor { Self.lunaBlue }
    var selectionFill: NSColor { Self.lunaBlue }

    // XP 系统字体为 Tahoma；当前系统缺失时回退到系统字体
    var rowFont: NSFont { Self.tahoma(ofSize: 12) }
    var captionFont: NSFont { Self.tahoma(ofSize: 11) }
    var titleFont: NSFont {
        let base = Self.tahoma(ofSize: 12)
        let boldDescriptor = base.fontDescriptor.withSymbolicTraits(.bold)
        return NSFont(descriptor: boldDescriptor, size: 12) ?? .systemFont(ofSize: 12, weight: .semibold)
    }

    private static let lunaBlue = NSColor(srgbRed: 0.192, green: 0.416, blue: 0.773, alpha: 1)
    private static let controlGray = NSColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 1)
    private static let darkGray = NSColor(srgbRed: 0.25, green: 0.25, blue: 0.25, alpha: 1)
    private static let midGray = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)

    private static func tahoma(ofSize size: CGFloat) -> NSFont {
        NSFont(name: "Tahoma", size: size) ?? .systemFont(ofSize: size)
    }
}
