import XCTest
@testable import MacOS

@MainActor
final class TerminalSessionViewModelTests: XCTestCase {
    func testWorkspaceTerminalModeAndStatusLabelsAreStableForHeaderUi() {
        XCTAssertEqual(WorkspaceTerminalSyncMode.locked.displayTitle, "锁定")
        XCTAssertEqual(WorkspaceTerminalSyncMode.synced.displayTitle, "同步")
        XCTAssertEqual(WorkspaceTerminalStatus.inSync.displayText, "已同步")
        XCTAssertEqual(WorkspaceTerminalStatus.differentDirectory.displayText, "目录不同")
        XCTAssertEqual(WorkspaceTerminalStatus.syncPending.displayText, "同步中")
        XCTAssertEqual(WorkspaceTerminalStatus.unsupported.displayText, "不支持同步")
        XCTAssertEqual(WorkspaceTerminalStatus.blocked.displayText, "同步受阻")
    }

    func testStartCreatesSessionInCurrentDirectory() async throws {
        let client = MockTerminalClient()
        let viewModel = makeViewModel(client: client, requestIds: ["req-1"])

        viewModel.start(cwd: "/workspace/current", cols: 100, rows: 30)
        try await waitUntil { client.createRequests.count == 1 }

        XCTAssertTrue(client.didConnect)
        XCTAssertEqual(viewModel.status, .connecting)
        XCTAssertEqual(client.createRequests.first?.cwd, "/workspace/current")
        XCTAssertEqual(client.createRequests.first?.cols, 100)
        XCTAssertEqual(client.createRequests.first?.rows, 30)
        XCTAssertEqual(client.createRequests.first?.requestId, "req-1")

        client.emit(.created(sessionId: "session-1", id: "req-1", cols: 100, rows: 30))

        XCTAssertEqual(viewModel.status, .active)
        XCTAssertEqual(viewModel.sessionId, "session-1")
    }

    func testStartConnectionCreatesSessionForConnectionInsteadOfLocalCwd() async throws {
        let client = MockTerminalClient()
        let viewModel = makeViewModel(client: client, requestIds: ["req-1"])

        viewModel.startConnection(connectionId: "conn-1", cols: 96, rows: 28)
        try await waitUntil { client.connectionCreateRequests.count == 1 }

        XCTAssertTrue(client.didConnect)
        XCTAssertEqual(viewModel.status, .connecting)
        XCTAssertNil(viewModel.cwd)
        XCTAssertEqual(viewModel.connectionId, "conn-1")
        XCTAssertTrue(client.createRequests.isEmpty)
        XCTAssertEqual(
            client.connectionCreateRequests.first,
            MockTerminalClient.ConnectionCreateRequest(
                connectionId: "conn-1",
                cols: 96,
                rows: 28,
                requestId: "req-1"
            )
        )

        client.emit(.created(sessionId: "session-1", id: "req-1", cols: 96, rows: 28))

        XCTAssertEqual(viewModel.status, .active)
        XCTAssertEqual(viewModel.sessionId, "session-1")
    }

    func testStartForS3WorkspaceRoutesToConnectionTerminal() async throws {
        let client = MockTerminalClient()
        let viewModel = makeViewModel(client: client, requestIds: ["req-1"])
        let state = WorkspaceState(
            currentDirectory: "s3://bucket/prefix",
            scheme: "s3",
            connectionId: "conn-1"
        )

        viewModel.startForWorkspace(
            state,
            fallbackCwd: "/workspace",
            cols: 88,
            rows: 26
        )
        try await waitUntil { client.connectionCreateRequests.count == 1 }

        XCTAssertTrue(client.createRequests.isEmpty)
        XCTAssertEqual(client.connectionCreateRequests.first?.connectionId, "conn-1")
        XCTAssertNil(viewModel.cwd)
        XCTAssertEqual(viewModel.connectionId, "conn-1")
    }

