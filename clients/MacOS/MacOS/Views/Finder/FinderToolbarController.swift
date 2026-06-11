//
//  FinderToolbarController.swift
//  MacOS
//
//  Created by Claude on 2026/6/11.
//

import AppKit
import Combine

extension NSToolbarItem.Identifier {
    static let finderNavBackForward = NSToolbarItem.Identifier("nav.backForward")
    static let finderNavBack = NSToolbarItem.Identifier("nav.back")
    static let finderNavForward = NSToolbarItem.Identifier("nav.forward")
    static let finderViewSwitcher = NSToolbarItem.Identifier("view.switcher")
    static let finderGroupMenu = NSToolbarItem.Identifier("group.menu")
    static let finderShare = NSToolbarItem.Identifier("item.share")
    static let finderTag = NSToolbarItem.Identifier("item.tag")
    static let finderTerminal = NSToolbarItem.Identifier("item.terminal")
    static let finderMoreMenu = NSToolbarItem.Identifier("more.menu")
    static let finderSearch = NSToolbarItem.Identifier("item.search")
}

/// NSToolbarDelegate building the Finder-style unified toolbar
/// (back/forward capsule, view switcher, group menu, share/tag/more, search).
final class FinderToolbarController: NSObject {
    private let workspaceVM: WorkspaceBrowserViewModel
    private let connectionVM: BackendConnectionViewModel
    private weak var actionTarget: FinderWindowController?

    private weak var backItem: NSToolbarItem?
    private weak var forwardItem: NSToolbarItem?
    private var moreMenu: NSMenu?
    private var cancellables: Set<AnyCancellable> = []

    init(
        workspaceVM: WorkspaceBrowserViewModel,
        connectionVM: BackendConnectionViewModel,
        actionTarget: FinderWindowController
    ) {
        self.workspaceVM = workspaceVM
        self.connectionVM = connectionVM
        self.actionTarget = actionTarget
        super.init()

        workspaceVM.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshNavigationItemStates()
            }
            .store(in: &cancellables)
    }

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "FinderToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    private func refreshNavigationItemStates() {
        backItem?.isEnabled = workspaceVM.canGoBack
        forwardItem?.isEnabled = workspaceVM.canGoForward
    }

    private static func symbolImage(_ names: [String], description: String) -> NSImage? {
        for name in names {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: description) {
                return image
            }
        }

        return nil
    }
}

// MARK: - NSToolbarDelegate

