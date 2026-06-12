//
//  FinderColumnView.swift
//  MacOS
//
//  Created by Codex on 2026/6/12.
//

import AppKit
import SwiftUI

enum FinderColumnMetrics {
    static let columnWidth: CGFloat = 220
    static let rowHeight: CGFloat = 24
    static let iconSize: CGFloat = 16
}

struct FinderColumnView: NSViewRepresentable {
    let entries: [DirectoryEntry]
    let selectedPath: String?
    let onSelect: (String?) -> Void
    let onOpen: (DirectoryEntry) -> Void
    let loadChildren: (String) async throws -> [DirectoryEntry]

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSelect: onSelect,
            onOpen: onOpen,
            loadChildren: loadChildren
        )
    }

    func makeNSView(context: Context) -> FinderColumnBrowserNSView {
        let browserView = FinderColumnBrowserNSView()
        context.coordinator.browserView = browserView
        context.coordinator.rebuildRoot(with: entries)
        context.coordinator.syncSelection(to: selectedPath)
        return browserView
    }

    func updateNSView(_ browserView: FinderColumnBrowserNSView, context: Context) {
        context.coordinator.browserView = browserView
        context.coordinator.onSelect = onSelect
        context.coordinator.onOpen = onOpen
        context.coordinator.loadChildren = loadChildren

        if context.coordinator.rootSignature(for: entries) != context.coordinator.currentRootSignature {
            context.coordinator.rebuildRoot(with: entries)
        }

        context.coordinator.syncSelection(to: selectedPath)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var onSelect: (String?) -> Void
        var onOpen: (DirectoryEntry) -> Void
        var loadChildren: (String) async throws -> [DirectoryEntry]

        weak var browserView: FinderColumnBrowserNSView?
        private(set) var currentRootSignature: [String] = []

        private var columns: [FinderColumnState] = []
        private var tableViews: [NSTableView] = []
        private var isApplyingSelection = false
        private var loadTask: Task<Void, Never>?

        init(
            onSelect: @escaping (String?) -> Void,
            onOpen: @escaping (DirectoryEntry) -> Void,
            loadChildren: @escaping (String) async throws -> [DirectoryEntry]
        ) {
            self.onSelect = onSelect
            self.onOpen = onOpen
            self.loadChildren = loadChildren
        }

        deinit {
            loadTask?.cancel()
        }

        func rootSignature(for entries: [DirectoryEntry]) -> [String] {
            entries.map(signature)
        }

        func rebuildRoot(with entries: [DirectoryEntry]) {
            loadTask?.cancel()
            currentRootSignature = rootSignature(for: entries)
            columns = [
                FinderColumnState(
                    parentPath: nil,
                    entries: entries,
                    selectedPath: nil,
                    placeholderText: nil
                )
            ]
            renderColumns(scrollToEnd: false)
        }

        func syncSelection(to selectedPath: String?) {
            guard let selectedPath else {
                clearSelection()
                return
            }

            if currentSelectedPath == selectedPath {
                applySelections()
                return
            }

            guard let location = findEntry(path: selectedPath) else {
                applySelections()
                return
            }

            select(
                location.entry,
                inColumnAt: location.columnIndex,
                notify: false,
                loadDirectory: location.entry.isDirectory
            )
        }

        private var currentSelectedPath: String? {
            columns.compactMap(\.selectedPath).last
        }

        private func signature(for entry: DirectoryEntry) -> String {
            [
                entry.path,
                entry.name,
                entry.kind.rawValue,
                entry.isDirectory ? "1" : "0",
                entry.size.map(String.init) ?? "",
                entry.modifiedAt ?? ""
            ].joined(separator: "\u{1F}")
        }

        private func clearSelection() {
            loadTask?.cancel()
            guard columns.contains(where: { $0.selectedPath != nil }) || columns.count > 1 else {
                applySelections()
                return
            }

            if let root = columns.first {
                columns = [
                    FinderColumnState(
                        parentPath: root.parentPath,
                        entries: root.entries,
                        selectedPath: nil,
                        placeholderText: nil
                    )
                ]
            }
            renderColumns(scrollToEnd: false)
        }

        private func findEntry(path: String) -> (columnIndex: Int, entry: DirectoryEntry)? {
            for (columnIndex, column) in columns.enumerated() where column.placeholderText == nil {
                if let entry = column.entries.first(where: { $0.path == path }) {
                    return (columnIndex, entry)
                }
            }

            return nil
        }

        private func select(
            _ entry: DirectoryEntry,
            inColumnAt columnIndex: Int,
            notify: Bool,
            loadDirectory: Bool
        ) {
            guard columns.indices.contains(columnIndex) else {
                return
            }

            loadTask?.cancel()
            columns = Array(columns.prefix(columnIndex + 1))
            columns[columnIndex].selectedPath = entry.path

            if notify {
                onSelect(entry.path)
            }

            if entry.isDirectory, loadDirectory {
                columns.append(
                    FinderColumnState(
                        parentPath: entry.path,
                        entries: [],
                        selectedPath: nil,
                        placeholderText: "正在载入..."
                    )
                )
                renderColumns(scrollToEnd: true)
                loadChildren(for: entry, selectedColumnIndex: columnIndex)
            } else {
                renderColumns(scrollToEnd: false)
            }
        }

        private func loadChildren(for entry: DirectoryEntry, selectedColumnIndex: Int) {
            let selectedPath = entry.path

            loadTask = Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                let loadedEntries: [DirectoryEntry]
                let placeholderText: String?
                do {
                    loadedEntries = try await loadChildren(selectedPath)
                    placeholderText = nil
                } catch {
                    loadedEntries = []
                    placeholderText = "无法载入"
                }

                guard columns.indices.contains(selectedColumnIndex),
                      columns[selectedColumnIndex].selectedPath == selectedPath
                else {
                    return
                }

                columns = Array(columns.prefix(selectedColumnIndex + 1))
                columns.append(
                    FinderColumnState(
                        parentPath: selectedPath,
                        entries: loadedEntries,
                        selectedPath: nil,
                        placeholderText: placeholderText
                    )
                )
                renderColumns(scrollToEnd: true)
            }
        }

        private func renderColumns(scrollToEnd: Bool) {
            guard let browserView else {
                return
            }

            isApplyingSelection = true
            defer {
                isApplyingSelection = false
            }

            tableViews = []
            browserView.removeColumns()

            for columnIndex in columns.indices {
                let tableView = makeTableView(columnIndex: columnIndex)
                tableViews.append(tableView)
                browserView.addColumn(tableView)
                tableView.reloadData()
            }

            applySelections()

            if scrollToEnd {
                browserView.scrollToTrailingColumn()
            }
        }

        private func makeTableView(columnIndex: Int) -> NSTableView {
            let tableView = FinderColumnTableView(frame: .zero)
            tableView.delegate = self
            tableView.dataSource = self
            tableView.target = self
            tableView.doubleAction = #selector(handleDoubleClick(_:))
            tableView.openSelectedRow = { [weak self] tableView in
                self?.openSelection(in: tableView)
            }
            tableView.allowsMultipleSelection = false
            tableView.allowsEmptySelection = true
            tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            tableView.focusRingType = .none
            tableView.gridStyleMask = []
            tableView.headerView = nil
            tableView.intercellSpacing = .zero
            tableView.rowHeight = FinderColumnMetrics.rowHeight
            tableView.selectionHighlightStyle = .regular
            tableView.backgroundColor = .controlBackgroundColor
            tableView.tag = columnIndex

            if #available(macOS 11.0, *) {
                tableView.style = .plain
            }

            let column = NSTableColumn(identifier: .finderColumnName)
            column.width = FinderColumnMetrics.columnWidth
            column.minWidth = FinderColumnMetrics.columnWidth
            column.maxWidth = FinderColumnMetrics.columnWidth
            column.resizingMask = []
            tableView.addTableColumn(column)
            return tableView
        }

        private func applySelections() {
            for (columnIndex, tableView) in tableViews.enumerated() {
                guard columns.indices.contains(columnIndex),
                      let selectedPath = columns[columnIndex].selectedPath,
                      let row = columns[columnIndex].entries.firstIndex(where: { $0.path == selectedPath })
                else {
                    if tableView.selectedRow != -1 {
                        tableView.deselectAll(nil)
                    }
                    continue
                }

                let indexSet = IndexSet(integer: row)
                if tableView.selectedRowIndexes != indexSet {
                    tableView.selectRowIndexes(indexSet, byExtendingSelection: false)
                    tableView.scrollRowToVisible(row)
                }
            }
        }

        private func columnIndex(for tableView: NSTableView) -> Int? {
            if let index = tableViews.firstIndex(where: { $0 === tableView }) {
                return index
            }

            return columns.indices.contains(tableView.tag) ? tableView.tag : nil
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int {
            guard let columnIndex = columnIndex(for: tableView),
                  columns.indices.contains(columnIndex)
            else {
                return 0
            }

            let column = columns[columnIndex]
            if column.placeholderText != nil {
                return 1
            }

            return column.entries.count
        }

        // MARK: Delegate

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard let columnIndex = columnIndex(for: tableView),
                  columns.indices.contains(columnIndex)
            else {
                return nil
            }

            let column = columns[columnIndex]
            if let placeholderText = column.placeholderText {
                return FinderColumnPlaceholderCell(text: placeholderText)
            }

            guard column.entries.indices.contains(row) else {
                return nil
            }

            return FinderColumnItemCell(entry: column.entries[row])
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection,
                  let tableView = notification.object as? NSTableView,
                  let columnIndex = columnIndex(for: tableView),
                  columns.indices.contains(columnIndex)
            else {
                return
            }

            let row = tableView.selectedRow
            guard row >= 0, columns[columnIndex].entries.indices.contains(row) else {
                onSelect(nil)
                return
            }

            let entry = columns[columnIndex].entries[row]
            select(entry, inColumnAt: columnIndex, notify: true, loadDirectory: true)
        }

        func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool {
            false
        }

        @objc func handleDoubleClick(_ sender: NSTableView) {
            let row = sender.clickedRow >= 0 ? sender.clickedRow : sender.selectedRow
            openSelection(in: sender, row: row)
        }

        private func openSelection(in tableView: NSTableView, row: Int? = nil) {
            let row = row ?? tableView.selectedRow
            guard let columnIndex = columnIndex(for: tableView),
                  columns.indices.contains(columnIndex),
                  row >= 0,
                  columns[columnIndex].entries.indices.contains(row)
            else {
                return
            }

            onOpen(columns[columnIndex].entries[row])
        }
    }
}

