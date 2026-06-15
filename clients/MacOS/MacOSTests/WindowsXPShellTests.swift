import XCTest
@testable import MacOS

@MainActor
final class WindowsXPShellViewActionTests: XCTestCase {
    func testWindowAndShellSwitchClosuresAreCallableFromShellView() {
        var calls: [String] = []

        let view = WindowsXPShellView(
            workspaceVM: WorkspaceBrowserViewModel(),
            terminalVM: TerminalSessionViewModel(),
            panelLayout: PseudoTerminalPanelLayoutState(),
            contentState: FinderContentViewState(),
            shellModeState: ClientShellModeState(mode: .windowsXP),
            onCloseTerminal: {},
            onSwitchToNative: { calls.append("native") },
            onSelectShell: { calls.append($0.rawValue) },
            onMinimize: { calls.append("minimize") },
            onZoom: { calls.append("zoom") },
            onClose: { calls.append("close") }
        )

        view.onSwitchToNative()
        view.onSelectShell(.windows98)
        view.onMinimize()
        view.onZoom()
        view.onClose()

        XCTAssertEqual(calls, ["native", "windows-98", "minimize", "zoom", "close"])
    }
}

final class WindowsXPChromeMetricsTests: XCTestCase {
    func testTitleBarHasRoomForShellSwitcherAndCaptionButtons() {
        XCTAssertEqual(WindowsXPChromeMetrics.titleBarHeight, 32, accuracy: 0.001)
    }
}
