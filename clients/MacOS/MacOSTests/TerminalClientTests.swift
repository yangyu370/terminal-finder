import Foundation
import XCTest
@testable import MacOS

final class TerminalClientTests: XCTestCase {
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
}
