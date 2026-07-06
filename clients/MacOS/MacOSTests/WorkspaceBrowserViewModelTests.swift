import Combine
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

    func testSuccessfulDirectoryNavigationPublishesOpenedDirectory() async throws {
        let backend = MockBackendClient()
        backend.state = WorkspaceState(currentDirectory: "/workspace", workspaceRoot: "/workspace")
        backend.listings["/workspace"] = listing(path: "/workspace")
        backend.openResults["/workspace/child"] = openResult(path: "/workspace/child")
        backend.openErrors["/workspace/missing"] = MockBackendClientError.missingOpenResult(
            "/workspace/missing"
        )
        let viewModel = makeViewModel(backend: backend)
        var cancellables: Set<AnyCancellable> = []
        var openedDirectories: [String] = []
        viewModel.openedDirectoryPublisher
            .sink { openedDirectories.append($0) }
            .store(in: &cancellables)

        viewModel.loadInitialState()
        try await waitUntilLoaded(viewModel)

        viewModel.open(entry(name: "child", path: "/workspace/child", isDirectory: true))
        try await waitUntilLoaded(viewModel)

        viewModel.open(entry(name: "missing", path: "/workspace/missing", isDirectory: true))
        try await waitUntilLoaded(viewModel)

        XCTAssertEqual(openedDirectories, ["/workspace/child"])
    }

    func testOpenTerminalDirectoryRoutesAsLocalNavigation() async throws {
        let backend = MockBackendClient()
        backend.state = WorkspaceState(
            currentDirectory: "bucket/",
            workspaceRoot: "bucket/",
            scheme: "s3",
            connectionId: "conn-42"
        )
        backend.listings["bucket/"] = listing(path: "bucket/")
        backend.openResults["/workspace/from-terminal"] = openResult(path: "/workspace/from-terminal")
        let viewModel = makeViewModel(backend: backend)

        viewModel.loadInitialState()
        try await waitUntilLoaded(viewModel)

        viewModel.openTerminalDirectory("/workspace/from-terminal")
        try await waitUntilLoaded(viewModel)

        XCTAssertEqual(backend.openDirectoryPaths, ["/workspace/from-terminal"])
        XCTAssertEqual(backend.openDirectoryConnectionIds, [nil])
        XCTAssertEqual(viewModel.path, "/workspace/from-terminal")
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
        alerts: MockWorkspaceAlertPresenter? = nil,
        transferActivityVM: TransferActivityViewModel? = nil
    ) -> WorkspaceBrowserViewModel {
        WorkspaceBrowserViewModel(
            backendClient: backend,
            workspaceItemOpener: opener ?? MockWorkspaceItemOpener(),
            workspaceAlertPresenter: alerts ?? MockWorkspaceAlertPresenter(),
            transferActivityVM: transferActivityVM,
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

    func testMoveEntryWithoutConflictRenamesIntoTargetDirectory() async throws {
        let backend = MockBackendClient()
        backend.state = WorkspaceState(currentDirectory: "/workspace", workspaceRoot: "/workspace")
        backend.listings["/workspace"] = listing(path: "/workspace")
        backend.listings["/workspace/target"] = listing(path: "/workspace/target")
        let viewModel = makeViewModel(backend: backend)

        viewModel.loadInitialState()
        try await waitUntilLoaded(viewModel)

        await viewModel.moveEntry(
            FinderDragItem(
                connectionId: nil,
                path: "/workspace/source.txt",
                name: "source.txt",
                isDirectory: false
            ),
            intoDirectory: entry(name: "target", path: "/workspace/target", isDirectory: true),
            conflict: .replace
        )

        XCTAssertEqual(
            backend.renameCalls,
            [
                MockBackendClient.RenameCall(
                    connectionId: nil,
                    from: "/workspace/source.txt",
                    to: "/workspace/target/source.txt"
                )
            ]
        )
        XCTAssertTrue(backend.deleteCalls.isEmpty)
        XCTAssertTrue(
            backend.listDirectoryPaths.contains("/workspace/target"),
            "Move should list the target directory before writing so it can detect conflicts."
        )
    }

    func testMoveEntryRejectsCrossConnectionMove() async throws {
        let backend = MockBackendClient()
        backend.state = WorkspaceState(
            currentDirectory: "target/",
            workspaceRoot: "target/",
            scheme: "s3",
            connectionId: "conn-target"
        )
        backend.listings["target/"] = listing(path: "target/")
        let alerts = MockWorkspaceAlertPresenter()
        let viewModel = makeViewModel(backend: backend, alerts: alerts)

        viewModel.loadInitialState()
        try await waitUntilLoaded(viewModel)

        await viewModel.moveEntry(
            FinderDragItem(
                connectionId: "conn-source",
                path: "source/report.txt",
                name: "report.txt",
                isDirectory: false
            ),
            intoDirectory: entry(name: "target", path: "target/", isDirectory: true),
            conflict: .replace
        )

        XCTAssertTrue(backend.renameCalls.isEmpty)
        XCTAssertTrue(backend.deleteCalls.isEmpty)
        XCTAssertEqual(alerts.warnings.count, 1)
    }

    func testMoveEntryRejectsDirectoryMovedIntoItselfOrChild() async throws {
        let backend = MockBackendClient()
        backend.state = WorkspaceState(currentDirectory: "/workspace", workspaceRoot: "/workspace")
        backend.listings["/workspace"] = listing(path: "/workspace")
        let alerts = MockWorkspaceAlertPresenter()
        let viewModel = makeViewModel(backend: backend, alerts: alerts)

        viewModel.loadInitialState()
        try await waitUntilLoaded(viewModel)

        let folder = FinderDragItem(
            connectionId: nil,
            path: "/workspace/folder",
            name: "folder",
            isDirectory: true
        )
        await viewModel.moveEntry(
            folder,
            intoDirectory: entry(name: "folder", path: "/workspace/folder", isDirectory: true),
            conflict: .replace
        )
        await viewModel.moveEntry(
            folder,
            intoDirectory: entry(name: "child", path: "/workspace/folder/child", isDirectory: true),
            conflict: .replace
        )

        XCTAssertTrue(backend.renameCalls.isEmpty)
        XCTAssertTrue(backend.deleteCalls.isEmpty)
        XCTAssertEqual(alerts.warnings.count, 2)
    }

    func testMoveEntryIntoSameParentIsNoOp() async throws {
        let backend = MockBackendClient()
        backend.state = WorkspaceState(currentDirectory: "/workspace", workspaceRoot: "/workspace")
        backend.listings["/workspace"] = listing(path: "/workspace")
        let viewModel = makeViewModel(backend: backend)

        viewModel.loadInitialState()
        try await waitUntilLoaded(viewModel)

        await viewModel.moveEntry(
            FinderDragItem(
                connectionId: nil,
                path: "/workspace/file.txt",
                name: "file.txt",
                isDirectory: false
            ),
            intoDirectory: entry(name: "workspace", path: "/workspace", isDirectory: true),
            conflict: .replace
        )

        XCTAssertTrue(backend.renameCalls.isEmpty)
        XCTAssertTrue(backend.deleteCalls.isEmpty)
        XCTAssertEqual(backend.listDirectoryPaths, ["/workspace"])
    }

    func testMoveEntryReplaceConflictDeletesTargetThenRenamesSource() async throws {
        let backend = MockBackendClient()
        backend.state = WorkspaceState(currentDirectory: "/workspace", workspaceRoot: "/workspace")
        backend.listings["/workspace"] = listing(path: "/workspace")
        backend.listings["/workspace/target"] = listing(
            path: "/workspace/target",
            entries: [entry(name: "report.txt", path: "/workspace/target/report.txt")]
        )
        let viewModel = makeViewModel(backend: backend)

        viewModel.loadInitialState()
        try await waitUntilLoaded(viewModel)

        await viewModel.moveEntry(
            FinderDragItem(
                connectionId: nil,
                path: "/workspace/source/report.txt",
                name: "report.txt",
                isDirectory: false
            ),
            intoDirectory: entry(name: "target", path: "/workspace/target", isDirectory: true),
            conflict: .replace
        )

        XCTAssertEqual(
            backend.operationOrder,
            [
                .delete(connectionId: nil, path: "/workspace/target/report.txt"),
                .rename(
                    connectionId: nil,
                    from: "/workspace/source/report.txt",
                    to: "/workspace/target/report.txt"
                )
            ]
        )
    }

    func testMoveEntryReplaceConflictPublishesDeleteAndRenameActivities() async throws {
        let backend = MockBackendClient()
        backend.state = WorkspaceState(currentDirectory: "/workspace", workspaceRoot: "/workspace")
        backend.listings["/workspace"] = listing(path: "/workspace")
        backend.listings["/workspace/target"] = listing(
            path: "/workspace/target",
            entries: [entry(name: "report.txt", path: "/workspace/target/report.txt")]
        )
        let transferActivityVM = TransferActivityViewModel()
        var activitySnapshots: [[TransferActivity]] = []
        let cancellable = transferActivityVM.$activeTransfers
            .dropFirst()
            .sink { activitySnapshots.append($0) }
        let viewModel = makeViewModel(
            backend: backend,
            transferActivityVM: transferActivityVM
        )

        viewModel.loadInitialState()
        try await waitUntilLoaded(viewModel)

        await viewModel.moveEntry(
            FinderDragItem(
                connectionId: nil,
                path: "/workspace/source/report.txt",
                name: "report.txt",
                isDirectory: false
            ),
            intoDirectory: entry(name: "target", path: "/workspace/target", isDirectory: true),
            conflict: .replace
        )
        withExtendedLifetime(cancellable) {}

        XCTAssertEqual(
            activitySnapshots.filter { !$0.isEmpty },
            [
                [
                    TransferActivity(
                        id: "delete|/workspace/target/report.txt",
                        title: "删除 report.txt",
                        kind: .delete
                    )
                ],
                [
                    TransferActivity(
                        id: "rename|/workspace/source/report.txt",
                        title: "移动 report.txt",
                        kind: .rename
                    )
                ]
            ]
        )
    }

    func testMoveEntryKeepBothChoosesAvailableName() async throws {
        let backend = MockBackendClient()
        backend.state = WorkspaceState(currentDirectory: "/workspace", workspaceRoot: "/workspace")
        backend.listings["/workspace"] = listing(path: "/workspace")
        backend.listings["/workspace/target"] = listing(
            path: "/workspace/target",
            entries: [
                entry(name: "report.txt", path: "/workspace/target/report.txt"),
                entry(name: "report 2.txt", path: "/workspace/target/report 2.txt")
            ]
        )
        let viewModel = makeViewModel(backend: backend)

        viewModel.loadInitialState()
        try await waitUntilLoaded(viewModel)

        await viewModel.moveEntry(
            FinderDragItem(
                connectionId: nil,
                path: "/workspace/source/report.txt",
                name: "report.txt",
                isDirectory: false
            ),
            intoDirectory: entry(name: "target", path: "/workspace/target", isDirectory: true),
            conflict: .keepBoth
        )

        XCTAssertEqual(
            backend.renameCalls,
            [
                MockBackendClient.RenameCall(
                    connectionId: nil,
                    from: "/workspace/source/report.txt",
                    to: "/workspace/target/report 3.txt"
                )
            ]
        )
        XCTAssertTrue(backend.deleteCalls.isEmpty)
    }

    func testMoveEntryCancelConflictDoesNotWrite() async throws {
        let backend = MockBackendClient()
        backend.state = WorkspaceState(currentDirectory: "/workspace", workspaceRoot: "/workspace")
        backend.listings["/workspace"] = listing(path: "/workspace")
        backend.listings["/workspace/target"] = listing(
            path: "/workspace/target",
            entries: [entry(name: "report.txt", path: "/workspace/target/report.txt")]
        )
        let viewModel = makeViewModel(backend: backend)

        viewModel.loadInitialState()
        try await waitUntilLoaded(viewModel)

        await viewModel.moveEntry(
            FinderDragItem(
                connectionId: nil,
                path: "/workspace/source/report.txt",
                name: "report.txt",
                isDirectory: false
            ),
            intoDirectory: entry(name: "target", path: "/workspace/target", isDirectory: true),
            conflict: .cancel
        )

        XCTAssertTrue(backend.renameCalls.isEmpty)
        XCTAssertTrue(backend.deleteCalls.isEmpty)
        XCTAssertTrue(backend.listDirectoryPaths.contains("/workspace/target"))
    }

    func testMoveEntryNilConflictUsesResolverWhenConflictExists() async throws {
        let backend = MockBackendClient()
        backend.state = WorkspaceState(currentDirectory: "/workspace", workspaceRoot: "/workspace")
        backend.listings["/workspace"] = listing(path: "/workspace")
        backend.listings["/workspace/target"] = listing(
            path: "/workspace/target",
            entries: [entry(name: "report.txt", path: "/workspace/target/report.txt")]
        )
        let viewModel = makeViewModel(backend: backend)
        var resolvedItem: FinderDragItem?
        var resolvedExistingEntry: DirectoryEntry?
        viewModel.moveConflictResolver = { item, existingEntry in
            resolvedItem = item
            resolvedExistingEntry = existingEntry
            return .keepBoth
        }

        viewModel.loadInitialState()
        try await waitUntilLoaded(viewModel)

        let item = FinderDragItem(
            connectionId: nil,
            path: "/workspace/source/report.txt",
            name: "report.txt",
            isDirectory: false
        )
        await viewModel.moveEntry(
            item,
            intoDirectory: entry(name: "target", path: "/workspace/target", isDirectory: true),
            conflict: nil
        )

        XCTAssertEqual(resolvedItem, item)
        XCTAssertEqual(resolvedExistingEntry?.path, "/workspace/target/report.txt")
        XCTAssertEqual(
            backend.renameCalls,
            [
                MockBackendClient.RenameCall(
                    connectionId: nil,
                    from: "/workspace/source/report.txt",
                    to: "/workspace/target/report 2.txt"
                )
            ]
        )
        XCTAssertTrue(backend.deleteCalls.isEmpty)
    }

    func testMoveEntryRenameFailureReportsWriteOperationAlert() async throws {
        let backend = MockBackendClient()
        backend.state = WorkspaceState(currentDirectory: "/workspace", workspaceRoot: "/workspace")
        backend.listings["/workspace"] = listing(path: "/workspace")
        backend.listings["/workspace/target"] = listing(path: "/workspace/target")
        backend.renameErrors["/workspace/target/report.txt"] = MockBackendClientError.writeFailed(
            "rename denied"
        )
        let alerts = MockWorkspaceAlertPresenter()
        let viewModel = makeViewModel(backend: backend, alerts: alerts)

        viewModel.loadInitialState()
        try await waitUntilLoaded(viewModel)

        await viewModel.moveEntry(
            FinderDragItem(
                connectionId: nil,
                path: "/workspace/source/report.txt",
                name: "report.txt",
                isDirectory: false
            ),
            intoDirectory: entry(name: "target", path: "/workspace/target", isDirectory: true),
            conflict: .replace
        )

        XCTAssertEqual(backend.renameCalls.count, 1)
        XCTAssertEqual(alerts.warnings.count, 1)
        XCTAssertEqual(alerts.warnings.first?.message, "移动失败")
        XCTAssertEqual(
            alerts.warnings.first?.informativeText,
            "无法移动 report.txt。"
        )
        XCTAssertEqual(alerts.warnings.first?.detailText, "rename denied")
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
    var renameErrors: [String: any Error] = [:]
    var openDirectoryDelayNanoseconds: UInt64 = 0

    private(set) var listDirectoryPaths: [String] = []
    private(set) var listDirectoryConnectionIds: [String?] = []
    private(set) var openDirectoryPaths: [String] = []
    private(set) var openDirectoryConnectionIds: [String?] = []
    private(set) var operationOrder: [Operation] = []

    enum Operation: Equatable {
        case delete(connectionId: String?, path: String)
        case rename(connectionId: String?, from: String, to: String)
    }

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
        let call = DeleteCall(connectionId: connectionId, path: path)
        deleteCalls.append(call)
        operationOrder.append(.delete(connectionId: connectionId, path: path))
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
        let call = RenameCall(connectionId: connectionId, from: from, to: to)
        renameCalls.append(call)
        operationOrder.append(.rename(connectionId: connectionId, from: from, to: to))

        if let error = renameErrors[to] {
            throw error
        }
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
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingListing(let path):
            return "Missing mock listing for \(path)."
        case .missingOpenResult(let path):
            return "Missing mock open result for \(path)."
        case .writeFailed(let message):
            return message
        }
    }
}
