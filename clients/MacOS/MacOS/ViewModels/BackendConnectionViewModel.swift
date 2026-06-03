//
//  BackendConnectionViewModel.swift
//  MacOS
//
//  Created by Wang on 2026/6/1.
//

import Combine
import Foundation

@MainActor
final class BackendConnectionViewModel: ObservableObject {
    @Published private(set) var status: ConnectionStatus = .disconnected
    @Published private(set) var detailText = "Core is expected at http://127.0.0.1:3587"

    private let backendClient: any BackendClientProtocol
    private let backendProcessLauncher: any BackendProcessLaunching
    private var connectionTask: Task<Void, Never>?

    var isConnecting: Bool {
        status == .connecting
    }

    var isConnected: Bool {
        status == .connected
    }

    init(
        backendClient: (any BackendClientProtocol)? = nil,
        backendProcessLauncher: (any BackendProcessLaunching)? = nil
    ) {
        self.backendClient = backendClient ?? BackendClient()
        self.backendProcessLauncher = backendProcessLauncher ?? BackendProcessLauncher()
    }

    deinit {
        connectionTask?.cancel()
    }

    func connect() {
        guard connectionTask == nil else {
            return
        }

        status = .connecting
        detailText = "Checking core health..."

        connectionTask = Task { [backendClient, backendProcessLauncher] in
            do {
                if let result = try? await backendClient.health() {
                    markConnected(result)
                    connectionTask = nil
                    return
                }

                detailText = "Starting core..."
                try backendProcessLauncher.launchBackendIfNeeded()

                let result = try await waitForHealth()
                markConnected(result)
            } catch is CancellationError {
                status = .disconnected
                detailText = "Core startup was cancelled."
            } catch {
                status = .disconnected
                detailText = error.localizedDescription
            }

            connectionTask = nil
        }
    }

    func reconnect() {
        connectionTask?.cancel()
        connectionTask = nil
        connect()
    }

    private func waitForHealth() async throws -> PingResult {
        var lastError: Error?

        for attempt in 1...40 {
            try Task.checkCancellation()

            do {
                return try await backendClient.health()
            } catch {
                lastError = error
                detailText = "Waiting for core health... \(attempt)/40"
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        if let lastError {
            throw lastError
        }

        throw BackendConnectionError.healthCheckTimedOut
    }

    private func markConnected(_ result: PingResult) {
        status = .connected
        detailText = "\(result.service) \(result.version)"
    }
}

enum BackendConnectionError: LocalizedError {
    case healthCheckTimedOut

    var errorDescription: String? {
        switch self {
        case .healthCheckTimedOut:
            return "Core did not pass health check in time."
        }
    }
}
