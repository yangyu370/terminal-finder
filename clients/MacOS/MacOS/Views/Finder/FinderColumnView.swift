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
    static let previewMinWidth: CGFloat = 260
    static let previewMaxComfortWidth: CGFloat = 360
    static let previewImageMinWidth: CGFloat = 160
    static let previewImageMinHeight: CGFloat = 120
    static let previewFallbackIconSize: CGFloat = 220
    static let previewResizeRequestThreshold: CGFloat = 16
    static let previewHorizontalInset: CGFloat = 18
}

enum FinderColumnLayout {
    static func previewPaneWidth(columnsWidth: CGFloat, visibleWidth: CGFloat) -> CGFloat {
        max(FinderColumnMetrics.previewMinWidth, visibleWidth - columnsWidth)
    }

    static func documentWidth(columnCount: Int, visibleWidth: CGFloat, hasPreviewPane: Bool) -> CGFloat {
        let columnsWidth = CGFloat(columnCount) * FinderColumnMetrics.columnWidth
        guard hasPreviewPane else {
            return max(visibleWidth, columnsWidth)
        }

        return max(
            visibleWidth,
            columnsWidth + previewPaneWidth(columnsWidth: columnsWidth, visibleWidth: visibleWidth)
        )
    }
}

struct FinderColumnView: NSViewRepresentable {
    let entries: [DirectoryEntry]
    let selectedPath: String?
    let onSelect: (String?) -> Void
    let onOpen: (DirectoryEntry) -> Void
    let loadChildren: (String) async throws -> [DirectoryEntry]
    var thumbnailProvider: ThumbnailProviding = ThumbnailProviders.shared

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSelect: onSelect,
            onOpen: onOpen,
            loadChildren: loadChildren
        )
    }

    func makeNSView(context: Context) -> FinderColumnBrowserNSView {
        let browserView = FinderColumnBrowserNSView()
        browserView.thumbnailProvider = thumbnailProvider
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
        browserView.thumbnailProvider = thumbnailProvider

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
        private var previewEntry: DirectoryEntry?

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
            previewEntry = nil
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
                previewEntry = nil
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
                previewEntry = nil
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
                previewEntry = entry.isDirectory ? nil : entry
                renderColumns(scrollToEnd: !entry.isDirectory)
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
                previewEntry = nil
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
            browserView.setPreviewEntry(previewEntry)

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
    var thumbnailProvider: ThumbnailProviding = ThumbnailProviders.shared

    private let scrollView = NSScrollView()
    private let documentView = FinderColumnDocumentView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        updateDocumentFrame()
    }

    func removeColumns() {
        documentView.removeColumns()
        documentView.setPreviewPane(nil)
        updateDocumentFrame()
    }

    func addColumn(_ tableView: NSTableView) {
        let columnView = FinderColumnContainerView(tableView: tableView)
        documentView.addColumn(columnView)
        updateDocumentFrame()
    }

    func setPreviewEntry(_ entry: DirectoryEntry?) {
        guard let entry, !entry.isDirectory else {
            documentView.setPreviewPane(nil)
            updateDocumentFrame()
            return
        }

        documentView.setPreviewPane(
            FinderColumnPreviewPane(entry: entry, thumbnailProvider: thumbnailProvider)
        )
        updateDocumentFrame()
    }

    func scrollToTrailingColumn() {
        layoutSubtreeIfNeeded()

        let maxX = max(0, documentView.frame.width - scrollView.contentView.bounds.width)
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

        addSubview(scrollView)
        scrollView.documentView = documentView

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func updateDocumentFrame() {
        let visibleWidth = scrollView.contentView.bounds.width
        let width = FinderColumnLayout.documentWidth(
            columnCount: documentView.columnCount,
            visibleWidth: visibleWidth,
            hasPreviewPane: documentView.hasPreviewPane
        )
        documentView.previewPaneWidth = documentView.hasPreviewPane
            ? FinderColumnLayout.previewPaneWidth(
                columnsWidth: CGFloat(documentView.columnCount) * FinderColumnMetrics.columnWidth,
                visibleWidth: visibleWidth
            )
            : 0
        let height = scrollView.contentView.bounds.height
        documentView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        documentView.needsLayout = true
    }

    var documentWidthForTesting: CGFloat {
        documentView.frame.width
    }

    var previewPaneWidthForTesting: CGFloat {
        documentView.previewPaneWidth
    }

    var hasPreviewPaneForTesting: Bool {
        documentView.hasPreviewPane
    }

    var previewPaneForTesting: FinderColumnPreviewPane? {
        documentView.previewPaneForTesting
    }

    var documentColumnCountForTesting: Int {
        documentView.columnCount
    }
}

private final class FinderColumnDocumentView: NSView {
    private var columnViews: [NSView] = []
    private var previewPane: FinderColumnPreviewPane?
    var previewPaneWidth: CGFloat = 0