extension FinderToolbarController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar,
            .sidebarTrackingSeparator,
            .finderNavBackForward,
            .flexibleSpace,
            .finderViewSwitcher,
            .finderGroupMenu,
            .finderShare,
            .finderTag,
            .finderTerminal,
            .finderMoreMenu,
            .finderSearch
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .finderNavBackForward:
            return makeBackForwardItem()
        case .finderViewSwitcher:
            return makeViewSwitcherItem()
        case .finderGroupMenu:
            return makeGroupMenuItem()
        case .finderShare:
            return makeDisabledImageItem(
                identifier: .finderShare,
                symbolNames: ["square.and.arrow.up"],
                label: "分享"
            )
        case .finderTag:
            return makeDisabledImageItem(
                identifier: .finderTag,
                symbolNames: ["tag"],
                label: "标签"
            )
        case .finderTerminal:
            return makeTerminalItem()
        case .finderMoreMenu:
            return makeMoreMenuItem()
        case .finderSearch:
            return makeSearchItem()
        default:
            return nil
        }
    }

    // MARK: Item builders

    private func makeBackForwardItem() -> NSToolbarItem {
        let back = NSToolbarItem(itemIdentifier: .finderNavBack)
        back.image = Self.symbolImage(["chevron.left"], description: "后退")
        back.label = "后退"
        back.toolTip = "后退"
        back.isBordered = true
        back.autovalidates = false
        back.target = actionTarget
        back.action = #selector(FinderWindowController.goBackAction(_:))

        let forward = NSToolbarItem(itemIdentifier: .finderNavForward)
        forward.image = Self.symbolImage(["chevron.right"], description: "前进")
        forward.label = "前进"
        forward.toolTip = "前进"
        forward.isBordered = true
        forward.autovalidates = false
        forward.target = actionTarget
        forward.action = #selector(FinderWindowController.goForwardAction(_:))

        let group = NSToolbarItemGroup(itemIdentifier: .finderNavBackForward)
        group.subitems = [back, forward]
        group.label = "后退/前进"
        group.isNavigational = true

        backItem = back
        forwardItem = forward
        refreshNavigationItemStates()
        return group
    }

    private func makeViewSwitcherItem() -> NSToolbarItem {
        let symbolNames: [[String]] = [
            ["square.grid.2x2"],
            ["list.bullet"],
            ["rectangle.split.3x1"],
            ["play.square.stack", "squares.below.rectangle"]
        ]

        let control = NSSegmentedControl()
        control.segmentCount = symbolNames.count
        control.trackingMode = .selectOne
        control.segmentStyle = .automatic
        for (index, names) in symbolNames.enumerated() {
            control.setImage(Self.symbolImage(names, description: "显示方式"), forSegment: index)
            control.setEnabled(index == 1, forSegment: index)
        }
        control.selectedSegment = 1

        let item = NSToolbarItem(itemIdentifier: .finderViewSwitcher)
        item.view = control
        item.label = "显示方式"
        item.toolTip = "显示方式"
        return item
    }

    private func makeGroupMenuItem() -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: .finderGroupMenu)
        item.image = Self.symbolImage(["square.grid.3x1.below.line.grid.1x2"], description: "分组方式")
        item.label = "分组"
        item.toolTip = "分组方式"
        item.showsIndicator = true

        let menu = NSMenu()
        menu.autoenablesItems = false
        let none = NSMenuItem(title: "无分组", action: nil, keyEquivalent: "")
        none.state = .on
        none.isEnabled = false
        menu.addItem(none)
        item.menu = menu
        return item
    }

    private func makeDisabledImageItem(
        identifier: NSToolbarItem.Identifier,
        symbolNames: [String],
        label: String
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = Self.symbolImage(symbolNames, description: label)
        item.label = label
        item.toolTip = label
        item.isBordered = true
        item.autovalidates = false
        item.isEnabled = false
        return item
    }

    private func makeMoreMenuItem() -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: .finderMoreMenu)
        item.image = Self.symbolImage(["ellipsis"], description: "更多")
        item.label = "更多"
        item.toolTip = "更多"
        item.showsIndicator = false

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        moreMenu = menu
        item.menu = menu
        return item
    }

    private func makeTerminalItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .finderTerminal)
        item.image = Self.symbolImage(["terminal"], description: "终端")
        item.label = "终端"
        item.toolTip = "显示或隐藏终端面板"
        item.isBordered = true
        item.autovalidates = false
        item.target = actionTarget
        item.action = #selector(FinderWindowController.toggleTerminalPanelAction(_:))
        return item
    }

    private func makeSearchItem() -> NSToolbarItem {
        let item = NSSearchToolbarItem(itemIdentifier: .finderSearch)
        item.label = "搜索"
        item.toolTip = "搜索将在后续阶段提供"
        item.autovalidates = false
        item.searchField.placeholderString = "搜索"
        item.searchField.isEnabled = false
        return item
    }
}

// MARK: - "More" menu content

extension FinderToolbarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === moreMenu else {
            return
        }

        menu.removeAllItems()

        let statusLines = [
            "连接状态：\(connectionVM.status.title)",
            connectionVM.detailText,
            connectionVM.eventStatusText
        ]
        for line in statusLines {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let reconnect = NSMenuItem(
            title: "重新连接",
            action: #selector(FinderWindowController.reconnectAction(_:)),
            keyEquivalent: ""
        )
        reconnect.target = actionTarget
        reconnect.isEnabled = true
        menu.addItem(reconnect)

        menu.addItem(.separator())

        let hidden = NSMenuItem(
            title: "显示隐藏文件",
            action: #selector(FinderWindowController.toggleHiddenFilesAction(_:)),
            keyEquivalent: "."
        )
        hidden.keyEquivalentModifierMask = [.command, .shift]
        hidden.target = actionTarget
        hidden.state = workspaceVM.showsHiddenFiles ? .on : .off
        hidden.isEnabled = true
        menu.addItem(hidden)

        let refresh = NSMenuItem(
            title: "刷新",
            action: #selector(FinderWindowController.refreshAction(_:)),
            keyEquivalent: "r"
        )
        refresh.target = actionTarget
        refresh.isEnabled = !workspaceVM.isLoading
        menu.addItem(refresh)

        let terminal = NSMenuItem(
            title: actionTarget?.panelLayout.isOpen == true ? "隐藏终端面板" : "显示终端面板",
            action: #selector(FinderWindowController.toggleTerminalPanelAction(_:)),
            keyEquivalent: "j"
        )
        terminal.target = actionTarget
        terminal.isEnabled = true
        menu.addItem(terminal)

        let goToFolder = NSMenuItem(
            title: "前往文件夹…",
            action: #selector(FinderWindowController.goToFolderAction(_:)),
            keyEquivalent: "g"
        )
        goToFolder.keyEquivalentModifierMask = [.command, .shift]
        goToFolder.target = actionTarget
        goToFolder.isEnabled = true
        menu.addItem(goToFolder)
    }
}
