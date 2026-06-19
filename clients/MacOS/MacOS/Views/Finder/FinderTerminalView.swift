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
    let focusesTerminalOnMouseDown: Bool

    init(viewModel: TerminalSessionViewModel, focusesTerminalOnMouseDown: Bool = false) {
        self.viewModel = viewModel
        self.focusesTerminalOnMouseDown = focusesTerminalOnMouseDown
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> FinderFocusableTerminalContainerView {
        let containerView = FinderFocusableTerminalContainerView(frame: .zero)
        containerView.focusesTerminalOnMouseDown = focusesTerminalOnMouseDown
        containerView.onWindowAttached = { [weak coordinator = context.coordinator] containerView in
            coordinator?.focusIfNeeded(containerView.terminalView)
        }
        let terminalView = containerView.terminalView
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
            if focusesTerminalOnMouseDown {
                containerView.requestKeyboardFocus()
            }
            context.coordinator.reportSize(from: terminalView)
        }
        context.coordinator.focusIfNeeded(terminalView)

        return containerView
    }

    func updateNSView(_ containerView: FinderFocusableTerminalContainerView, context: Context) {
        containerView.focusesTerminalOnMouseDown = focusesTerminalOnMouseDown
        let terminalView = containerView.terminalView
        context.coordinator.viewModel = viewModel
        context.coordinator.attach(to: terminalView)
        viewModel.attachRenderer(context.coordinator.renderer)

        DispatchQueue.main.async {
            if focusesTerminalOnMouseDown {
                containerView.requestKeyboardFocus()
            }
            context.coordinator.reportSize(from: terminalView)
        }
        context.coordinator.focusIfNeeded(terminalView)
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var viewModel: TerminalSessionViewModel
        let renderer = FinderSwiftTermRenderer()

        private weak var terminalView: TerminalView?
        private var lastGridSize: FinderTerminalGridSize?
        private var lastFocusedSessionId: String?

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

        func focusIfNeeded(_ terminalView: TerminalView) {
            guard let sessionId = viewModel.sessionId else {
                lastFocusedSessionId = nil
                return
            }
            guard sessionId != lastFocusedSessionId else {
                return
            }

            lastFocusedSessionId = sessionId
            for delay in [0, 0.05, 0.2, 0.5, 1.0] {
                requestFocus(for: terminalView, after: delay)
            }
        }

        private func requestFocus(for terminalView: TerminalView, after delay: TimeInterval) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak terminalView] in
                guard let terminalView else {
                    return
                }
                terminalView.window?.makeFirstResponder(terminalView)
            }
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

final class FinderFocusableTerminalContainerView: NSView {
    let terminalView = TerminalView(frame: .zero)

    var focusesTerminalOnMouseDown = false {
        didSet {
            focusOverlay.isEnabled = focusesTerminalOnMouseDown
            updateEventMonitors()
        }
    }
    var onWindowAttached: ((FinderFocusableTerminalContainerView) -> Void)?

    private let focusOverlay = FinderTerminalFocusOverlayView()
    private var keyMonitor: Any?
    private var mouseMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusOverlay.terminalView = terminalView
        focusOverlay.focusOwner = self
        addSubview(terminalView)
        addSubview(focusOverlay)
    }

    deinit {
        removeEventMonitors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        terminalView.frame = bounds
        focusOverlay.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateEventMonitors()
        onWindowAttached?(self)
    }

    @discardableResult
    func requestKeyboardFocus() -> Bool {
        guard let window else {
            return false
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
        if window.makeFirstResponder(terminalView) {
            return true
        }
        return window.makeFirstResponder(self)
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        terminalView.keyDown(with: event)
    }

    private func updateEventMonitors() {
        removeEventMonitors()
        guard focusesTerminalOnMouseDown, window != nil else {
            return
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event) ?? event
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            self?.handleMouseDown(event) ?? event
        }
    }

    private func removeEventMonitors() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard focusesTerminalOnMouseDown,
              eventBelongsToWindow(event)
        else {
            return event
        }

        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            return event
        }

        guard window?.firstResponder !== terminalView else {
            return event
        }

        terminalView.keyDown(with: event)
        return nil
    }

    private func handleMouseDown(_ event: NSEvent) -> NSEvent? {
        guard focusesTerminalOnMouseDown,
              eventBelongsToWindow(event)
        else {
            return event
        }

        let location = convert(event.locationInWindow, from: nil)
        if bounds.contains(location) {
            requestKeyboardFocus()
        }
        return event
    }

    private func eventBelongsToWindow(_ event: NSEvent) -> Bool {
        guard let window else {
            return false
        }
        if let eventWindow = event.window {
            return eventWindow === window
        }
        return NSApp.keyWindow === window || NSApp.mainWindow === window
    }
}

private final class FinderTerminalFocusOverlayView: NSView {
    weak var terminalView: TerminalView?
    weak var focusOwner: FinderFocusableTerminalContainerView?
    var isEnabled = false {
        didSet {
            needsDisplay = true
        }
    }

    override var isOpaque: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isEnabled ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func mouseDown(with event: NSEvent) {
        focusTerminal()
        terminalView?.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        terminalView?.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        terminalView?.mouseUp(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        focusTerminal()
        terminalView?.rightMouseDown(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        terminalView?.rightMouseDragged(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        terminalView?.rightMouseUp(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        focusTerminal()
        terminalView?.otherMouseDown(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        terminalView?.otherMouseDragged(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        terminalView?.otherMouseUp(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        terminalView?.scrollWheel(with: event)
    }

    private func focusTerminal() {
        focusOwner?.requestKeyboardFocus()
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
