import XCTest
@testable import MacOS

@MainActor
final class ConnectionViewModelTests: XCTestCase {
    func test_create_persists_to_core_keychain_and_store() async throws {
        let keychain = InMemoryKeychainService()
        let store = InMemoryConnectionStore()
        let core = MockCoreConnectionClient()
        let vm = ConnectionViewModel(core: core, keychain: keychain, store: store)

        try await vm.create(
            displayName: "MinIO local",
            endpoint: "http://localhost:9000",
            region: "us-east-1",
            bucket: "test-bucket",
            basePrefix: "",
            pathStyle: true,
            accessKeyId: "AKIA",
            secretAccessKey: "SECRET"
        )

        XCTAssertEqual(core.createCalls.count, 1)
        XCTAssertEqual(core.createCalls[0].accessKeyId, "AKIA")
        XCTAssertEqual(core.createCalls[0].secretAccessKey, "SECRET")

        let id = core.createCalls[0].returnedId
        let creds = try keychain.load(connectionId: id)
        XCTAssertEqual(creds.accessKeyId, "AKIA")
        XCTAssertEqual(creds.secretAccessKey, "SECRET")

        let stored = store.load()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].connectionId, id)
        XCTAssertEqual(stored[0].displayName, "MinIO local")
        XCTAssertEqual(stored[0].kind, "s3")

        XCTAssertEqual(vm.connections.count, 1)
        XCTAssertEqual(vm.connections[0].id, id)
        XCTAssertEqual(vm.connections[0].displayName, "MinIO local")
    }

    func test_load_restores_from_store_into_core_with_stable_id() async throws {
        // Regression guard: load() MUST route through core.restore so the id
        // round-trips from disk into the registry. The old implementation
        // called create() and minted a fresh UUID, leaving the sidebar rows
        // pointing at ids core never registered ("connection not found" on
        // first click after restart).
        let keychain = InMemoryKeychainService()
        try keychain.save(connectionId: "id-1", accessKeyId: "AKIA", secretAccessKey: "SECRET")
        let store = InMemoryConnectionStore(initial: [
            StoredConnection(
                connectionId: "id-1",
                displayName: "Saved",
                endpoint: "http://localhost:9000",
                region: "us-east-1",
                bucket: "b",
                basePrefix: "",
                pathStyle: true
            )
        ])
        let core = MockCoreConnectionClient()
        let vm = ConnectionViewModel(core: core, keychain: keychain, store: store)

        try await vm.load()

        XCTAssertEqual(vm.connections.count, 1)
        XCTAssertEqual(vm.connections[0].id, "id-1")
        XCTAssertEqual(vm.connections[0].displayName, "Saved")

        // The fix: restore is called with the persisted id; create is NOT.
        XCTAssertEqual(core.createCalls.count, 0, "load() must not mint new ids")
        XCTAssertEqual(core.restoreCalls.count, 1)
        XCTAssertEqual(core.restoreCalls[0].connectionId, "id-1")
        XCTAssertEqual(core.restoreCalls[0].displayName, "Saved")
        XCTAssertEqual(core.restoreCalls[0].accessKeyId, "AKIA")
        XCTAssertEqual(core.restoreCalls[0].secretAccessKey, "SECRET")
    }

    func test_load_skips_orphan_store_entries_with_missing_keychain_credentials() async throws {
        let keychain = InMemoryKeychainService()  // empty
        let store = InMemoryConnectionStore(initial: [
            StoredConnection(
                connectionId: "orphan",
                displayName: "Orphan",
                endpoint: "e",
                region: "r",
                bucket: "b",
                basePrefix: "",
                pathStyle: true
            )
        ])
        let core = MockCoreConnectionClient()
        let vm = ConnectionViewModel(core: core, keychain: keychain, store: store)

        try await vm.load()

        XCTAssertEqual(vm.connections.count, 0)
        XCTAssertEqual(core.createCalls.count, 0)
    }

    func test_loadCapabilities_populatesMapFromCapabilitiesClient() {
        let core = MockCoreConnectionClient()
        let caps = MockCapabilitiesClient(
            stub: ProviderCapsDto(
                canRename: false,
                canSymlink: false,
                canWrite: true,
                hasNativeDirectories: false
            )
        )
        let vm = ConnectionViewModel(
            core: core,
            capabilitiesClient: caps,
            keychain: InMemoryKeychainService(),
            store: InMemoryConnectionStore()
        )

        vm.loadCapabilities(for: "conn-1")

        XCTAssertEqual(caps.queries, ["conn-1"])
        XCTAssertEqual(vm.capabilities["conn-1"]?.canRename, false)
        XCTAssertEqual(vm.capabilities["conn-1"]?.canWrite, true)
        XCTAssertEqual(vm.capabilities["conn-1"]?.hasNativeDirectories, false)
    }

    func test_remove_clears_core_keychain_and_store() async throws {
        let keychain = InMemoryKeychainService()
        try keychain.save(connectionId: "id-1", accessKeyId: "AKIA", secretAccessKey: "SECRET")
        let store = InMemoryConnectionStore(initial: [
            StoredConnection(
                connectionId: "id-1",
                displayName: "A",
                endpoint: "e",
                region: "r",
                bucket: "b",
                basePrefix: "",
                pathStyle: true
            )
        ])
        let core = MockCoreConnectionClient()
        let vm = ConnectionViewModel(core: core, keychain: keychain, store: store)
        try await vm.load()

        try await vm.remove(id: "id-1")

        XCTAssertEqual(core.removeCalls, ["id-1"])
        XCTAssertThrowsError(try keychain.load(connectionId: "id-1"))
        XCTAssertEqual(store.load(), [])
        XCTAssertEqual(vm.connections, [])
    }
}

