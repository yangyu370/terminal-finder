import XCTest
@testable import MacOS

@MainActor
final class WorkspaceBrowserViewModelTests: XCTestCase {
    func testInitialLoadFiltersHiddenEntriesAndToggleRestoresThem() async throws {
        let backend = MockBackendClient()
        backend.state = WorkspaceState(currentDirectory: "/workspace", workspaceRoot: "/workspace")
        backend.listings["/workspace"] = listing(
            path: "/workspace",
            entries: [
                entry(name: ".hidden", path: "/workspace/.hidden"),
                entry(name: "visible.txt", path: "/workspace/visible.txt")
            ]
        )
        let viewModel = makeViewModel(backend: backend)

        viewModel.loadInitialState()
        try await waitUntilLoaded(viewModel)

        XCTAssertEqual(viewModel.path, "/workspace")
        XCTAssertEqual(viewModel.entries.map(\.name), ["visible.txt"])

        viewModel.toggleHiddenFiles()
        XCTAssertEqual(viewModel.entries.map(\.name), [".hidden", "visible.txt"])

        viewModel.selectEntry(path: "/workspace/.hidden")
        viewModel.toggleHiddenFiles()

        XCTAssertNil(viewModel.selectedEntryPath)
        XCTAssertEqual(viewModel.entries.map(\.name), ["visible.txt"])
    }

    func testDirectoryNavigationMaintainsBackAndForwardHistory() async throws {
        let backend = MockBackendClient()
        backend.state = WorkspaceState(currentDirectory: "/workspace", workspaceRoot: "/workspace")
        backend.listings["/workspace"] = listing(path: "/workspace")
        backend.openResults["/workspace/child"] = openResult(path: "/workspace/child")
        backend.openResults["/workspace"] = openResult(path: "/workspace")
        let viewModel = makeViewModel(backend: backend)

        viewModel.loadInitialState()
        try await waitUntilLoaded(viewModel)

        viewModel.open(entry(name: "child", path: "/workspace/child", isDirectory: true))
        try await waitUntilLoaded(viewModel)

        XCTAssertEqual(viewModel.path, "/workspace/child")
        XCTAssertTrue(viewModel.canGoBack)
        XCTAssertFalse(viewModel.canGoForward)

        viewModel.goBack()
        try await waitUntilLoaded(viewModel)

        XCTAssertEqual(viewModel.path, "/workspace")
        XCTAssertFalse(viewModel.canGoBack)
        XCTAssertTrue(viewModel.canGoForward)

        viewModel.goForward()
        try await waitUntilLoaded(viewModel)

        XCTAssertEqual(viewModel.path, "/workspace/child")
        XCTAssertTrue(viewModel.canGoBack)
        XCTAssertFalse(viewModel.canGoForward)
    }

    func testNewNavigationAfterGoingBackClearsForwardHistory() async throws {
        let backend = MockBackendClient()
        backend.state = WorkspaceState(currentDirectory: "/workspace", workspaceRoot: "/workspace")
        backend.listings["/workspace"] = listing(path: "/workspace")
        backend.openResults["/workspace/child"] = openResult(path: "/workspace/child")
        backend.openResults["/workspace/other"] = openResult(path: "/workspace/other")
        backend.openResults["/workspace"] = openResult(path: "/workspace")
        let viewModel = makeViewModel(backend: backend)

        viewModel.loadInitialState()
        try await waitUntilLoaded(viewModel)

        viewModel.open(entry(name: "child", path: "/workspace/child", isDirectory: true))
        try await waitUntilLoaded(viewModel)
        viewModel.goBack()
        try await waitUntilLoaded(viewModel)

        XCTAssertTrue(viewModel.canGoForward)

        viewModel.open(entry(name: "other", path: "/workspace/other", isDirectory: true))
        try await waitUntilLoaded(viewModel)

        XCTAssertEqual(viewModel.path, "/workspace/other")
        XCTAssertTrue(viewModel.canGoBack)
        XCTAssertFalse(viewModel.canGoForward)
    }

