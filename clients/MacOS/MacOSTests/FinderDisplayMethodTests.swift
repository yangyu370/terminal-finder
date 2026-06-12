import XCTest
@testable import MacOS

final class FinderDisplayMethodTests: XCTestCase {
    func testDisplayModesMatchToolbarSegmentIndexes() {
        XCTAssertEqual(FinderDisplayMode.icon.segmentIndex, 0)
        XCTAssertEqual(FinderDisplayMode.list.segmentIndex, 1)
        XCTAssertEqual(FinderDisplayMode.column.segmentIndex, 2)
        XCTAssertEqual(FinderDisplayMode.gallery.segmentIndex, 3)

        XCTAssertEqual(FinderDisplayMode(segmentIndex: 0), .icon)
        XCTAssertEqual(FinderDisplayMode(segmentIndex: 1), .list)
        XCTAssertEqual(FinderDisplayMode(segmentIndex: 2), .column)
        XCTAssertEqual(FinderDisplayMode(segmentIndex: 3), .gallery)
        XCTAssertNil(FinderDisplayMode(segmentIndex: 4))
    }

    @MainActor
    func testDisplayModeStateOnlySelectsImplementedModes() {
        let state = FinderDisplayModeState()

        XCTAssertEqual(state.mode, .list)

        state.select(.icon)
        XCTAssertEqual(state.mode, .icon)

        state.select(.column)
        XCTAssertEqual(state.mode, .column)

        state.select(.gallery)
        XCTAssertEqual(state.mode, .column)

        state.select(.list)
        XCTAssertEqual(state.mode, .list)
    }

    func testIconGridMetricsUseFinderLikeCells() {
        XCTAssertEqual(FinderIconGridMetrics.iconSize, 64)
        XCTAssertGreaterThan(FinderIconGridMetrics.itemWidth, FinderIconGridMetrics.iconSize)
        XCTAssertGreaterThan(FinderIconGridMetrics.itemHeight, FinderIconGridMetrics.iconSize)
        XCTAssertEqual(FinderIconGridMetrics.sectionInset.top, 18)
        XCTAssertEqual(FinderIconGridMetrics.sectionInset.left, 20)
    }
}
