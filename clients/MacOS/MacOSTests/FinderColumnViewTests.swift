import XCTest
@testable import MacOS

final class FinderColumnViewTests: XCTestCase {
    func testColumnMetricsMatchFinderStyleColumnBrowser() {
        XCTAssertEqual(FinderColumnMetrics.columnWidth, 220)
        XCTAssertEqual(FinderColumnMetrics.rowHeight, 24)
        XCTAssertEqual(FinderColumnMetrics.iconSize, 16)
    }
}
