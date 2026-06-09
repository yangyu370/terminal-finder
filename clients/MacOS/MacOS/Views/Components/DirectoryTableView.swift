//
//  DirectoryTableView.swift
//  MacOS
//
//  Created by Codex on 2026/6/3.
//

import AppKit
import SwiftUI

struct DirectoryTableView: NSViewRepresentable {
    let entries: [DirectoryEntry]
    let selectedPath: String?
    let onSelect: (String?) -> Void
    let onOpen: (DirectoryEntry) -> Void
    let loadChildren: (String) async throws -> [DirectoryEntry]

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect, onOpen: onOpen, loadChildren: loadChildren)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outlineView = NSOutlineView()
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.rowHeight = 32
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.gridStyleMask = []
        outlineView.backgroundColor = .clear
        outlineView.selectionHighlightStyle = .regular
        outlineView.indentationPerLevel = 14
        outlineView.autoresizesOutlineColumn = false
        if #available(macOS 11.0, *) {
            outlineView.style = .inset
        }
        outlineView.headerView = NSTableHeaderView()
        outlineView.target = context.coordinator
        outlineView.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        outlineView.delegate = context.coordinator
        outlineView.dataSource = context.coordinator

        let nameColumn = NSTableColumn(identifier: Column.name.identifier)
        nameColumn.title = "Name"
        nameColumn.minWidth = 220
        nameColumn.width = 360
        outlineView.addTableColumn(nameColumn)
        outlineView.outlineTableColumn = nameColumn

        let kindColumn = NSTableColumn(identifier: Column.kind.identifier)
        kindColumn.title = "Kind"
        kindColumn.minWidth = 90
        kindColumn.width = 120
        outlineView.addTableColumn(kindColumn)

        let modifiedColumn = NSTableColumn(identifier: Column.modified.identifier)
        modifiedColumn.title = "Date Modified"
        modifiedColumn.minWidth = 140
        modifiedColumn.width = 180
        outlineView.addTableColumn(modifiedColumn)

        let sizeColumn = NSTableColumn(identifier: Column.size.identifier)
        sizeColumn.title = "Size"
        sizeColumn.minWidth = 80
        sizeColumn.width = 96
        outlineView.addTableColumn(sizeColumn)

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = outlineView

        context.coordinator.outlineView = outlineView
        context.coordinator.rebuildRoots(with: entries)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.onOpen = onOpen
        context.coordinator.loadChildren = loadChildren

        guard let outlineView = scrollView.documentView as? NSOutlineView else {
            return
        }

        context.coordinator.isApplyingSelection = true
        defer {
            context.coordinator.isApplyingSelection = false
        }

        // Only rebuild the tree (and collapse everything) when the top-level
        // listing actually changes — e.g. navigating or refreshing. Pure
        // selection updates must preserve the user's expanded folders.
        if context.coordinator.topLevelSignature(for: entries) != context.coordinator.currentSignature {
            context.coordinator.rebuildRoots(with: entries)
        }

        applySelection(on: outlineView, coordinator: context.coordinator)
    }

    private func applySelection(on outlineView: NSOutlineView, coordinator: Coordinator) {
        guard let selectedPath,
              let node = coordinator.findNode(path: selectedPath) else {
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

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var onSelect: (String?) -> Void
        var onOpen: (DirectoryEntry) -> Void
        var loadChildren: (String) async throws -> [DirectoryEntry]
        var isApplyingSelection = false
        weak var outlineView: NSOutlineView?

        private(set) var currentSignature: [String] = []
        private var rootNodes: [OutlineNode] = []

        init(
            onSelect: @escaping (String?) -> Void,
            onOpen: @escaping (DirectoryEntry) -> Void,
            loadChildren: @escaping (String) async throws -> [DirectoryEntry]
        ) {
            self.onSelect = onSelect
            self.onOpen = onOpen
            self.loadChildren = loadChildren
        }

        func topLevelSignature(for entries: [DirectoryEntry]) -> [String] {
            entries.map(\.path)
        }

        func rebuildRoots(with entries: [DirectoryEntry]) {
            rootNodes = entries.map { OutlineNode(entry: $0) }
            currentSignature = topLevelSignature(for: entries)
            outlineView?.reloadData()
        }

        fileprivate func findNode(path: String) -> OutlineNode? {
            func search(_ nodes: [OutlineNode]) -> OutlineNode? {
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

        // MARK: - Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? OutlineNode else {
                return rootNodes.count
            }

            if let children = node.children {
                return children.count
            }

            // Directory whose children have not been loaded yet: keep a single
            // placeholder row so the disclosure triangle stays available and a
            // "Loading…" hint appears while fetching.
            return node.isDirectory ? 1 : 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? OutlineNode else {
                return rootNodes[index]
            }

            if let children = node.children {
                return children[index]
            }

            return node.placeholder
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? OutlineNode else {
                return false
            }

            return node.isDirectory
        }

        func outlineViewItemWillExpand(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? OutlineNode,
                  node.isDirectory,
                  node.children == nil,
                  !node.isLoading else {
                return
            }

            node.isLoading = true
            let path = node.entry.path

            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                do {
                    let entries = try await self.loadChildren(path)
                    node.children = entries.map { OutlineNode(entry: $0) }
                } catch {
                    node.children = []
                }

                node.isLoading = false
                self.reloadExpanded(node)
            }
        }

        private func reloadExpanded(_ node: OutlineNode) {
            guard let outlineView, outlineView.row(forItem: node) >= 0 else {
                return
            }

            outlineView.reloadItem(node, reloadChildren: true)
            outlineView.expandItem(node)
        }

        // MARK: - Delegate

        func outlineView(
            _ outlineView: NSOutlineView,
            viewFor tableColumn: NSTableColumn?,
            item: Any
        ) -> NSView? {
            guard let column = Column(identifier: tableColumn?.identifier) else {
                return nil
            }

            if item is LoadingPlaceholder {
                return column == .name ? makeTextCell(text: "Loading…", alignment: .left) : NSView()
            }

            guard let node = item as? OutlineNode else {
                return nil
            }

            let entry = node.entry
            switch column {
            case .name:
                return makeNameCell(entry: entry)
            case .kind:
                return makeTextCell(text: entry.kind.displayName, alignment: .left)
            case .modified:
                return makeTextCell(text: entry.modifiedAt?.finderDisplayDate ?? "--", alignment: .left)
            case .size:
                return makeTextCell(text: entry.displaySize, alignment: .right)
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

            let selectedRow = outlineView.selectedRow
            guard selectedRow >= 0,
                  let node = outlineView.item(atRow: selectedRow) as? OutlineNode else {
                onSelect(nil)
                return
            }

            onSelect(node.entry.path)
        }

        @objc func handleDoubleClick(_ sender: NSOutlineView) {
            let row = sender.clickedRow >= 0 ? sender.clickedRow : sender.selectedRow
            guard row >= 0,
                  let node = sender.item(atRow: row) as? OutlineNode else {
                return
            }

            onOpen(node.entry)
        }

        private func makeNameCell(entry: DirectoryEntry) -> NSTableCellView {
            let cell = NameCell()
            let icon = entry.iconAppearance
            cell.normalTintColor = icon.color

            let imageView = NSImageView()
            imageView.image = icon.image
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.contentTintColor = icon.color
            imageView.translatesAutoresizingMaskIntoConstraints = false

            let textField = NSTextField(labelWithString: entry.name)
            textField.font = .systemFont(ofSize: 13)
            textField.lineBreakMode = .byTruncatingMiddle
            textField.translatesAutoresizingMaskIntoConstraints = false

            cell.addSubview(imageView)
            cell.addSubview(textField)
            cell.imageView = imageView
            cell.textField = textField

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 20),
                imageView.heightAnchor.constraint(equalToConstant: 20),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])

            return cell
        }

        private func makeTextCell(text: String, alignment: NSTextAlignment) -> NSTableCellView {
            let cell = SecondaryTextCell()
            let textField = NSTextField(labelWithString: text)
            textField.font = .systemFont(ofSize: 13)
            textField.alignment = alignment
            textField.textColor = .secondaryLabelColor
            textField.lineBreakMode = .byTruncatingTail
            textField.translatesAutoresizingMaskIntoConstraints = false

            cell.addSubview(textField)
            cell.textField = textField

            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])

            return cell
        }
    }
}

