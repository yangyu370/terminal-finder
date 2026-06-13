import XCTest
@testable import MacOS

final class FinderPreviewImageLayoutTests: XCTestCase {
    func testAspectFitRectFitsWideImageWithoutCropping() {
        let container = CGRect(x: 10, y: 20, width: 300, height: 200)
        let rect = FinderPreviewImageLayout.aspectFitRect(
            imageSize: CGSize(width: 600, height: 300),
            container: container
        )

        XCTAssertEqual(rect.width, 300)
        XCTAssertEqual(rect.height, 150)
        XCTAssertTrue(container.contains(rect))
        XCTAssertEqual(rect.midX, container.midX, accuracy: 0.5)
        XCTAssertEqual(rect.midY, container.midY, accuracy: 0.5)
    }

    func testAspectFitRectFitsTallImageWithoutCropping() {
        let container = CGRect(x: 0, y: 0, width: 300, height: 200)
        let rect = FinderPreviewImageLayout.aspectFitRect(
            imageSize: CGSize(width: 200, height: 600),
            container: container
        )

        XCTAssertEqual(rect.width, 67, accuracy: 1)
        XCTAssertEqual(rect.height, 200)
        XCTAssertGreaterThanOrEqual(rect.minX, container.minX)
        XCTAssertGreaterThanOrEqual(rect.minY, container.minY)
        XCTAssertLessThanOrEqual(rect.maxX, container.maxX)
        XCTAssertLessThanOrEqual(rect.maxY, container.maxY)
    }

    func testAspectFitRectFitsSquareImageAndHonorsMaximumScale() {
        let container = CGRect(x: 0, y: 0, width: 300, height: 200)
        let rect = FinderPreviewImageLayout.aspectFitRect(
            imageSize: CGSize(width: 50, height: 50),
            container: container,
            maximumScale: 2
        )

        XCTAssertEqual(rect.width, 100)
        XCTAssertEqual(rect.height, 100)
        XCTAssertTrue(container.contains(rect))
    }

    func testAspectFitRectHandlesEmptyOrInvalidSizes() {
        let container = CGRect(x: 0, y: 0, width: 300, height: 200)
        let emptyImageRect = FinderPreviewImageLayout.aspectFitRect(
            imageSize: .zero,
            container: container
        )
        let emptyContainerRect = FinderPreviewImageLayout.aspectFitRect(
            imageSize: CGSize(width: 100, height: 100),
            container: .zero
        )
        let invalidRect = FinderPreviewImageLayout.aspectFitRect(
            imageSize: CGSize(width: CGFloat.nan, height: 100),
            container: container
        )

        for rect in [emptyImageRect, emptyContainerRect, invalidRect] {
            XCTAssertEqual(rect.width, 0)
            XCTAssertEqual(rect.height, 0)
            XCTAssertTrue(rect.origin.x.isFinite)
            XCTAssertTrue(rect.origin.y.isFinite)
        }
    }
}
