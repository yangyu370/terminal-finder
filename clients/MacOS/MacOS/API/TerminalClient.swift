//
//  TerminalClient.swift
//  MacOS
//
//  Created by Codex on 2026/6/7.
//

import Foundation
import os

@MainActor
protocol TerminalClientProtocol: AnyObject {
    func connect(
        onEvent: @escaping @MainActor (TerminalServerEvent) -> Void,
        onError: @escaping @MainActor (Error) -> Void
    )
    func disconnect()
    func create(cwd: String, cols: Int, rows: Int, requestId: String) async throws
    func createConnection(connectionId: String, cols: Int, rows: Int, requestId: String) async throws
    func shutdownWorkspace() async
    func sendInput(sessionId: String, bytes: [UInt8]) async throws
    func resize(sessionId: String, cols: Int, rows: Int, requestId: String) async throws
    func close(sessionId: String, requestId: String) async throws
}

nonisolated enum TerminalServerEvent: Equatable {
    case created(sessionId: String, id: String?, cols: Int, rows: Int)
    case output(sessionId: String, bytes: [UInt8])
    case resized(sessionId: String, id: String?, cols: Int, rows: Int)
    case closed(sessionId: String, id: String?)
    case exit(sessionId: String, code: Int?, signal: Int?)
    case error(sessionId: String?, id: String?, code: String, message: String)
    case unknown(type: String)
}

@MainActor
final class TerminalClient: TerminalClientProtocol {
    static let defaultEndpoint = URL(string: "ws://127.0.0.1:3587/terminal")!

    private let endpoint: URL
    private let session: URLSession
    private let sender = TerminalWebSocketSender()
    private let logger = Logger(subsystem: "wang.MacOS", category: "terminal")
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    init(
        endpoint: URL? = nil,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint ?? TerminalClient.defaultEndpoint
        self.session = session
    }

    deinit {
        receiveTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    func connect(
        onEvent: @escaping @MainActor (TerminalServerEvent) -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        disconnect()
        logger.info("terminal websocket connecting endpoint=\(self.endpoint.absoluteString, privacy: .public)")

        let task = session.webSocketTask(with: endpoint)
        webSocketTask = task
        task.resume()

        receiveTask = Task.detached(priority: .userInitiated) { [task, logger] in
            await Self.receiveLoop(
                task: task,
                logger: logger,
                onEvent: onEvent,
                onError: onError
            )
        }
    }

    func disconnect() {
        if webSocketTask != nil || receiveTask != nil {
            logger.info("terminal websocket disconnect requested")
        }
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    func create(cwd: String, cols: Int, rows: Int, requestId: String) async throws {
        try await send(
            TerminalOutgoingEnvelope(
                type: "terminal.create",
                sessionId: nil,
                id: requestId,
                data: .create(cwd: cwd, cols: UInt16(clamping: cols), rows: UInt16(clamping: rows))
            )
        )
    }

    func createConnection(connectionId: String, cols: Int, rows: Int, requestId: String) async throws {
        throw TerminalClientError.invalidData("connection terminal requires the in-process FFI client")
    }

    func shutdownWorkspace() async {
    }

    func sendInput(sessionId: String, bytes: [UInt8]) async throws {
        try await send(
            TerminalOutgoingEnvelope(
                type: "terminal.input",
                sessionId: sessionId,
                id: nil,
                data: .bytes(bytes)
            )
        )
    }

    func resize(sessionId: String, cols: Int, rows: Int, requestId: String) async throws {
        try await send(
            TerminalOutgoingEnvelope(
                type: "terminal.resize",
                sessionId: sessionId,
                id: requestId,
                data: .resize(cols: UInt16(clamping: cols), rows: UInt16(clamping: rows))
            )
        )
    }

    func close(sessionId: String, requestId: String) async throws {
        try await send(
            TerminalOutgoingEnvelope(
                type: "terminal.close",
                sessionId: sessionId,
                id: requestId,
                data: .empty
            )
        )
    }

    private func send(_ envelope: TerminalOutgoingEnvelope) async throws {
        try await sender.send(envelope, task: webSocketTask)
    }

    private nonisolated static func receiveLoop(
        task: URLSessionWebSocketTask,
        logger: Logger,
        onEvent: @escaping @MainActor (TerminalServerEvent) -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) async {
        do {
            while !Task.isCancelled {
                let message = try await task.receive()
                let event = try Self.decode(message)
                if event.shouldLogReceipt {
                    logger.info("terminal websocket event received type=\(event.logType, privacy: .public)")
                }
                await MainActor.run {
                    onEvent(event)
                }
            }
        } catch is CancellationError {
            logger.info("terminal websocket receive loop cancelled")
        } catch {
            logger.warning("terminal websocket receive failed message=\(error.localizedDescription, privacy: .public)")
            await MainActor.run {
                onError(error)
            }
        }
    }

    nonisolated static func decode(_ message: URLSessionWebSocketTask.Message) throws -> TerminalServerEvent {
        let data: Data
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let messageData):
            data = messageData
        @unknown default:
            throw TerminalClientError.unsupportedMessage
        }

        let envelope = try JSONDecoder().decode(TerminalIncomingEnvelope.self, from: data)
        return try envelope.event()
    }
}

private actor TerminalWebSocketSender {
    func send(_ envelope: TerminalOutgoingEnvelope, task: URLSessionWebSocketTask?) async throws {
        guard let task else {
            throw TerminalClientError.notConnected
        }

        let data = try JSONEncoder().encode(envelope)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TerminalClientError.invalidJSON
        }

        try await task.send(.string(text))
    }
}

