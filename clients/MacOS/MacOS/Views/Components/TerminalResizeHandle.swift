//
//  TerminalResizeHandle.swift
//  MacOS
//
//  Created by Codex on 2026/6/6.
//

import AppKit
import SwiftUI

struct TerminalResizeHandle: View {
    let onResize: (CGFloat) -> Void

    @State private var accumulatedDrag: CGFloat = 0
    @State private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor.opacity(0.22) : Color.clear)
            .frame(height: 8)
            .overlay(alignment: .center) {
                Capsule()
                    .fill(Color.secondary.opacity(isDragging ? 0.55 : 0.32))
                    .frame(width: 48, height: 3)
            }
            .contentShape(Rectangle())
            .cursor(.resizeUpDown)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        let incrementalDrag = value.translation.height - accumulatedDrag
                        accumulatedDrag = value.translation.height
                        onResize(incrementalDrag)
                    }
                    .onEnded { _ in
                        accumulatedDrag = 0
                        isDragging = false
                    }
            )
    }
}

private extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { isHovering in
            if isHovering {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