    func testStartForLocalWorkspaceRoutesToWorkspaceTerminal() async throws {
        let client = MockTerminalClient()
        let viewModel = makeViewModel(client: client, requestIds: ["req-1"])
        let state = WorkspaceState(currentDirectory: "/workspace", scheme: "local")

        viewModel.startForWorkspace(
            state,
            fallbackCwd: "/workspace",
            cols: 88,
            rows: 26
        )
        try await waitUntil { client.workspaceCreateRequests.count == 1 }

        XCTAssertTrue(client.connectionCreateRequests.isEmpty)
        XCTAssertTrue(client.createRequests.isEmpty)
        XCTAssertEqual(
            client.workspaceCreateRequests.first,
            MockTerminalClient.WorkspaceCreateRequest(cols: 88, rows: 26, requestId: "req-1")
        )
        XCTAssertEqual(viewModel.cwd, "/workspace")
        XCTAssertNil(viewModel.connectionId)

        client.emit(.created(sessionId: "session-1", id: "req-1", cols: 88, rows: 26))

        XCTAssertEqual(viewModel.workspaceTerminalCapability, .bidirectionalLocal)
        XCTAssertEqual(viewModel.workspaceTerminalStatus, .differentDirectory)
    }

    func testLockedModeRecordsTerminalCwdWithoutOpeningFinder() async throws {
        let client = MockTerminalClient()
        let viewModel = makeViewModel(client: client, requestIds: ["req-1"])
        let state = WorkspaceState(currentDirectory: "/workspace", scheme: "local")

        viewModel.startForWorkspace(state, fallbackCwd: "/workspace")
        try await waitUntil { client.workspaceCreateRequests.count == 1 }
        client.emit(.created(sessionId: "session-1", id: "req-1", cols: 80, rows: 24))

        viewModel.handleHostCurrentDirectoryUpdate("file://localhost/tmp")
        try await waitUntil { client.cwdUpdateRequests.count == 1 }

        XCTAssertEqual(
            client.cwdUpdateRequests,
            [MockTerminalClient.CwdUpdateRequest(sessionId: "session-1", directoryUrl: "file://localhost/tmp")]
        )
        XCTAssertEqual(viewModel.workspaceTerminalStatus, .inSync)
    }

    func testFollowFinderQueuesDirectoryChangeAfterSuccessfulFinderNavigation() async throws {
        let client = MockTerminalClient()
        let viewModel = makeViewModel(client: client, requestIds: ["req-1"])
        let state = WorkspaceState(currentDirectory: "/workspace", scheme: "local")

        viewModel.startForWorkspace(state, fallbackCwd: "/workspace")
        try await waitUntil { client.workspaceCreateRequests.count == 1 }
        client.emit(.created(sessionId: "session-1", id: "req-1", cols: 80, rows: 24))

        viewModel.workspaceTerminalSyncMode = .synced
        viewModel.finderDidOpenDirectory("/workspace/next")
        try await waitUntil { client.changeDirectoryRequests.count == 1 }

        XCTAssertEqual(
            client.changeDirectoryRequests,
            [MockTerminalClient.ChangeDirectoryRequest(sessionId: "session-1", targetDirectory: "/workspace/next")]
        )
        XCTAssertEqual(viewModel.workspaceTerminalStatus, .syncPending)
    }

