import Foundation
import XCTest
@testable import MacOS

final class TerminalClientTests: XCTestCase {
    func testWebSocketClientRejectsConnectionTerminalCreation() async {
        let client = TerminalClient()

        do {
            try await client.createConnection(
                connectionId: "conn-1",
                cols: 80,
                rows: 24,
                requestId: "req-1"
            )
            XCTFail("Expected connection terminal creation to require the FFI client.")
        } catch {
            XCTAssertEqual(
                error as? TerminalClientError,
                .invalidData("connection terminal requires the in-process FFI client")
            )
        }
    }

    func testWebSocketClientRejectsWorkspaceTerminalHelpers() async {
        let client = TerminalClient()

        await assertTerminalClientInvalidData(
            try await client.createWorkspace(cols: 80, rows: 24, requestId: "req-1"),
            "workspace terminal requires the in-process FFI client"
        )
        await assertTerminalClientInvalidData(
            try await client.updateWorkingDirectory(
                sessionId: "session-1",
                directoryUrl: "file://localhost/tmp"
            ),
            "workspace terminal cwd updates require the in-process FFI client"
        )
        await assertTerminalClientInvalidData(
            try await client.compareWorkingDirectory(sessionId: "session-1"),
            "workspace terminal cwd comparison requires the in-process FFI client"
        )
        await assertTerminalClientInvalidData(
            try await client.changeDirectory(sessionId: "session-1", targetDirectory: "/tmp"),
            "workspace terminal directory changes require the in-process FFI client"
        )
    }

    func testCreateEnvelopeEncodesProtocolShape() throws {
        let envelope = TerminalOutgoingEnvelope(
            type: "terminal.create",
            sessionId: nil,
            id: "req-1",
            data: .create(cwd: "/workspace", cols: 80, rows: 24)
        )

        let data = try JSONEncoder().encode(envelope)
        let message = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let payload = message?["data"] as? [String: Any]

        XCTAssertEqual(message?["type"] as? String, "terminal.create")
        XCTAssertEqual(message?["id"] as? String, "req-1")
        XCTAssertNil(message?["sessionId"])
        XCTAssertEqual(payload?["cwd"] as? String, "/workspace")
        XCTAssertEqual(payload?["cols"] as? Int, 80)
        XCTAssertEqual(payload?["rows"] as? Int, 24)
        XCTAssertTrue(payload?["shell"] is NSNull)
    }

    func testInputEnvelopeEncodesBytesAsBase64() throws {
        let envelope = TerminalOutgoingEnvelope(
            type: "terminal.input",
            sessionId: "session-1",
            id: nil,
            data: .bytes([0x1b, 0x5b, 0x41])
        )

        let data = try JSONEncoder().encode(envelope)
        let message = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let payload = message?["data"] as? [String: Any]

        XCTAssertEqual(payload?["bytes"] as? String, "G1tB")
    }

    func testOutputEnvelopeDecodesBase64Bytes() throws {
        let message = URLSessionWebSocketTask.Message.string(
            """
            {"type":"terminal.output","sessionId":"session-1","data":{"bytes":"G1tB"}}
            """
        )

        let event = try TerminalClient.decode(message)

        XCTAssertEqual(event, .output(sessionId: "session-1", bytes: [0x1b, 0x5b, 0x41]))
    }

    func testErrorEnvelopeDecodesCodeAndMessage() throws {
        let message = URLSessionWebSocketTask.Message.string(
            """
            {"type":"terminal.error","sessionId":"session-1","id":"req-2","data":{"code":"unknown_session","message":"missing"}}
            """
        )

        let event = try TerminalClient.decode(message)

        XCTAssertEqual(
            event,
            .error(
                sessionId: "session-1",
                id: "req-2",
                code: "unknown_session",
                message: "missing"
            )
        )
    }

    func testExitEnvelopeDecodesNullCode() throws {
        let message = URLSessionWebSocketTask.Message.string(
            """
            {"type":"terminal.exit","sessionId":"session-1","data":{"code":null,"signal":15}}
            """
        )

        let event = try TerminalClient.decode(message)

        XCTAssertEqual(event, .exit(sessionId: "session-1", code: nil, signal: 15))
    }

    private func assertTerminalClientInvalidData<T>(
        _ expression: @autoclosure () async throws -> T,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected invalidData error.", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? TerminalClientError, .invalidData(message), file: file, line: line)
        }
    }
}