private struct FinderColumnState {
    let parentPath: String?
    let entries: [DirectoryEntry]
    var selectedPath: String?
    let placeholderText: String?
}

final class FinderColumnBrowserNSView: NSView {
    private let scrollView = NSScrollView()
    private let documentView = NSView()
    private let stackView = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func removeColumns() {
        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    func addColumn(_ tableView: NSTableView) {
        let columnView = FinderColumnContainerView(tableView: tableView)
        stackView.addArrangedSubview(columnView)
        columnView.widthAnchor.constraint(equalToConstant: FinderColumnMetrics.columnWidth).isActive = true
    }

    func scrollToTrailingColumn() {
        layoutSubtreeIfNeeded()
        guard let documentView = scrollView.documentView else {
            return
        }

        let maxX = max(0, documentView.bounds.width - scrollView.contentView.bounds.width)
        scrollView.contentView.scroll(to: NSPoint(x: maxX, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true

        documentView.translatesAutoresizingMaskIntoConstraints = false
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .horizontal
        stackView.alignment = .height
        stackView.distribution = .fill
        stackView.spacing = 0

        addSubview(scrollView)
        scrollView.documentView = documentView
        documentView.addSubview(stackView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            documentView.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),
            documentView.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.widthAnchor),

            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: documentView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
        ])
    }
}

