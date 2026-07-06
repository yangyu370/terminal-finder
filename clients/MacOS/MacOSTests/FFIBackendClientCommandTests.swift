import Foundation
import Darwin
import XCTest
@testable import MacOS

final class FFIBackendClientCommandTests: XCTestCase {
    func testOpenDirectoryRoutesThroughCommandInvoke() async throws {
        let core = RoutingProbeCoreHandle()
        let client = FFIBackendClient(core: core)

        let result = try await client.openDirectory(path: "/requested/open", connectionId: "conn-1")

        XCTAssertEqual(result.state.currentDirectory, "/command/opened")
        XCTAssertEqual(result.listing?.path, "/command/opened")
        XCTAssertTrue(result.listing?.entries.contains { $0.name == "entry.txt" } ?? false)
        XCTAssertEqual(core.commandInvocations.map(\.id), ["workspace.openDirectory"])

        let invocation = try XCTUnwrap(core.commandInvocations.first)
        let params = try decodeJSONObject(invocation.paramsJson)
        XCTAssertEqual(params["path"] as? String, "/requested/open")
        XCTAssertEqual(params["connection_id"] as? String, "conn-1")
    }

    func testListDirectoryRoutesThroughCommandInvoke() async throws {
        let core = RoutingProbeCoreHandle()
        let client = FFIBackendClient(core: core)

        let listing = try await client.listDirectory(path: "/requested/list", connectionId: nil)

        XCTAssertEqual(listing.path, "/command/listed")
        XCTAssertTrue(listing.entries.contains { $0.name == "entry.txt" })
        XCTAssertEqual(core.commandInvocations.map(\.id), ["workspace.listDirectory"])

        let invocation = try XCTUnwrap(core.commandInvocations.first)
        let params = try decodeJSONObject(invocation.paramsJson)
        XCTAssertEqual(params["path"] as? String, "/requested/list")
        XCTAssertNil(params["connection_id"])
    }

    func testGetStateStaysOnDirectWorkspaceState() async throws {
        let core = RoutingProbeCoreHandle()
        let client = FFIBackendClient(core: core)

        let state = try await client.getState()

        XCTAssertEqual(state.workspaceRoot, "/direct/root")
        XCTAssertEqual(state.currentDirectory, "/direct/current")
        XCTAssertEqual(state.scheme, "local")
        XCTAssertNil(state.connectionId)
        XCTAssertEqual(core.directWorkspaceStateCalls, 1)
        XCTAssertTrue(core.commandInvocations.isEmpty)
    }

    func testOpenDirectoryWithRealCoreReturnsListingAndUpdatedState() async throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("entry.txt", isDirectory: false)
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        let client = FFIBackendClient(core: CoreHandle())

        let result = try await client.openDirectory(path: directory.path, connectionId: nil)

