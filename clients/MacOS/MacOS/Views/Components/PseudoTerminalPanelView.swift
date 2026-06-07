//
//  PseudoTerminalPanelView.swift
//  MacOS
//
//  Created by Codex on 2026/6/6.
//

import Foundation
import SwiftUI

struct PseudoTerminalPanelView: View {
    @ObservedObject var terminalSessionViewModel: TerminalSessionViewModel

    let onClose: () -> Void
    let onViewportChanged: (CGSize) -> Void

    init(
        terminalSessionViewModel: TerminalSessionViewModel,
        onClose: @escaping () -> Void = {},
        onViewportChanged: @escaping (CGSize) -> Void = { _ in }
    ) {
        self.terminalSessionViewModel = terminalSessionViewModel
        self.onClose = onClose
        self.onViewportChanged = onViewportChanged
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(height: 1)

            SwiftTermTerminalView(viewModel: terminalSessionViewModel)
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .preference(
                                key: TerminalViewportSizePreferenceKey.self,
                                value: geometry.size
                            )
                    }
                }
        }
        .background(Color(red: 0.025, green: 0.029, blue: 0.036))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(height: 1)
        }
        .onPreferenceChange(TerminalViewportSizePreferenceKey.self) { size in
            onViewportChanged(size)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .shadow(color: statusColor.opacity(0.45), radius: 4)

            VStack(alignment: .leading, spacing: 1) {
                Text("Terminal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.86))

                if let subtitleText {
                    Text(subtitleText)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.48))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 10)

            if let statusText {
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .lineLimit(1)
            }

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.white.opacity(0.56))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Terminal")
            .accessibilityLabel("Close Terminal")
        }
        .frame(height: 32)
        .padding(.horizontal, 12)
        .background(Color(red: 0.045, green: 0.050, blue: 0.060))
    }

    private var statusText: String? {
        switch terminalSessionViewModel.status {
        case .idle:
            return nil
        case .connecting:
            return "connecting"
        case .active, .resizing:
            return nil
        case .closing:
            return "closing"
        case .exited:
            return nil
        case .error:
            return terminalSessionViewModel.errorText ?? "disconnected"
        }
    }

    private var subtitleText: String? {
        guard let cwd = terminalSessionViewModel.cwd,
              !cwd.isEmpty
        else {
            return nil
        }

        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    private var statusColor: Color {
        switch terminalSessionViewModel.status {
        case .active, .resizing:
            return Color(red: 0.35, green: 0.86, blue: 0.56)
        case .connecting, .closing:
            return Color(red: 0.92, green: 0.70, blue: 0.32)
        case .error:
            return Color(red: 0.95, green: 0.38, blue: 0.38)
        case .idle, .exited:
            return Color.white.opacity(0.35)
        }
    }
}

private struct TerminalViewportSizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
