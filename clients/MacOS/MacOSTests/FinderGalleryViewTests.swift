import XCTest
@testable import MacOS

final class FinderGalleryViewTests: XCTestCase {
    func testGalleryMetricsUseFinderLikePreviewAndFilmstrip() {
        XCTAssertEqual(FinderGalleryMetrics.previewIconSize, 260)
        XCTAssertEqual(FinderGalleryMetrics.previewContentInsetX, 32)
        XCTAssertEqual(FinderGalleryMetrics.previewContentInsetY, 28)
        XCTAssertEqual(FinderGalleryMetrics.previewMinimumThumbnailWidth, 160)
        XCTAssertEqual(FinderGalleryMetrics.previewMinimumThumbnailHeight, 120)
        XCTAssertEqual(FinderGalleryMetrics.previewResizeRequestThreshold, 16)
        XCTAssertEqual(FinderGalleryMetrics.inspectorWidth, 240)
        XCTAssertEqual(FinderGalleryMetrics.inspectorIconSize, 44)
        XCTAssertEqual(FinderGalleryMetrics.filmstripHeight, 118)
        XCTAssertEqual(FinderGalleryMetrics.filmstripIconSize, 40)
        XCTAssertGreaterThan(FinderGalleryMetrics.filmstripItemWidth, FinderGalleryMetrics.filmstripIconSize)
        XCTAssertGreaterThan(FinderGalleryMetrics.filmstripItemHeight, FinderGalleryMetrics.filmstripIconSize)
        XCTAssertEqual(FinderGalleryMetrics.filmstripSectionInset.left, 14)
        XCTAssertEqual(FinderGalleryMetrics.filmstripItemSpacing, 8)
    }

    func testGalleryCentralPreviewRequestsThumbnailForSelectedFile() {
        let provider = MockThumbnailProvider()
        let browserView = makeBrowserView(provider: provider)
        let entry = makeEntry(name: "Report.pdf", path: "/tmp/Report.pdf", isDirectory: false)

        browserView.configurePreview(entry: entry)

        XCTAssertEqual(provider.requests.count, 1)
        let descriptor = provider.requests[0].descriptor
        XCTAssertEqual(descriptor.path, entry.path)
        XCTAssertEqual(descriptor.purpose, .galleryPreview)
        XCTAssertGreaterThanOrEqual(descriptor.pointSize.width, FinderGalleryMetrics.previewMinimumThumbnailWidth)
        XCTAssertGreaterThanOrEqual(descriptor.pointSize.height, FinderGalleryMetrics.previewMinimumThumbnailHeight)
    }

    func testGalleryCentralPreviewDoesNotRequestThumbnailForDirectory() {
        let provider = MockThumbnailProvider()
        let browserView = makeBrowserView(provider: provider)
        let entry = makeEntry(name: "Folder", path: "/tmp/Folder", isDirectory: true)

        browserView.configurePreview(entry: entry)

        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testGalleryCentralPreviewCancelsOldTokenAndIgnoresStaleCompletion() {
        let provider = MockThumbnailProvider()
        let browserView = makeBrowserView(provider: provider)
        let firstEntry = makeEntry(name: "First.pdf", path: "/tmp/First.pdf", isDirectory: false)
        let secondEntry = makeEntry(name: "Second.pdf", path: "/tmp/Second.pdf", isDirectory: false)
        let staleImage = NSImage(size: NSSize(width: 80, height: 80))
        let currentImage = NSImage(size: NSSize(width: 120, height: 90))

        browserView.configurePreview(entry: firstEntry)
        browserView.configurePreview(entry: secondEntry)

        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertTrue(provider.requests[0].token.isCancelled)

        provider.completeRequest(at: 0, image: staleImage)
        XCTAssertFalse(browserView.previewImageForTesting === staleImage)

        provider.completeRequest(at: 1, image: currentImage)
        XCTAssertTrue(browserView.previewImageForTesting === currentImage)
    }

    private func makeBrowserView(provider: MockThumbnailProvider) -> FinderGalleryBrowserNSView {
        let browserView = FinderGalleryBrowserNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        browserView.thumbnailProvider = provider
        browserView.layout()
        return browserView
    }

    private func makeEntry(name: String, path: String, isDirectory: Bool) -> DirectoryEntry {
        DirectoryEntry(
            name: name,
            path: path,
            kind: isDirectory ? .directory : .file,
            isDirectory: isDirectory,
            size: isDirectory ? nil : 1024,
            modifiedAt: "2026-06-13T10:00:00Z"
        )
    }
}
