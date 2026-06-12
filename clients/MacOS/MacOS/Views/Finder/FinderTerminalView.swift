//
//  FinderTerminalView.swift
//  MacOS
//
//  Created by Codex on 2026/6/11.
//

import AppKit
import SwiftTerm
import SwiftUI

struct FinderTerminalView: NSViewRepresentable {
    let viewModel: TerminalSessionViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> TerminalView {
        let terminalView = TerminalView(frame: .zero)
        terminalView.terminalDelegate = context.coordinator
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        terminalView.nativeBackgroundColor = NSColor.windowBackgroundColor
        terminalView.nativeForegroundColor = NSColor.labelColor
        terminalView.caretColor = NSColor.controlAccentColor
        terminalView.caretViewTracksFocus = true

        context.coordinator.attach(to: terminalView)
        viewModel.attachRenderer(context.coordinator.renderer)

        DispatchQueue.main.async {
            terminalView.window?.makeFirstResponder(terminalView)
            context.coordinator.reportSize(from: terminalView)
        }

        return terminalView
    }

    func updateNSView(_ terminalView: TerminalView, context: Context) {
        context.coordinator.viewModel = viewModel
        context.coordinator.attach(to: terminalView)
        viewModel.attachRenderer(context.coordinator.renderer)

        DispatchQueue.main.async {
            context.coordinator.reportSize(from: terminalView)
        }
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var viewModel: TerminalSessionViewModel
        let renderer = FinderSwiftTermRenderer()

        private weak var terminalView: TerminalView?
        private var lastGridSize: FinderTerminalGridSize?

        init(viewModel: TerminalSessionViewModel) {
            self.viewModel = viewModel
        }

        func attach(to terminalView: TerminalView) {
            self.terminalView = terminalView
            renderer.terminalView = terminalView
        }

        func reportSize(from terminalView: TerminalView) {
            let dims = terminalView.getTerminal().getDims()
            reportSize(cols: dims.cols, rows: dims.rows)
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            reportSize(cols: newCols, rows: newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            viewModel.sendInput(Array(data))
        }

        func scrolled(source: TerminalView, position: Double) {}

        func clipboardCopy(source: TerminalView, content: Data) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(content, forType: .string)
        }

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        private func reportSize(cols: Int, rows: Int) {
            let gridSize = FinderTerminalGridSize(cols: cols, rows: rows)
            guard gridSize != lastGridSize else {
                return
            }

            lastGridSize = gridSize
            Task { @MainActor [viewModel] in
                viewModel.resize(cols: cols, rows: rows)
            }
        }
    }
}

@MainActor
final class FinderSwiftTermRenderer: TerminalRendering {
    weak var terminalView: TerminalView?

    func write(_ bytes: [UInt8]) {
        terminalView?.feed(byteArray: bytes[...])
    }

    func reset() {
        terminalView?.getTerminal().resetToInitialState()
        terminalView?.needsDisplay = true
    }
}