/// A node in the directory outline tree. `children == nil` means the folder's
/// contents have not been fetched yet; an empty array means it was loaded and
/// is empty.
private final class OutlineNode {
    let entry: DirectoryEntry
    var children: [OutlineNode]?
    var isLoading = false
    private(set) lazy var placeholder = LoadingPlaceholder()

    init(entry: DirectoryEntry) {
        self.entry = entry
    }

    var isDirectory: Bool {
        entry.isDirectory
    }
}

/// Sentinel row shown under a folder while its children are being fetched.
private final class LoadingPlaceholder {}

/// Name-column cell that flips its icon tint to white while the row is selected.
private final class NameCell: NSTableCellView {
    var normalTintColor: NSColor = .secondaryLabelColor

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            imageView?.contentTintColor = backgroundStyle == .emphasized
                ? .alternateSelectedControlTextColor
                : normalTintColor
        }
    }
}

/// Secondary text cell that flips its label to white while the row is selected.
private final class SecondaryTextCell: NSTableCellView {
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            textField?.textColor = backgroundStyle == .emphasized
                ? .alternateSelectedControlTextColor
                : .secondaryLabelColor
        }
    }
}

private enum Column {
    case name
    case kind
    case modified
    case size

    var identifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(rawValue: rawValue)
    }

    init?(identifier: NSUserInterfaceItemIdentifier?) {
        guard let identifier,
              let column = Column(rawValue: identifier.rawValue)
        else {
            return nil
        }

        self = column
    }

    private var rawValue: String {
        switch self {
        case .name:
            return "name"
        case .kind:
            return "kind"
        case .modified:
            return "modified"
        case .size:
            return "size"
        }
    }

    private init?(rawValue: String) {
        switch rawValue {
        case "name":
            self = .name
        case "kind":
            self = .kind
        case "modified":
            self = .modified
        case "size":
            self = .size
        default:
            return nil
        }
    }
}

