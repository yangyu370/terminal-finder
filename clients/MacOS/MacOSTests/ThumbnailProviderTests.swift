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

    func testCachedThumbnailCompletionRunsWhenTokenIsNotRetained() async {
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

        let cachedExpectation = expectation(description: "Cached callback should run")
        provider.thumbnail(for: descriptor) { result in
            XCTAssertNotNil(result)
            cachedExpectation.fulfill()
        }

        await fulfillment(of: [cachedExpectation], timeout: 1)
    }

    func testDistinctRequestsAreCappedByMaxConcurrentGenerationCount() async {
        let first = makeDescriptor(path: "/tmp/first.png")
        let second = makeDescriptor(path: "/tmp/second.png")
        let image = NSImage(size: NSSize(width: 20, height: 20))
        var pendingCompletions: [(NSImage?) -> Void] = []
        var generatedPaths: [String] = []
        let provider = QuickLookThumbnailProvider(maxConcurrentRequests: 1) { descriptor, completion in
            generatedPaths.append(descriptor.path)
            pendingCompletions.append(completion)
            return ThumbnailGenerationToken()
        }

        let firstExpectation = expectation(description: "First callback")
        let secondExpectation = expectation(description: "Second callback")

        provider.thumbnail(for: first) { _ in
            firstExpectation.fulfill()
        }
        provider.thumbnail(for: second) { _ in
            secondExpectation.fulfill()
        }

        XCTAssertEqual(generatedPaths, [first.path])

        pendingCompletions[0](image)
        await fulfillment(of: [firstExpectation], timeout: 1)
        XCTAssertEqual(generatedPaths, [first.path, second.path])

        pendingCompletions[1](image)
        await fulfillment(of: [secondExpectation], timeout: 1)
    }

    func testTransparentPngIsCompositedOnFixedNeutralBackground() async throws {
        let descriptor = makeDescriptor(path: "/tmp/transparent.png")
        let transparentImage = NSImage(size: NSSize(width: 4, height: 4))
        transparentImage.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill(using: .copy)
        transparentImage.unlockFocus()

        var pendingCompletions: [(NSImage?) -> Void] = []
        let provider = QuickLookThumbnailProvider { _, completion in
            pendingCompletions.append(completion)
            return ThumbnailGenerationToken()
        }
        var deliveredImage: NSImage?
        let expectation = expectation(description: "Prepared transparent image")
        provider.thumbnail(for: descriptor) { image in
            deliveredImage = image
            expectation.fulfill()
        }
        pendingCompletions[0](transparentImage)
        await fulfillment(of: [expectation], timeout: 1)

        let prepared = try XCTUnwrap(deliveredImage)
        let color = try XCTUnwrap(colorAtOrigin(in: prepared))
        let expected = QuickLookThumbnailProvider.neutralThumbnailBackgroundColor.usingColorSpace(.genericRGB)
        XCTAssertEqual(color.redComponent, expected?.redComponent ?? 0, accuracy: 0.02)
        XCTAssertEqual(color.greenComponent, expected?.greenComponent ?? 0, accuracy: 0.02)
        XCTAssertEqual(color.blueComponent, expected?.blueComponent ?? 0, accuracy: 0.02)
        XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.01)
    }

    private func makeDescriptor(path: String = "/tmp/image.png") -> ThumbnailDescriptor {
        ThumbnailDescriptor(
            path: path,
            modifiedAt: "2026-06-13T10:00:00Z",
            size: 128,
            pointSize: CGSize(width: 320, height: 240),
            scale: 2,
            purpose: .galleryPreview
        )
    }

    private func colorAtOrigin(in image: NSImage) -> NSColor? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else {
            return nil
        }

        return bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.genericRGB)
    }
}
