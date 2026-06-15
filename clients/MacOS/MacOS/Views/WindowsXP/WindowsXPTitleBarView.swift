//
//  WindowsXPTitleBarView.swift
//  MacOS
//
//  Created by Claude on 2026/6/14.
//
//  Luna blue glass title bar: title text + Native switch + caption buttons
//  (minimize/maximize blue glass, close red). Knows nothing about NSWindow —
//  window actions arrive as closures from the controller.

import AppKit
import SwiftUI

struct WindowsXPTitleBarView: View {
    let title: String
    @ObservedObject var shellModeState: ClientShellModeState
    let onSwitchToNative: () -> Void
    let onSelectShell: (ClientShellMode) -> Void
    let onMinimize: () -> Void
    let onZoom: () -> Void
    let onClose: () -> Void

    @State private var shellMenuAnchorView: NSView?

    var body: some View {
        HStack(spacing: 8) {
            Text("XP")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(WindowsXPPalette.titleText)
                .frame(width: 22, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(WindowsXPPalette.titleGloss.opacity(0.65))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color.white.opacity(0.55), lineWidth: 1)
                }

            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(WindowsXPPalette.titleText)
                .shadow(color: .black.opacity(0.35), radius: 0, x: 0, y: 1)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 4)

            Spacer()

            shellSwitcher
                .layoutPriority(1)

            HStack(spacing: 3) {
                Button(action: onMinimize) {
                    Text("_")
                        .baselineOffset(3)
                }
                .buttonStyle(WindowsXPCaptionButtonStyle(role: .minimize))
                .help("Minimize")

                Button(action: onZoom) {
                    Text("□")
                }
                .buttonStyle(WindowsXPCaptionButtonStyle(role: .maximize))
                .help("Zoom")

                Button(action: onClose) {
                    Text("✕")
                }
                .buttonStyle(WindowsXPCaptionButtonStyle(role: .close))
                .help("Close")
            }
            .layoutPriority(2)
        }
        .padding(.horizontal, 6)
        .frame(height: WindowsXPChromeMetrics.titleBarHeight)
        .frame(maxWidth: .infinity)
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
                .frame(height: 12)
                .allowsHitTesting(false)
            }
        )
        .overlay(alignment: .bottom) {
            WindowsXPPalette.titleActiveBottom.opacity(0.9)
                .frame(height: 1)
        }
    }

    private var shellSwitcher: some View {
        Button {
            ClientShellModeMenuPresenter.popUp(
                currentMode: shellModeState.mode,
                anchoredTo: shellMenuAnchorView,
                onSelect: selectShell
            )
        } label: {
            HStack(spacing: 4) {
                Text("界面")
                Text(shellModeState.mode.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("▼")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 11, weight: .bold))
        }
        .background(ClientShellModeMenuAnchorView(view: $shellMenuAnchorView))
        .buttonStyle(WindowsXPShellSwitchButtonStyle())
        .help("切换客户端界面")
    }

    private func selectShell(_ mode: ClientShellMode) {
        guard shellModeState.mode != mode else {
            return
        }

        if mode == .nativeFinder {
            onSwitchToNative()
        } else {
            onSelectShell(mode)
        }
    }
}

enum WindowsXPChromeMetrics {
    static let titleBarHeight: CGFloat = 32
}
