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
    @Published private(set) var eventStatusText = "events disconnected"

    private let backendClient: any BackendClientProtocol
    private let backendProcessLauncher: any BackendProcessLaunching
    private let eventClient: any EventClientProtocol
    private let workspaceAlertPresenter: any WorkspaceAlertPresenting
    private let eventHeartbeatTimeoutNanoseconds: UInt64
    private var connectionTask: Task<Void, Never>?
    private var eventHeartbeatTask: Task<Void, Never>?

    var isConnecting: Bool {
        status == .connecting
    }

    var isConnected: Bool {
        status == .connected
    }

    init(
        backendClient: (any BackendClientProtocol)? = nil,
        backendProcessLauncher: (any BackendProcessLaunching)? = nil,
        eventClient: (any EventClientProtocol)? = nil,
        workspaceAlertPresenter: (any WorkspaceAlertPresenting)? = nil,
        eventHeartbeatTimeoutNanoseconds: UInt64 = 30_000_000_000
    ) {
        self.backendClient = backendClient ?? BackendClient()
        self.backendProcessLauncher = backendProcessLauncher ?? BackendProcessLauncher()
        self.eventClient = eventClient ?? EventClient()
        self.workspaceAlertPresenter = workspaceAlertPresenter ?? WorkspaceAlertPresenter()
        self.eventHeartbeatTimeoutNanoseconds = eventHeartbeatTimeoutNanoseconds
    }

    deinit {
        connectionTask?.cancel()
        eventHeartbeatTask?.cancel()
    }

    func connect() {
        guard connectionTask == nil else {
            return
        }

        status = .connecting
        detailText = "Checking core health..."
        eventStatusText = "events disconnected"

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
                showBackendConnectionWarning(error)
            }

            connectionTask = nil
        }
    }

    func reconnect() {
        connectionTask?.cancel()
        connectionTask = nil
        eventClient.disconnect()
        cancelEventHeartbeatTimeout()
        eventStatusText = "events disconnected"
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
        connectEvents()
    }

    private func connectEvents() {
        eventStatusText = "connecting events..."
        scheduleEventHeartbeatTimeout()
        eventClient.connect { [weak self] event in
            self?.handleEvent(event)
        } onError: { [weak self] error in
            self?.cancelEventHeartbeatTimeout()
            self?.eventStatusText = "events disconnected - \(error.localizedDescription)"
            self?.showEventConnectionWarning(error)
        }
    }

    private func scheduleEventHeartbeatTimeout() {
        eventHeartbeatTask?.cancel()

        let timeout = eventHeartbeatTimeoutNanoseconds
        guard timeout > 0 else {
            eventHeartbeatTask = nil
            return
        }

        eventHeartbeatTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeout)
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            self?.handleEventHeartbeatTimeout()
        }
    }

    private func cancelEventHeartbeatTimeout() {
        eventHeartbeatTask?.cancel()
        eventHeartbeatTask = nil
    }

    private func handleEventHeartbeatTimeout() {
        eventHeartbeatTask = nil
        let error = BackendConnectionError.eventHeartbeatTimedOut
        eventClient.disconnect()
        eventStatusText = "events disconnected - \(error.localizedDescription)"
        showEventConnectionWarning(error)
    }

    private func showBackendConnectionWarning(_ error: Error) {
        workspaceAlertPresenter.showWarning(
            message: "Core can’t be reached.",
            informativeText: "Terminal Finder could not connect to the local backend.",
            detailText: error.localizedDescription,
            recoverySuggestion: "Check whether the backend is running at 127.0.0.1:3587, then try reconnecting."
        )
    }

    private func showEventConnectionWarning(_ error: Error) {
        workspaceAlertPresenter.showWarning(
            message: "Event stream disconnected.",
            informativeText: "The backend health check passed, but Terminal Finder could not keep the WebSocket event channel connected.",
            detailText: error.localizedDescription,
            recoverySuggestion: "Confirm the backend /events endpoint is available, then reconnect."
        )
    }

    private func handleEvent(_ event: BackendEvent) {
        switch event {
        case .backendReady:
            eventStatusText = "events connected"
        case .heartbeat:
            scheduleEventHeartbeatTimeout()
            eventStatusText = "events connected - heartbeat \(Self.eventTimeFormatter.string(from: Date()))"
        case .unknown:
            break
        }
    }

    private static let eventTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

enum BackendConnectionError: LocalizedError {
    case healthCheckTimedOut
    case eventHeartbeatTimedOut

    var errorDescription: String? {
        switch self {
        case .healthCheckTimedOut:
            return "Core did not pass health check in time."
        case .eventHeartbeatTimedOut:
            return "Core event heartbeat timed out."
        }
    }
}
