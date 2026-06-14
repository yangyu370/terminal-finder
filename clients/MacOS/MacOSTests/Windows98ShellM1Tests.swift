import AppKit
import XCTest
@testable import MacOS

final class Windows98IconProviderTests: XCTestCase {
    func testEntryIconKindsUseWindows98Fallbacks() {
        let provider = Windows98IconProvider()

        XCTAssertEqual(provider.iconKind(for: entry(name: "Folder", kind: .directory, isDirectory: true)), .folder)
        XCTAssertEqual(provider.iconKind(for: entry(name: "Notes.txt", kind: .file, isDirectory: false)), .file)
        XCTAssertEqual(provider.iconKind(for: entry(name: "Link", kind: .symlink, isDirectory: false)), .symlink)
        XCTAssertEqual(provider.iconKind(for: entry(name: "Socket", kind: .other, isDirectory: false)), .other)

        XCTAssertEqual(provider.icon(for: entry(name: "Notes.txt", kind: .file, isDirectory: false)).size, NSSize(width: 16, height: 16))
    }

    func testSidebarIconKindsAvoidSFSymbolFallbacks() {
        let provider = Windows98IconProvider()
        let locations = [
            WorkspaceSidebarLocation(title: "Home", systemImageName: "house", path: "/Users/mac"),
            WorkspaceSidebarLocation(title: "Desktop", systemImageName: "desktopcomputer", path: "/Users/mac/Desktop"),
            WorkspaceSidebarLocation(title: "Downloads", systemImageName: "arrow.down.circle", path: "/Users/mac/Downloads"),
            WorkspaceSidebarLocation(title: "Documents", systemImageName: "doc.text", path: "/Users/mac/Documents")
        ]
        let items = FinderSidebarItem.makeItems(from: locations)

        XCTAssertEqual(provider.sidebarIconKind(for: item("favorites.desktop", in: items)), .desktop)
        XCTAssertEqual(provider.sidebarIconKind(for: item("favorites.downloads", in: items)), .downloads)
        XCTAssertEqual(provider.sidebarIconKind(for: item("favorites.documents", in: items)), .documents)
        XCTAssertEqual(provider.sidebarIconKind(for: item("locations.home", in: items)), .home)
    }

    private func entry(
        name: String,
        kind: EntryKind,
        isDirectory: Bool
    ) -> DirectoryEntry {
        DirectoryEntry(
            name: name,
            path: "/tmp/\(name)",
            kind: kind,
            isDirectory: isDirectory,
            size: 10,
            modifiedAt: nil
        )
    }

    private func item(_ id: String, in items: [FinderSidebarItem]) -> FinderSidebarItem {
        guard let item = items.first(where: { $0.id == id }) else {
            XCTFail("Missing sidebar item \(id)")
            return items[0]
        }

        return item
    }
}

final class Windows98SidebarItemFilterTests: XCTestCase {
    func testAccessibleItemsOnlyKeepsReadableDirectoriesWithLocations() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("Windows98SidebarItemFilterTests-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let desktop = root.appendingPathComponent("Desktop", isDirectory: true)
        let documentsFile = root.appendingPathComponent("Documents", isDirectory: false)
        let missingDownloads = root.appendingPathComponent("Downloads", isDirectory: true)

        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: desktop, withIntermediateDirectories: true)
        try "not a directory".write(to: documentsFile, atomically: true, encoding: .utf8)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let filter = Windows98SidebarItemFilter(fileManager: fileManager)
        let items = filter.accessibleItems(
            from: [
                WorkspaceSidebarLocation(title: "Home", systemImageName: "house", path: home.path),
                WorkspaceSidebarLocation(title: "Desktop", systemImageName: "desktopcomputer", path: desktop.path),
                WorkspaceSidebarLocation(title: "Downloads", systemImageName: "arrow.down.circle", path: missingDownloads.path),
                WorkspaceSidebarLocation(title: "Documents", systemImageName: "doc.text", path: documentsFile.path)
            ]
        )
        let ids = Set(items.map(\.id))

        XCTAssertEqual(ids, ["favorites.desktop", "locations.home"])
        XCTAssertTrue(items.allSatisfy { $0.location != nil })
        XCTAssertTrue(items.allSatisfy { $0.group != .tags })
    }
}

