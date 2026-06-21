import AppKit
import SwiftUI
import XCTest
@testable import MacOS

@MainActor
final class WindowsLegacyShellFileListLayoutTests: XCTestCase {
    func testWindowsXPShortFileListFillsAvailableContentHeight() async throws {
        let viewModel = try await makeLoadedViewModel()
        let host = NSHostingController(
            rootView: WindowsXPFileListView(
                workspaceVM: viewModel,
                iconProvider: WindowsXPIconProvider(),
                availableWidth: 800
            )
            .frame(width: 800, height: 420)
        )

        let scrollView = try await largestScrollView(in: host, size: NSSize(width: 800, height: 420))

        XCTAssertGreaterThan(scrollView.frame.height, 300)
    }

    func testWindows98ShortFileListFillsAvailableContentHeight() async throws {
        let viewModel = try await makeLoadedViewModel()
        let host = NSHostingController(
            rootView: Windows98ShellView(
                workspaceVM: viewModel,
                terminalVM: TerminalSessionViewModel(),
                panelLayout: PseudoTerminalPanelLayoutState(),
                contentState: FinderContentViewState(),
                shellModeState: ClientShellModeState(mode: .windows98),
                onCloseTerminal: {},
                onSwitchToNative: {},
                onMinimize: {},
                onZoom: {},
                onClose: {}
            )
            .frame(width: 1007, height: 689)
        )

        let scrollView = try await largestScrollView(in: host, size: NSSize(width: 1007, height: 689))

        XCTAssertGreaterThan(scrollView.frame.height, 300)
    }

    private func makeLoadedViewModel() async throws -> WorkspaceBrowserViewModel {
        let backend = LayoutTestBackendClient()
        backend.state = WorkspaceState(currentDirectory: "/workspace", workspaceRoot: "/workspace")
        backend.listings["/workspace"] = DirectoryListing(
            path: "/workspace",
            entries: [
                entry(name: "src", path: "/workspace/src", isDirectory: true),
                entry(name: "target", path: "/workspace/target", isDirectory: true),
                entry(name: "pom.xml", path: "/workspace/pom.xml", isDirectory: false)
            ]
        )

        let viewModel = WorkspaceBrowserViewModel(
            backendClient: backend,
            workspaceItemOpener: LayoutTestWorkspaceItemOpener(),
            workspaceAlertPresenter: LayoutTestWorkspaceAlertPresenter(),
            initialPath: "/workspace"
        )
        viewModel.loadInitialState()

        for _ in 0..<100 {
            if !viewModel.isLoading {
                return viewModel
            }

            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTFail("View model did not finish loading in time.")
        return viewModel
    }

    private func largestScrollView<Root: View>(
        in host: NSHostingController<Root>,
        size: NSSize
    ) async throws -> NSScrollView {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = host
        host.view.frame = NSRect(origin: .zero, size: size)
        host.view.layoutSubtreeIfNeeded()
        await drainMainQueue()
        host.view.layoutSubtreeIfNeeded()

        let scrollViews = scrollViews(in: host.view)
        guard let largest = scrollViews.max(by: { lhs, rhs in
            lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
        }) else {
            XCTFail("Expected SwiftUI shell view to create an NSScrollView.")
            throw LayoutTestError.missingScrollView
        }

        _ = window
        return largest
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        var result: [NSScrollView] = []

        if let scrollView = view as? NSScrollView {
            result.append(scrollView)
        }

        for subview in view.subviews {
            result.append(contentsOf: scrollViews(in: subview))
        }

        return result
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func entry(
        name: String,
        path: String,
        isDirectory: Bool
    ) -> DirectoryEntry {
        DirectoryEntry(
            name: name,
            path: path,
            kind: isDirectory ? .directory : .file,
            isDirectory: isDirectory,
            size: isDirectory ? nil : 2048,
            modifiedAt: nil
        )
    }
}

private enum LayoutTestError: Error {
    case missingScrollView
}

@MainActor
private final class LayoutTestBackendClient: BackendClientProtocol {
    var state = WorkspaceState(currentDirectory: "/workspace", workspaceRoot: "/workspace")
    var listings: [String: DirectoryListing] = [:]

    func health() async throws -> PingResult {
        PingResult(service: "test-core", version: "test")
    }

    func ping() async throws -> PingResult {
        PingResult(service: "test-core", version: "test")
    }

    func getState() async throws -> WorkspaceState {
        state
    }

    func openDirectory(path: String, connectionId: String?) async throws -> OpenDirectoryResult {
        OpenDirectoryResult(state: WorkspaceState(currentDirectory: path), listing: listings[path])
    }

    func listDirectory(path: String, connectionId: String?) async throws -> DirectoryListing {
        guard let listing = listings[path] else {
            throw LayoutTestError.missingScrollView
        }

        return listing
    }
}

private final class LayoutTestWorkspaceItemOpener: WorkspaceItemOpening {
    func openFile(atPath path: String) throws {
    }
}

@MainActor
private final class LayoutTestWorkspaceAlertPresenter: WorkspaceAlertPresenting {
    func showWarning(_ warning: WorkspaceAlertWarning) {
    }
}