nonisolated struct TerminalOutgoingEnvelope: Encodable, Equatable {
    let type: String
    let sessionId: String?
    let id: String?
    let data: TerminalOutgoingData

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId
        case id
        case data
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(data, forKey: .data)
    }
}

nonisolated enum TerminalOutgoingData: Encodable, Equatable {
    case create(cwd: String, cols: UInt16, rows: UInt16)
    case bytes([UInt8])
    case resize(cols: UInt16, rows: UInt16)
    case empty

    enum CodingKeys: String, CodingKey {
        case cwd
        case cols
        case rows
        case shell
        case bytes
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .create(let cwd, let cols, let rows):
            try container.encode(cwd, forKey: .cwd)
            try container.encode(cols, forKey: .cols)
            try container.encode(rows, forKey: .rows)
            try container.encodeNil(forKey: .shell)
        case .bytes(let bytes):
            try container.encode(Data(bytes).base64EncodedString(), forKey: .bytes)
        case .resize(let cols, let rows):
            try container.encode(cols, forKey: .cols)
            try container.encode(rows, forKey: .rows)
        case .empty:
            break
        }
    }
}

nonisolated private struct TerminalIncomingEnvelope: Decodable {
    let type: String
    let sessionId: String?
    let id: String?
    let data: TerminalIncomingData

    func event() throws -> TerminalServerEvent {
        switch type {
        case "terminal.created":
            guard let sessionId else {
                throw TerminalClientError.missingSessionId
            }
            return .created(
                sessionId: sessionId,
                id: id,
                cols: try data.requiredCols(),
                rows: try data.requiredRows()
            )
        case "terminal.output":
            guard let sessionId else {
                throw TerminalClientError.missingSessionId
            }
            return .output(sessionId: sessionId, bytes: try data.requiredBytes())
        case "terminal.resized":
            guard let sessionId else {
                throw TerminalClientError.missingSessionId
            }
            return .resized(
                sessionId: sessionId,
                id: id,
                cols: try data.requiredCols(),
                rows: try data.requiredRows()
            )
        case "terminal.closed":
            guard let sessionId else {
                throw TerminalClientError.missingSessionId
            }
            return .closed(sessionId: sessionId, id: id)
        case "terminal.exit":
            guard let sessionId else {
                throw TerminalClientError.missingSessionId
            }
            return .exit(sessionId: sessionId, code: data.exitCode, signal: data.signal)
        case "terminal.error":
            return .error(
                sessionId: sessionId,
                id: id,
                code: try data.requiredCode(),
                message: try data.requiredMessage()
            )
        default:
            return .unknown(type: type)
        }
    }
}

nonisolated private struct TerminalIncomingData: Decodable {
    let cols: Int?
    let rows: Int?
    let bytes: String?
    let code: TerminalCodeValue?
    let signal: Int?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case cols
        case rows
        case bytes
        case code
        case signal
        case message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cols = try container.decodeIfPresent(Int.self, forKey: .cols)
        rows = try container.decodeIfPresent(Int.self, forKey: .rows)
        bytes = try container.decodeIfPresent(String.self, forKey: .bytes)
        code = try container.decodeIfPresent(TerminalCodeValue.self, forKey: .code)
        signal = try container.decodeIfPresent(Int.self, forKey: .signal)
        message = try container.decodeIfPresent(String.self, forKey: .message)
    }

    func requiredCols() throws -> Int {
        guard let cols else {
            throw TerminalClientError.invalidData("missing cols")
        }
        return cols
    }

    func requiredRows() throws -> Int {
        guard let rows else {
            throw TerminalClientError.invalidData("missing rows")
        }
        return rows
    }

    func requiredBytes() throws -> [UInt8] {
        guard let bytes,
              let data = Data(base64Encoded: bytes)
        else {
            throw TerminalClientError.invalidData("invalid bytes")
        }
        return Array(data)
    }

    func requiredCode() throws -> String {
        guard case .string(let value) = code else {
            throw TerminalClientError.invalidData("missing error code")
        }
        return value
    }

    func requiredMessage() throws -> String {
        guard let message else {
            throw TerminalClientError.invalidData("missing error message")
        }
        return message
    }
}

nonisolated private enum TerminalCodeValue: Decodable, Equatable {
    case int(Int)
    case string(String)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Int.self) {
            self = .int(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        self = .int(try container.decode(Int.self))
    }
}

private extension TerminalIncomingData {
    nonisolated var exitCode: Int? {
        guard case .int(let value) = code else {
            return nil
        }
        return value
    }
}

enum TerminalClientError: LocalizedError, Equatable {
    case notConnected
    case invalidJSON
    case unsupportedMessage
    case missingSessionId
    case invalidData(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Terminal channel is not connected."
        case .invalidJSON:
            return "Terminal message could not be encoded."
        case .unsupportedMessage:
            return "Core sent an unsupported terminal WebSocket message."
        case .missingSessionId:
            return "Core terminal message did not include a sessionId."
        case .invalidData(let reason):
            return "Core terminal message data is invalid: \(reason)."
        }
    }
}

private extension TerminalServerEvent {
    nonisolated var logType: String {
        switch self {
        case .created:
            return "terminal.created"
        case .output:
            return "terminal.output"
        case .resized:
            return "terminal.resized"
        case .closed:
            return "terminal.closed"
        case .exit:
            return "terminal.exit"
        case .error:
            return "terminal.error"
        case .unknown(let type):
            return type
        }
    }

    nonisolated var shouldLogReceipt: Bool {
        switch self {
        case .output:
            return false
        case .created, .resized, .closed, .exit, .error, .unknown:
            return true
        }
    }
}