    func testFollowTerminalRequestsFinderOpenAfterValidatedDifferentCwd() async throws {
        let client = MockTerminalClient()
        client.workingDirectoryUpdate = TerminalWorkingDirectoryUpdate(
            binding: WorkspaceTerminalBinding(
                sessionId: "session-1",
                kind: .local,
                launchWorkspaceRoot: "/workspace",
                launchWorkspaceCurrentDirectory: "/workspace",
                scheme: "local",
                connectionId: nil,
                latestTerminalWorkingDirectory: "/workspace/from-terminal",
                syncCapability: .bidirectionalLocal
            ),
            reportedDirectory: "/workspace/from-terminal",
            openable: true,
            matchesCurrent: false,
            reason: nil
        )
        let viewModel = makeViewModel(client: client, requestIds: ["req-1"])
        var openedDirectories: [String] = []
        viewModel.onOpenDirectoryFromTerminal = { openedDirectories.append($0) }
        let state = WorkspaceState(currentDirectory: "/workspace", scheme: "local")

        viewModel.startForWorkspace(state, fallbackCwd: "/workspace")
        try await waitUntil { client.workspaceCreateRequests.count == 1 }
        client.emit(.created(sessionId: "session-1", id: "req-1", cols: 80, rows: 24))

        viewModel.workspaceTerminalSyncMode = .synced
        viewModel.handleHostCurrentDirectoryUpdate("file://localhost/workspace/from-terminal")
        try await waitUntil { openedDirectories.count == 1 }

        XCTAssertEqual(openedDirectories, ["/workspace/from-terminal"])
        XCTAssertEqual(viewModel.workspaceTerminalStatus, .syncPending)
    }

    func testStartConnectionWorkspaceErrorsUseExistingFailurePath() async throws {
        for (code, message) in [
            ("mount_failed", "Mount failed."),
            ("workspace_runtime_unavailable", "Workspace runtime unavailable.")
        ] {
            let client = MockTerminalClient()
            client.createConnectionError = BackendClientError.rpcError(code: code, message: message)
            let viewModel = makeViewModel(client: client, requestIds: ["req-1"])

            viewModel.startConnection(connectionId: "conn-1")
            try await waitUntil { viewModel.status == .error }

            XCTAssertTrue(client.didDisconnect)
            XCTAssertEqual(viewModel.errorText, message)
            XCTAssertNil(viewModel.sessionId)
            XCTAssertEqual(client.connectionCreateRequests.count, 1)
        }
    }

    func testCloseWhileConnectionCreateIsInFlightIgnoresLateCreate() async throws {
        let client = MockTerminalClient()
        client.suspendConnectionCreate = true
        let viewModel = makeViewModel(client: client, requestIds: ["req-1"])

        viewModel.startConnection(connectionId: "conn-1")
        try await waitUntil { client.connectionCreateRequests.count == 1 }

        viewModel.close()
        try await waitUntil { client.createConnectionWasCancelled }

        XCTAssertTrue(client.didDisconnect)
        XCTAssertEqual(viewModel.status, .exited)
        XCTAssertNil(viewModel.sessionId)

        client.resumeConnectionCreate()
        client.emit(.created(sessionId: "late-session", id: "req-1", cols: 80, rows: 24))
        try await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(viewModel.status, .exited)
        XCTAssertNil(viewModel.sessionId)
    }

    func testOutputWritesToAttachedRenderer() async throws {
        let client = MockTerminalClient()
        let renderer = MockTerminalRenderer()
        let viewModel = makeViewModel(client: client, requestIds: ["req-1"])
        viewModel.attachRenderer(renderer)

        viewModel.start(cwd: "/workspace")
        try await waitUntil { client.createRequests.count == 1 }
        client.emit(.created(sessionId: "session-1", id: "req-1", cols: 80, rows: 24))

        client.emit(.output(sessionId: "session-1", bytes: [0x24, 0x20]))
        try await waitUntil { renderer.writtenBytes.count == 1 }

        XCTAssertEqual(renderer.writtenBytes, [[0x24, 0x20]])
    }

    func testBurstInputIsCoalescedBeforeSending() async throws {
        let client = MockTerminalClient()
        let viewModel = makeViewModel(client: client, requestIds: ["req-1"])

        viewModel.start(cwd: "/workspace")
        try await waitUntil { client.createRequests.count == 1 }
        client.emit(.created(sessionId: "session-1", id: "req-1", cols: 80, rows: 24))

        viewModel.sendInput([0x61])
        viewModel.sendInput([0x62, 0x63])
        try await waitUntil { client.inputRequests.count == 1 }

        XCTAssertEqual(
            client.inputRequests,
            [MockTerminalClient.InputRequest(sessionId: "session-1", bytes: [0x61, 0x62, 0x63])]
        )
    }

