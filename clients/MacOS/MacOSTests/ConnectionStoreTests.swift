import XCTest
@testable import MacOS

final class ConnectionStoreTests: XCTestCase {
    private var tempDir: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("connection-store-tests-\(UUID().uuidString)", isDirectory: true)
        storeURL = tempDir.appendingPathComponent("connections.json", isDirectory: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func sampleConnection(id: String = "conn-1", name: String = "MinIO local") -> StoredConnection {
        StoredConnection(
            connectionId: id,
            displayName: name,
            endpoint: "http://localhost:9000",
            region: "us-east-1",
            bucket: "test-bucket",
            basePrefix: "",
            pathStyle: true
        )
    }

    func test_load_returns_empty_when_file_missing() {
        let store = ConnectionStore(fileURL: storeURL)
        XCTAssertEqual(store.load(), [])
    }

    func test_upsert_then_load_roundtrip() throws {
        let store = ConnectionStore(fileURL: storeURL)
        let conn = sampleConnection()
        try store.upsert(conn)
        XCTAssertEqual(store.load(), [conn])
    }

    func test_upsert_same_id_replaces_not_duplicates() throws {
        let store = ConnectionStore(fileURL: storeURL)
        try store.upsert(sampleConnection(id: "conn-1", name: "Old Name"))
        try store.upsert(sampleConnection(id: "conn-1", name: "New Name"))
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.displayName, "New Name")
    }

    func test_remove_deletes_entry() throws {
        let store = ConnectionStore(fileURL: storeURL)
        try store.upsert(sampleConnection(id: "conn-1"))
        try store.upsert(sampleConnection(id: "conn-2", name: "Second"))
        try store.remove(connectionId: "conn-1")
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.connectionId, "conn-2")
    }

    func test_remove_missing_id_is_noop() throws {
        let store = ConnectionStore(fileURL: storeURL)
        try store.upsert(sampleConnection(id: "conn-1"))
        try store.remove(connectionId: "nonexistent")
        XCTAssertEqual(store.load().count, 1)
    }

    func test_corrupt_file_loads_as_empty() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try Data("{ this is not valid json ]".utf8).write(to: storeURL)
        let store = ConnectionStore(fileURL: storeURL)
        XCTAssertEqual(store.load(), [], "corrupt file must not crash or throw — returns empty")
    }

    func test_persisted_json_contains_no_credentials() throws {
        let store = ConnectionStore(fileURL: storeURL)
        try store.upsert(sampleConnection())
        let raw = try String(contentsOf: storeURL, encoding: .utf8)
        XCTAssertFalse(raw.lowercased().contains("access_key"), "JSON must not contain access key")
        XCTAssertFalse(raw.lowercased().contains("secret"), "JSON must not contain secret")
        XCTAssertFalse(raw.contains("accessKeyId"), "JSON must not contain accessKeyId")
        XCTAssertFalse(raw.contains("secretAccessKey"), "JSON must not contain secretAccessKey")
    }

    /// Proves the design closes the loop: ConnectionStore (config) + Keychain
    /// (credential) together reconstitute every argument needed to re-register
    /// a connection in core via connectionCreate(...).
    func test_store_plus_keychain_reconstitutes_full_create_params() throws {
        let store = ConnectionStore(fileURL: storeURL)
        let keychain = InMemoryKeychainService()

        // Simulate an earlier create: persist config + credential under same id.
        let conn = sampleConnection(id: "conn-xyz", name: "Prod R2")
        try store.upsert(conn)
        try keychain.save(connectionId: conn.connectionId, accessKeyId: "AKIA_X", secretAccessKey: "SECRET_X")

        // Simulate a restart: load config, then fetch matching credential.
        let restored = store.load().first { $0.connectionId == "conn-xyz" }
        let cred = try keychain.load(connectionId: "conn-xyz")

        XCTAssertEqual(restored?.displayName, "Prod R2")
        XCTAssertEqual(restored?.endpoint, "http://localhost:9000")
        XCTAssertEqual(restored?.bucket, "test-bucket")
        XCTAssertEqual(restored?.pathStyle, true)
        XCTAssertEqual(cred.accessKeyId, "AKIA_X")
        XCTAssertEqual(cred.secretAccessKey, "SECRET_X")
        // All 8 connectionCreate args now available:
        // displayName, endpoint, region, bucket, basePrefix, pathStyle (from store)
        // + accessKeyId, secretAccessKey (from keychain)
    }
}
