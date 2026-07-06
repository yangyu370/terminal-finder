import Foundation
import XCTest
@testable import MacOS

final class CommandClientTests: XCTestCase {
    func testInvokeDecodesWorkspaceListDirectoryFromInProcessCore() async throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("entry.txt", isDirectory: false)
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        let client = FFICommandClient(core: CoreHandle())

        let listing: DirectoryListing = try await client.invoke(
            "workspace.listDirectory",
            ListDirectoryParams(path: directory.path, connectionId: nil)
        )

        XCTAssertEqual(listing.path, directory.path)
        XCTAssertTrue(
            listing.entries.contains { $0.name == "entry.txt" },
            "Expected listing to contain entry.txt, got \(listing.entries.map(\.name))"
        )
    }

    func testInvokeMapsUnknownCommandToBackendRpcError() async throws {
        let client = FFICommandClient(core: CoreHandle())

        await assertRpcError(
            try await client.invoke(
                "workspace.unknownCommand",
                EmptyParams()
            ) as DirectoryListing,
            code: "unknown_method"
        )
    }

    func testInvokeMapsOpenFileAsDirectoryToBackendRpcError() async throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("entry.txt", isDirectory: false)
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        let client = FFICommandClient(core: CoreHandle())

        await assertRpcError(
            try await client.invoke(
                "workspace.openDirectory",
                OpenDirectoryParams(path: file.path, connectionId: nil)
            ) as OpenDirectoryResult,
            code: "not_directory"
        )
    }

    func testInvokeVoidAcceptsSuccessfulCommandResultWithoutDecodingIt() async throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("entry.txt", isDirectory: false)
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        let client = FFICommandClient(core: CoreHandle())

        try await client.invokeVoid(
            "workspace.listDirectory",
            ListDirectoryParams(path: directory.path, connectionId: nil)
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommandClientTests-\(UUID().uuidString)", isDirectory: true)
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
