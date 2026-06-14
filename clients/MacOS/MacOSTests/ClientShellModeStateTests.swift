import XCTest
@testable import MacOS

@MainActor
final class ClientShellModeStateTests: XCTestCase {
    func testDefaultsToNativeFinderShell() {
        let state = ClientShellModeState()

        XCTAssertEqual(state.mode, .nativeFinder)
        XCTAssertEqual(state.mode.displayName, "Native Finder")
    }

    func testSelectUpdatesShellMode() {
        let state = ClientShellModeState()

        state.select(.windows98)

        XCTAssertEqual(state.mode, .windows98)
        XCTAssertEqual(state.mode.displayName, "Windows 98")
    }

    func testShellModeHasStableRawValuesForMenus() {
        XCTAssertEqual(ClientShellMode.nativeFinder.rawValue, "native-finder")
        XCTAssertEqual(ClientShellMode.windows98.rawValue, "windows-98")
    }
}
