import XCTest
@testable import MacOS

final class FinderGalleryViewTests: XCTestCase {
    func testGalleryMetricsUseFinderLikePreviewAndFilmstrip() {
        XCTAssertEqual(FinderGalleryMetrics.previewIconSize, 260)
        XCTAssertEqual(FinderGalleryMetrics.inspectorWidth, 240)
        XCTAssertEqual(FinderGalleryMetrics.inspectorIconSize, 44)
        XCTAssertEqual(FinderGalleryMetrics.filmstripHeight, 118)
        XCTAssertEqual(FinderGalleryMetrics.filmstripIconSize, 40)
        XCTAssertGreaterThan(FinderGalleryMetrics.filmstripItemWidth, FinderGalleryMetrics.filmstripIconSize)
        XCTAssertGreaterThan(FinderGalleryMetrics.filmstripItemHeight, FinderGalleryMetrics.filmstripIconSize)
        XCTAssertEqual(FinderGalleryMetrics.filmstripSectionInset.left, 14)
        XCTAssertEqual(FinderGalleryMetrics.filmstripItemSpacing, 8)
    }
}
