//
//  WindowsXPTerminalPanelView.swift
//  MacOS
//
//  Created by Claude on 2026/6/14.
//
//  Luna-skinned terminal panel. Renders the shared FinderTerminalView surface
//  directly (not FinderTerminalPanelView, whose native .bar header would clash)
//  inside a Luna blue title strip + field border, per XP_SKIN_DESIGN.md §2.3.

import SwiftUI

struct WindowsXPTerminalPanelView: View {
    @ObservedObject var terminalVM: TerminalSessionViewModel

    let onClose: () -> Void
    let onViewportChanged: (CGSize) -> Void

    var body: some View {
        VStack(spacing: 0) {
            titleStrip

            FinderTerminalView(viewModel: terminalVM, focusesTerminalOnMouseDown: true)
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .preference(
                                key: WindowsXPTerminalViewportSizePreferenceKey.self,
                                value: geometry.size
                            )
                    }
                }
        }
        .background(WindowsXPPalette.surface)
        .overlay {
            WindowsXPFieldBorder()
        }
        .onPreferenceChange(WindowsXPTerminalViewportSizePreferenceKey.self) { size in
            onViewportChanged(size)
        }
    }

    private var titleStrip: some View {
        HStack(spacing: 6) {
            Text("Command Prompt")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(WindowsXPPalette.titleText)
                .shadow(color: .black.opacity(0.3), radius: 0, x: 0, y: 1)

            if let cwdTitle {
                Text(cwdTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(WindowsXPPalette.titleText.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if let statusText {
                Text(statusText)
                    .font(.system(size: 10))
                    .foregroundStyle(WindowsXPPalette.titleText.opacity(0.85))
                    .lineLimit(1)
            }

            Button(action: onClose) {
                Text("✕")
            }
            .buttonStyle(WindowsXPCaptionButtonStyle(role: .close))
            .help("关闭终端")
            .accessibilityLabel("关闭终端")
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(
            ZStack(alignment: .top) {
                LinearGradient(
                    colors: [
                        WindowsXPPalette.titleActiveTop,
                        WindowsXPPalette.titleActiveMid,
                        WindowsXPPalette.titleActiveBottom
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                LinearGradient(
                    colors: [WindowsXPPalette.titleGloss, .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 9)
                .allowsHitTesting(false)
            }
        )
    }

    private var cwdTitle: String? {
        guard let cwd = terminalVM.cwd, !cwd.isEmpty else {
            return nil
        }

        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    private var statusText: String? {
        switch terminalVM.status {
        case .idle:
            return nil
        case .connecting:
            return "正在连接"
        case .active:
            return "\(terminalVM.cols) x \(terminalVM.rows)"
        case .resizing:
            return "正在调整"
        case .closing:
            return "正在关闭"
        case .exited:
            return nil
        case .error:
            return terminalVM.errorText ?? "终端已断开"
        }
    }
}

private struct WindowsXPTerminalViewportSizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
