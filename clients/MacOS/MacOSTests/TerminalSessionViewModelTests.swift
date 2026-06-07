import XCTest
@testable import MacOS

@MainActor
final class TerminalSessionViewModelTests: XCTestCase {
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
    private(set) var inputRequests: [InputRequest] = []
    private(set) var resizeRequests: [ResizeRequest] = []
    private(set) var closeRequests: [CloseRequest] = []

    private var onEvent: (@MainActor (TerminalServerEvent) -> Void)?
    private var onError: (@MainActor (Error) -> Void)?

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
    }

    func create(cwd: String, cols: Int, rows: Int, requestId: String) async throws {
        createRequests.append(
            CreateRequest(cwd: cwd, cols: cols, rows: rows, requestId: requestId)
        )
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
