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

    private let backendClient: BackendClient

    var isConnecting: Bool {
        status == .connecting
    }

    init(backendClient: BackendClient? = nil) {
        self.backendClient = backendClient ?? BackendClient()
    }

    func ping() {
        guard !isConnecting else {
            return
        }

        status = .connecting
        detailText = "Calling core.ping..."

        Task {
            do {
                let result = try await backendClient.ping()
                status = .connected
                detailText = "\(result.service) \(result.version)"
            } catch {
                status = .disconnected
                detailText = error.localizedDescription
            }
        }
    }
}
