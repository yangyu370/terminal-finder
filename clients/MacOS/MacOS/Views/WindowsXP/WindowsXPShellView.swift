//
//  WindowsXPShellView.swift
//  MacOS
//
//  Created by Claude on 2026/6/14.
//
//  Independent Windows XP (Luna) shell. Mirrors the Windows98ShellView skeleton
//  (approach A: decoupled shells sharing only ViewModels) with Luna styling:
//  blue glass title bar + red close button, beige #ECE9D8 controls, blue task
//  pane, and #316AC5 selection.

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
                titleBar
                menuBar
                toolbar
                addressBar

                HStack(spacing: 0) {
                    sidebar
                        .frame(width: WindowsXPLayout.sidebarWidth)

                    WindowsXPRaisedDivider(axis: .vertical)

                    fileList(
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

                statusBar
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

    private var titleBar: some View {
        HStack(spacing: 8) {
            Text(titleText)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(WindowsXPPalette.titleText)
                .shadow(color: .black.opacity(0.35), radius: 0, x: 0, y: 1)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 4)

            Spacer()

            Button {
                onSwitchToNative()
            } label: {
                Text("Native")
                    .font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(WindowsXPButtonStyle(compact: true))
            .help("切回 Native Finder shell")
            .layoutPriority(1)

            HStack(spacing: 3) {
                Button(action: onMinimize) {
                    Text("_")
                        .baselineOffset(3)
                }
                .buttonStyle(WindowsXPCaptionButtonStyle(role: .minimize))
                .help("Minimize")

                Button(action: onZoom) {
                    Text("□")
                }
                .buttonStyle(WindowsXPCaptionButtonStyle(role: .maximize))
                .help("Zoom")

                Button(action: onClose) {
                    Text("✕")
                }
                .buttonStyle(WindowsXPCaptionButtonStyle(role: .close))
                .help("Close")
            }
            .layoutPriority(2)
        }
        .padding(.horizontal, 5)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(
            ZStack(alignment: .top) {
                LinearGradient(
                    colors: [
                        WindowsXPPalette.titleActiveTop,
                        WindowsXPPalette.titleActiveMid,
                        WindowsXPPalette.titleActiveBottom
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                LinearGradient(
                    colors: [WindowsXPPalette.titleGloss, .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 12)
                .allowsHitTesting(false)
            }
        )
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

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button("Back") {
                workspaceVM.goBack()
            }
            .disabled(!workspaceVM.canGoBack)
            .buttonStyle(WindowsXPButtonStyle())

            Button("Forward") {
                workspaceVM.goForward()
            }
            .disabled(!workspaceVM.canGoForward)
            .buttonStyle(WindowsXPButtonStyle())

            Button("Up") {
                workspaceVM.goUp()
            }
            .disabled(!workspaceVM.canGoUp)
            .buttonStyle(WindowsXPButtonStyle())

            WindowsXPRaisedDivider(axis: .vertical)
                .frame(height: 22)

            Button("Refresh") {
                workspaceVM.refresh()
            }
            .disabled(workspaceVM.isLoading)
            .buttonStyle(WindowsXPButtonStyle())

            Button(workspaceVM.showsHiddenFiles ? "Hide Dotfiles" : "Show Dotfiles") {
                workspaceVM.toggleHiddenFiles()
            }
            .buttonStyle(WindowsXPButtonStyle())

            Spacer()

            Button(panelLayout.isOpen ? "Hide Terminal" : "Terminal") {
                toggleTerminalPanel()
            }
            .buttonStyle(WindowsXPButtonStyle())
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [WindowsXPPalette.toolbarTop, WindowsXPPalette.toolbarBottom],
                startPoint: .top,
                endPoint: .bottom
            )
        )
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

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                taskPanel(title: "Other Places") {
                    ForEach(sidebarItemFilter.accessibleItems(from: workspaceVM.sidebarLocations)) { item in
                        sidebarRow(item)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            LinearGradient(
                colors: [WindowsXPPalette.taskPaneTop, WindowsXPPalette.taskPaneBottom],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func fileList(availableWidth: CGFloat) -> some View {
        let columns = WindowsXPListColumns(availableWidth: availableWidth)

        return VStack(spacing: 0) {
            fileHeader(columns: columns)

            ZStack {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(spacing: 0) {
                        ForEach(workspaceVM.entries) { entry in
                            fileRow(entry, columns: columns)
                        }
                    }
                    .frame(width: columns.totalWidth, alignment: .leading)
                    .padding(.vertical, 2)
                }
                .background(WindowsXPPalette.contentBackground)

                if workspaceVM.isLoading {
                    Text("Loading...")
                        .padding(8)
                        .background(WindowsXPPalette.surface)
                        .overlay {
                            WindowsXPFieldBorder()
                        }
                } else if let errorText = workspaceVM.errorText, workspaceVM.entries.isEmpty {
                    messageBlock(title: "Unable to load folder", detail: errorText)
                } else if workspaceVM.entries.isEmpty {
                    messageBlock(title: "This folder is empty", detail: workspaceVM.path)
                }
            }
            .overlay {
                WindowsXPFieldBorder()
            }
        }
    }

    private func fileHeader(columns: WindowsXPListColumns) -> some View {
        HStack(spacing: 0) {
            headerCell("Name", width: columns.name)
            headerCell("Type", width: columns.type)
            headerCell("Size", width: columns.size)
            headerCell("Modified", width: columns.modified)
        }
        .frame(width: columns.totalWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 24)
        .background(
            LinearGradient(
                colors: [WindowsXPPalette.surfaceLight, WindowsXPPalette.surface],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var statusBar: some View {
        HStack(spacing: 4) {
            statusCell("\(workspaceVM.entries.count) object\(workspaceVM.entries.count == 1 ? "" : "s")")
                .frame(width: 132)

            statusCell(selectedStatusText)

            statusCell(shellModeState.mode.displayName)
                .frame(width: 130)
        }
        .padding(4)
        .background(WindowsXPPalette.surface)
    }

    private var selectedStatusText: String {
        guard let selectedPath = workspaceVM.selectedEntryPath,
              let entry = workspaceVM.entries.first(where: { $0.path == selectedPath })
        else {
            return workspaceVM.terminalCwdPath
        }

        return entry.name
    }

    private func menuLabel(_ title: String) -> some View {
        Text(title)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .foregroundStyle(WindowsXPPalette.text)
    }

    private func taskPanel<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(WindowsXPPalette.taskHeaderText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    LinearGradient(
                        colors: [Color.white, WindowsXPPalette.taskPaneTop.opacity(0.22)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            content()
                .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WindowsXPPalette.taskPanelFill)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(WindowsXPPalette.fieldBorder, lineWidth: 1)
        }
    }

    private func sidebarRow(_ item: FinderSidebarItem) -> some View {
        Button {
            guard let location = item.location else {
                return
            }

            workspaceVM.open(location)
        } label: {
            HStack(spacing: 6) {
                Image(nsImage: iconProvider.sidebarIcon(for: item))
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 16, height: 16)

                Text(item.title)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)
            }
            .foregroundStyle(item.isEnabled ? WindowsXPPalette.linkText : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled || item.location == nil)
    }

    private func fileRow(_ entry: DirectoryEntry, columns: WindowsXPListColumns) -> some View {
        let isSelected = workspaceVM.selectedEntryPath == entry.path

        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(nsImage: iconProvider.icon(for: entry))
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 16, height: 16)

                Text(FinderListFormatters.displayName(for: entry))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 6)
            .frame(width: columns.name, alignment: .leading)

            Text(FinderListFormatters.kindDisplayText(for: entry))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 6)
                .frame(width: columns.type, alignment: .leading)

            Text(FinderListFormatters.sizeDisplayText(isDirectory: entry.isDirectory, size: entry.size))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(width: columns.size, alignment: .trailing)

            Text(FinderListFormatters.dateDisplayText(isoString: entry.modifiedAt))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 6)
                .frame(width: columns.modified, alignment: .leading)
        }
        .frame(width: columns.totalWidth, alignment: .leading)
        .frame(height: 24)
        .foregroundStyle(isSelected ? WindowsXPPalette.selectedText : WindowsXPPalette.text)
        .background(isSelected ? WindowsXPPalette.selection : WindowsXPPalette.contentBackground)
        .contentShape(Rectangle())
        .onTapGesture {
            workspaceVM.selectEntry(path: entry.path)
        }
        .onTapGesture(count: 2) {
            workspaceVM.open(entry)
        }
    }

    private func headerCell(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .padding(.horizontal, 6)
            .frame(width: width, alignment: .leading)
            .frame(height: 22)
            .overlay {
                WindowsXPRaisedBorder()
            }
    }

    private func statusCell(_ text: String) -> some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 5)
            .frame(height: 20)
            .overlay {
                WindowsXPFieldBorder()
            }
    }

    private func messageBlock(title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
            Text(detail)
                .font(.system(size: 12))
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(16)
        .foregroundStyle(WindowsXPPalette.text)
        .background(WindowsXPPalette.contentBackground)
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

struct WindowsXPListColumns {
    let name: CGFloat
    let type: CGFloat
    let size: CGFloat
    let modified: CGFloat

    var totalWidth: CGFloat {
        name + type + size + modified
    }

    init(availableWidth: CGFloat) {
        let effectiveWidth = max(720, availableWidth)
        size = 120
        modified = min(280, max(220, effectiveWidth * 0.24))
        type = min(220, max(150, effectiveWidth * 0.19))
        name = max(260, effectiveWidth - type - size - modified)
    }
}