    func testFailedDirectoryNavigationDoesNotChangeHistoryOrCurrentPath() async throws {
        let backend = MockBackendClient()
        backend.state = WorkspaceState(currentDirectory: "/workspace", workspaceRoot: "/workspace")
        backend.listings["/workspace"] = listing(path: "/workspace")
        backend.openErrors["/workspace/missing"] = MockBackendClientError.missingOpenResult(
            "/workspace/missing"
        )
        let viewModel = makeViewModel(backend: backend)

        viewModel.loadInitialState()
        try await waitUntilLoaded(viewModel)

        viewModel.open(entry(name: "missing", path: "/workspace/missing", isDirectory: true))
        try await waitUntilLoaded(viewModel)

        XCTAssertEqual(viewModel.path, "/workspace")
        XCTAssertFalse(viewModel.canGoBack)
        XCTAssertFalse(viewModel.canGoForward)
        XCTAssertNotNil(viewModel.errorText)
    }

    func testRelativePathIsResolvedFromCurrentDirectory() async throws {
        let backend = MockBackendClient()
        backend.state = WorkspaceState(
            currentDirectory: "/workspace/current",
            workspaceRoot: "/workspace"
        )
        backend.listings["/workspace/current"] = listing(path: "/workspace/current")
        backend.openResults["/workspace/sibling"] = openResult(path: "/workspace/sibling")
        let viewModel = makeViewModel(backend: backend)

        viewModel.loadInitialState()
        try await waitUntilLoaded(viewModel)

        viewModel.updatePathInput("../sibling")
        viewModel.openCurrentPath()
        try await waitUntilLoaded(viewModel)

        XCTAssertEqual(backend.openDirectoryPaths, ["/workspace/sibling"])
        XCTAssertEqual(viewModel.path, "/workspace/sibling")
    }

    func testEnteredFilePathIsOpenedAfterNotDirectoryResponse() async throws {
        let backend = MockBackendClient()
        backend.state = WorkspaceState(currentDirectory: "/workspace", workspaceRoot: "/workspace")
        backend.listings["/workspace"] = listing(path: "/workspace")
        backend.openErrors["/workspace/file.txt"] = BackendClientError.rpcError(
            code: "not_directory",
            message: "path is not a directory"
        )
        let opener = MockWorkspaceItemOpener()
        let viewModel = makeViewModel(backend: backend, opener: opener)

        viewModel.loadInitialState()
        try await waitUntilLoaded(viewModel)

        viewModel.updatePathInput("/workspace/file.txt")
        viewModel.openCurrentPath()
        try await waitUntilLoaded(viewModel)

        XCTAssertEqual(opener.openedPaths, ["/workspace/file.txt"])
        XCTAssertNil(viewModel.fileOpenErrorText)
        XCTAssertNil(viewModel.errorText)
    }

    func testRefreshListsCurrentDirectoryWithoutOpeningIt() async throws {
        let backend = MockBackendClient()
        backend.state = WorkspaceState(currentDirectory: "/workspace", workspaceRoot: "/workspace")
        backend.listings["/workspace"] = listing(
            path: "/workspace",
            entries: [entry(name: "before.txt", path: "/workspace/before.txt")]
        )
        let viewModel = makeViewModel(backend: backend)

        viewModel.loadInitialState()
        try await waitUntilLoaded(viewModel)

        backend.listings["/workspace"] = listing(
            path: "/workspace",
            entries: [entry(name: "after.txt", path: "/workspace/after.txt")]
        )
        viewModel.refresh()
        try await waitUntilLoaded(viewModel)

        XCTAssertEqual(backend.listDirectoryPaths, ["/workspace", "/workspace"])
        XCTAssertTrue(backend.openDirectoryPaths.isEmpty)
        XCTAssertEqual(viewModel.entries.map(\.name), ["after.txt"])
    }