    func testResizeUsesRequestCorrelation() async throws {
        let client = MockTerminalClient()
        let viewModel = makeViewModel(client: client, requestIds: ["req-1", "req-2"])

        viewModel.start(cwd: "/workspace")
        try await waitUntil { client.createRequests.count == 1 }
        client.emit(.created(sessionId: "session-1", id: "req-1", cols: 80, rows: 24))

        viewModel.resize(cols: 120, rows: 40)
        try await waitUntil { client.resizeRequests.count == 1 }

        XCTAssertEqual(viewModel.status, .resizing)
        XCTAssertEqual(client.resizeRequests.first?.requestId, "req-2")

        client.emit(.resized(sessionId: "session-1", id: "req-2", cols: 120, rows: 40))

        XCTAssertEqual(viewModel.status, .active)
        XCTAssertEqual(viewModel.cols, 120)
        XCTAssertEqual(viewModel.rows, 40)
    }

    func testResizeMeasuredBeforeCreateIsSentAfterSessionIsCreated() async throws {
        let client = MockTerminalClient()
        let viewModel = makeViewModel(client: client, requestIds: ["req-1", "req-2"])

        viewModel.start(cwd: "/workspace")
        try await waitUntil { client.createRequests.count == 1 }

        viewModel.resize(cols: 132, rows: 38)
        client.emit(.created(sessionId: "session-1", id: "req-1", cols: 80, rows: 24))
        try await waitUntil { client.resizeRequests.count == 1 }

        XCTAssertEqual(viewModel.status, .resizing)
        XCTAssertEqual(viewModel.cols, 132)
        XCTAssertEqual(viewModel.rows, 38)
        XCTAssertEqual(
            client.resizeRequests.first,
            MockTerminalClient.ResizeRequest(
                sessionId: "session-1",
                cols: 132,
                rows: 38,
                requestId: "req-2"
            )
        )
    }

    func testCloseSendsTerminalCloseAndEndsAfterExit() async throws {
        let client = MockTerminalClient()
        let viewModel = makeViewModel(client: client, requestIds: ["req-1", "req-2"])
        var didEnd = false
        viewModel.onSessionEnded = {
            didEnd = true
        }

        viewModel.start(cwd: "/workspace")
        try await waitUntil { client.createRequests.count == 1 }
        client.emit(.created(sessionId: "session-1", id: "req-1", cols: 80, rows: 24))

        viewModel.close()
        try await waitUntil { client.closeRequests.count == 1 }

        XCTAssertEqual(viewModel.status, .closing)
        XCTAssertEqual(client.closeRequests.first?.sessionId, "session-1")
        XCTAssertEqual(client.closeRequests.first?.requestId, "req-2")

        client.emit(.closed(sessionId: "session-1", id: "req-2"))
        XCTAssertEqual(viewModel.status, .closing)

        client.emit(.exit(sessionId: "session-1", code: 0, signal: nil))

        XCTAssertEqual(viewModel.status, .exited)
        XCTAssertNil(viewModel.sessionId)
        XCTAssertTrue(client.didDisconnect)
        XCTAssertTrue(didEnd)
    }

    func testSocketDisconnectInvalidatesSession() async throws {
        let client = MockTerminalClient()
        let viewModel = makeViewModel(client: client, requestIds: ["req-1"])

        viewModel.start(cwd: "/workspace")
        try await waitUntil { client.createRequests.count == 1 }
        client.emit(.created(sessionId: "session-1", id: "req-1", cols: 80, rows: 24))

        client.emitError(MockTerminalError.disconnected)

        XCTAssertEqual(viewModel.status, .error)
        XCTAssertNil(viewModel.sessionId)
        XCTAssertEqual(viewModel.errorText, MockTerminalError.disconnected.localizedDescription)
    }

