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
            .background(CursorTrackingView(cursor: .resizeUpDown))
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

private struct CursorTrackingView: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> CursorTrackingNSView {
        CursorTrackingNSView(cursor: cursor)
    }

    func updateNSView(_ nsView: CursorTrackingNSView, context: Context) {
        nsView.cursor = cursor
    }
}

private final class CursorTrackingNSView: NSView {
    var cursor: NSCursor {
        didSet {
            window?.invalidateCursorRects(for: self)
        }
    }

    init(cursor: NSCursor) {
        self.cursor = cursor
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: cursor)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
