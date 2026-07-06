import AppKit
import XCTest
@testable import MacOS

final class FinderDragItemTests: XCTestCase {
    func testJSONRoundTripPreservesDragItemPayload() throws {
        let item = FinderDragItem(
            connectionId: "conn-1",
            path: "bucket/folder/report.txt",
            name: "report.txt",
            isDirectory: false
        )

        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(FinderDragItem.self, from: data)

        XCTAssertEqual(decoded, item)
    }

    func testPasteboardItemRoundTripUsesTerminalFinderEntryType() throws {
        let item = FinderDragItem(
            connectionId: nil,
            path: "/workspace/folder",
            name: "folder",
            isDirectory: true
        )

        let pasteboardItem = try item.makePasteboardItem()
        let decoded = FinderDragItem(pasteboardItem: pasteboardItem)

        XCTAssertEqual(
            pasteboardItem.availableType(from: [.terminalFinderEntry]),
            .terminalFinderEntry
        )
        XCTAssertEqual(decoded, item)
    }

    func testPasteboardItemWithoutCustomTypeReturnsNil() {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString("/workspace/file.txt", forType: .fileURL)

        XCTAssertNil(FinderDragItem(pasteboardItem: pasteboardItem))
    }
}