    private func makeViewModel(
        client: MockTerminalClient,
        requestIds: [String]
    ) -> TerminalSessionViewModel {
        var ids = requestIds
        return TerminalSessionViewModel(
            terminalClient: client,
            requestIdGenerator: {
                ids.removeFirst()
            }
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<100 {
            if condition() {
                return
            }

            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTFail("Condition did not become true in time.")
    }
}

@MainActor
private final class MockTerminalClient: TerminalClientProtocol {
    private(set) var didConnect = false
    private(set) var didDisconnect = false
    private(set) var createRequests: [CreateRequest] = []
    private(set) var connectionCreateRequests: [ConnectionCreateRequest] = []
    private(set) var workspaceCreateRequests: [WorkspaceCreateRequest] = []
    private(set) var cwdUpdateRequests: [CwdUpdateRequest] = []
    private(set) var cwdCompareRequests: [String] = []
    private(set) var changeDirectoryRequests: [ChangeDirectoryRequest] = []
    private(set) var inputRequests: [InputRequest] = []
    private(set) var resizeRequests: [ResizeRequest] = []
    private(set) var closeRequests: [CloseRequest] = []
    var createConnectionError: Error?
    var suspendConnectionCreate = false
    var workingDirectoryUpdate: TerminalWorkingDirectoryUpdate?
    private(set) var createConnectionWasCancelled = false

    private var onEvent: (@MainActor (TerminalServerEvent) -> Void)?
    private var onError: (@MainActor (Error) -> Void)?
    private var connectionCreateContinuation: CheckedContinuation<Void, Error>?

    func connect(
        onEvent: @escaping @MainActor (TerminalServerEvent) -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        didConnect = true
        self.onEvent = onEvent
        self.onError = onError
    }

    func disconnect() {
        didDisconnect = true
        onEvent = nil
        onError = nil
    }

    func create(cwd: String, cols: Int, rows: Int, requestId: String) async throws {
        createRequests.append(
            CreateRequest(cwd: cwd, cols: cols, rows: rows, requestId: requestId)
        )
    }

    func createConnection(connectionId: String, cols: Int, rows: Int, requestId: String) async throws {
        connectionCreateRequests.append(
            ConnectionCreateRequest(
                connectionId: connectionId,
                cols: cols,
                rows: rows,
                requestId: requestId
            )
        )
        if suspendConnectionCreate {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    connectionCreateContinuation = continuation
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.createConnectionWasCancelled = true
                    self?.resumeConnectionCreate(throwing: CancellationError())
                }
            }
        }
        if let createConnectionError {
            throw createConnectionError
        }
    }

    func createWorkspace(cols: Int, rows: Int, requestId: String) async throws -> WorkspaceTerminalCreateResult {
        workspaceCreateRequests.append(
            WorkspaceCreateRequest(cols: cols, rows: rows, requestId: requestId)
        )
        return WorkspaceTerminalCreateResult(
            binding: WorkspaceTerminalBinding(
                sessionId: "workspace-session",
                kind: .local,
                launchWorkspaceRoot: "/workspace",
                launchWorkspaceCurrentDirectory: "/workspace",
                scheme: "local",
                connectionId: nil,
                latestTerminalWorkingDirectory: nil,
                syncCapability: .bidirectionalLocal
            )
        )
    }

    func updateWorkingDirectory(
        sessionId: String,
        directoryUrl: String
    ) async throws -> TerminalWorkingDirectoryUpdate {
        cwdUpdateRequests.append(CwdUpdateRequest(sessionId: sessionId, directoryUrl: directoryUrl))
        if let workingDirectoryUpdate {
            return workingDirectoryUpdate
        }

        return TerminalWorkingDirectoryUpdate(
            binding: WorkspaceTerminalBinding(
                sessionId: sessionId,
                kind: .local,
                launchWorkspaceRoot: "/workspace",
                launchWorkspaceCurrentDirectory: "/workspace",
                scheme: "local",
                connectionId: nil,
                latestTerminalWorkingDirectory: directoryUrl,
                syncCapability: .bidirectionalLocal
            ),
            reportedDirectory: directoryUrl,
            openable: true,
            matchesCurrent: true,
            reason: nil
        )
    }

