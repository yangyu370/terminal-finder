import CoreGraphics
import XCTest
@testable import MacOS

@MainActor
final class PseudoTerminalPanelLayoutStateTests: XCTestCase {
    func testOpenMarksPanelVisible() {
        let layout = PseudoTerminalPanelLayoutState()

        layout.open()

        XCTAssertTrue(layout.isOpen)
    }

    func testCloseMarksPanelHidden() {
        let layout = PseudoTerminalPanelLayoutState()

        layout.open()
        layout.close()

        XCTAssertFalse(layout.isOpen)
    }

    func testResizeDragAdjustsHeightWithinBounds() {
        let layout = PseudoTerminalPanelLayoutState(height: 184)

        layout.resize(byVerticalDrag: -80, availableContentHeight: 560)
        XCTAssertEqual(layout.height, 264)

        layout.resize(byVerticalDrag: 1_000, availableContentHeight: 560)
        XCTAssertEqual(layout.height, PseudoTerminalPanelLayoutState.minimumHeight)

        layout.setHeight(900, availableContentHeight: 300)
        XCTAssertEqual(
            layout.height,
            300 - PseudoTerminalPanelLayoutState.minimumDirectoryHeight
        )
    }

    func testViewportResizeIsDebouncedToLatestSize() async throws {
        let layout = PseudoTerminalPanelLayoutState(
            viewportResizeDebounceNanoseconds: 10_000_000
        )
        var deliveredSizes: [CGSize] = []
        layout.onViewportResize = { size in
            deliveredSizes.append(size)
        }

        layout.noteViewportSize(CGSize(width: 320.8, height: 120.4))
        layout.noteViewportSize(CGSize(width: 420.2, height: 180.9))

        try await waitUntil {
            deliveredSizes.count == 1
        }

        XCTAssertEqual(deliveredSizes, [CGSize(width: 420, height: 180)])
        XCTAssertEqual(layout.viewportSize, CGSize(width: 420, height: 180))
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<100 {
            if condition() {
                return
            }

            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTFail("Condition was not met in time.")
    }
}