    var columnCount: Int {
        columnViews.count
    }

    var hasPreviewPane: Bool {
        previewPane != nil
    }

    var previewPaneForTesting: FinderColumnPreviewPane? {
        previewPane
    }

    override var isFlipped: Bool {
        true
    }

    func removeColumns() {
        for columnView in columnViews {
            columnView.removeFromSuperview()
        }
        columnViews.removeAll()
        needsLayout = true
    }

    func setPreviewPane(_ pane: FinderColumnPreviewPane?) {
        previewPane?.cancelThumbnail()
        previewPane?.removeFromSuperview()
        previewPane = pane
        if let pane {
            addSubview(pane)
        }
        needsLayout = true
    }

    func addColumn(_ columnView: NSView) {
        columnViews.append(columnView)
        addSubview(columnView)
        needsLayout = true
    }

    override func layout() {
        super.layout()

        for (index, columnView) in columnViews.enumerated() {
            columnView.frame = NSRect(
                x: CGFloat(index) * FinderColumnMetrics.columnWidth,
                y: 0,
                width: FinderColumnMetrics.columnWidth,
                height: bounds.height
            )
        }

        if let previewPane {
            previewPane.frame = NSRect(
                x: CGFloat(columnViews.count) * FinderColumnMetrics.columnWidth,
                y: 0,
                width: previewPaneWidth,
                height: bounds.height
            )
        }
    }
}

