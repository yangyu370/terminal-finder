//
//  FinderWindowController.swift
//  MacOS
//
//  Created by Claude on 2026/6/11.
//

import AppKit
import Combine
import SwiftUI

private final class FinderWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

/// Owns the Finder-style main window, its toolbar, and all ViewModels.
/// ViewModels live as long as the window and are injected downwards.
final class FinderWindowController: NSWindowController {
    static let minimumWindowFrameSize = NSSize(width: 1007, height: 709)
    /// AppKit content sizing excludes the 20pt titlebar chrome measured in the reference screenshot.
    static let initialContentSize = NSSize(width: 1007, height: 689)
    private static let windowStyleMask: NSWindow.StyleMask = [
        .titled,
        .closable,
        .miniaturizable,
        .resizable,
        .fullSizeContentView
    ]
    private static let shellWindowStyleMask: NSWindow.StyleMask = [
        .closable,
        .miniaturizable,
        .resizable,
        .fullSizeContentView
    ]

    let workspaceVM: WorkspaceBrowserViewModel
    let connectionVM: BackendConnectionViewModel
    let cloudConnectionVM: ConnectionViewModel
    let terminalVM: TerminalSessionViewModel
    let panelLayout: PseudoTerminalPanelLayoutState
    let contentState: FinderContentViewState
    let displayModeState: FinderDisplayModeState
    let shellModeState: ClientShellModeState
    let transferActivityVM: TransferActivityViewModel

    private var toolbarController: FinderToolbarController?
    private var windows98ContentViewController: NSViewController?
    private var windowsXPContentViewController: NSViewController?
    private var cancellables: Set<AnyCancellable> = []
    private var hasStartedInitialLoad = false
    private var terminalShortcutMonitor: Any?

    init() {
        let transferActivityVM = TransferActivityViewModel()
        workspaceVM = WorkspaceBrowserViewModel(transferActivityVM: transferActivityVM)
        connectionVM = BackendConnectionViewModel()
        cloudConnectionVM = ConnectionViewModel(
            core: FFIConnectionClient(),
            capabilitiesClient: FFICapabilitiesClient(),
            keychain: KeychainService(),
            store: ConnectionStore()
        )
        terminalVM = TerminalSessionViewModel()
        panelLayout = PseudoTerminalPanelLayoutState()
        contentState = FinderContentViewState()
        displayModeState = FinderDisplayModeState()
        shellModeState = ClientShellModeState(mode: ClientShellMode.initialMode())
        self.transferActivityVM = transferActivityVM

        let window = FinderWindow(
            contentRect: NSRect(origin: .zero, size: Self.initialContentSize),
            styleMask: Self.windowStyleMask,
            backing: .buffered,
            defer: false
        )
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
        window.minSize = Self.initialContentSize

        super.init(window: window)

        workspaceVM.moveConflictResolver = { [weak self] item, existingEntry in
            guard let window = self?.window else {
                return .cancel
            }

            return FinderWriteOpDialogs.moveConflictResolution(
                window: window,
                item: item,
                existingEntry: existingEntry
            )
        }

        window.setContentSize(Self.initialContentSize)
        window.center()
        window.setFrameAutosaveName("FinderMainWindow")

        let toolbarController = FinderToolbarController(
            workspaceVM: workspaceVM,
            connectionVM: connectionVM,
            displayModeState: displayModeState,
            shellModeState: shellModeState,
            actionTarget: self
        )
        self.toolbarController = toolbarController
        applyShellMode(shellModeState.mode)

        wireTerminalLifecycle()
        subscribeWorkspaceNavigation()
        installTerminalShortcutMonitor()
        subscribeShellModeUpdates()
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

    // MARK: - Write-op actions

    @objc func newFolderAction(_ sender: Any?) {
        guard let window else { return }
        let name = FinderWriteOpDialogs.promptForName(
            window: window,
            title: "新建文件夹",
            informativeText: "请输入文件夹名称。",
            defaultName: "未命名文件夹",
            confirmTitle: "新建"
        )
        guard let name, !name.isEmpty else { return }

        let parent = workspaceVM.terminalCwdPath
        let directoryPath = joinPath(parent, name)
        let warning = nonNativeDirectoryWarningIfNeeded()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let warning {
                guard FinderWriteOpDialogs.confirm(
                    window: self.window ?? window,
                    title: "云端目录注意事项",
                    informativeText: warning,
                    confirmTitle: "继续创建",
                    confirmIsDestructive: false
                ) else { return }
            }
            await self.workspaceVM.createDirectory(path: directoryPath)
        }
    }

