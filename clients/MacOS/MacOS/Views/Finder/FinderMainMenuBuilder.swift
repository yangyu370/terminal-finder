//
//  FinderMainMenuBuilder.swift
//  MacOS
//
//  Created by Claude on 2026/6/11.
//

import AppKit

/// Builds the minimal main menu required for Phase 1 keyboard reachability.
/// Targets actions at the `FinderWindowController`, which validates them.
enum FinderMainMenuBuilder {
    static func buildMainMenu(for controller: FinderWindowController) -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(makeAppMenuItem())
        mainMenu.addItem(makeFileMenuItem(for: controller))
        mainMenu.addItem(makeViewMenuItem(for: controller))
        mainMenu.addItem(makeGoMenuItem(for: controller))
        mainMenu.addItem(makeWindowMenuItem())
        return mainMenu
    }

    private static func makeAppMenuItem() -> NSMenuItem {
        let appName = ProcessInfo.processInfo.processName
        let menu = NSMenu(title: appName)

        menu.addItem(
            withTitle: "关于 \(appName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "退出 \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private static func makeFileMenuItem(for controller: FinderWindowController) -> NSMenuItem {
        let menu = NSMenu(title: "文件")

        let open = NSMenuItem(
            title: "打开",
            action: #selector(FinderWindowController.openAction(_:)),
            keyEquivalent: "o"
        )
        open.target = controller
        menu.addItem(open)

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "关闭窗口",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private static func makeViewMenuItem(for controller: FinderWindowController) -> NSMenuItem {
        let menu = NSMenu(title: "显示")

        let hidden = NSMenuItem(
            title: "显示隐藏文件",
            action: #selector(FinderWindowController.toggleHiddenFilesAction(_:)),
            keyEquivalent: "."
        )
        hidden.keyEquivalentModifierMask = [.command, .shift]
        hidden.target = controller
        menu.addItem(hidden)

        let refresh = NSMenuItem(
            title: "刷新",
            action: #selector(FinderWindowController.refreshAction(_:)),
            keyEquivalent: "r"
        )
        refresh.target = controller
        menu.addItem(refresh)

        menu.addItem(.separator())

        let terminal = NSMenuItem(
            title: "显示终端面板",
            action: #selector(FinderWindowController.toggleTerminalPanelAction(_:)),
            keyEquivalent: "j"
        )
        terminal.target = controller
        menu.addItem(terminal)

        let terminalAlternate = NSMenuItem(
            title: "切换终端面板",
            action: #selector(FinderWindowController.toggleTerminalPanelAction(_:)),
            keyEquivalent: "k"
        )
        terminalAlternate.target = controller
        menu.addItem(terminalAlternate)

        menu.addItem(.separator())

        let switchTheme = NSMenuItem(
            title: "切换主题",
            action: #selector(FinderWindowController.switchThemeAction(_:)),
            keyEquivalent: ""
        )
        switchTheme.target = controller
        menu.addItem(switchTheme)

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private static func makeGoMenuItem(for controller: FinderWindowController) -> NSMenuItem {
        let menu = NSMenu(title: "前往")

        let back = NSMenuItem(
            title: "后退",
            action: #selector(FinderWindowController.goBackAction(_:)),
            keyEquivalent: "["
        )
        back.target = controller
        menu.addItem(back)

        let forward = NSMenuItem(
            title: "前进",
            action: #selector(FinderWindowController.goForwardAction(_:)),
            keyEquivalent: "]"
        )
        forward.target = controller
        menu.addItem(forward)

        let up = NSMenuItem(
            title: "上层文件夹",
            action: #selector(FinderWindowController.goUpAction(_:)),
            keyEquivalent: String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!)
        )
        up.keyEquivalentModifierMask = [.command]
        up.target = controller
        menu.addItem(up)

        menu.addItem(.separator())

        let goToFolder = NSMenuItem(
            title: "前往文件夹…",
            action: #selector(FinderWindowController.goToFolderAction(_:)),
            keyEquivalent: "g"
        )
        goToFolder.keyEquivalentModifierMask = [.command, .shift]
        goToFolder.target = controller
        menu.addItem(goToFolder)

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private static func makeWindowMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "窗口")
        menu.addItem(
            withTitle: "最小化",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        NSApp.windowsMenu = menu

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }
}
