import XCTest
@testable import MacOS

final class KeychainServiceTests: XCTestCase {
    func test_save_load_roundtrip() throws {
        let service = InMemoryKeychainService()
        try service.save(
            connectionId: "conn-1",
            accessKeyId: "AKIA_TEST",
            secretAccessKey: "SECRET_TEST"
        )

        let loaded = try service.load(connectionId: "conn-1")
        XCTAssertEqual(loaded.accessKeyId, "AKIA_TEST")
        XCTAssertEqual(loaded.secretAccessKey, "SECRET_TEST")
    }

    func test_delete_removes_entry() throws {
        let service = InMemoryKeychainService()
        try service.save(
            connectionId: "conn-1",
            accessKeyId: "AKIA_TEST",
            secretAccessKey: "SECRET_TEST"
        )
        try service.delete(connectionId: "conn-1")
        XCTAssertThrowsError(try service.load(connectionId: "conn-1")) { error in
            guard case KeychainServiceError.notFound = error else {
                XCTFail("expected .notFound, got \(error)")
                return
            }
        }
    }

    func test_load_missing_throws_not_found() {
        let service = InMemoryKeychainService()
        XCTAssertThrowsError(try service.load(connectionId: "nonexistent")) { error in
            guard case KeychainServiceError.notFound = error else {
                XCTFail("expected .notFound, got \(error)")
                return
            }
        }
    }

    func test_save_twice_overwrites_existing_entry() throws {
        let service = InMemoryKeychainService()
        try service.save(
            connectionId: "conn-1",
            accessKeyId: "OLD_ACCESS",
            secretAccessKey: "OLD_SECRET"
        )
        try service.save(
            connectionId: "conn-1",
            accessKeyId: "NEW_ACCESS",
            secretAccessKey: "NEW_SECRET"
        )

        let loaded = try service.load(connectionId: "conn-1")
        XCTAssertEqual(loaded.accessKeyId, "NEW_ACCESS")
        XCTAssertEqual(loaded.secretAccessKey, "NEW_SECRET")
    }
}
