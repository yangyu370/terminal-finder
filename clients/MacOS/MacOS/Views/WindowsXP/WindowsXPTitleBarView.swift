//
//  WindowsXPTitleBarView.swift
//  MacOS
//
//  Created by Claude on 2026/6/14.
//
//  Luna blue glass title bar: title text + Native switch + caption buttons
//  (minimize/maximize blue glass, close red). Knows nothing about NSWindow —
//  window actions arrive as closures from the controller.

import SwiftUI

struct WindowsXPTitleBarView: View {
    let title: String
    let onSwitchToNative: () -> Void
    let onMinimize: () -> Void
    let onZoom: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(WindowsXPPalette.titleText)
                .shadow(color: .black.opacity(0.35), radius: 0, x: 0, y: 1)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 4)

            Spacer()

            Button {
                onSwitchToNative()
            } label: {
                Text("Native")
                    .font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(WindowsXPButtonStyle(compact: true))
            .help("切回 Native Finder shell")
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
        .padding(.horizontal, 5)
        .frame(height: 28)
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
    }
}
