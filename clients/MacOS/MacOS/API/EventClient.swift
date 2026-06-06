//
//  EventClient.swift
//  MacOS
//
//  Created by Codex on 2026/6/6.
//

import Foundation
import os

@MainActor
protocol EventClientProtocol: AnyObject {
    func connect(
        onEvent: @escaping @MainActor (BackendEvent) -> Void,
        onError: @escaping @MainActor (Error) -> Void
    )
    func disconnect()
}

enum BackendEvent: Equatable {
    case backendReady(service: String?, version: String?)
    case heartbeat
    case unknown(String)
}

@MainActor
final class EventClient: EventClientProtocol {
    static let defaultEndpoint = URL(string: "ws://127.0.0.1:3587/events")!

    private let endpoint: URL
    private let session: URLSession
    private let logger = Logger(subsystem: "wang.MacOS", category: "events")
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    init(
        endpoint: URL? = nil,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint ?? EventClient.defaultEndpoint
        self.session = session
    }

    deinit {
        receiveTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    func connect(
        onEvent: @escaping @MainActor (BackendEvent) -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        disconnect()
        logger.info("websocket connecting endpoint=\(self.endpoint.absoluteString, privacy: .public)")

        let task = session.webSocketTask(with: endpoint)
        webSocketTask = task
        task.resume()
        logger.info("websocket task resumed")

        receiveTask = Task { [weak self, task] in
            await self?.receiveLoop(
                task: task,
                onEvent: onEvent,
                onError: onError
            )
        }
    }

    func disconnect() {
        if webSocketTask != nil || receiveTask != nil {
            logger.info("websocket disconnect requested")
        }
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    private func receiveLoop(
        task: URLSessionWebSocketTask,
        onEvent: @escaping @MainActor (BackendEvent) -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) async {
        do {
            while !Task.isCancelled {
                let message = try await task.receive()
                let event = try Self.decode(message)
                if event.shouldLogReceipt {
                    logger.info("websocket event received type=\(event.logType, privacy: .public)")
                }
                onEvent(event)
            }
        } catch is CancellationError {
            logger.info("websocket receive loop cancelled")
        } catch {
            logger.warning("websocket receive failed message=\(error.localizedDescription, privacy: .public)")
            onError(error)
        }
    }

    private static func decode(_ message: URLSessionWebSocketTask.Message) throws -> BackendEvent {
        let data: Data
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let messageData):
            data = messageData
        @unknown default:
            throw EventClientError.unsupportedMessage
        }

        let envelope = try JSONDecoder().decode(BackendEventEnvelope.self, from: data)
        switch envelope.messageType {
        case "backend.ready":
            return .backendReady(
                service: envelope.data.service,
                version: envelope.data.version
            )
        case "heartbeat":
            return .heartbeat
        default:
            return .unknown(envelope.messageType)
        }
    }
}

private struct BackendEventEnvelope: Decodable {
    let messageType: String
    let data: BackendEventData

    private enum CodingKeys: String, CodingKey {
        case messageType = "type"
        case data
    }
}

private struct BackendEventData: Decodable {
    let service: String?
    let version: String?
}

enum EventClientError: LocalizedError {
    case unsupportedMessage

    var errorDescription: String? {
        switch self {
        case .unsupportedMessage:
            return "Core sent an unsupported WebSocket message."
        }
    }
}

private extension BackendEvent {
    var logType: String {
        switch self {
        case .backendReady:
            return "backend.ready"
        case .heartbeat:
            return "heartbeat"
        case .unknown(let type):
            return type
        }
    }

    var shouldLogReceipt: Bool {
        switch self {
        case .heartbeat:
            return false
        case .backendReady, .unknown:
            return true
        }
    }
}
