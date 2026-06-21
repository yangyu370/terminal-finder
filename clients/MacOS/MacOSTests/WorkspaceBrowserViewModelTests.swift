import XCTest
@testable import MacOS

@MainActor
final class WorkspaceBrowserViewModelTests: XCTestCase {
    /// PR 1e firewall guarantee: the ViewModel never sends a non-nil
    /// connection_id to the backend. S3 routing is wired up in PR 1f via a
    /// dedicated connection-aware ViewModel; this contract guards against
    /// accidental drift before then.
    func testFirewall_viewModelAlwaysRoutesWithNilConnectionId() async throws {
        let backend = MockBackendClient()
        backend.state = WorkspaceState(currentDirectory: "/workspace", workspaceRoot: "/workspace")
        backend.listings["/workspace"] = listing(
            path: "/workspace",
            entries: [
                entry(name: "child", path: "/workspace/child", isDirectory: true),
                entry(name: "leaf.txt", path: "/workspace/leaf.txt")
            ]
        )
        backend.listings["/workspace/child"] = listing(path: "/workspace/child")
        backend.openResults["/workspace/child"] = openResult(path: "/workspace/child")
        let viewModel = makeViewModel(backend: backend)

        viewModel.loadInitialState()
        try await waitUntilLoaded(viewModel)

        viewModel.open(entry(name: "child", path: "/workspace/child", isDirectory: true))
        try await waitUntilLoaded(viewModel)

        viewModel.refresh()
        try await waitUntilLoaded(viewModel)

        _ = try await viewModel.loadChildren(path: "/workspace/child")

        XCTAssertFalse(backend.listDirectoryConnectionIds.isEmpty)
        XCTAssertFalse(backend.openDirectoryConnectionIds.isEmpty)
        XCTAssertTrue(
            backend.listDirectoryConnectionIds.allSatisfy { $0 == nil },
            "ViewModel must route every listDirectory through connectionId: nil. Saw: \(backend.listDirectoryConnectionIds)"
        )
        XCTAssertTrue(
            backend.openDirectoryConnectionIds.allSatisfy { $0 == nil },
            "ViewModel must route every openDirectory through connectionId: nil. Saw: \(backend.openDirectoryConnectionIds)"
        )
    }

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
        backend.listings["/workspace"] = listing(
            path: "/workspace",
            entries: [entry(name: "stable.txt", path: "/workspace/stable.txt")]
        )
        backend.openErrors["/workspace/missing"] = MockBackendClientError.missingOpenResult(
            "/workspace/missing"
        )
        let alerts = MockWorkspaceAlertPresenter()
        let viewModel = makeViewModel(backend: backend, alerts: alerts)

        viewModel.loadInitialState()
        try await waitUntilLoaded(viewModel)

        backend.listings["/workspace"] = listing(
            path: "/workspace",
            entries: [entry(name: "refreshed.txt", path: "/workspace/refreshed.txt")]
        )
        viewModel.open(entry(name: "missing", path: "/workspace/missing", isDirectory: true))
        try await waitUntilLoaded(viewModel)

