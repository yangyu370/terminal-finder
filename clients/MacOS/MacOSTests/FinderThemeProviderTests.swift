import AppKit
import XCTest
@testable import MacOS

@MainActor
final class FinderThemeProviderTests: XCTestCase {
    func testDefaultsToFirstAvailableTheme() {
        let provider = FinderThemeProvider()

        XCTAssertEqual(provider.current.id, "system")
        XCTAssertEqual(provider.available.first?.id, "system")
        XCTAssertTrue(provider.available.contains { $0.id == "windows-classic" })
    }

    func testInitialThemeOverrideWins() {
        let provider = FinderThemeProvider(initial: WindowsClassicFinderTheme())

        XCTAssertEqual(provider.current.id, "windows-classic")
    }

    func testApplyUpdatesCurrentAndBroadcasts() {
        let provider = FinderThemeProvider()
        let expectation = expectation(
            forNotification: FinderThemeProvider.didChange,
            object: provider,
            handler: nil
        )

        provider.apply(WindowsClassicFinderTheme())

        XCTAssertEqual(provider.current.id, "windows-classic")
        wait(for: [expectation], timeout: 1)
    }

    func testCycleRotatesThroughAvailableThemesAndWrapsAround() {
        let provider = FinderThemeProvider()
        XCTAssertEqual(provider.current.id, "system")

        provider.cycle()
        XCTAssertEqual(provider.current.id, "windows-classic")

        provider.cycle()
        XCTAssertEqual(provider.current.id, "system")
    }

    func testCycleBroadcastsDidChange() {
        let provider = FinderThemeProvider()
        let expectation = expectation(
            forNotification: FinderThemeProvider.didChange,
            object: provider,
            handler: nil
        )

        provider.cycle()

        wait(for: [expectation], timeout: 1)
    }

    /// 锁定「默认主题 = 现状」：每个槽位必须映射回现有语义系统色 / 字号，
    /// 防止后续机械替换时悄悄改变默认观感。
    func testSystemThemeMapsToCurrentSystemTokens() {
        let theme = SystemFinderTheme()

        XCTAssertEqual(theme.listBackground, .controlBackgroundColor)
        XCTAssertEqual(theme.previewBackground, .controlBackgroundColor)
        XCTAssertEqual(theme.inspectorBackground, .controlBackgroundColor)
        XCTAssertEqual(theme.tagBackground, .textBackgroundColor)

        XCTAssertEqual(theme.primaryText, .labelColor)
        XCTAssertEqual(theme.secondaryText, .secondaryLabelColor)
        XCTAssertEqual(theme.tertiaryText, .tertiaryLabelColor)
        XCTAssertEqual(theme.selectedText, .alternateSelectedControlTextColor)

        XCTAssertEqual(theme.accent, .controlAccentColor)
        XCTAssertEqual(theme.selectionFill, .controlAccentColor)

        XCTAssertEqual(theme.rowFont, .systemFont(ofSize: 13))
        XCTAssertEqual(theme.captionFont, .systemFont(ofSize: 12))
        XCTAssertEqual(theme.titleFont, .systemFont(ofSize: 13, weight: .semibold))
    }

    func testWindowsClassicThemeUsesFixedLightSkin() {
        let theme = WindowsClassicFinderTheme()

        XCTAssertEqual(theme.id, "windows-classic")
        XCTAssertEqual(theme.listBackground, .white)
        XCTAssertEqual(theme.selectedText, .white)
        // 经典蓝底白字：选中文字与选区填充必须是不同的颜色。
        XCTAssertNotEqual(theme.selectionFill, theme.selectedText)
        XCTAssertFalse(theme.displayName.isEmpty)
    }
}