        let canonicalPath = try canonicalPath(directory.path)
        XCTAssertEqual(result.state.currentDirectory, canonicalPath)
        XCTAssertEqual(result.listing?.path, canonicalPath)
        XCTAssertTrue(
            result.listing?.entries.contains { $0.name == "entry.txt" } ?? false,
            "Expected listing to contain entry.txt, got \(result.listing?.entries.map(\.name) ?? [])"
        )
    }

    func testListDirectoryWithRealCoreReturnsListing() async throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("entry.txt", isDirectory: false)
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        let client = FFIBackendClient(core: CoreHandle())

        let listing = try await client.listDirectory(path: directory.path, connectionId: nil)

        XCTAssertEqual(listing.path, directory.path)
        XCTAssertTrue(
            listing.entries.contains { $0.name == "entry.txt" },
            "Expected listing to contain entry.txt, got \(listing.entries.map(\.name))"
        )
    }

    func testOpenDirectoryWithFilePathMapsNotDirectoryRpcError() async throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("entry.txt", isDirectory: false)
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        let client = FFIBackendClient(core: CoreHandle())

        await assertRpcError(
            try await client.openDirectory(path: file.path, connectionId: nil),
            code: "not_directory"
        )
    }

    func testDeleteEntryWithRealCoreRemovesFile() async throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("victim.txt", isDirectory: false)
        try "bye".write(to: file, atomically: true, encoding: .utf8)
        let client = FFIBackendClient(core: CoreHandle())

        try await client.deleteEntry(connectionId: nil, path: file.path)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: file.path),
            "fs.delete via command_invoke must remove the file"
        )
    }

    func testCreateRemoteDirectoryWithRealCoreCreatesDirectory() async throws {
        let directory = try makeTemporaryDirectory()
        let newDir = directory.appendingPathComponent("made", isDirectory: true)
        let client = FFIBackendClient(core: CoreHandle())

        try await client.createRemoteDirectory(connectionId: nil, path: newDir.path)

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: newDir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue, "fs.mkdir must create a directory")
    }

    func testRenameEntryWithRealCoreMovesFile() async throws {
        let directory = try makeTemporaryDirectory()
        let from = directory.appendingPathComponent("from.txt", isDirectory: false)
        let to = directory.appendingPathComponent("to.txt", isDirectory: false)
        try "hi".write(to: from, atomically: true, encoding: .utf8)
        let client = FFIBackendClient(core: CoreHandle())

        try await client.renameEntry(connectionId: nil, from: from.path, to: to.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: from.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: to.path))
    }

    func testUploadFileWithMissingSourceMapsRpcError() async throws {
        let directory = try makeTemporaryDirectory()
        let missing = directory.appendingPathComponent("nope.txt", isDirectory: false)
        let dest = directory.appendingPathComponent("dest.txt", isDirectory: false)
        let client = FFIBackendClient(core: CoreHandle())

        await assertRpcError(
            try await client.uploadFile(
                connectionId: nil,
                remotePath: dest.path,
                localSource: missing.path
            ),
            code: "filesystem_read_failed"
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FFIBackendClientCommandTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func assertRpcError<T>(
        _ expression: @autoclosure () async throws -> T,
        code: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected BackendClientError.rpcError(\(code)).", file: file, line: line)
        } catch BackendClientError.rpcError(let actualCode, let message) {
            XCTAssertEqual(actualCode, code, file: file, line: line)
            XCTAssertFalse(message.isEmpty, file: file, line: line)
        } catch {
            XCTFail("Expected BackendClientError.rpcError(\(code)), got \(error).", file: file, line: line)
        }
    }
}

private final class RoutingProbeCoreHandle: CoreHandle, @unchecked Sendable {
    struct CommandInvocation {
        let id: String
        let paramsJson: String
    }

    private(set) var commandInvocations: [CommandInvocation] = []
    private(set) var directWorkspaceStateCalls = 0

    init() {
        super.init(noHandle: CoreHandle.NoHandle())
    }

    required init(unsafeFromHandle handle: UInt64) {
        super.init(unsafeFromHandle: handle)
    }

    override func commandInvoke(id: String, paramsJson: String) async throws -> String {
        commandInvocations.append(CommandInvocation(id: id, paramsJson: paramsJson))

        switch id {
        case "workspace.openDirectory":
            return try jsonString([
                "state": [
                    "workspaceRoot": "/command/root",
                    "currentDirectory": "/command/opened",
                    "scheme": "local",
                    "connectionId": NSNull()
                ],
                "listing": directoryListing(path: "/command/opened")
            ])
        case "workspace.listDirectory":
            return try jsonString(directoryListing(path: "/command/listed"))
        default:
            throw CoreError.Rpc(code: "unknown_method", message: "Unknown command id: \(id)")
        }
    }

    override func workspaceState() -> WorkspaceStateDto {
        directWorkspaceStateCalls += 1
        return WorkspaceStateDto(
            workspaceRoot: "/direct/root",
            currentDirectory: "/direct/current",
            scheme: "local",
            connectionId: nil
        )
    }

    private func directoryListing(path: String) -> [String: Any] {
        [
            "path": path,
            "entries": [
                [
                    "name": "entry.txt",
                    "path": "\(path)/entry.txt",
                    "kind": "file",
                    "isDirectory": false,
                    "size": 5,
                    "modifiedAt": NSNull()
                ]
            ]
        ]
    }

    private func jsonString(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }
}

private func decodeJSONObject(_ json: String) throws -> [String: Any] {
    let data = Data(json.utf8)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func canonicalPath(_ path: String) throws -> String {
    guard let result = realpath(path, nil) else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
    }
    defer { free(result) }
    return String(cString: result)
}
