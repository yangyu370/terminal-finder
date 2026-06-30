//
//  FinderTerminalPanelView.swift
//  MacOS
//
//  Created by Codex on 2026/6/11.
//

import SwiftUI

struct FinderTerminalPanelView: View {
    @ObservedObject var terminalVM: TerminalSessionViewModel

    let onClose: () -> Void
    let onViewportChanged: (CGSize) -> Void
    let focusesTerminalOnMouseDown: Bool

    init(
        terminalVM: TerminalSessionViewModel,
        onClose: @escaping () -> Void,
        onViewportChanged: @escaping (CGSize) -> Void,
        focusesTerminalOnMouseDown: Bool = false
    ) {
        self.terminalVM = terminalVM
        self.onClose = onClose
        self.onViewportChanged = onViewportChanged
        self.focusesTerminalOnMouseDown = focusesTerminalOnMouseDown
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)

            FinderTerminalView(
                viewModel: terminalVM,
                focusesTerminalOnMouseDown: focusesTerminalOnMouseDown
            )
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .preference(
                                key: FinderTerminalViewportSizePreferenceKey.self,
                                value: geometry.size
                            )
                    }
                }
        }
        .background(.regularMaterial)
        .onPreferenceChange(FinderTerminalViewportSizePreferenceKey.self) { size in
            onViewportChanged(size)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: statusSymbolName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(statusColor)
                .frame(width: 16)

            Text("终端")
                .font(.system(size: 12, weight: .semibold))

            if let cwdTitle {
                Text(cwdTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            syncLockButton

            if let statusText {
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭终端")
            .accessibilityLabel("关闭终端")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(.bar)
    }

    private var syncLockButton: some View {
        let locked = terminalVM.workspaceTerminalSyncMode == .locked
        return Button {
            terminalVM.workspaceTerminalSyncMode = locked ? .synced : .locked
        } label: {
            Image(systemName: locked ? "lock.fill" : "lock.open")
                .font(.system(size: 13, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(terminalVM.workspaceTerminalCapability == .launchOnly)
        .help(locked ? "已锁定：终端与访达互不影响" : "已同步：终端与访达双向跟随")
        .accessibilityLabel("终端同步锁定")
    }

    private var cwdTitle: String? {
        guard let cwd = terminalVM.cwd, !cwd.isEmpty else {
            return nil
        }

        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    private var statusSymbolName: String {
        switch terminalVM.status {
        case .active, .resizing:
            return "checkmark.circle.fill"
        case .connecting, .closing:
            return "clock.fill"
        case .error:
            return "exclamationmark.circle.fill"
        case .idle, .exited:
            return "circle"
        }
    }

    private var statusColor: Color {
        switch terminalVM.status {
        case .active, .resizing:
            return Color(nsColor: .systemGreen)
        case .connecting, .closing:
            return Color(nsColor: .systemOrange)
        case .error:
            return Color(nsColor: .systemRed)
        case .idle, .exited:
            return .secondary
        }
    }

    private var statusText: String? {
        let workspaceStatus = terminalVM.workspaceTerminalStatus.displayText
        switch terminalVM.status {
        case .idle:
            return workspaceStatus
        case .connecting:
            return "正在连接"
        case .active:
            return [workspaceStatus, "\(terminalVM.cols) x \(terminalVM.rows)"]
                .compactMap { $0 }
                .joined(separator: " · ")
        case .resizing:
            return "正在调整"
        case .closing:
            return "正在关闭"
        case .exited:
            return workspaceStatus
        case .error:
            return terminalVM.errorText ?? "终端已断开"
        }
    }
}

private struct FinderTerminalViewportSizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
