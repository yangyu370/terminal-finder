//
//  BackendStatusView.swift
//  MacOS
//
//  Created by Wang on 2026/6/1.
//

import SwiftUI

struct BackendStatusView: View {
    let status: ConnectionStatus
    let detailText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)

                Text(status.title)
                    .font(.headline)
            }

            Text(detailText)
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch status {
        case .disconnected:
            return .red
        case .connecting:
            return .yellow
        case .connected:
            return .green
        }
    }
}
