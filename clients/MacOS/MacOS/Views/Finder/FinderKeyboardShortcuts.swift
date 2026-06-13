//
//  FinderKeyboardShortcuts.swift
//  MacOS
//
//  Created by Claude on 2026/6/13.
//

import AppKit

/// 集中定义客户端自有键盘快捷键的匹配规则，便于单测。
///
/// 为什么不只靠主菜单 key equivalent：菜单的 `performKeyEquivalent:` 会在
/// 窗口视图层的 `performKeyEquivalent:` **之后**才被尝试。当 SwiftTerm 终端是
/// first responder 时，Command+J 可能被其先吞掉，导致菜单永远收不到事件、
/// 面板「有概率」切不出来。`FinderWindowController` 用窗口级 local key monitor
/// 在事件下发到响应链之前按此规则判定，从而让 Command+J / Command+K 始终生效。
enum FinderKeyboardShortcuts {
    /// 切换终端面板：Command+J 或 Command+K，且不带其它修饰键。
    /// - Parameters:
    ///   - characters: 建议传入 `NSEvent.charactersIgnoringModifiers`。
    ///   - modifierFlags: 事件的修饰键集合（会自动忽略设备无关的杂项位）。
    static func isToggleTerminalPanel(
        characters: String?,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        let relevant: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        guard modifierFlags.intersection(relevant) == .command else {
            return false
        }
        guard let key = characters?.lowercased() else {
            return false
        }
        return key == "j" || key == "k"
    }

    static func isToggleTerminalPanel(_ event: NSEvent) -> Bool {
        isToggleTerminalPanel(
            characters: event.charactersIgnoringModifiers,
            modifierFlags: event.modifierFlags
        )
    }
}
