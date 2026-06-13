import XCTest
@testable import MacOS

final class FinderColumnViewTests: XCTestCase {
    func testColumnMetricsMatchFinderStyleColumnBrowser() {
        XCTAssertEqual(FinderColumnMetrics.columnWidth, 220)
        XCTAssertEqual(FinderColumnMetrics.rowHeight, 24)
        XCTAssertEqual(FinderColumnMetrics.iconSize, 16)
        XCTAssertEqual(FinderColumnMetrics.previewMinWidth, 260)
        XCTAssertEqual(FinderColumnMetrics.previewMaxComfortWidth, 360)
        XCTAssertEqual(FinderColumnMetrics.previewImageMinWidth, 160)
        XCTAssertEqual(FinderColumnMetrics.previewImageMinHeight, 120)
        XCTAssertEqual(FinderColumnMetrics.previewFallbackIconSize, 220)
        XCTAssertEqual(FinderColumnMetrics.previewResizeRequestThreshold, 16)
    }

    func testColumnLayoutAddsPreviewPaneToDocumentWidth() {
        XCTAssertEqual(
            FinderColumnLayout.documentWidth(columnCount: 2, visibleWidth: 800, hasPreviewPane: false),
            800
        )
        XCTAssertEqual(
            FinderColumnLayout.previewPaneWidth(columnsWidth: 440, visibleWidth: 800),
            360
        )
        XCTAssertEqual(
            FinderColumnLayout.documentWidth(columnCount: 2, visibleWidth: 800, hasPreviewPane: true),
            800
        )
        XCTAssertEqual(
            FinderColumnLayout.previewPaneWidth(columnsWidth: 1_100, visibleWidth: 800),
            260
        )
        XCTAssertEqual(
            FinderColumnLayout.documentWidth(columnCount: 5, visibleWidth: 800, hasPreviewPane: true),
            1_360
        )
    }

    func testColumnPreviewPaneOccupiesVeryWideRemainingSpace() {
        let columnsWidth = FinderColumnMetrics.columnWidth * 2
        let previewWidth = FinderColumnLayout.previewPaneWidth(
            columnsWidth: columnsWidth,
            visibleWidth: 1_400
        )

        XCTAssertEqual(previewWidth, 960)
        XCTAssertGreaterThan(previewWidth, FinderColumnMetrics.previewMaxComfortWidth)
        XCTAssertEqual(
            FinderColumnLayout.documentWidth(columnCount: 2, visibleWidth: 1_400, hasPreviewPane: true),
            1_400
        )
    }

    func testColumnBrowserShowsPreviewPaneForFileAndRemovesItForDirectory() {
        let provider = MockThumbnailProvider()
        let browserView = makeBrowserView(provider: provider)
        browserView.addColumn(NSTableView())
        browserView.addColumn(NSTableView())

        browserView.setPreviewEntry(makeEntry(name: "Report.pdf", path: "/tmp/Report.pdf", isDirectory: false))
        browserView.layoutSubtreeIfNeeded()

        XCTAssertTrue(browserView.hasPreviewPaneForTesting)
        XCTAssertEqual(browserView.documentColumnCountForTesting, 2)
        XCTAssertEqual(browserView.previewPaneWidthForTesting, 360)
        XCTAssertEqual(browserView.documentWidthForTesting, 800)

        browserView.setPreviewEntry(makeEntry(name: "Folder", path: "/tmp/Folder", isDirectory: true))
        browserView.layoutSubtreeIfNeeded()

        XCTAssertFalse(browserView.hasPreviewPaneForTesting)
        XCTAssertEqual(browserView.documentWidthForTesting, 800)
    }

    func testColumnPreviewPaneRequestsColumnThumbnailAndCancelsWhenRemoved() {
        let provider = MockThumbnailProvider()
        let browserView = makeBrowserView(provider: provider)
        browserView.addColumn(NSTableView())
        browserView.setPreviewEntry(makeEntry(name: "Report.pdf", path: "/tmp/Report.pdf", isDirectory: false))
        browserView.layoutSubtreeIfNeeded()

        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(provider.requests[0].descriptor.purpose, .columnPreview)
        XCTAssertGreaterThanOrEqual(provider.requests[0].descriptor.pointSize.width, FinderColumnMetrics.previewImageMinWidth)
        XCTAssertGreaterThanOrEqual(provider.requests[0].descriptor.pointSize.height, FinderColumnMetrics.previewImageMinHeight)

        browserView.setPreviewEntry(nil)

        XCTAssertTrue(provider.requests[0].token.isCancelled)
        XCTAssertFalse(browserView.hasPreviewPaneForTesting)
    }

    func testColumnPreviewPaneCancelsOldTokenAndIgnoresStaleCompletion() {
        let provider = MockThumbnailProvider()
        let browserView = makeBrowserView(provider: provider)
        browserView.addColumn(NSTableView())
        let firstEntry = makeEntry(name: "First.pdf", path: "/tmp/First.pdf", isDirectory: false)
        let secondEntry = makeEntry(name: "Second.pdf", path: "/tmp/Second.pdf", isDirectory: false)
        let staleImage = NSImage(size: NSSize(width: 80, height: 80))
        let currentImage = NSImage(size: NSSize(width: 120, height: 90))

        browserView.setPreviewEntry(firstEntry)
        browserView.layoutSubtreeIfNeeded()
        browserView.setPreviewEntry(secondEntry)
        browserView.layoutSubtreeIfNeeded()

        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertTrue(provider.requests[0].token.isCancelled)

        provider.completeRequest(at: 0, image: staleImage)
        XCTAssertFalse(browserView.previewPaneForTesting?.previewImageForTesting === staleImage)

        provider.completeRequest(at: 1, image: currentImage)
        XCTAssertTrue(browserView.previewPaneForTesting?.previewImageForTesting === currentImage)
    }

    private func makeBrowserView(provider: MockThumbnailProvider) -> FinderColumnBrowserNSView {
        let browserView = FinderColumnBrowserNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        browserView.thumbnailProvider = provider
        browserView.layoutSubtreeIfNeeded()
        return browserView
    }

    private func makeEntry(name: String, path: String, isDirectory: Bool) -> DirectoryEntry {
        DirectoryEntry(
            name: name,
            path: path,
            kind: isDirectory ? .directory : .file,
            isDirectory: isDirectory,
            size: isDirectory ? nil : 2048,
            modifiedAt: "2026-06-13T10:00:00Z"
        )
    }
}
