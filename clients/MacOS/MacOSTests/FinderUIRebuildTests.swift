import XCTest
@testable import MacOS

final class FinderUIRebuildTests: XCTestCase {
    func testSidebarItemsMapBackendLocationsIntoFinderSections() {
        let locations = [
            WorkspaceSidebarLocation(title: "Home", systemImageName: "house", path: "/Users/mac"),
            WorkspaceSidebarLocation(title: "Desktop", systemImageName: "desktopcomputer", path: "/Users/mac/Desktop"),
            WorkspaceSidebarLocation(title: "Downloads", systemImageName: "arrow.down.circle", path: "/Users/mac/Downloads"),
            WorkspaceSidebarLocation(title: "Documents", systemImageName: "doc.text", path: "/Users/mac/Documents")
        ]

        let items = FinderSidebarItem.makeItems(from: locations)

        XCTAssertEqual(items.first { $0.id == "favorites.desktop" }?.title, "桌面")
        XCTAssertEqual(items.first { $0.id == "favorites.documents" }?.title, "文稿")
        XCTAssertEqual(items.first { $0.id == "favorites.downloads" }?.title, "下载")
        XCTAssertEqual(items.first { $0.id == "locations.home" }?.title, "mac")
        XCTAssertEqual(items.first { $0.id == "locations.home" }?.location?.path, "/Users/mac")
        XCTAssertFalse(items.first { $0.id == "general.recents" }?.isEnabled ?? true)
        XCTAssertFalse(items.contains { $0.group == .tags })
        XCTAssertFalse(items.contains { $0.id.hasPrefix("tags.") })
    }

    func testFinderListFormattersMatchFinderStylePlaceholders() {
        XCTAssertEqual(FinderListFormatters.placeholderText, "--")
        XCTAssertEqual(
            FinderListFormatters.sizeDisplayText(isDirectory: true, size: nil),
            "--"
        )
        XCTAssertEqual(
            FinderListFormatters.sizeDisplayText(isDirectory: false, size: 82),
            ByteCountFormatter.string(fromByteCount: 82, countStyle: .file)
        )
        XCTAssertEqual(
            FinderListFormatters.dateDisplayText(
                isoString: "2026-06-01T07:16:00Z",
                locale: Locale(identifier: "zh_CN"),
                timeZone: TimeZone(secondsFromGMT: 8 * 60 * 60)
            ),
            "2026年6月1日 15:16"
        )
        XCTAssertFalse(
            FinderListFormatters.kindDisplayText(
                name: "Notes",
                kind: .directory,
                isDirectory: true
            ).isEmpty
        )
    }

    func testFinderListSortingUsesFinderColumnKeys() {
        let entries = [
            entry(name: "b.txt", path: "/b.txt", size: 20, modifiedAt: "2026-06-02T00:00:00Z"),
            entry(name: "a.txt", path: "/a.txt", size: 40, modifiedAt: "2026-06-01T00:00:00Z"),
            entry(name: "Folder", path: "/Folder", isDirectory: true, size: nil, modifiedAt: "2026-06-03T00:00:00Z")
        ]

        XCTAssertEqual(
            FinderListSortComparator.sorted(entries, key: .name, ascending: true).map(\.name),
            ["a.txt", "b.txt", "Folder"]
        )
        XCTAssertEqual(
            FinderListSortComparator.sorted(entries, key: .dateModified, ascending: false).map(\.name),
            ["Folder", "b.txt", "a.txt"]
        )
        XCTAssertEqual(
            FinderListSortComparator.sorted(entries, key: .size, ascending: true).map(\.name),
            ["Folder", "b.txt", "a.txt"]
        )
    }

    func testTerminalSurfaceMetricsClampToAtLeastOneCell() {
        XCTAssertEqual(
            FinderTerminalSurfaceMetrics.gridSize(for: .zero),
            FinderTerminalGridSize(cols: 1, rows: 1)
        )
        XCTAssertEqual(
            FinderTerminalSurfaceMetrics.gridSize(for: CGSize(width: 720, height: 288)),
            FinderTerminalGridSize(cols: 100, rows: 20)
        )
    }

    private func entry(
        name: String,
        path: String,
        isDirectory: Bool = false,
        size: UInt64? = nil,
        modifiedAt: String? = nil
    ) -> DirectoryEntry {
        DirectoryEntry(
            name: name,
            path: path,
            kind: isDirectory ? .directory : .file,
            isDirectory: isDirectory,
            size: size,
            modifiedAt: modifiedAt
        )
    }
}
