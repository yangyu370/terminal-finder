import AppKit
import XCTest
@testable import MacOS

final class FinderKeyboardShortcutsTests: XCTestCase {
    func testCommandJToggleTerminalPanel() {
        XCTAssertTrue(FinderKeyboardShortcuts.isToggleTerminalPanel(characters: "j", modifierFlags: [.command]))
        XCTAssertTrue(FinderKeyboardShortcuts.isToggleTerminalPanel(characters: "J", modifierFlags: [.command]))
    }

    func testCommandKDoesNotToggleTerminalPanel() {
        XCTAssertFalse(FinderKeyboardShortcuts.isToggleTerminalPanel(characters: "k", modifierFlags: [.command]))
        XCTAssertFalse(FinderKeyboardShortcuts.isToggleTerminalPanel(characters: "K", modifierFlags: [.command]))
    }

    func testIgnoresIrrelevantModifierBitsSuchAsCapsLock() {
        // capsLock / function 等设备无关位不应影响判定。
        XCTAssertTrue(
            FinderKeyboardShortcuts.isToggleTerminalPanel(characters: "j", modifierFlags: [.command, .capsLock])
        )
        XCTAssertFalse(
            FinderKeyboardShortcuts.isToggleTerminalPanel(characters: "k", modifierFlags: [.command, .function])
        )
    }

    func testFallsBackToPhysicalJKeyCodeWhenCharactersAreUnavailable() {
        XCTAssertTrue(
            FinderKeyboardShortcuts.isToggleTerminalPanel(
                characters: nil,
                modifierFlags: [.command],
                keyCode: 38
            )
        )
        XCTAssertFalse(
            FinderKeyboardShortcuts.isToggleTerminalPanel(
                characters: "\n",
                modifierFlags: [.command],
                keyCode: 40
            )
        )
    }

    func testRequiresCommandModifier() {
        XCTAssertFalse(FinderKeyboardShortcuts.isToggleTerminalPanel(characters: "j", modifierFlags: []))
        XCTAssertFalse(FinderKeyboardShortcuts.isToggleTerminalPanel(characters: "j", modifierFlags: [.shift]))
        XCTAssertFalse(FinderKeyboardShortcuts.isToggleTerminalPanel(characters: "k", modifierFlags: [.control]))
    }

    func testRejectsExtraCommandModifierCombinations() {
        XCTAssertFalse(
            FinderKeyboardShortcuts.isToggleTerminalPanel(characters: "j", modifierFlags: [.command, .shift])
        )
        XCTAssertFalse(
            FinderKeyboardShortcuts.isToggleTerminalPanel(characters: "j", modifierFlags: [.command, .option])
        )
        XCTAssertFalse(
            FinderKeyboardShortcuts.isToggleTerminalPanel(characters: "k", modifierFlags: [.command, .control])
        )
    }

    func testRejectsOtherKeysAndMissingCharacters() {
        XCTAssertFalse(FinderKeyboardShortcuts.isToggleTerminalPanel(characters: "x", modifierFlags: [.command]))
        XCTAssertFalse(FinderKeyboardShortcuts.isToggleTerminalPanel(characters: "i", modifierFlags: [.command]))
        XCTAssertFalse(FinderKeyboardShortcuts.isToggleTerminalPanel(characters: "", modifierFlags: [.command]))
        XCTAssertFalse(FinderKeyboardShortcuts.isToggleTerminalPanel(characters: nil, modifierFlags: [.command]))
        XCTAssertFalse(
            FinderKeyboardShortcuts.isToggleTerminalPanel(
                characters: nil,
                modifierFlags: [.command],
                keyCode: 7
            )
        )
    }
}
