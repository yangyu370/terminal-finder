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

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect, onOpen: onOpen)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.rowHeight = 28
        tableView.headerView = NSTableHeaderView()
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator

        let nameColumn = NSTableColumn(identifier: Column.name.identifier)
        nameColumn.title = "Name"
        nameColumn.minWidth = 220
        nameColumn.width = 320
        tableView.addTableColumn(nameColumn)

        let kindColumn = NSTableColumn(identifier: Column.kind.identifier)
        kindColumn.title = "Kind"
        kindColumn.minWidth = 90
        kindColumn.width = 110
        tableView.addTableColumn(kindColumn)

        let modifiedColumn = NSTableColumn(identifier: Column.modified.identifier)
        modifiedColumn.title = "Modified"
        modifiedColumn.minWidth = 120
        modifiedColumn.width = 150
        tableView.addTableColumn(modifiedColumn)

        let sizeColumn = NSTableColumn(identifier: Column.size.identifier)
        sizeColumn.title = "Size"
        sizeColumn.minWidth = 80
        sizeColumn.width = 96
        tableView.addTableColumn(sizeColumn)

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView

        context.coordinator.tableView = tableView
        context.coordinator.entries = entries
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.entries = entries
        context.coordinator.onSelect = onSelect
        context.coordinator.onOpen = onOpen

        guard let tableView = scrollView.documentView as? NSTableView else {
            return
        }

        context.coordinator.isApplyingSelection = true
        defer {
            context.coordinator.isApplyingSelection = false
        }

        tableView.reloadData()
        if let selectedPath,
           let selectedIndex = entries.firstIndex(where: { $0.path == selectedPath }) {
            let selectedRows = tableView.selectedRowIndexes
            if selectedRows.count != 1 || !selectedRows.contains(selectedIndex) {
                tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
            }
        } else {
            if tableView.selectedRow != -1 {
                tableView.deselectAll(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var entries: [DirectoryEntry] = []
        var onSelect: (String?) -> Void
        var onOpen: (DirectoryEntry) -> Void
        var isApplyingSelection = false
        weak var tableView: NSTableView?

        init(
            onSelect: @escaping (String?) -> Void,
            onOpen: @escaping (DirectoryEntry) -> Void
        ) {
            self.onSelect = onSelect
            self.onOpen = onOpen
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            entries.count
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard row < entries.count,
                  let column = Column(identifier: tableColumn?.identifier)
            else {
                return nil
            }

            let entry = entries[row]
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

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection else {
                return
            }

            guard let tableView else {
                onSelect(nil)
                return
            }

            let selectedRow = tableView.selectedRow
            guard selectedRow >= 0, selectedRow < entries.count else {
                onSelect(nil)
                return
            }

            onSelect(entries[selectedRow].path)
        }

        @objc func handleDoubleClick(_ sender: NSTableView) {
            let row = sender.clickedRow >= 0 ? sender.clickedRow : sender.selectedRow
            guard row >= 0, row < entries.count else {
                return
            }

            onOpen(entries[row])
        }

        private func makeNameCell(entry: DirectoryEntry) -> NSTableCellView {
            let cell = NSTableCellView()
            let imageView = NSImageView()
            imageView.image = entry.iconImage
            imageView.contentTintColor = entry.isDirectory ? .controlAccentColor : .secondaryLabelColor
            imageView.translatesAutoresizingMaskIntoConstraints = false

            let textField = NSTextField(labelWithString: entry.name)
            textField.lineBreakMode = .byTruncatingMiddle
            textField.translatesAutoresizingMaskIntoConstraints = false

            cell.addSubview(imageView)
            cell.addSubview(textField)
            cell.imageView = imageView
            cell.textField = textField

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 18),
                imageView.heightAnchor.constraint(equalToConstant: 18),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])

            return cell
        }

        private func makeTextCell(text: String, alignment: NSTextAlignment) -> NSTableCellView {
            let cell = NSTableCellView()
            let textField = NSTextField(labelWithString: text)
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

private extension DirectoryEntry {
    var iconImage: NSImage? {
        let symbolName: String
        switch kind {
        case .directory:
            symbolName = "folder"
        case .file:
            symbolName = "doc"
        case .symlink:
            symbolName = "arrowshape.turn.up.right"
        case .other:
            symbolName = "questionmark.square"
        }

        return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
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

private extension String {
    var finderDisplayDate: String {
        replacingOccurrences(of: "T", with: " ")
            .replacingOccurrences(of: "Z", with: "")
    }
}
