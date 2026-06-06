//
//  PseudoTerminalPanelView.swift
//  MacOS
//
//  Created by Codex on 2026/6/6.
//

import SwiftUI

struct PseudoTerminalPanelView: View {
    let onViewportChanged: (CGSize) -> Void

    init(onViewportChanged: @escaping (CGSize) -> Void = { _ in }) {
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
