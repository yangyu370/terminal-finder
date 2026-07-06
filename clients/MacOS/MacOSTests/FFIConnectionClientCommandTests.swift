import Foundation
import XCTest
@testable import MacOS

/// Locks that FFIConnectionClient.list/remove route through command_invoke
/// against a real in-process core, and that create/restore still work (they
/// stay on the granular FFI methods because they carry credentials).
final class FFIConnectionClientCommandTests: XCTestCase {
    private func makeConnection(on core: CoreHandle, displayName: String) -> String {
        core.connectionCreate(
            displayName: displayName,
            endpoint: "http://127.0.0.1:1",
            region: "us-east-1",
            bucket: "bucket",
            basePrefix: "prefix/",
            pathStyle: true,
            accessKeyId: "x",
            secretAccessKey: "x"
        )
    }

    func testListReturnsCreatedConnectionThroughCommandInvoke() async throws {
        let core = CoreHandle()
        let client = FFIConnectionClient(core: core)
        let id = makeConnection(on: core, displayName: "prod")

        let summaries = try await client.list()

        let match = try XCTUnwrap(summaries.first { $0.connectionId == id })
        XCTAssertEqual(match.displayName, "prod")
        XCTAssertEqual(match.bucket, "bucket")
        XCTAssertEqual(match.basePrefix, "prefix/")
    }

    func testRemoveDelistsConnectionThroughCommandInvoke() async throws {
        let core = CoreHandle()
        let client = FFIConnectionClient(core: core)
        let id = makeConnection(on: core, displayName: "temp")

        try await client.remove(connectionId: id)

        let summaries = try await client.list()
        XCTAssertFalse(summaries.contains { $0.connectionId == id })
    }

    func testRemoveUnknownIdMapsConnectionNotFoundRpcError() async throws {
        let client = FFIConnectionClient(core: CoreHandle())

        do {
            try await client.remove(connectionId: "nonexistent")
            XCTFail("Expected rpcError(connection_not_found).")
        } catch BackendClientError.rpcError(let code, let message) {
            XCTAssertEqual(code, "connection_not_found")
            XCTAssertFalse(message.isEmpty)
        }
    }
}
