//
//  PseudoTerminalPanelView.swift
//  MacOS
//
//  Created by Codex on 2026/6/6.
//

import SwiftUI

struct PseudoTerminalPanelView: View {
    let onClose: () -> Void
    let onViewportChanged: (CGSize) -> Void

    init(
        onClose: @escaping () -> Void = {},
        onViewportChanged: @escaping (CGSize) -> Void = { _ in }
    ) {
        self.onClose = onClose
        self.onViewportChanged = onViewportChanged
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color(red: 0.035, green: 0.039, blue: 0.047))

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)

            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: .controlAccentColor).opacity(0.72))
                .frame(width: 8, height: 18)
                .padding(.leading, 22)
                .padding(.top, 22)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Terminal")
            .accessibilityLabel("Close Terminal")
            .padding(.top, 8)
            .padding(.trailing, 10)
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .preference(
                        key: TerminalViewportSizePreferenceKey.self,
                        value: geometry.size
                    )
            }
        }
        .onPreferenceChange(TerminalViewportSizePreferenceKey.self) { size in
            onViewportChanged(size)
        }
    }
}

private struct TerminalViewportSizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
