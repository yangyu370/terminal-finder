//
//  FinderTerminalFocusTests.swift
//  MacOSTests
//
//  Created by Codex on 2026/6/18.
//

import AppKit
import XCTest
@testable import MacOS

@MainActor
final class FinderTerminalFocusTests: XCTestCase {
    func testFocusableTerminalContainerFocusesHostedTerminalView() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }

        let containerView = FinderFocusableTerminalContainerView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = containerView
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(containerView.requestKeyboardFocus())
        XCTAssertTrue(window.firstResponder === containerView.terminalView)
    }
}
