//
//  FinderListView.swift
//  MacOS
//
//  Created by Codex on 2026/6/11.
//

import AppKit
import SwiftUI

struct FinderListView: NSViewRepresentable {
    let entries: [DirectoryEntry]
    let selectedPath: String?
    let isLoading: Bool
    let themeProvider: FinderThemeProvider
    let onSelect: (String?) -> Void
    let onOpen: (DirectoryEntry) -> Void
    let loadChildren: (String) async throws -> [DirectoryEntry]

    func makeCoordinator() -> Coordinator {
        Coordinator(
            themeProvider: themeProvider,
            onSelect: onSelect,
            onOpen: onOpen,
            loadChildren: loadChildren
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outlineView = NSOutlineView(frame: .zero)
        outlineView.delegate = context.coordinator
        outlineView.dataSource = context.coordinator
        outlineView.target = context.coordinator
        outlineView.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.autoresizesOutlineColumn = false
        outlineView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outlineView.gridStyleMask = []
        outlineView.headerView = NSTableHeaderView()
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.rowHeight = 20
        outlineView.selectionHighlightStyle = .regular
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.indentationPerLevel = 16
        outlineView.backgroundColor = themeProvider.current.listBackground
        if #available(macOS 11.0, *) {
            outlineView.style = .inset
        }

        let nameColumn = makeColumn(.name, width: 344, minWidth: 220)
        outlineView.addTableColumn(nameColumn)
        outlineView.outlineTableColumn = nameColumn

        outlineView.addTableColumn(makeColumn(.dateModified, width: 161, minWidth: 132))
        outlineView.addTableColumn(makeColumn(.size, width: 97, minWidth: 76))
        outlineView.addTableColumn(makeColumn(.kind, width: 132, minWidth: 104))
        outlineView.sortDescriptors = [NSSortDescriptor(key: FinderListSortKey.name.rawValue, ascending: false)]

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = themeProvider.current.listBackground
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = outlineView

        context.coordinator.outlineView = outlineView
        context.coordinator.observeThemeChanges()
        context.coordinator.rebuildRoots(with: entries)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.onOpen = onOpen
        context.coordinator.loadChildren = loadChildren
        context.coordinator.isLoading = isLoading

        guard let outlineView = scrollView.documentView as? NSOutlineView else {
            return
        }

        if context.coordinator.topLevelSignature(for: entries) != context.coordinator.currentSignature {
            context.coordinator.rebuildRoots(with: entries)
        }

        applySelection(on: outlineView, coordinator: context.coordinator)
    }

    private func makeColumn(
        _ column: FinderListColumn,
        width: CGFloat,
        minWidth: CGFloat
    ) -> NSTableColumn {
        let tableColumn = NSTableColumn(identifier: column.identifier)
        tableColumn.title = column.title
        tableColumn.width = width
        tableColumn.minWidth = minWidth
        tableColumn.resizingMask = .autoresizingMask
        tableColumn.sortDescriptorPrototype = NSSortDescriptor(
            key: column.sortKey.rawValue,
            ascending: column.defaultAscending
        )
        return tableColumn
    }

