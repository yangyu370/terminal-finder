import AppKit
import XCTest
@testable import MacOS

final class ThumbnailProviderTests: XCTestCase {
    func testDescriptorEqualityUsesFileIdentitySizeScaleAndPurpose() {
        let base = ThumbnailDescriptor(
            path: "/tmp/report.pdf",
            modifiedAt: "2026-06-13T10:00:00Z",
            size: 42,
            pointSize: CGSize(width: 320.2, height: 240.4),
            scale: 2,
            purpose: .galleryPreview
        )

        XCTAssertEqual(
            base,
            ThumbnailDescriptor(
                path: "/tmp/report.pdf",
                modifiedAt: "2026-06-13T10:00:00Z",
                size: 42,
                pointSize: CGSize(width: 320.4, height: 240.4),
                scale: 2,
                purpose: .galleryPreview
            )
        )
        XCTAssertNotEqual(
            base,
            ThumbnailDescriptor(
                path: "/tmp/report.pdf",
                modifiedAt: "2026-06-13T10:00:01Z",
                size: 42,
                pointSize: CGSize(width: 320.2, height: 240.4),
                scale: 2,
                purpose: .galleryPreview
            )
        )
        XCTAssertNotEqual(
            base,
            ThumbnailDescriptor(
                path: "/tmp/report.pdf",
                modifiedAt: "2026-06-13T10:00:00Z",
                size: 42,
                pointSize: CGSize(width: 340, height: 240),
                scale: 2,
                purpose: .galleryPreview
            )
        )
        XCTAssertNotEqual(
            base,
            ThumbnailDescriptor(
                path: "/tmp/report.pdf",
                modifiedAt: "2026-06-13T10:00:00Z",
                size: 42,
                pointSize: CGSize(width: 320.2, height: 240.4),
                scale: 1,
                purpose: .galleryPreview
            )
        )
        XCTAssertNotEqual(
            base,
            ThumbnailDescriptor(
                path: "/tmp/report.pdf",
                modifiedAt: "2026-06-13T10:00:00Z",
                size: 42,
                pointSize: CGSize(width: 320.2, height: 240.4),
                scale: 2,
                purpose: .columnPreview
            )
        )
    }

    func testSharedRequestCancelingOneTokenKeepsOtherCallback() async {
        let descriptor = makeDescriptor()
        let image = NSImage(size: NSSize(width: 12, height: 10))
        var pendingCompletions: [(NSImage?) -> Void] = []
        var generationCount = 0
        var cancelCount = 0
        let provider = QuickLookThumbnailProvider { _, completion in
            generationCount += 1
            pendingCompletions.append(completion)
            return ThumbnailGenerationToken {
                cancelCount += 1
            }
        }

        let canceledExpectation = expectation(description: "Canceled callback should not run")
        canceledExpectation.isInverted = true
        let deliveredExpectation = expectation(description: "Active callback should run")

        let token = provider.thumbnail(for: descriptor) { _ in
            canceledExpectation.fulfill()
        }
        provider.thumbnail(for: descriptor) { result in
            XCTAssertNotNil(result)
            deliveredExpectation.fulfill()
        }

        XCTAssertEqual(generationCount, 1)
        XCTAssertEqual(pendingCompletions.count, 1)

        token.cancel()
        pendingCompletions[0](image)

        await fulfillment(of: [canceledExpectation, deliveredExpectation], timeout: 1)
        XCTAssertEqual(cancelCount, 0)
        XCTAssertNotNil(provider.cachedThumbnail(for: descriptor))
    }

    func testCancelingAllSharedTokensCancelsGenerationAndSuppressesCallbacks() async {
        let descriptor = makeDescriptor()
        var pendingCompletions: [(NSImage?) -> Void] = []
        var cancelCount = 0
        let provider = QuickLookThumbnailProvider { _, completion in
            pendingCompletions.append(completion)
            return ThumbnailGenerationToken {
                cancelCount += 1
            }
        }

        let firstExpectation = expectation(description: "First callback should not run")
        firstExpectation.isInverted = true
        let secondExpectation = expectation(description: "Second callback should not run")
        secondExpectation.isInverted = true

        let firstToken = provider.thumbnail(for: descriptor) { _ in
            firstExpectation.fulfill()
        }
        let secondToken = provider.thumbnail(for: descriptor) { _ in
            secondExpectation.fulfill()
        }

        firstToken.cancel()
        secondToken.cancel()
        XCTAssertEqual(cancelCount, 1)

        pendingCompletions[0](NSImage(size: NSSize(width: 10, height: 10)))
        await fulfillment(of: [firstExpectation, secondExpectation], timeout: 0.2)
        XCTAssertNil(provider.cachedThumbnail(for: descriptor))
    }

    func testCachedThumbnailStillCallsCompletionAsynchronouslyAndCanBeCanceled() async {
        let descriptor = makeDescriptor()
        let image = NSImage(size: NSSize(width: 20, height: 20))
        var pendingCompletions: [(NSImage?) -> Void] = []
        let provider = QuickLookThumbnailProvider { _, completion in
            pendingCompletions.append(completion)
            return ThumbnailGenerationToken()
        }

        let warmExpectation = expectation(description: "Warm cache")
        provider.thumbnail(for: descriptor) { _ in
            warmExpectation.fulfill()
        }
        pendingCompletions[0](image)
        await fulfillment(of: [warmExpectation], timeout: 1)

        let cachedExpectation = expectation(description: "Canceled cached callback should not run")
        cachedExpectation.isInverted = true
        let token = provider.thumbnail(for: descriptor) { _ in
            cachedExpectation.fulfill()
        }
        token.cancel()

        await fulfillment(of: [cachedExpectation], timeout: 0.2)
    }

    private func makeDescriptor() -> ThumbnailDescriptor {
        ThumbnailDescriptor(
            path: "/tmp/image.png",
            modifiedAt: "2026-06-13T10:00:00Z",
            size: 128,
            pointSize: CGSize(width: 320, height: 240),
            scale: 2,
            purpose: .galleryPreview
        )
    }
}
