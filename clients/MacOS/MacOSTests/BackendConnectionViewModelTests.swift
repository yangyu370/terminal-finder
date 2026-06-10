import XCTest
@testable import MacOS

@MainActor
final class BackendConnectionViewModelTests: XCTestCase {
    func testConnectStartsEventsAfterHealthSucceeds() async throws {
        let eventClient = MockEventClient()
        let viewModel = BackendConnectionViewModel(
            backendClient: MockBackendClient(),
            eventClient: eventClient
        )

        viewModel.connect()
        try await waitUntil { viewModel.isConnected }

        XCTAssertTrue(eventClient.didConnect)
        XCTAssertEqual(viewModel.eventStatusText, "connecting events...")
    }

    func testReadyAndHeartbeatUpdateEventStatusText() async throws {
        let eventClient = MockEventClient()
        let viewModel = BackendConnectionViewModel(
            backendClient: MockBackendClient(),
            eventClient: eventClient
        )

        viewModel.connect()
        try await waitUntil { eventClient.didConnect }

        eventClient.send(.backendReady(service: "terminal-finder-core", version: "test"))
        XCTAssertEqual(viewModel.eventStatusText, "events connected")

        eventClient.send(.heartbeat)
        XCTAssertTrue(viewModel.eventStatusText.hasPrefix("events connected - heartbeat "))
    }

    func testConnectionFailureShowsWorkspaceAlert() async throws {
        let backendClient = MockBackendClient(healthError: MockConnectionError.healthFailed)
        let alerts = MockWorkspaceAlertPresenter()
        let viewModel = BackendConnectionViewModel(
            backendClient: backendClient,
            eventClient: MockEventClient(),
            workspaceAlertPresenter: alerts
        )

        viewModel.connect()
        try await waitUntil { !viewModel.isConnecting }

        XCTAssertEqual(viewModel.status, .disconnected)
        XCTAssertEqual(viewModel.detailText, MockConnectionError.healthFailed.localizedDescription)
        XCTAssertEqual(alerts.warnings.count, 1)
        XCTAssertEqual(alerts.warnings.first?.message, "Core can’t be reached.")
        XCTAssertEqual(alerts.warnings.first?.detailText, MockConnectionError.healthFailed.localizedDescription)
    }

    func testEventConnectionFailureShowsWorkspaceAlert() async throws {
        let eventClient = MockEventClient()
        let alerts = MockWorkspaceAlertPresenter()
        let viewModel = BackendConnectionViewModel(
            backendClient: MockBackendClient(),
            eventClient: eventClient,
            workspaceAlertPresenter: alerts
        )

        viewModel.connect()
        try await waitUntil { eventClient.didConnect }

        eventClient.sendError(MockConnectionError.eventDisconnected)

        XCTAssertEqual(alerts.warnings.count, 1)
        XCTAssertEqual(alerts.warnings.first?.message, "Event stream disconnected.")
        XCTAssertEqual(alerts.warnings.first?.detailText, MockConnectionError.eventDisconnected.localizedDescription)
        XCTAssertEqual(viewModel.eventStatusText, "events disconnected - Event socket disconnected.")
    }

    func testMissingEventHeartbeatDisconnectsEventsAndShowsWorkspaceAlert() async throws {
        let eventClient = MockEventClient()
        let alerts = MockWorkspaceAlertPresenter()
        let viewModel = BackendConnectionViewModel(
            backendClient: MockBackendClient(),
            eventClient: eventClient,
            workspaceAlertPresenter: alerts,
            eventHeartbeatTimeoutNanoseconds: 10_000_000
        )

        viewModel.connect()
        try await waitUntil { eventClient.didConnect }
        try await waitUntil { eventClient.didDisconnect }

        XCTAssertEqual(alerts.warnings.count, 1)
        XCTAssertEqual(alerts.warnings.first?.message, "Event stream disconnected.")
        XCTAssertEqual(alerts.warnings.first?.detailText, BackendConnectionError.eventHeartbeatTimedOut.localizedDescription)
        XCTAssertEqual(viewModel.eventStatusText, "events disconnected - Core event heartbeat timed out.")
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
private final class MockBackendClient: BackendClientProtocol {
    private let healthError: Error?

    init(healthError: Error? = nil) {
        self.healthError = healthError
    }

    func health() async throws -> PingResult {
        if let healthError {
            throw healthError
        }

        return PingResult(service: "test-core", version: "test")
    }

    func ping() async throws -> PingResult {
        PingResult(service: "test-core", version: "test")
    }

    func getState() async throws -> WorkspaceState {
        WorkspaceState(currentDirectory: "/workspace", workspaceRoot: "/workspace")
    }

    func openDirectory(path: String) async throws -> OpenDirectoryResult {
        OpenDirectoryResult(
            state: WorkspaceState(currentDirectory: path, workspaceRoot: "/workspace"),
            listing: nil
        )
    }

    func listDirectory(path: String) async throws -> DirectoryListing {
        DirectoryListing(path: path, entries: [])
    }
}

@MainActor
private final class MockEventClient: EventClientProtocol {
    private(set) var didConnect = false
    private(set) var didDisconnect = false
    private var onEvent: (@MainActor (BackendEvent) -> Void)?
    private var onError: (@MainActor (Error) -> Void)?

    func connect(
        onEvent: @escaping @MainActor (BackendEvent) -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        didConnect = true
        self.onEvent = onEvent
        self.onError = onError
    }

    func disconnect() {
        didDisconnect = true
    }

    func send(_ event: BackendEvent) {
        onEvent?(event)
    }

    func sendError(_ error: Error) {
        onError?(error)
    }
}

@MainActor
private final class MockWorkspaceAlertPresenter: WorkspaceAlertPresenting {
    private(set) var warnings: [WorkspaceAlertWarning] = []

    func showWarning(_ warning: WorkspaceAlertWarning) {
        warnings.append(warning)
    }
}

private enum MockConnectionError: LocalizedError {
    case healthFailed
    case eventDisconnected

    var errorDescription: String? {
        switch self {
        case .healthFailed:
            return "Health check failed."
        case .eventDisconnected:
            return "Event socket disconnected."
        }
    }
}