    private func applySelection(on outlineView: NSOutlineView, coordinator: Coordinator) {
        coordinator.isApplyingSelection = true
        defer {
            coordinator.isApplyingSelection = false
        }

        guard let selectedPath,
              let node = coordinator.findNode(path: selectedPath)
        else {
            if outlineView.selectedRow != -1 {
                outlineView.deselectAll(nil)
            }
            return
        }

        let row = outlineView.row(forItem: node)
        guard row >= 0 else {
            if outlineView.selectedRow != -1 {
                outlineView.deselectAll(nil)
            }
            return
        }

        let selectedRows = outlineView.selectedRowIndexes
        if selectedRows.count != 1 || !selectedRows.contains(row) {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        let themeProvider: FinderThemeProvider
        var onSelect: (String?) -> Void
        var onOpen: (DirectoryEntry) -> Void
        var loadChildren: (String) async throws -> [DirectoryEntry]
        var isApplyingSelection = false
        var isLoading = false

        weak var outlineView: NSOutlineView?
        private(set) var currentSignature: [String] = []

        private var rootNodes: [FinderOutlineNode] = []
        private var originalEntries: [DirectoryEntry] = []
        private var sortKey: FinderListSortKey = .name
        private var sortAscending = false
        private var themeObserver: NSObjectProtocol?

        private var theme: FinderTheme {
            themeProvider.current
        }

        init(
            themeProvider: FinderThemeProvider,
            onSelect: @escaping (String?) -> Void,
            onOpen: @escaping (DirectoryEntry) -> Void,
            loadChildren: @escaping (String) async throws -> [DirectoryEntry]
        ) {
            self.themeProvider = themeProvider
            self.onSelect = onSelect
            self.onOpen = onOpen
            self.loadChildren = loadChildren
        }

        deinit {
            if let themeObserver {
                NotificationCenter.default.removeObserver(themeObserver)
            }
        }

        /// 订阅主题广播：切换后重设缓存底色 + reloadData，让单元格按新 token 重建。
        func observeThemeChanges() {
            guard themeObserver == nil else {
                return
            }

            themeObserver = NotificationCenter.default.addObserver(
                forName: FinderThemeProvider.didChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else {
                    return
                }
                Task { @MainActor in
                    self.applyTheme()
                }
            }
        }

        private func applyTheme() {
            guard let outlineView else {
                return
            }

            outlineView.backgroundColor = theme.listBackground
            outlineView.enclosingScrollView?.backgroundColor = theme.listBackground
            outlineView.reloadData()
        }

        func topLevelSignature(for entries: [DirectoryEntry]) -> [String] {
            entries.map { entry in
                [
                    entry.path,
                    entry.name,
                    entry.kind.rawValue,
                    entry.isDirectory ? "1" : "0",
                    entry.size.map(String.init) ?? "",
                    entry.modifiedAt ?? ""
                ].joined(separator: "\u{1F}")
            }
        }

        func rebuildRoots(with entries: [DirectoryEntry]) {
            originalEntries = entries
            currentSignature = topLevelSignature(for: entries)
            rootNodes = sorted(entries).map(FinderOutlineNode.init(entry:))
            outlineView?.reloadData()
        }

        fileprivate func findNode(path: String) -> FinderOutlineNode? {
            func search(_ nodes: [FinderOutlineNode]) -> FinderOutlineNode? {
                for node in nodes {
                    if node.entry.path == path {
                        return node
                    }
                    if let children = node.children, let match = search(children) {
                        return match
                    }
                }
                return nil
            }

            return search(rootNodes)
        }

        private func sorted(_ entries: [DirectoryEntry]) -> [DirectoryEntry] {
            FinderListSortComparator.sorted(entries, key: sortKey, ascending: sortAscending)
        }

        // MARK: Sorting

        func outlineView(
            _ outlineView: NSOutlineView,
            sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
        ) {
            guard let descriptor = outlineView.sortDescriptors.first,
                  let key = descriptor.key,
                  let newSortKey = FinderListSortKey(rawValue: key)
            else {
                return
            }

            sortKey = newSortKey
            sortAscending = descriptor.ascending
            rebuildRoots(with: originalEntries)
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? FinderOutlineNode else {
                return rootNodes.count
            }

            if let children = node.children {
                return children.count
            }

            return node.isDirectory ? 1 : 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? FinderOutlineNode else {
                return rootNodes[index]
            }

            if let children = node.children {
                return children[index]
            }

            return node.placeholder
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? FinderOutlineNode else {
                return false
            }

            return node.isDirectory
        }

        func outlineViewItemWillExpand(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? FinderOutlineNode,
                  node.isDirectory,
                  node.children == nil,
                  !node.isLoading
            else {
                return
            }

            node.isLoading = true
            let path = node.entry.path

            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                do {
                    let entries = try await loadChildren(path)
                    node.children = sorted(entries).map(FinderOutlineNode.init(entry:))
                } catch {
                    node.children = []
                }

                node.isLoading = false
                reloadExpanded(node)
            }
        }

        private func reloadExpanded(_ node: FinderOutlineNode) {
            guard let outlineView, outlineView.row(forItem: node) >= 0 else {
                return
            }

            outlineView.reloadItem(node, reloadChildren: true)
            outlineView.expandItem(node)
        }

        // MARK: Delegate

        func outlineView(
            _ outlineView: NSOutlineView,
            viewFor tableColumn: NSTableColumn?,
            item: Any
        ) -> NSView? {
            guard let column = FinderListColumn(identifier: tableColumn?.identifier) else {
                return nil
            }

            if item is FinderLoadingPlaceholder {
                return column == .name
                    ? makeTextCell(text: "正在载入…", alignment: .left, color: theme.secondaryText)
                    : NSTableCellView()
            }

            guard let node = item as? FinderOutlineNode else {
                return nil
            }

            let entry = node.entry
            switch column {
            case .name:
                return makeNameCell(entry: entry)
            case .dateModified:
                return makeTextCell(
                    text: FinderListFormatters.dateDisplayText(isoString: entry.modifiedAt),
                    alignment: .left,
                    color: theme.secondaryText
                )
            case .size:
                return makeTextCell(
                    text: FinderListFormatters.sizeDisplayText(
                        isDirectory: entry.isDirectory,
                        size: entry.size
                    ),
                    alignment: .right,
                    color: theme.secondaryText
                )
            case .kind:
                return makeTextCell(
                    text: FinderListFormatters.kindDisplayText(for: entry),
                    alignment: .left,
                    color: theme.secondaryText
                )
            }
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection else {
                return
            }

            guard let outlineView else {
                onSelect(nil)
                return
            }

            let row = outlineView.selectedRow
            guard row >= 0,
                  let node = outlineView.item(atRow: row) as? FinderOutlineNode
            else {
                onSelect(nil)
                return
            }

            onSelect(node.entry.path)
        }

        func outlineView(_ outlineView: NSOutlineView, shouldEdit tableColumn: NSTableColumn?, item: Any) -> Bool {
            false
        }

        @objc func handleDoubleClick(_ sender: NSOutlineView) {
            let row = sender.clickedRow >= 0 ? sender.clickedRow : sender.selectedRow
            guard row >= 0,
                  let node = sender.item(atRow: row) as? FinderOutlineNode
            else {
                return
            }

            onOpen(node.entry)
        }

        private func makeNameCell(entry: DirectoryEntry) -> NSTableCellView {
            let cell = FinderNameCell()
            let imageView = NSImageView()
            let icon = NSWorkspace.shared.icon(forFile: entry.path)
            icon.size = NSSize(width: 16, height: 16)
            imageView.image = icon
            imageView.imageScaling = .scaleProportionallyDown
            imageView.translatesAutoresizingMaskIntoConstraints = false

            let textField = NSTextField(labelWithString: FinderListFormatters.displayName(for: entry))
            textField.font = theme.rowFont
            textField.lineBreakMode = .byTruncatingMiddle
            textField.textColor = theme.primaryText
            textField.allowsDefaultTighteningForTruncation = true
            textField.translatesAutoresizingMaskIntoConstraints = false

            cell.normalTextColor = theme.primaryText
            cell.selectedTextColor = theme.selectedText
            cell.addSubview(imageView)
            cell.addSubview(textField)
            cell.imageView = imageView
            cell.textField = textField

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])

