//
//  FinderThemeProvider.swift
//  MacOS
//
//  Created by Claude on 2026/6/13.
//

import AppKit
import Combine

/// 主题的单一可观察源：持有当前主题、切换并广播。
///
/// - SwiftUI 侧（sidebar / content）用 `@EnvironmentObject` 注入，`current`
///   变化时自动重渲染。
/// - AppKit 侧订阅 `didChange` 通知，收到后重设缓存颜色 + `reloadData`。
///
/// 详见 `THEME_DECOUPLING_DESIGN.md` §4.3 / §6③。
@MainActor
final class FinderThemeProvider: ObservableObject {
    /// AppKit 视图据此重刷缓存颜色 + reloadData 的广播。
    static let didChange = Notification.Name("FinderThemeDidChange")

    /// 可切换的全部主题；切换入口按此顺序轮换。
    let available: [FinderTheme]

    @Published private(set) var current: FinderTheme

    init(
        available: [FinderTheme] = [SystemFinderTheme(), WindowsClassicFinderTheme()],
        initial: FinderTheme? = nil
    ) {
        precondition(!available.isEmpty, "FinderThemeProvider 至少需要一套主题")
        self.available = available
        self.current = initial ?? available[0]
    }

    /// 应用指定主题：更新 `current`（驱动 SwiftUI）并广播（驱动 AppKit）。
    /// 同一套主题重复 apply 也会广播，便于强制重刷。
    func apply(_ theme: FinderTheme) {
        current = theme
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// 轮换到下一套主题（顶部导航栏切换按钮 / 菜单项使用）。
    func cycle() {
        let index = available.firstIndex { $0.id == current.id } ?? -1
        let next = available[(index + 1) % available.count]
        apply(next)
    }
}