    func testInitialLoadRequestedDuringNavigationRunsAfterNavigationFinishes() async throws {
        let backend = MockBackendClient()
        backend.state = WorkspaceState(currentDirectory: "/workspace", workspaceRoot: "/workspace")
        backend.listings["/workspace"] = listing(path: "/workspace")
        backend.openResults["/workspace/child"] = openResult(path: "/workspace/child")
        let viewModel = makeViewModel(backend: backend)

        viewModel.loadInitialState()
        try await waitUntilLoaded(viewModel)

        backend.openDirectoryDelayNanoseconds = 50_000_000
        viewModel.open(entry(name: "child", path: "/workspace/child", isDirectory: true))

        backend.state = WorkspaceState(currentDirectory: "/reconnected", workspaceRoot: "/reconnected")
        backend.listings["/reconnected"] = listing(
            path: "/reconnected",
            entries: [entry(name: "fresh.txt", path: "/reconnected/fresh.txt")]
        )
        viewModel.loadInitialState()
        try await waitUntilLoaded(viewModel)

        XCTAssertEqual(viewModel.path, "/reconnected")
        XCTAssertEqual(viewModel.entries.map(\.name), ["fresh.txt"])
        XCTAssertEqual(backend.listDirectoryPaths, ["/workspace", "/reconnected"])
    }

    private func makeViewModel(
        backend: MockBackendClient,
        opener: MockWorkspaceItemOpener? = nil
    ) -> WorkspaceBrowserViewModel {
        WorkspaceBrowserViewModel(
            backendClient: backend,
            workspaceItemOpener: opener ?? MockWorkspaceItemOpener(),
            initialPath: "/initial"
        )
    }

    private func waitUntilLoaded(_ viewModel: WorkspaceBrowserViewModel) async throws {
        for _ in 0..<100 {
            if !viewModel.isLoading {
                return
            }

            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTFail("View model did not finish loading in time.")
    }

    private func listing(
        path: String,
        entries: [DirectoryEntry] = []
    ) -> DirectoryListing {
        DirectoryListing(path: path, entries: entries)
    }

    private func openResult(path: String) -> OpenDirectoryResult {
        OpenDirectoryResult(
            state: WorkspaceState(currentDirectory: path, workspaceRoot: "/workspace"),
            listing: listing(path: path)
        )
    }

    private func entry(
        name: String,
        path: String,
        isDirectory: Bool = false
    ) -> DirectoryEntry {
        DirectoryEntry(
            name: name,
            path: path,
            kind: isDirectory ? .directory : .file,
            isDirectory: isDirectory,
            size: isDirectory ? nil : 0,
            modifiedAt: nil
        )
    }
}

@MainActor
private final class MockBackendClient: BackendClientProtocol {
    var state = WorkspaceState(currentDirectory: "/workspace", workspaceRoot: "/workspace")
    var listings: [String: DirectoryListing] = [:]
    var openResults: [String: OpenDirectoryResult] = [:]
    var openErrors: [String: any Error] = [:]
    var openDirectoryDelayNanoseconds: UInt64 = 0

    private(set) var listDirectoryPaths: [String] = []
    private(set) var openDirectoryPaths: [String] = []

    func health() async throws -> PingResult {
        PingResult(service: "test-core", version: "test")
    }

    func ping() async throws -> PingResult {
        PingResult(service: "test-core", version: "test")
    }

    func getState() async throws -> WorkspaceState {
        state
    }

    func openDirectory(path: String) async throws -> OpenDirectoryResult {
        openDirectoryPaths.append(path)

        if openDirectoryDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: openDirectoryDelayNanoseconds)
        }

        if let error = openErrors[path] {
            throw error
        }

        guard let result = openResults[path] else {
            throw MockBackendClientError.missingOpenResult(path)
        }

        return result
    }

    func listDirectory(path: String) async throws -> DirectoryListing {
        listDirectoryPaths.append(path)

        guard let listing = listings[path] else {
            throw MockBackendClientError.missingListing(path)
        }

        return listing
    }
}

@MainActor
private final class MockWorkspaceItemOpener: WorkspaceItemOpening {
    private(set) var openedPaths: [String] = []

    func openFile(atPath path: String) throws {
        openedPaths.append(path)
    }
}

private enum MockBackendClientError: LocalizedError {
    case missingListing(String)
    case missingOpenResult(String)

    var errorDescription: String? {
        switch self {
        case .missingListing(let path):
            return "Missing mock listing for \(path)."
        case .missingOpenResult(let path):
            return "Missing mock open result for \(path)."
        }
    }
}
