//
//  FinderDragItem.swift
//  MacOS
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FinderDragItem: Codable, Equatable, Transferable {
    static let typeIdentifier = "com.terminalfinder.entry"

    let connectionId: String?
    let path: String
    let name: String
    let isDirectory: Bool

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .terminalFinderEntry)
    }

    init(
        connectionId: String?,
        path: String,
        name: String,
        isDirectory: Bool
    ) {
        self.connectionId = connectionId
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
    }

    init?(pasteboardItem: NSPasteboardItem) {
        guard let data = pasteboardItem.data(forType: .terminalFinderEntry),
              let item = try? JSONDecoder().decode(Self.self, from: data)
        else {
            return nil
        }

        self = item
    }

    func makePasteboardItem() throws -> NSPasteboardItem {
        let item = FinderDragPasteboardItem()
        let data = try JSONEncoder().encode(self)
        guard item.setData(data, forType: .terminalFinderEntry) else {
            throw FinderDragItemError.pasteboardWriteFailed
        }

        return item
    }
}

private final class FinderDragPasteboardItem: NSPasteboardItem {
    override func availableType(
        from types: [NSPasteboard.PasteboardType]
    ) -> NSPasteboard.PasteboardType? {
        if types.contains(.terminalFinderEntry),
           data(forType: .terminalFinderEntry) != nil {
            return .terminalFinderEntry
        }

        return super.availableType(from: types)
    }
}

extension UTType {
    static let terminalFinderEntry = UTType(exportedAs: FinderDragItem.typeIdentifier)
}

extension NSPasteboard.PasteboardType {
    static let terminalFinderEntry = NSPasteboard.PasteboardType(FinderDragItem.typeIdentifier)
}

private enum FinderDragItemError: LocalizedError {
    case pasteboardWriteFailed

    var errorDescription: String? {
        "Unable to write Terminal Finder drag payload."
    }
}

enum FinderMoveDropGuard {
    static func canMove(
        _ item: FinderDragItem,
        intoDirectory targetDirectory: String,
        targetConnectionId: String?
    ) -> Bool {
        guard item.connectionId == targetConnectionId else {
            return false
        }

        if item.isDirectory,
           isDirectoryMoveIntoSelfOrDescendant(source: item.path, targetDirectory: targetDirectory) {
            return false
        }

        return normalizedDirectoryPath(parentDirectory(of: item.path)) != normalizedDirectoryPath(targetDirectory)
    }

    private static func parentDirectory(of itemPath: String) -> String {
        guard !itemPath.isEmpty else {
            return ""
        }

        if itemPath.hasPrefix("/") {
            let parent = (itemPath as NSString).deletingLastPathComponent
            return parent == "." ? "" : parent
        }

        guard let slashIndex = itemPath.lastIndex(of: "/") else {
            return ""
        }

        if slashIndex == itemPath.startIndex {
            return ""
        }

        return String(itemPath[..<slashIndex])
    }

    private static func isDirectoryMoveIntoSelfOrDescendant(
        source: String,
        targetDirectory: String
    ) -> Bool {
        let normalizedSource = normalizedDirectoryPath(source)
        let normalizedTarget = normalizedDirectoryPath(targetDirectory)

        guard !normalizedSource.isEmpty else {
            return normalizedTarget.isEmpty
        }

        return normalizedTarget == normalizedSource
            || normalizedTarget.hasPrefix("\(normalizedSource)/")
    }

    private static func normalizedDirectoryPath(_ value: String) -> String {
        var path = value
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }

        return path
    }
}
