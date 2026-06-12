//
//  FinderWindowController.swift
//  MacOS
//
//  Created by Claude on 2026/6/11.
//

import AppKit
import Combine
import SwiftUI

/// Owns the Finder-style main window, its toolbar, and all ViewModels.
/// ViewModels live as long as the window and are injected downwards.
final class FinderWindowController: NSWindowController {
    let workspaceVM: WorkspaceBrowserViewModel
    let connectionVM: BackendConnectionViewModel
    let terminalVM: TerminalSessionViewModel
    let panelLayout: PseudoTerminalPanelLayoutState
    let contentState: FinderContentViewState
    let displayModeState: FinderDisplayModeState

    private var toolbarController: FinderToolbarController?
    private var cancellables: Set<AnyCancellable> = []
    private var hasStartedInitialLoad = false

    init() {
        workspaceVM = WorkspaceBrowserViewModel()
        connectionVM = BackendConnectionViewModel()
        terminalVM = TerminalSessionViewModel()
        panelLayout = PseudoTerminalPanelLayoutState()
        contentState = FinderContentViewState()
        displayModeState = FinderDisplayModeState()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
        window.minSize = NSSize(width: 700, height: 400)

        super.init(window: window)

        let sidebarHost = NSHostingController(rootView: FinderSidebarView(workspaceVM: workspaceVM))
        sidebarHost.sizingOptions = []
        let contentHost = NSHostingController(
            rootView: FinderContentView(
                workspaceVM: workspaceVM,
                terminalVM: terminalVM,
                panelLayout: panelLayout,
                contentState: contentState,
                displayModeState: displayModeState,
                onCloseTerminal: { [weak self] in
                    self?.closeTerminalSession()
                }
            )
        )
        contentHost.sizingOptions = []

        window.contentViewController = FinderSplitViewController(
            sidebarViewController: sidebarHost,
            contentViewController: contentHost
        )
        window.setContentSize(NSSize(width: 920, height: 620))
        window.center()
        window.setFrameAutosaveName("FinderMainWindow")

        let toolbarController = FinderToolbarController(
            workspaceVM: workspaceVM,
            connectionVM: connectionVM,
            displayModeState: displayModeState,
            actionTarget: self
        )
        self.toolbarController = toolbarController
        window.toolbar = toolbarController.makeToolbar()

        wireTerminalLifecycle()
        subscribeWindowChromeUpdates()
        refreshWindowChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)

        guard !hasStartedInitialLoad else {
            return
        }

        hasStartedInitialLoad = true
        connectionVM.connect()
        workspaceVM.loadInitialState()
    }

    // MARK: - Menu / toolbar actions

    @objc func openAction(_ sender: Any?) {
        workspaceVM.openSelectedItemOrCurrentPath()
    }

    @objc func goBackAction(_ sender: Any?) {
        workspaceVM.goBack()
    }

    @objc func goForwardAction(_ sender: Any?) {
        workspaceVM.goForward()
    }

    @objc func goUpAction(_ sender: Any?) {
        workspaceVM.goUp()
    }

    @objc func refreshAction(_ sender: Any?) {
        workspaceVM.refresh()
    }

    @objc func toggleHiddenFilesAction(_ sender: Any?) {
        workspaceVM.toggleHiddenFiles()
    }

    @objc func changeDisplayModeAction(_ sender: Any?) {
        guard let control = sender as? NSSegmentedControl,
              let mode = FinderDisplayMode(segmentIndex: control.selectedSegment)
        else {
            return
        }

        displayModeState.select(mode)
    }

    @objc func goToFolderAction(_ sender: Any?) {
        contentState.isGoToFolderSheetPresented = true
    }

    @objc func reconnectAction(_ sender: Any?) {
        connectionVM.reconnect()
    }

    @objc func toggleTerminalPanelAction(_ sender: Any?) {
        if panelLayout.isOpen {
            closeTerminalSession()
        } else {
            panelLayout.open()
            let grid = FinderTerminalSurfaceMetrics.gridSize(for: panelLayout.viewportSize)
            terminalVM.start(cwd: workspaceVM.terminalCwdPath, cols: grid.cols, rows: grid.rows)
        }
    }

    private func closeTerminalSession() {
        // Sends terminal.close; the panel collapses once the session reports
        // it has ended (`onSessionEnded`), keeping protocol teardown ahead of UI.
        terminalVM.close()
    }

    // MARK: - Wiring

    private func wireTerminalLifecycle() {
        terminalVM.onSessionEnded = { [weak self] in
            self?.panelLayout.close()
        }

        panelLayout.onViewportResize = { [weak self] size in
            guard let self else {
                return
            }

            let grid = FinderTerminalSurfaceMetrics.gridSize(for: size)
            terminalVM.resize(cols: grid.cols, rows: grid.rows)
        }
    }

    private func subscribeWindowChromeUpdates() {
        workspaceVM.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshWindowChrome()
            }
            .store(in: &cancellables)
    }

    private func refreshWindowChrome() {
        guard let window else {
            return
        }

        window.representedURL = URL(fileURLWithPath: workspaceVM.terminalCwdPath)
        window.title = workspaceVM.currentDirectoryName
    }
}

// MARK: - Menu validation

extension FinderWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(openAction(_:)):
            return workspaceVM.canOpen
        case #selector(goBackAction(_:)):
            return workspaceVM.canGoBack
        case #selector(goForwardAction(_:)):
            return workspaceVM.canGoForward
        case #selector(goUpAction(_:)):
            return workspaceVM.canGoUp
        case #selector(refreshAction(_:)):
            return !workspaceVM.isLoading
        case #selector(toggleHiddenFilesAction(_:)):
            menuItem.state = workspaceVM.showsHiddenFiles ? .on : .off
            return true
        case #selector(toggleTerminalPanelAction(_:)):
            menuItem.title = panelLayout.isOpen ? "隐藏终端面板" : "显示终端面板"
            return true
        case #selector(goToFolderAction(_:)):
            return true
        case #selector(reconnectAction(_:)):
            return true
        default:
            return true
        }
    }
}