    @objc func uploadFileAction(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.title = "上传文件"
        panel.prompt = "上传"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            let urls = panel.urls
            let parent = self.workspaceVM.terminalCwdPath
            Task { @MainActor [weak self] in
                guard let self else { return }
                for url in urls {
                    let remotePath = self.joinPath(parent, url.lastPathComponent)
                    await self.workspaceVM.uploadFile(
                        localSource: url.path,
                        remotePath: remotePath
                    )
                }
            }
        }
    }

    @objc func downloadSelectedAction(_ sender: Any?) {
        guard let window,
              let entry = workspaceVM.selectedEntryForActions,
              !entry.isDirectory
        else { return }

        let panel = NSSavePanel()
        panel.title = "下载到"
        panel.prompt = "下载"
        panel.nameFieldStringValue = entry.name
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                await self?.workspaceVM.downloadEntry(entry, to: url)
            }
        }
    }

    @objc func renameSelectedAction(_ sender: Any?) {
        guard let window,
              let entry = workspaceVM.selectedEntryForActions
        else { return }

        let newName = FinderWriteOpDialogs.promptForName(
            window: window,
            title: "重命名",
            informativeText: "请输入新名称。",
            defaultName: entry.name,
            confirmTitle: "重命名"
        )
        guard let newName, !newName.isEmpty, newName != entry.name else { return }

        let parent = (entry.path as NSString).deletingLastPathComponent
        let target = parent.isEmpty
            ? newName
            : joinPath(parent, newName)
        let warning = nonAtomicRenameWarningIfNeeded()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let warning {
                guard FinderWriteOpDialogs.confirm(
                    window: self.window ?? window,
                    title: "重命名注意事项",
                    informativeText: warning,
                    confirmTitle: "继续重命名",
                    confirmIsDestructive: false
                ) else { return }
            }
            await self.workspaceVM.renameEntry(from: entry.path, to: target)
        }
    }

    @objc func deleteSelectedAction(_ sender: Any?) {
        guard let window,
              let entry = workspaceVM.selectedEntryForActions
        else { return }

        let info = workspaceVM.currentConnectionId == nil
            ? "项目将被移到废纸篓 / 移除。"
            : "对象将从云端永久删除，且无法撤销。"
        guard FinderWriteOpDialogs.confirm(
            window: window,
            title: "确定要删除 \(entry.name) 吗？",
            informativeText: info,
            confirmTitle: "删除",
            confirmIsDestructive: true
        ) else { return }

        Task { @MainActor [weak self] in
            await self?.workspaceVM.deleteEntry(path: entry.path)
        }
    }

    func handleMoveDrop(_ item: FinderDragItem, intoDirectory targetDirectory: String) {
        Task { @MainActor [weak self] in
            await self?.workspaceVM.moveEntry(item, intoDirectory: targetDirectory, conflict: nil)
        }
    }

    // MARK: - Helpers

    private func joinPath(_ parent: String, _ child: String) -> String {
        // For S3 (relative paths), avoid leading "/" which would become an
        // empty-prefix key; for local (absolute), pathComponent appending DTRT.
        if parent.isEmpty {
            return child
        }
        if parent.hasPrefix("/") {
            return (parent as NSString).appendingPathComponent(child)
        }
        if parent.hasSuffix("/") {
            return parent + child
        }
        return "\(parent)/\(child)"
    }

    private func nonNativeDirectoryWarningIfNeeded() -> String? {
        guard let connectionId = workspaceVM.currentConnectionId,
              let caps = cloudConnectionVM.capabilities[connectionId],
              !caps.hasNativeDirectories
        else { return nil }
        return "此连接的存储后端（如 S3）没有原生目录概念。新建文件夹将写入一个零字节占位对象，后续放入文件后占位对象可被忽略。"
    }

    private func nonAtomicRenameWarningIfNeeded() -> String? {
        guard let connectionId = workspaceVM.currentConnectionId,
              let caps = cloudConnectionVM.capabilities[connectionId],
              !caps.canRename
        else { return nil }
        return "此连接的存储后端（如 S3）不支持原子重命名。操作将复制后删除原对象，过程中失败可能导致原文件丢失或残留副本。"
    }

    @objc func reconnectAction(_ sender: Any?) {
        connectionVM.reconnect()
    }

    @objc func selectShellAction(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              let rawValue = menuItem.representedObject as? String,
              let mode = ClientShellMode(rawValue: rawValue)
        else {
            return
        }

        shellModeState.select(mode)
    }

    @objc func toggleTerminalPanelAction(_ sender: Any?) {
        if panelLayout.isOpen {
            closeTerminalSession()
        } else {
            panelLayout.open()
            let grid = FinderTerminalSurfaceMetrics.gridSize(for: panelLayout.viewportSize)
            terminalVM.startForWorkspace(
                workspaceVM.workspaceState,
                fallbackCwd: workspaceVM.terminalCwdPath,
                cols: grid.cols,
                rows: grid.rows
            )
        }
    }

    private func closeTerminalSession() {
        // Sends terminal.close; the panel collapses once the session reports
        // it has ended (`onSessionEnded`), keeping protocol teardown ahead of UI.
        terminalVM.close()
    }

    // MARK: - Wiring

    private func subscribeShellModeUpdates() {
        shellModeState.$mode
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                self?.applyShellMode(mode)
            }
            .store(in: &cancellables)
    }

    private func applyShellMode(_ mode: ClientShellMode) {
        guard let window else {
            return
        }

        switch mode {
        case .nativeFinder:
            applyNativeFinderChrome(to: window)
            installContentViewController(makeNativeContentViewController(), in: window)
        case .windows98:
            applyWindows98Chrome(to: window)
            installContentViewController(makeWindows98ContentViewController(), in: window)
        case .windowsXP:
            applyWindowsXPChrome(to: window)
            installContentViewController(makeWindowsXPContentViewController(), in: window)
        }

        refreshWindowChrome()
    }

    private func installContentViewController(_ viewController: NSViewController, in window: NSWindow) {
        let contentBounds = window.contentView?.bounds ?? NSRect(origin: .zero, size: Self.initialContentSize)
        viewController.view.frame = contentBounds
        viewController.view.autoresizingMask = [.width, .height]
        window.contentViewController = viewController
    }

    private func applyNativeFinderChrome(to window: NSWindow) {
        window.styleMask = Self.windowStyleMask
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.toolbar = toolbarController?.makeToolbar()
        window.isMovableByWindowBackground = false
        setStandardWindowButtonsHidden(false, in: window)
    }

    private func applyWindows98Chrome(to window: NSWindow) {
        window.styleMask = Self.shellWindowStyleMask
        window.toolbar = nil
        window.toolbarStyle = .expanded
        window.titlebarSeparatorStyle = .none
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        setStandardWindowButtonsHidden(true, in: window)
    }

    private func applyWindowsXPChrome(to window: NSWindow) {
        window.styleMask = Self.shellWindowStyleMask
        window.toolbar = nil
        window.toolbarStyle = .expanded
        window.titlebarSeparatorStyle = .none
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        setStandardWindowButtonsHidden(true, in: window)
    }

    private func setStandardWindowButtonsHidden(_ isHidden: Bool, in window: NSWindow) {
        [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton
        ].forEach { buttonType in
            window.standardWindowButton(buttonType)?.isHidden = isHidden
        }
    }

    private func makeNativeContentViewController() -> NSViewController {
        let sidebarHost = NSHostingController(
            rootView: FinderSidebarView(
                workspaceVM: workspaceVM,
                connectionVM: cloudConnectionVM,
                onMove: { [weak self] item, targetDirectory in
                    self?.handleMoveDrop(item, intoDirectory: targetDirectory)
                }
            )
        )
        sidebarHost.sizingOptions = []

        let contentHost = NSHostingController(
            rootView: FinderContentView(
                workspaceVM: workspaceVM,
                terminalVM: terminalVM,
                panelLayout: panelLayout,
                contentState: contentState,
                displayModeState: displayModeState,
                transferActivityVM: transferActivityVM,
                onCloseTerminal: { [weak self] in
                    self?.closeTerminalSession()
                },
                onMove: { [weak self] item, targetDirectory in
                    self?.handleMoveDrop(item, intoDirectory: targetDirectory)
                }
            )
        )
        contentHost.sizingOptions = []

        let splitViewController = FinderSplitViewController(
            sidebarViewController: sidebarHost,
            contentViewController: contentHost
        )
        return splitViewController
    }

    private func makeWindows98ContentViewController() -> NSViewController {
        if let windows98ContentViewController {
            return windows98ContentViewController
        }

        let host = NSHostingController(
            rootView: Windows98ShellView(
                workspaceVM: workspaceVM,
                terminalVM: terminalVM,
                panelLayout: panelLayout,
                contentState: contentState,
                shellModeState: shellModeState,
                onCloseTerminal: { [weak self] in
                    self?.closeTerminalSession()
                },
                onSwitchToNative: { [weak self] in
                    self?.shellModeState.select(.nativeFinder)
                },
                onSelectShell: { [weak self] mode in
                    self?.shellModeState.select(mode)
                },
                onMinimize: { [weak self] in
                    self?.window?.miniaturize(nil)
                },
                onZoom: { [weak self] in
                    self?.window?.zoom(nil)
                },
                onClose: { [weak self] in
                    self?.window?.close()
                }
            )
        )
        host.sizingOptions = []
        windows98ContentViewController = host
        return host
    }

    private func makeWindowsXPContentViewController() -> NSViewController {
        if let windowsXPContentViewController {
            return windowsXPContentViewController
        }

        let host = NSHostingController(
            rootView: WindowsXPShellView(
                workspaceVM: workspaceVM,
                terminalVM: terminalVM,
                panelLayout: panelLayout,
                contentState: contentState,
                shellModeState: shellModeState,
                onCloseTerminal: { [weak self] in
                    self?.closeTerminalSession()
                },
                onSwitchToNative: { [weak self] in
                    self?.shellModeState.select(.nativeFinder)
                },
                onSelectShell: { [weak self] mode in
                    self?.shellModeState.select(mode)
                },
                onMinimize: { [weak self] in
                    self?.window?.miniaturize(nil)
                },
                onZoom: { [weak self] in
                    self?.window?.zoom(nil)
                },
                onClose: { [weak self] in
                    self?.window?.close()
                }
            )
        )
        host.sizingOptions = []
        windowsXPContentViewController = host
        return host
    }

    /// 窗口级 local key monitor：在按键下发到响应链 / 菜单之前判定
    /// Command+J / Command+K 切换终端面板。这样即便 SwiftTerm 终端处于
    /// first responder（会先于主菜单消费 key equivalent），快捷键依然可靠。
    /// 详见 `FinderKeyboardShortcuts`。
    private func installTerminalShortcutMonitor() {
        terminalShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let window = self.window,
                  self.event(event, belongsTo: window),
                  FinderKeyboardShortcuts.isToggleTerminalPanel(event)
            else {
                return event
            }

            self.toggleTerminalPanelAction(nil)
            // 吞掉事件，避免主菜单 / SwiftTerm 再处理一次造成重复切换。
            return nil
        }
    }

    private func event(_ event: NSEvent, belongsTo window: NSWindow) -> Bool {
        if let eventWindow = event.window {
            return eventWindow === window
        }

        return NSApp.keyWindow === window || NSApp.mainWindow === window
    }

    private func wireTerminalLifecycle() {
        terminalVM.onSessionEnded = { [weak self] in
            self?.panelLayout.close()
        }
        terminalVM.onOpenDirectoryFromTerminal = { [weak self] directory in
            self?.workspaceVM.openTerminalDirectory(directory)
        }

        panelLayout.onViewportResize = { [weak self] size in
            guard let self else {
                return
            }

            let grid = FinderTerminalSurfaceMetrics.gridSize(for: size)
            terminalVM.resize(cols: grid.cols, rows: grid.rows)
        }
    }

    private func subscribeWorkspaceNavigation() {
        workspaceVM.openedDirectoryPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] directory in
                self?.terminalVM.finderDidOpenDirectory(directory)
            }
            .store(in: &cancellables)
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
        case #selector(newFolderAction(_:)),
             #selector(uploadFileAction(_:)):
            return !workspaceVM.isLoading
        case #selector(downloadSelectedAction(_:)):
            guard let entry = workspaceVM.selectedEntryForActions else { return false }
            return !workspaceVM.isLoading && !entry.isDirectory
        case #selector(renameSelectedAction(_:)),
             #selector(deleteSelectedAction(_:)):
            return !workspaceVM.isLoading && workspaceVM.selectedEntryForActions != nil
        case #selector(selectShellAction(_:)):
            if let rawValue = menuItem.representedObject as? String,
               let mode = ClientShellMode(rawValue: rawValue) {
                menuItem.state = shellModeState.mode == mode ? .on : .off
            }
            return true
        default:
            return true
        }
    }
}