private struct IconAppearance {
    let image: NSImage?
    let color: NSColor
}

private extension DirectoryEntry {
    var iconAppearance: IconAppearance {
        let symbolName: String
        let color: NSColor

        switch kind {
        case .directory:
            symbolName = "folder.fill"
            color = .controlAccentColor
        case .symlink:
            symbolName = "arrowshape.turn.up.right.fill"
            color = .systemTeal
        case .other:
            symbolName = "questionmark.square.fill"
            color = .systemGray
        case .file:
            let descriptor = Self.descriptor(forExtension: (name as NSString).pathExtension.lowercased())
            symbolName = descriptor.symbol
            color = descriptor.color
        }

        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        return IconAppearance(image: image, color: color)
    }

    private static func descriptor(forExtension ext: String) -> (symbol: String, color: NSColor) {
        switch ext {
        case "doc", "docx", "pages", "rtf":
            return ("doc.text.fill", .systemBlue)
        case "xls", "xlsx", "csv", "numbers":
            return ("tablecells.fill", .systemGreen)
        case "ppt", "pptx", "key":
            return ("rectangle.on.rectangle.angled.fill", .systemOrange)
        case "pdf":
            return ("doc.richtext.fill", .systemRed)
        case "txt", "md", "markdown", "log":
            return ("doc.plaintext.fill", .systemGray)
        case "swift":
            return ("swift", .systemOrange)
        case "py", "rs", "go", "c", "h", "cpp", "java", "js", "ts", "rb", "sh", "json", "yaml", "yml", "toml":
            return ("chevron.left.forwardslash.chevron.right", .systemPurple)
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp", "svg":
            return ("photo.fill", .systemTeal)
        case "mp4", "mov", "avi", "mkv", "m4v":
            return ("film.fill", .systemPink)
        case "mp3", "wav", "aac", "flac", "m4a":
            return ("music.note", .systemPink)
        case "zip", "tar", "gz", "rar", "7z":
            return ("doc.zipper", .systemBrown)
        case "dmg", "iso", "img":
            return ("externaldrive.fill", .systemGray)
        case "app":
            return ("app.fill", .systemBlue)
        default:
            return ("doc.fill", .secondaryLabelColor)
        }
    }

    var displaySize: String {
        if isDirectory {
            return "--"
        }

        guard let size else {
            return kind.displayName
        }

        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

private extension EntryKind {
    var displayName: String {
        switch self {
        case .directory:
            return "Folder"
        case .file:
            return "File"
        case .symlink:
            return "Alias"
        case .other:
            return "Other"
        }
    }
}

private enum FinderDateFormatter {
    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("HHmm")
        return formatter
    }()

    private static let monthDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMMd HHmm")
        return formatter
    }()

    private static let fullDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("yMMMd HHmm")
        return formatter
    }()

    static func display(_ raw: String) -> String {
        guard let date = isoFractional.date(from: raw) ?? iso.date(from: raw) else {
            return raw.replacingOccurrences(of: "T", with: " ")
                .replacingOccurrences(of: "Z", with: "")
        }

        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return String(format: NSLocalizedString("Today %@", comment: ""), time.string(from: date))
        }
        if calendar.isDateInYesterday(date) {
            return String(format: NSLocalizedString("Yesterday %@", comment: ""), time.string(from: date))
        }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return monthDay.string(from: date)
        }
        return fullDate.string(from: date)
    }
}

private extension String {
    var finderDisplayDate: String {
        FinderDateFormatter.display(self)
    }
}