private final class FinderColumnContainerView: NSView {
    init(tableView: NSTableView) {
        super.init(frame: .zero)
        setup(tableView: tableView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func setup(tableView: NSTableView) {
        translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView

        let separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator

        addSubview(scrollView)
        addSubview(separator)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: separator.leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1)
        ])
    }
}

private final class FinderColumnTableView: NSTableView {
    var openSelectedRow: ((NSTableView) -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.charactersIgnoringModifiers == "\r" {
            openSelectedRow?(self)
            return
        }

        super.keyDown(with: event)
    }
}

private final class FinderColumnItemCell: NSTableCellView {
    private let normalTextColor = NSColor.labelColor
    private let normalChevronColor = NSColor.tertiaryLabelColor

    init(entry: DirectoryEntry) {
        super.init(frame: .zero)
        setup(entry: entry)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            textField?.textColor = backgroundStyle == .emphasized
                ? .alternateSelectedControlTextColor
                : normalTextColor
            imageView?.contentTintColor = backgroundStyle == .emphasized
                ? .alternateSelectedControlTextColor
                : nil

            subviews.compactMap { $0 as? NSImageView }.last?.contentTintColor = backgroundStyle == .emphasized
                ? .alternateSelectedControlTextColor
                : normalChevronColor
        }
    }

    private func setup(entry: DirectoryEntry) {
        let iconView = NSImageView()
        let icon = NSWorkspace.shared.icon(forFile: entry.path)
        icon.size = NSSize(width: FinderColumnMetrics.iconSize, height: FinderColumnMetrics.iconSize)
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let textField = NSTextField(labelWithString: FinderListFormatters.displayName(for: entry))
        textField.font = .systemFont(ofSize: 13)
        textField.lineBreakMode = .byTruncatingTail
        textField.textColor = normalTextColor
        textField.allowsDefaultTighteningForTruncation = true
        textField.translatesAutoresizingMaskIntoConstraints = false

        let chevronView = NSImageView()
        chevronView.image = entry.isDirectory
            ? NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: nil)
            : nil
        chevronView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        chevronView.contentTintColor = normalChevronColor
        chevronView.imageScaling = .scaleProportionallyDown
        chevronView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(textField)
        addSubview(chevronView)
        imageView = iconView
        self.textField = textField

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: FinderColumnMetrics.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: FinderColumnMetrics.iconSize),

            textField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
            textField.trailingAnchor.constraint(equalTo: chevronView.leadingAnchor, constant: -6),

            chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 10),
            chevronView.heightAnchor.constraint(equalToConstant: 14)
        ])
    }
}

private final class FinderColumnPlaceholderCell: NSTableCellView {
    init(text: String) {
        super.init(frame: .zero)
        setup(text: text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            textField?.textColor = backgroundStyle == .emphasized
                ? .alternateSelectedControlTextColor
                : .secondaryLabelColor
        }
    }

    private func setup(text: String) {
        let textField = NSTextField(labelWithString: text)
        textField.font = .systemFont(ofSize: 13)
        textField.lineBreakMode = .byTruncatingTail
        textField.textColor = .secondaryLabelColor
        textField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(textField)
        self.textField = textField

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let finderColumnName = NSUserInterfaceItemIdentifier("finderColumnName")
}