final class FinderColumnPreviewPane: NSView {
    private let entry: DirectoryEntry
    private let thumbnailProvider: ThumbnailProviding
    private let separator = NSBox()
    private let imageView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let infoTitleField = NSTextField(labelWithString: "信息")
    private let modifiedLabelField = NSTextField(labelWithString: "修改时间")
    private let modifiedValueField = NSTextField(labelWithString: "")
    private let sizeLabelField = NSTextField(labelWithString: "大小")
    private let sizeValueField = NSTextField(labelWithString: "")
    private let moreButton = NSButton(
        image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "更多") ?? NSImage(),
        target: nil,
        action: nil
    )
    private let moreField = NSTextField(labelWithString: "更多...")
    private var thumbnailToken: ThumbnailRequestToken?
    private var currentDescriptor: ThumbnailDescriptor?
    private var imageContainer: CGRect = .zero
    private var imageMaximumScale: CGFloat = 1

    init(entry: DirectoryEntry, thumbnailProvider: ThumbnailProviding) {
        self.entry = entry
        self.thumbnailProvider = thumbnailProvider
        super.init(frame: .zero)
        setup()
        showFallbackIcon()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        thumbnailToken?.cancel()
    }

    override var isFlipped: Bool {
        true
    }

    override func layout() {
        super.layout()

        let inset = FinderColumnMetrics.previewHorizontalInset
        separator.frame = NSRect(x: 0, y: 0, width: 1, height: bounds.height)

        let contentX = inset
        let contentWidth = max(0, bounds.width - inset * 2)
        let imageHeight = max(
            140,
            min(bounds.height * 0.42, bounds.height - 210)
        )
        imageContainer = NSRect(
            x: contentX,
            y: 24,
            width: contentWidth,
            height: max(80, imageHeight)
        )
        layoutPreviewImage()

        let titleY = imageContainer.maxY + 18
        titleField.frame = NSRect(x: contentX, y: titleY, width: contentWidth, height: 20)
        subtitleField.frame = NSRect(x: contentX, y: titleY + 22, width: contentWidth, height: 18)
        infoTitleField.frame = NSRect(x: contentX, y: titleY + 58, width: contentWidth, height: 20)
        layoutInfoRow(
            labelField: modifiedLabelField,
            valueField: modifiedValueField,
            y: titleY + 86,
            contentX: contentX,
            contentWidth: contentWidth
        )
        layoutInfoRow(
            labelField: sizeLabelField,
            valueField: sizeValueField,
            y: titleY + 114,
            contentX: contentX,
            contentWidth: contentWidth
        )

        moreButton.frame = NSRect(
            x: max(contentX, bounds.midX - 14),
            y: max(titleY + 150, bounds.height - 72),
            width: 28,
            height: 28
        )
        moreField.frame = NSRect(
            x: contentX,
            y: moreButton.frame.maxY + 2,
            width: contentWidth,
            height: 18
        )

        requestThumbnailIfNeeded()
    }

    func cancelThumbnail() {
        thumbnailToken?.cancel()
        thumbnailToken = nil
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        separator.boxType = .separator

        imageView.imageScaling = .scaleProportionallyUpOrDown

        titleField.stringValue = FinderListFormatters.displayName(for: entry)
        titleField.font = .systemFont(ofSize: 14, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.alignment = .center

        subtitleField.stringValue = [
            FinderListFormatters.kindDisplayText(for: entry),
            FinderListFormatters.sizeDisplayText(isDirectory: entry.isDirectory, size: entry.size)
        ].filter { !$0.isEmpty }.joined(separator: " - ")
        subtitleField.font = .systemFont(ofSize: 12)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.lineBreakMode = .byTruncatingMiddle
        subtitleField.alignment = .center

        infoTitleField.font = .systemFont(ofSize: 13, weight: .semibold)
        modifiedLabelField.font = .systemFont(ofSize: 12, weight: .medium)
        modifiedLabelField.textColor = .secondaryLabelColor
        modifiedValueField.stringValue = FinderListFormatters.dateDisplayText(isoString: entry.modifiedAt)
        modifiedValueField.font = .systemFont(ofSize: 12)
        modifiedValueField.alignment = .right
        modifiedValueField.lineBreakMode = .byTruncatingMiddle
        sizeLabelField.font = .systemFont(ofSize: 12, weight: .medium)
        sizeLabelField.textColor = .secondaryLabelColor
        sizeValueField.stringValue = FinderListFormatters.sizeDisplayText(isDirectory: entry.isDirectory, size: entry.size)
        sizeValueField.font = .systemFont(ofSize: 12)
        sizeValueField.alignment = .right
        sizeValueField.lineBreakMode = .byTruncatingMiddle
        moreButton.isBordered = false
        moreField.font = .systemFont(ofSize: 12)
        moreField.textColor = .secondaryLabelColor
        moreField.alignment = .center

        [
            separator,
            imageView,
            titleField,
            subtitleField,
            infoTitleField,
            modifiedLabelField,
            modifiedValueField,
            sizeLabelField,
            sizeValueField,
            moreButton,
            moreField
        ].forEach(addSubview)
    }

    private func layoutInfoRow(
        labelField: NSTextField,
        valueField: NSTextField,
        y: CGFloat,
        contentX: CGFloat,
        contentWidth: CGFloat
    ) {
        labelField.frame = NSRect(x: contentX, y: y, width: 70, height: 18)
        valueField.frame = NSRect(
            x: contentX + 78,
            y: y,
            width: max(0, contentWidth - 78),
            height: 18
        )
    }

    private func showFallbackIcon() {
        let icon = NSWorkspace.shared.icon(forFile: entry.path)
        icon.size = NSSize(
            width: FinderColumnMetrics.previewFallbackIconSize,
            height: FinderColumnMetrics.previewFallbackIconSize
        )
        imageMaximumScale = 1
        imageView.image = icon
        layoutPreviewImage()
    }

    private func showThumbnail(_ image: NSImage) {
        imageMaximumScale = .greatestFiniteMagnitude
        imageView.image = image
        layoutPreviewImage()
    }

    private func layoutPreviewImage() {
        guard let image = imageView.image else {
            imageView.frame = .zero
            return
        }

        imageView.frame = FinderPreviewImageLayout.aspectFitRect(
            imageSize: image.size,
            container: imageContainer,
            maximumScale: imageMaximumScale
        )
    }

    private func requestThumbnailIfNeeded() {
        guard imageContainer.width > 0, imageContainer.height > 0 else {
            return
        }

        let descriptor = ThumbnailDescriptor(
            entry: entry,
            pointSize: CGSize(
                width: max(FinderColumnMetrics.previewImageMinWidth, imageContainer.width),
                height: max(FinderColumnMetrics.previewImageMinHeight, imageContainer.height)
            ),
            scale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2,
            purpose: .columnPreview
        )
        guard shouldRequestThumbnail(next: descriptor) else {
            return
        }

        thumbnailToken?.cancel()
        currentDescriptor = descriptor

        if let cachedImage = thumbnailProvider.cachedThumbnail(for: descriptor) {
            thumbnailToken = nil
            showThumbnail(cachedImage)
            return
        }

        thumbnailToken = thumbnailProvider.thumbnail(for: descriptor) { [weak self] image in
            guard let self,
                  self.currentDescriptor == descriptor,
                  let image
            else {
                return
            }

            self.showThumbnail(image)
        }
    }

    private func shouldRequestThumbnail(next descriptor: ThumbnailDescriptor) -> Bool {
        guard let current = currentDescriptor else {
            return true
        }

        guard current.path == descriptor.path,
              current.modifiedAt == descriptor.modifiedAt,
              current.size == descriptor.size,
              current.scale == descriptor.scale,
              current.purpose == descriptor.purpose
        else {
            return true
        }

        return abs(current.pointSize.width - descriptor.pointSize.width) > FinderColumnMetrics.previewResizeRequestThreshold
            || abs(current.pointSize.height - descriptor.pointSize.height) > FinderColumnMetrics.previewResizeRequestThreshold
    }

    var previewImageForTesting: NSImage? {
        imageView.image
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
        translatesAutoresizingMaskIntoConstraints = true

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
