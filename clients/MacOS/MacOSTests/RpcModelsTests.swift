import XCTest
@testable import MacOS

final class RpcModelsTests: XCTestCase {
    func test_workspaceState_publicInit_defaultsToLocalScheme() {
        let state = WorkspaceState(currentDirectory: "/tmp")
        XCTAssertEqual(state.scheme, "local")
        XCTAssertNil(state.connectionId)
    }

    func test_workspaceState_decodes_scheme_and_connectionId() throws {
        let json = """
        {
            "currentDirectory": "bucket/prefix/",
            "workspaceRoot": "bucket/prefix/",
            "scheme": "s3",
            "connectionId": "abc-123"
        }
        """.data(using: .utf8)!

        let state = try JSONDecoder().decode(WorkspaceState.self, from: json)
        XCTAssertEqual(state.scheme, "s3")
        XCTAssertEqual(state.connectionId, "abc-123")
        XCTAssertEqual(state.currentDirectory, "bucket/prefix/")
    }

    func test_workspaceState_decoder_defaultsSchemeToLocal_whenAbsent() throws {
        let json = """
        { "currentDirectory": "/tmp" }
        """.data(using: .utf8)!

        let state = try JSONDecoder().decode(WorkspaceState.self, from: json)
        XCTAssertEqual(state.scheme, "local")
        XCTAssertNil(state.connectionId)
    }
}
