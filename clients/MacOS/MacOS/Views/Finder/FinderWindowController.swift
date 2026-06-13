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
    let themeProvider: FinderThemeProvider

    private var toolbarController: FinderToolbarController?
    private var cancellables: Set<AnyCancellable> = []
    private var hasStartedInitialLoad = false
    private var terminalShortcutMonitor: Any?

    init() {
        workspaceVM = WorkspaceBrowserViewModel()
        connectionVM = BackendConnectionViewModel()
        terminalVM = TerminalSessionViewModel()
        panelLayout = PseudoTerminalPanelLayoutState()
        contentState = FinderContentViewState()
        displayModeState = FinderDisplayModeState()
        themeProvider = FinderThemeProvider()

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

        let sidebarHost = NSHostingController(
            rootView: FinderSidebarView(workspaceVM: workspaceVM)
                .environmentObject(themeProvider)
        )
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
            .environmentObject(themeProvider)
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
        installTerminalShortcutMonitor()
        subscribeWindowChromeUpdates()
        refreshWindowChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let terminalShortcutMonitor {
            NSEvent.removeMonitor(terminalShortcutMonitor)
        }
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

    @objc func switchThemeAction(_ sender: Any?) {
        themeProvider.cycle()
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

    /// 窗口级 local key monitor：在按键下发到响应链 / 菜单之前判定
    /// Command+J / Command+K 切换终端面板。这样即便 SwiftTerm 终端处于
    /// first responder（会先于主菜单消费 key equivalent），快捷键依然可靠。
    /// 详见 `FinderKeyboardShortcuts`。
    private func installTerminalShortcutMonitor() {
        terminalShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let window = self.window,
                  event.window === window,
                  FinderKeyboardShortcuts.isToggleTerminalPanel(event)
            else {
                return event
            }

            self.toggleTerminalPanelAction(nil)
            // 吞掉事件，避免主菜单 / SwiftTerm 再处理一次造成重复切换。
            return nil
        }
    }

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
        case #selector(switchThemeAction(_:)):
            menuItem.title = "切换主题（\(themeProvider.current.displayName)）"
            return true
        default:
            return true
        }
    }
}
