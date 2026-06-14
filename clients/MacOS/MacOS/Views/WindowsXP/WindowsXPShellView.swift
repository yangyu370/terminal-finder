//
//  WindowsXPShellView.swift
//  MacOS
//
//  Created by Claude on 2026/6/14.
//
//  Independent Windows XP (Luna) shell. Mirrors the Windows98ShellView skeleton
//  (approach A: decoupled shells sharing only ViewModels). This view only
//  assembles the layout and owns the menu bar, address bar, terminal lifecycle,
//  alerts and sheets; the chrome regions live in dedicated component views.

import AppKit
import SwiftUI

struct WindowsXPShellView: View {
    @ObservedObject var workspaceVM: WorkspaceBrowserViewModel
    @ObservedObject var terminalVM: TerminalSessionViewModel
    @ObservedObject var panelLayout: PseudoTerminalPanelLayoutState
    @ObservedObject var contentState: FinderContentViewState
    @ObservedObject var shellModeState: ClientShellModeState

    let onCloseTerminal: () -> Void
    let onSwitchToNative: () -> Void
    let onMinimize: () -> Void
    let onZoom: () -> Void
    let onClose: () -> Void

    private let iconProvider: WindowsXPIconProvider
    private let sidebarItemFilter: WindowsXPSidebarItemFilter

    @State private var pathInput: String

    init(
        workspaceVM: WorkspaceBrowserViewModel,
        terminalVM: TerminalSessionViewModel,
        panelLayout: PseudoTerminalPanelLayoutState,
        contentState: FinderContentViewState,
        shellModeState: ClientShellModeState,
        iconProvider: WindowsXPIconProvider = WindowsXPIconProvider(),
        sidebarItemFilter: WindowsXPSidebarItemFilter = WindowsXPSidebarItemFilter(),
        onCloseTerminal: @escaping () -> Void,
        onSwitchToNative: @escaping () -> Void,
        onMinimize: @escaping () -> Void,
        onZoom: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.workspaceVM = workspaceVM
        self.terminalVM = terminalVM
        self.panelLayout = panelLayout
        self.contentState = contentState
        self.shellModeState = shellModeState
        self.iconProvider = iconProvider
        self.sidebarItemFilter = sidebarItemFilter
        self.onCloseTerminal = onCloseTerminal
        self.onSwitchToNative = onSwitchToNative
        self.onMinimize = onMinimize
        self.onZoom = onZoom
        self.onClose = onClose
        _pathInput = State(initialValue: workspaceVM.path)
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                WindowsXPTitleBarView(
                    title: titleText,
                    onSwitchToNative: onSwitchToNative,
                    onMinimize: onMinimize,
                    onZoom: onZoom,
                    onClose: onClose
                )

                menuBar

                WindowsXPToolbarView(
                    workspaceVM: workspaceVM,
                    panelLayout: panelLayout,
                    onToggleTerminal: toggleTerminalPanel
                )

                addressBar

                HStack(spacing: 0) {
                    WindowsXPSidebarView(
                        workspaceVM: workspaceVM,
                        iconProvider: iconProvider,
                        sidebarItemFilter: sidebarItemFilter
                    )
                    .frame(width: WindowsXPLayout.sidebarWidth)

                    WindowsXPRaisedDivider(axis: .vertical)

                    WindowsXPFileListView(
                        workspaceVM: workspaceVM,
                        iconProvider: iconProvider,
                        availableWidth: max(
                            0,
                            geometry.size.width - WindowsXPLayout.sidebarWidth - WindowsXPLayout.raisedDividerWidth
                        )
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if panelLayout.isOpen {
                    FinderTerminalResizeHandle { verticalDrag in
                        panelLayout.resize(
                            byVerticalDrag: verticalDrag,
                            availableContentHeight: geometry.size.height
                        )
                    }

                    FinderTerminalPanelView(
                        terminalVM: terminalVM,
                        onClose: onCloseTerminal,
                        onViewportChanged: { size in
                            panelLayout.noteViewportSize(size)
                        }
                    )
                    .frame(
                        maxWidth: .infinity,
                        minHeight: panelLayout.height,
                        idealHeight: panelLayout.height,
                        maxHeight: panelLayout.height
                    )
                }

                WindowsXPStatusBarView(
                    workspaceVM: workspaceVM,
                    shellModeState: shellModeState
                )
            }
            .font(.system(size: 12))
            .background(WindowsXPPalette.surface)
        }
        .ignoresSafeArea()
        .onChange(of: workspaceVM.path) { _, newValue in
            pathInput = newValue
        }
        .alert(
            "Unable to Open File",
            isPresented: Binding(
                get: { workspaceVM.fileOpenErrorText != nil },
                set: { isPresented in
                    if !isPresented {
                        workspaceVM.dismissFileOpenError()
                    }
                }
            )
        ) {
            Button("OK") {
                workspaceVM.dismissFileOpenError()
            }
        } message: {
            Text(workspaceVM.fileOpenErrorText ?? "macOS could not open this file.")
        }
        .sheet(isPresented: $contentState.isGoToFolderSheetPresented) {
            FinderGoToFolderSheet(initialPath: workspaceVM.path) { path in
                workspaceVM.updatePathInput(path)
                workspaceVM.openCurrentPath()
                contentState.isGoToFolderSheetPresented = false
            } onCancel: {
                contentState.isGoToFolderSheetPresented = false
            }
        }
    }

    private var titleText: String {
        let name = workspaceVM.currentDirectoryName
        return name.isEmpty ? "Windows XP" : name
    }

    private var menuBar: some View {
        HStack(spacing: 2) {
            ForEach(["File", "Edit", "View", "Favorites", "Tools", "Help"], id: \.self) { title in
                menuLabel(title)
            }
            Spacer()
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .frame(maxWidth: .infinity)
        .background(WindowsXPPalette.surface)
        .overlay(alignment: .bottom) {
            WindowsXPRaisedDivider(axis: .horizontal)
        }
    }

    private var addressBar: some View {
        HStack(spacing: 6) {
            Text("Address")
                .foregroundStyle(WindowsXPPalette.text)

            TextField("", text: $pathInput, onCommit: openPathInput)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 5)
                .frame(height: 22)
                .frame(maxWidth: .infinity)
                .background(WindowsXPPalette.contentBackground)
                .overlay {
                    WindowsXPFieldBorder(cornerRadius: 1)
                }
                .layoutPriority(1)

            Button("Go") {
                openPathInput()
            }
            .buttonStyle(WindowsXPButtonStyle(compact: true))
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background(WindowsXPPalette.surface)
    }

    private func menuLabel(_ title: String) -> some View {
        Text(title)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .foregroundStyle(WindowsXPPalette.text)
    }

    private func openPathInput() {
        workspaceVM.updatePathInput(pathInput)
        workspaceVM.openCurrentPath()
    }

    private func toggleTerminalPanel() {
        if panelLayout.isOpen {
            onCloseTerminal()
        } else {
            panelLayout.open()
            let grid = FinderTerminalSurfaceMetrics.gridSize(for: panelLayout.viewportSize)
            terminalVM.start(cwd: workspaceVM.terminalCwdPath, cols: grid.cols, rows: grid.rows)
        }
    }
}

private enum WindowsXPLayout {
    static let sidebarWidth: CGFloat = 200
    static let raisedDividerWidth: CGFloat = 2
}
