//
//  ConnectionStatus.swift
//  MacOS
//
//  Created by Wang on 2026/6/1.
//

enum ConnectionStatus {
    case disconnected
    case connecting
    case connected

    var title: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        }
    }
}