// MARK: - Test doubles

final class MockCoreConnectionClient: CoreConnectionClientProtocol {
    struct CreateCall: Equatable {
        let displayName: String
        let accessKeyId: String
        let secretAccessKey: String
        let returnedId: String
    }

    struct RestoreCall: Equatable {
        let connectionId: String
        let displayName: String
        let accessKeyId: String
        let secretAccessKey: String
    }

    var createCalls: [CreateCall] = []
    var restoreCalls: [RestoreCall] = []
    var removeCalls: [String] = []
    private var nextIdSeed = 0

    func create(
        displayName: String,
        endpoint: String,
        region: String,
        bucket: String,
        basePrefix: String,
        pathStyle: Bool,
        accessKeyId: String,
        secretAccessKey: String
    ) async throws -> String {
        let id = "mock-\(nextIdSeed)"
        nextIdSeed += 1
        createCalls.append(
            CreateCall(
                displayName: displayName,
                accessKeyId: accessKeyId,
                secretAccessKey: secretAccessKey,
                returnedId: id
            )
        )
        return id
    }

    func restore(
        connectionId: String,
        displayName: String,
        endpoint: String,
        region: String,
        bucket: String,
        basePrefix: String,
        pathStyle: Bool,
        accessKeyId: String,
        secretAccessKey: String
    ) async throws {
        restoreCalls.append(
            RestoreCall(
                connectionId: connectionId,
                displayName: displayName,
                accessKeyId: accessKeyId,
                secretAccessKey: secretAccessKey
            )
        )
    }

    func list() async throws -> [CoreConnectionSummary] {
        []
    }

    func remove(connectionId: String) async throws {
        removeCalls.append(connectionId)
    }
}

final class MockCapabilitiesClient: CoreCapabilitiesClientProtocol {
    let stub: ProviderCapsDto
    private(set) var queries: [String] = []

    init(stub: ProviderCapsDto) {
        self.stub = stub
    }

    func connectionCapabilities(connectionId: String) throws -> ProviderCapsDto {
        queries.append(connectionId)
        return stub
    }
}

final class InMemoryConnectionStore: ConnectionStoring {
    private var connections: [StoredConnection]

    init(initial: [StoredConnection] = []) {
        self.connections = initial
    }

    func load() -> [StoredConnection] {
        connections
    }

    func upsert(_ connection: StoredConnection) throws {
        if let index = connections.firstIndex(where: { $0.connectionId == connection.connectionId }) {
            connections[index] = connection
        } else {
            connections.append(connection)
        }
    }

    func remove(connectionId: String) throws {
        connections.removeAll { $0.connectionId == connectionId }
    }
}