    func compareWorkingDirectory(sessionId: String) async throws -> TerminalWorkingDirectoryUpdate {
        cwdCompareRequests.append(sessionId)
        return TerminalWorkingDirectoryUpdate(
            binding: WorkspaceTerminalBinding(
                sessionId: sessionId,
                kind: .local,
                launchWorkspaceRoot: "/workspace",
                launchWorkspaceCurrentDirectory: "/workspace",
                scheme: "local",
                connectionId: nil,
                latestTerminalWorkingDirectory: "/workspace",
                syncCapability: .bidirectionalLocal
            ),
            reportedDirectory: "/workspace",
            openable: true,
            matchesCurrent: true,
            reason: nil
        )
    }

    func changeDirectory(
        sessionId: String,
        targetDirectory: String
    ) async throws -> TerminalDirectoryChange {
        changeDirectoryRequests.append(
            ChangeDirectoryRequest(sessionId: sessionId, targetDirectory: targetDirectory)
        )
        return TerminalDirectoryChange(
            binding: WorkspaceTerminalBinding(
                sessionId: sessionId,
                kind: .local,
                launchWorkspaceRoot: "/workspace",
                launchWorkspaceCurrentDirectory: "/workspace",
                scheme: "local",
                connectionId: nil,
                latestTerminalWorkingDirectory: nil,
                syncCapability: .bidirectionalLocal
            ),
            queued: true,
            targetDirectory: targetDirectory,
            reason: nil
        )
    }

    func resumeConnectionCreate(throwing error: Error? = nil) {
        guard let continuation = connectionCreateContinuation else {
            return
        }

        connectionCreateContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    func shutdownWorkspace() async {
    }

    func sendInput(sessionId: String, bytes: [UInt8]) async throws {
        inputRequests.append(InputRequest(sessionId: sessionId, bytes: bytes))
    }

    func resize(sessionId: String, cols: Int, rows: Int, requestId: String) async throws {
        resizeRequests.append(
            ResizeRequest(
                sessionId: sessionId,
                cols: cols,
                rows: rows,
                requestId: requestId
            )
        )
    }

    func close(sessionId: String, requestId: String) async throws {
        closeRequests.append(CloseRequest(sessionId: sessionId, requestId: requestId))
    }

    func emit(_ event: TerminalServerEvent) {
        onEvent?(event)
    }

    func emitError(_ error: Error) {
        onError?(error)
    }

    struct CreateRequest: Equatable {
        let cwd: String
        let cols: Int
        let rows: Int
        let requestId: String
    }

    struct ConnectionCreateRequest: Equatable {
        let connectionId: String
        let cols: Int
        let rows: Int
        let requestId: String
    }

    struct WorkspaceCreateRequest: Equatable {
        let cols: Int
        let rows: Int
        let requestId: String
    }

    struct CwdUpdateRequest: Equatable {
        let sessionId: String
        let directoryUrl: String
    }

    struct ChangeDirectoryRequest: Equatable {
        let sessionId: String
        let targetDirectory: String
    }

    struct InputRequest: Equatable {
        let sessionId: String
        let bytes: [UInt8]
    }

    struct ResizeRequest: Equatable {
        let sessionId: String
        let cols: Int
        let rows: Int
        let requestId: String
    }

    struct CloseRequest: Equatable {
        let sessionId: String
        let requestId: String
    }
}

@MainActor
private final class MockTerminalRenderer: TerminalRendering {
    private(set) var writtenBytes: [[UInt8]] = []
    private(set) var didReset = false

    func write(_ bytes: [UInt8]) {
        writtenBytes.append(bytes)
    }

    func reset() {
        didReset = true
    }
}

private enum MockTerminalError: LocalizedError {
    case disconnected

    var errorDescription: String? {
        switch self {
        case .disconnected:
            return "Terminal socket disconnected."
        }
    }
}
