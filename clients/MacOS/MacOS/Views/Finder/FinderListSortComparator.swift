//
//  FinderListSortComparator.swift
//  MacOS
//
//  Created by Claude on 2026/6/11.
//

import Foundation

/// Sort keys for the directory list columns; raw values double as the
/// `NSSortDescriptor` keys configured on the table columns.
enum FinderListSortKey: String {
    case name
    case dateModified
    case size
    case kind
}

/// Client-side visual sorting of the displayed entries. Pure function over
/// the presentation array; never written back to the backend.
enum FinderListSortComparator {
    static func sorted(
        _ entries: [DirectoryEntry],
        key: FinderListSortKey,
        ascending: Bool
    ) -> [DirectoryEntry] {
        let sortedAscending: [DirectoryEntry]

        switch key {
        case .name:
            sortedAscending = entries.sorted { nameIsOrderedAscending($0, $1) }

        case .dateModified:
            sortedAscending = entries.sorted { lhs, rhs in
                let lhsDate = FinderListFormatters.parseModifiedDate(lhs.modifiedAt) ?? .distantPast
                let rhsDate = FinderListFormatters.parseModifiedDate(rhs.modifiedAt) ?? .distantPast
                guard lhsDate != rhsDate else {
                    return nameIsOrderedAscending(lhs, rhs)
                }

                return lhsDate < rhsDate
            }

        case .size:
            sortedAscending = entries.sorted { lhs, rhs in
                // Directories (shown as "--") group ahead of files.
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory
                }

                let lhsSize = lhs.isDirectory ? 0 : (lhs.size ?? 0)
                let rhsSize = rhs.isDirectory ? 0 : (rhs.size ?? 0)
                guard lhsSize != rhsSize else {
                    return nameIsOrderedAscending(lhs, rhs)
                }

                return lhsSize < rhsSize
            }

        case .kind:
            sortedAscending = entries.sorted { lhs, rhs in
                let lhsKind = FinderListFormatters.kindDisplayText(for: lhs)
                let rhsKind = FinderListFormatters.kindDisplayText(for: rhs)
                let comparison = lhsKind.localizedStandardCompare(rhsKind)
                guard comparison == .orderedSame else {
                    return comparison == .orderedAscending
                }

                return nameIsOrderedAscending(lhs, rhs)
            }
        }

        return ascending ? sortedAscending : sortedAscending.reversed()
    }

    private static func nameIsOrderedAscending(_ lhs: DirectoryEntry, _ rhs: DirectoryEntry) -> Bool {
        FinderListFormatters.displayName(for: lhs)
            .localizedStandardCompare(FinderListFormatters.displayName(for: rhs)) == .orderedAscending
    }
}