            return cell
        }

        private func makeTextCell(
            text: String,
            alignment: NSTextAlignment,
            color: NSColor
        ) -> NSTableCellView {
            let cell = FinderTextCell(normalTextColor: color, selectedTextColor: theme.selectedText)
            let textField = NSTextField(labelWithString: text)
            textField.font = theme.rowFont
            textField.alignment = alignment
            textField.lineBreakMode = .byTruncatingTail
            textField.textColor = color
            textField.allowsDefaultTighteningForTruncation = true
            textField.translatesAutoresizingMaskIntoConstraints = false

            cell.addSubview(textField)
            cell.textField = textField

            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])

            return cell
        }
    }
}

private final class FinderOutlineNode {
    let entry: DirectoryEntry
    var children: [FinderOutlineNode]?
    var isLoading = false
    private(set) lazy var placeholder = FinderLoadingPlaceholder()

    init(entry: DirectoryEntry) {
        self.entry = entry
    }

    var isDirectory: Bool {
        entry.isDirectory
    }
}

private final class FinderLoadingPlaceholder {}

private final class FinderNameCell: NSTableCellView {
    var normalTextColor: NSColor = .labelColor
    var selectedTextColor: NSColor = .alternateSelectedControlTextColor

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            textField?.textColor = backgroundStyle == .emphasized
                ? selectedTextColor
                : normalTextColor
        }
    }
}

private final class FinderTextCell: NSTableCellView {
    private let normalTextColor: NSColor
    private let selectedTextColor: NSColor

    init(normalTextColor: NSColor, selectedTextColor: NSColor) {
        self.normalTextColor = normalTextColor
        self.selectedTextColor = selectedTextColor
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            textField?.textColor = backgroundStyle == .emphasized
                ? selectedTextColor
                : normalTextColor
        }
    }
}

private enum FinderListColumn: CaseIterable {
    case name
    case dateModified
    case size
    case kind

    var identifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(sortKey.rawValue)
    }

    var sortKey: FinderListSortKey {
        switch self {
        case .name:
            return .name
        case .dateModified:
            return .dateModified
        case .size:
            return .size
        case .kind:
            return .kind
        }
    }

    var title: String {
        switch self {
        case .name:
            return "名称"
        case .dateModified:
            return "修改日期"
        case .size:
            return "大小"
        case .kind:
            return "种类"
        }
    }

    var defaultAscending: Bool {
        switch self {
        case .name:
            return false
        case .dateModified:
            return false
        case .size, .kind:
            return true
        }
    }

    init?(identifier: NSUserInterfaceItemIdentifier?) {
        guard let rawValue = identifier?.rawValue,
              let sortKey = FinderListSortKey(rawValue: rawValue)
        else {
            return nil
        }

        self.init(sortKey: sortKey)
    }

    private init(sortKey: FinderListSortKey) {
        switch sortKey {
        case .name:
            self = .name
        case .dateModified:
            self = .dateModified
        case .size:
            self = .size
        case .kind:
            self = .kind
        }
    }
}
