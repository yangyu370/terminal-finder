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
        XCTAssertEqual(ClientShellMode.windowsXP.rawValue, "windows-xp")
    }

    func testInitialModeCanBeReadFromLaunchArguments() {
        XCTAssertEqual(
            ClientShellMode.initialMode(arguments: ["MacOS", "--terminal-finder-shell", "windows-98"]),
            .windows98
        )
        XCTAssertEqual(
            ClientShellMode.initialMode(arguments: ["MacOS", "--terminal-finder-shell=windows-xp"]),
            .windowsXP
        )
    }

    func testInitialModeFallsBackToUserDefaultsForScreenshotVerification() {
        let suiteName = "ClientShellModeStateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("windows-xp", forKey: ClientShellMode.initialModeDefaultsKey)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertEqual(ClientShellMode.initialMode(arguments: ["MacOS"], defaults: defaults), .windowsXP)
    }
}