final class Windows98ChromeMetricsTests: XCTestCase {
    func testTopInsetIsAlignedToBackingPixels() {
        XCTAssertEqual(
            Windows98ChromeMetrics.pixelAlignedTopInset(20.2, displayScale: 2),
            20.5,
            accuracy: 0.001
        )
    }

    func testTopInsetClampsInvalidValues() {
        XCTAssertEqual(Windows98ChromeMetrics.pixelAlignedTopInset(-4, displayScale: 2), 0)
        XCTAssertEqual(Windows98ChromeMetrics.pixelAlignedTopInset(12, displayScale: 0), 12)
    }
}

final class Windows98ListColumnsTests: XCTestCase {
    func testColumnsUseTheSameTotalWidthAsTheAvailableListArea() {
        let columns = Windows98ListColumns(availableWidth: 830)

        XCTAssertEqual(columns.totalWidth, 830, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(columns.name, 260)
        XCTAssertGreaterThanOrEqual(columns.type, 150)
        XCTAssertEqual(columns.size, 120)
        XCTAssertGreaterThanOrEqual(columns.modified, 220)
    }

    func testColumnsKeepAMinimumScrollableWidthForNarrowWindows() {
        let columns = Windows98ListColumns(availableWidth: 560)

        XCTAssertEqual(columns.totalWidth, Windows98ListColumns.minimumScrollableWidth, accuracy: 0.001)
    }
}

@MainActor
final class Windows98ShellViewActionTests: XCTestCase {
    func testWindowButtonClosuresAreCallableFromShellView() {
        var calls: [String] = []

        let view = Windows98ShellView(
            workspaceVM: WorkspaceBrowserViewModel(),
            terminalVM: TerminalSessionViewModel(),
            panelLayout: PseudoTerminalPanelLayoutState(),
            contentState: FinderContentViewState(),
            shellModeState: ClientShellModeState(mode: .windows98),
            onCloseTerminal: {},
            onSwitchToNative: { calls.append("native") },
            onMinimize: { calls.append("minimize") },
            onZoom: { calls.append("zoom") },
            onClose: { calls.append("close") }
        )

        view.onSwitchToNative()
        view.onMinimize()
        view.onZoom()
        view.onClose()

        XCTAssertEqual(calls, ["native", "minimize", "zoom", "close"])
    }
}

@MainActor
final class FinderWindowControllerShellChromeTests: XCTestCase {
    func testInitialWindowSizeMatchesReferenceScreenshotMinimum() {
        let controller = FinderWindowController()
        guard let window = controller.window else {
            XCTFail("FinderWindowController did not create a window")
            return
        }

        XCTAssertEqual(window.minSize, FinderWindowController.minimumWindowFrameSize)
        XCTAssertGreaterThanOrEqual(window.frame.width, FinderWindowController.minimumWindowFrameSize.width)
        XCTAssertGreaterThanOrEqual(window.frame.height, FinderWindowController.minimumWindowFrameSize.height)
    }

    func testShellSwitchPreservesFrameAndRestoresWindowChrome() async {
        let controller = FinderWindowController()
        guard let window = controller.window else {
            XCTFail("FinderWindowController did not create a window")
            return
        }

        let initialFrame = window.frame

        controller.shellModeState.select(.windows98)
        await drainMainQueue()

        XCTAssertEqual(window.frame, initialFrame)
        XCTAssertNil(window.toolbar)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertTrue(window.standardWindowButton(.closeButton)?.isHidden ?? false)
        XCTAssertTrue(window.standardWindowButton(.miniaturizeButton)?.isHidden ?? false)
        XCTAssertTrue(window.standardWindowButton(.zoomButton)?.isHidden ?? false)

        controller.shellModeState.select(.nativeFinder)
        await drainMainQueue()

        XCTAssertEqual(window.frame, initialFrame)
        XCTAssertNotNil(window.toolbar)
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertFalse(window.titlebarAppearsTransparent)
        XCTAssertFalse(window.standardWindowButton(.closeButton)?.isHidden ?? true)
        XCTAssertFalse(window.standardWindowButton(.miniaturizeButton)?.isHidden ?? true)
        XCTAssertFalse(window.standardWindowButton(.zoomButton)?.isHidden ?? true)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}