        XCTAssertEqual(viewModel.path, "/workspace")
        XCTAssertFalse(viewModel.canGoBack)
        XCTAssertFalse(viewModel.canGoForward)
        XCTAssertNil(viewModel.errorText)
        XCTAssertEqual(viewModel.entries.map(\.name), ["refreshed.txt"])
        XCTAssertEqual(backend.listDirectoryPaths, ["/workspace", "/workspace"])
        XCTAssertEqual(alerts.warnings.map(\.message), ["The folder can’t be opened."])
        XCTAssertEqual(
            alerts.warnings.first?.recoverySuggestion,
            "Check the path, permissions, or whether the folder still exists."
        )
    }

    func testFailedEnteredDirectoryRestoresCurrentPathAndRefreshesListing() async throws {
        let backend = MockBackendClient()
        backend.state = WorkspaceState(currentDirectory: "/workspace", workspaceRoot: "/workspace")
        backend.listings["/workspace"] = listing(path: "/workspace")
        backend.openErrors["/workspace/missing"] = MockBackendClientError.missingOpenResult(
            "/workspace/missing"
        )
        let alerts = MockWorkspaceAlertPresenter()
        let viewModel = makeViewModel(backend: backend, alerts: alerts)

        viewModel.loadInitialState()
        try await waitUntilLoaded(viewModel)

        backend.listings["/workspace"] = listing(
            path: "/workspace",
            entries: [entry(name: "after-refresh.txt", path: "/workspace/after-refresh.txt")]
        )
        viewModel.updatePathInput("/workspace/missing")
        viewModel.openCurrentPath()
        try await waitUntilLoaded(viewModel)

        XCTAssertEqual(viewModel.path, "/workspace")
        XCTAssertEqual(viewModel.entries.map(\.name), ["after-refresh.txt"])
        XCTAssertNil(viewModel.errorText)
        XCTAssertEqual(backend.openDirectoryPaths, ["/workspace/missing"])
        XCTAssertEqual(backend.listDirectoryPaths, ["/workspace", "/workspace"])
        XCTAssertEqual(alerts.warnings.count, 1)
        XCTAssertEqual(alerts.warnings.first?.message, "The folder can’t be opened.")
        XCTAssertEqual(
            alerts.warnings.first?.informativeText,
            "Terminal Finder kept your current folder open and refreshed it."
        )
        XCTAssertEqual(
            alerts.warnings.first?.detailText,
            "Missing mock open result for /workspace/missing."
        )
    }

    func testEmptyEnteredPathShowsWarningWithoutChangingCurrentDirectory() async throws {
        let backend = MockBackendClient()
        backend.state = WorkspaceState(currentDirectory: "/workspace", workspaceRoot: "/workspace")
        backend.listings["/workspace"] = listing(path: "/workspace")
        let alerts = MockWorkspaceAlertPresenter()
        let viewModel = makeViewModel(backend: backend, alerts: alerts)

        viewModel.loadInitialState()
        try await waitUntilLoaded(viewModel)

        viewModel.updatePathInput(" ")
        viewModel.openCurrentPath()

        XCTAssertEqual(viewModel.path, "/workspace")
        XCTAssertNil(viewModel.errorText)
        XCTAssertTrue(backend.openDirectoryPaths.isEmpty)
        XCTAssertEqual(backend.listDirectoryPaths, ["/workspace"])
        XCTAssertEqual(alerts.warnings.map(\.message), ["Enter a folder path to continue."])
        XCTAssertEqual(
            alerts.warnings.first?.recoverySuggestion,
            "Type or paste a valid file or folder path, then try again."
        )
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
        opener: MockWorkspaceItemOpener? = nil,
        alerts: MockWorkspaceAlertPresenter? = nil
    ) -> WorkspaceBrowserViewModel {
        WorkspaceBrowserViewModel(
            backendClient: backend,
            workspaceItemOpener: opener ?? MockWorkspaceItemOpener(),
            workspaceAlertPresenter: alerts ?? MockWorkspaceAlertPresenter(),
            initialPath: "/initial"
        )
    }

    func test_writeActions_routeThroughCurrentWorkspaceConnection() async throws {
        let backend = MockBackendClient()
        backend.state = WorkspaceState(
            currentDirectory: "bucket/",
            workspaceRoot: "bucket/",
            scheme: "s3",
            connectionId: "conn-99"
        )
        backend.listings["bucket/"] = listing(path: "bucket/")
        let viewModel = makeViewModel(backend: backend)

        viewModel.loadInitialState()
        try await waitUntilLoaded(viewModel)

        await viewModel.uploadFile(localSource: "/tmp/x.txt", remotePath: "bucket/x.txt")
        await viewModel.deleteEntry(path: "bucket/old.txt")
        await viewModel.createDirectory(path: "bucket/newdir")
        await viewModel.renameEntry(from: "bucket/a.txt", to: "bucket/b.txt")

        XCTAssertEqual(
            backend.uploadCalls,
            [
                MockBackendClient.UploadCall(
                    connectionId: "conn-99",
                    remotePath: "bucket/x.txt",
                    localSource: "/tmp/x.txt"
                )
            ]
        )
        XCTAssertEqual(
            backend.deleteCalls,
            [MockBackendClient.DeleteCall(connectionId: "conn-99", path: "bucket/old.txt")]
        )
        XCTAssertEqual(
            backend.mkdirCalls,
            [MockBackendClient.MkdirCall(connectionId: "conn-99", path: "bucket/newdir")]
        )
        XCTAssertEqual(
            backend.renameCalls,
            [
                MockBackendClient.RenameCall(
                    connectionId: "conn-99",
                    from: "bucket/a.txt",
                    to: "bucket/b.txt"
                )
            ]
        )
    }

    func test_openS3File_downloadsThenOpensLocally() async throws {
        let backend = MockBackendClient()
        backend.state = WorkspaceState(
            currentDirectory: "bucket/",
            workspaceRoot: "bucket/",
            scheme: "s3",
            connectionId: "conn-42"
        )
        backend.listings["bucket/"] = listing(
            path: "bucket/",
            entries: [entry(name: "report.txt", path: "bucket/report.txt")]
        )
        let opener = MockWorkspaceItemOpener()
        let viewModel = makeViewModel(backend: backend, opener: opener)

        viewModel.loadInitialState()
        try await waitUntilLoaded(viewModel)

        viewModel.open(entry(name: "report.txt", path: "bucket/report.txt"))

        // Drive the unstructured Task we kicked off in open(_:).
        for _ in 0..<100 where backend.downloadCalls.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(backend.downloadCalls.count, 1)
        let call = backend.downloadCalls[0]
        XCTAssertEqual(call.connectionId, "conn-42")
        XCTAssertEqual(call.remotePath, "bucket/report.txt")
        XCTAssertTrue(
            call.localDestination.hasSuffix("/com.terminal-finder/downloads/report.txt"),
            "Expected sandboxed cache path, got: \(call.localDestination)"
        )

        for _ in 0..<100 where opener.openedPaths.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(opener.openedPaths, [call.localDestination])
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
    private(set) var listDirectoryConnectionIds: [String?] = []
    private(set) var openDirectoryPaths: [String] = []
    private(set) var openDirectoryConnectionIds: [String?] = []

    struct DownloadCall: Equatable {
        let connectionId: String?
        let remotePath: String
        let localDestination: String
    }
    private(set) var downloadCalls: [DownloadCall] = []
    var downloadHandler: ((DownloadCall) throws -> Void)?

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
        openDirectoryPaths.append(path)
        openDirectoryConnectionIds.append(connectionId)

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

    func listDirectory(path: String, connectionId: String?) async throws -> DirectoryListing {
        listDirectoryPaths.append(path)
        listDirectoryConnectionIds.append(connectionId)

        guard let listing = listings[path] else {
            throw MockBackendClientError.missingListing(path)
        }

        return listing
    }

    func downloadFile(
        connectionId: String?,
        remotePath: String,
        localDestination: String
    ) async throws {
        let call = DownloadCall(
            connectionId: connectionId,
            remotePath: remotePath,
            localDestination: localDestination
        )
        downloadCalls.append(call)
        try downloadHandler?(call)
    }

    struct UploadCall: Equatable {
        let connectionId: String?
        let remotePath: String
        let localSource: String
    }
    private(set) var uploadCalls: [UploadCall] = []

    func uploadFile(
        connectionId: String?,
        remotePath: String,
        localSource: String
    ) async throws {
        uploadCalls.append(
            UploadCall(connectionId: connectionId, remotePath: remotePath, localSource: localSource)
        )
    }

    struct DeleteCall: Equatable {
        let connectionId: String?
        let path: String
    }
    private(set) var deleteCalls: [DeleteCall] = []

    func deleteEntry(connectionId: String?, path: String) async throws {
        deleteCalls.append(DeleteCall(connectionId: connectionId, path: path))
    }

    struct MkdirCall: Equatable {
        let connectionId: String?
        let path: String
    }
    private(set) var mkdirCalls: [MkdirCall] = []

    func createRemoteDirectory(connectionId: String?, path: String) async throws {
        mkdirCalls.append(MkdirCall(connectionId: connectionId, path: path))
    }

    struct RenameCall: Equatable {
        let connectionId: String?
        let from: String
        let to: String
    }
    private(set) var renameCalls: [RenameCall] = []

    func renameEntry(connectionId: String?, from: String, to: String) async throws {
        renameCalls.append(RenameCall(connectionId: connectionId, from: from, to: to))
    }

    var capabilitiesStub: ProviderCapsDto = ProviderCapsDto(
        canRename: false,
        canSymlink: false,
        canWrite: true,
        hasNativeDirectories: false
    )

    func connectionCapabilities(connectionId: String) throws -> ProviderCapsDto {
        capabilitiesStub
    }
}

@MainActor
private final class MockWorkspaceItemOpener: WorkspaceItemOpening {
    private(set) var openedPaths: [String] = []

    func openFile(atPath path: String) throws {
        openedPaths.append(path)
    }
}

@MainActor
private final class MockWorkspaceAlertPresenter: WorkspaceAlertPresenting {
    private(set) var warnings: [WorkspaceAlertWarning] = []

    func showWarning(_ warning: WorkspaceAlertWarning) {
        warnings.append(warning)
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
