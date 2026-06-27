import AppKit
import XCTest
@testable import MacOS

final class FinderAppDelegateTests: XCTestCase {
    func testApplicationWillTerminateInvokesWorkspaceShutdown() {
        let shutdownCalled = expectation(description: "shutdownWorkspace called")
        let delegate = FinderAppDelegate {
            shutdownCalled.fulfill()
        }

        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )

        wait(for: [shutdownCalled], timeout: 1)
    }
}
