//
//  FinderTerminalResizeHandle.swift
//  MacOS
//
//  Created by Codex on 2026/6/11.
//

import AppKit
import SwiftUI

struct FinderTerminalResizeHandle: View {
    let onResize: (CGFloat) -> Void

    @State private var accumulatedDrag: CGFloat = 0
    @State private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor.opacity(0.18) : Color(nsColor: .separatorColor).opacity(0.36))
            .frame(height: isDragging ? 6 : 1)
            .frame(height: 8)
            .overlay {
                Capsule()
                    .fill(Color.secondary.opacity(isDragging ? 0.48 : 0.22))
                    .frame(width: 46, height: 3)
            }
            .contentShape(Rectangle())
            .background(FinderCursorTrackingView(cursor: .resizeUpDown))
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

private struct FinderCursorTrackingView: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> FinderCursorTrackingNSView {
        FinderCursorTrackingNSView(cursor: cursor)
    }

    func updateNSView(_ nsView: FinderCursorTrackingNSView, context: Context) {
        nsView.cursor = cursor
    }
}

private final class FinderCursorTrackingNSView: NSView {
    var cursor: NSCursor {
        didSet {
            window?.invalidateCursorRects(for: self)
        }
    }

    init(cursor: NSCursor) {
        self.cursor = cursor
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: cursor)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
