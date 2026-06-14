//
//  Windows98ShellView.swift
//  MacOS
//
//  Created by Codex on 2026/6/14.
//

import AppKit
import SwiftUI

struct Windows98ShellView: View {
    @Environment(\.displayScale) private var displayScale

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

    private let iconProvider: Windows98IconProvider
    private let sidebarItemFilter: Windows98SidebarItemFilter

    @State private var pathInput: String

    init(
        workspaceVM: WorkspaceBrowserViewModel,
        terminalVM: TerminalSessionViewModel,
        panelLayout: PseudoTerminalPanelLayoutState,
        contentState: FinderContentViewState,
        shellModeState: ClientShellModeState,
        iconProvider: Windows98IconProvider = Windows98IconProvider(),
        sidebarItemFilter: Windows98SidebarItemFilter = Windows98SidebarItemFilter(),
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
            let titleBarTopInset = Windows98ChromeMetrics.pixelAlignedTopInset(
                geometry.safeAreaInsets.top,
                displayScale: displayScale
            )

            VStack(spacing: 0) {
                windowChrome(
                    topInset: titleBarTopInset,
                    availableWidth: geometry.size.width
                )

                contentSplit(availableWidth: geometry.size.width)

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
                    .frame(width: geometry.size.width)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .font(.system(size: 12))
            .background(Windows98Palette.surface)
        }
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

    private func windowChrome(topInset: CGFloat, availableWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            titleBar(topInset: topInset)
            menuBar
            toolbar
            addressBar
        }
        .frame(width: availableWidth, alignment: .topLeading)
        .background(Windows98Palette.surface)
    }

    private func contentSplit(availableWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: Windows98Layout.sidebarWidth)

            Windows98RaisedDivider(axis: .vertical)

            fileList(
                availableWidth: max(
                    0,
                    availableWidth - Windows98Layout.sidebarWidth - Windows98Layout.raisedDividerWidth
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: availableWidth, alignment: .leading)
        .frame(maxHeight: .infinity)
    }

    private func titleBar(topInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: topInset)

            HStack(spacing: 8) {
                Text("C:\\")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Windows98Palette.surface)
                    .foregroundStyle(.black)

                Spacer()

                Button {
                    onSwitchToNative()
                } label: {
                    Text("Native")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(Windows98ButtonStyle(compact: true))
                .help("切回 Native Finder shell")
                .layoutPriority(1)

                HStack(spacing: 2) {
                    Button(action: onMinimize) {
                        Text("_")
                            .baselineOffset(3)
                    }
                    .buttonStyle(Windows98TitleButtonStyle())
                    .help("Minimize")

                    Button(action: onZoom) {
                        Text("□")
                    }
                    .buttonStyle(Windows98TitleButtonStyle())
                    .help("Zoom")

                    Button(action: onClose) {
                        Text("X")
                    }
                    .buttonStyle(Windows98TitleButtonStyle(isCloseButton: true))
                    .help("Close")
                }
                .layoutPriority(2)
            }
            .padding(.horizontal, 4)
            .frame(height: Windows98ChromeMetrics.titleBarContentHeight)
        }
        .frame(height: Windows98ChromeMetrics.titleBarHeight(topInset: topInset))
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(
                colors: [Windows98Palette.titleBlue, Windows98Palette.titleBlueLight],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    private var menuBar: some View {
        HStack(spacing: 4) {
            menuLabel("File")
            menuLabel("Edit")
            menuLabel("View")
            menuLabel("Go")
            menuLabel("Help")
            Spacer()
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(Windows98Palette.surface)
        .overlay(alignment: .bottom) {
            Windows98RaisedDivider(axis: .horizontal)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button("Back") {
                workspaceVM.goBack()
            }
            .disabled(!workspaceVM.canGoBack)
            .buttonStyle(Windows98ButtonStyle())

            Button("Forward") {
                workspaceVM.goForward()
            }
            .disabled(!workspaceVM.canGoForward)
            .buttonStyle(Windows98ButtonStyle())

            Button("Up") {
                workspaceVM.goUp()
            }
            .disabled(!workspaceVM.canGoUp)
            .buttonStyle(Windows98ButtonStyle())

            Windows98RaisedDivider(axis: .vertical)
                .frame(height: 22)

            Button("Refresh") {
                workspaceVM.refresh()
            }
            .disabled(workspaceVM.isLoading)
            .buttonStyle(Windows98ButtonStyle())

            Button(workspaceVM.showsHiddenFiles ? "Hide Dotfiles" : "Show Dotfiles") {
                workspaceVM.toggleHiddenFiles()
            }
            .buttonStyle(Windows98ButtonStyle())

            Spacer()

            Button(panelLayout.isOpen ? "Hide Terminal" : "Terminal") {
                toggleTerminalPanel()
            }
            .buttonStyle(Windows98ButtonStyle())
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Windows98Palette.surface)
    }

    private var addressBar: some View {
        HStack(spacing: 6) {
            Text("Address")
                .foregroundStyle(.black)

            TextField("", text: $pathInput, onCommit: openPathInput)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 4)
                .frame(height: 22)
                .frame(maxWidth: .infinity)
                .background(.white)
                .overlay {
                    Windows98InsetBorder()
                }
                .layoutPriority(1)

            Button("Go") {
                openPathInput()
            }
            .buttonStyle(Windows98ButtonStyle(compact: true))
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background(Windows98Palette.surface)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Explorer")
                    .font(.system(size: 12, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .foregroundStyle(.white)
                    .background(Windows98Palette.titleBlue)

                ForEach(sidebarItemFilter.accessibleItems(from: workspaceVM.sidebarLocations)) { item in
                    sidebarRow(item)
                }
            }
        }
        .background(Windows98Palette.sidebar)
    }

    private func fileList(availableWidth: CGFloat) -> some View {
        let columns = Windows98ListColumns(availableWidth: availableWidth)

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
                .background(.white)

                if workspaceVM.isLoading {
                    Text("Loading...")
                        .padding(8)
                        .background(Windows98Palette.surface)
                        .overlay {
                            Windows98RaisedBorder()
                        }
                } else if let errorText = workspaceVM.errorText, workspaceVM.entries.isEmpty {
                    messageBlock(title: "Unable to load folder", detail: errorText)
                } else if workspaceVM.entries.isEmpty {
                    messageBlock(title: "This folder is empty", detail: workspaceVM.path)
                }
            }
            .overlay {
                Windows98InsetBorder()
            }
        }
    }

    private func fileHeader(columns: Windows98ListColumns) -> some View {
        HStack(spacing: 0) {
            headerCell("Name", width: columns.name)
            headerCell("Type", width: columns.type)
            headerCell("Size", width: columns.size)
            headerCell("Modified", width: columns.modified)
        }
        .frame(width: columns.totalWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 24)
        .background(Windows98Palette.surface)
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
        .background(Windows98Palette.surface)
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
            .padding(.horizontal, 5)
            .frame(height: 20)
            .foregroundStyle(.black)
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
                    .frame(width: 18)

                Text(item.title)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)
            }
            .foregroundStyle(item.isEnabled ? Color.black : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled || item.location == nil)
    }

    private func fileRow(_ entry: DirectoryEntry, columns: Windows98ListColumns) -> some View {
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
        .foregroundStyle(isSelected ? Color.white : Color.black)
        .background(isSelected ? Windows98Palette.selection : Color.white)
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
                Windows98RaisedBorder()
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
                Windows98InsetBorder()
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
        .foregroundStyle(.black)
        .background(.white)
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

struct Windows98SidebarItemFilter {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func accessibleItems(from locations: [WorkspaceSidebarLocation]) -> [FinderSidebarItem] {
        FinderSidebarItem.makeItems(from: locations)
            .filter(isAccessibleDirectory)
    }

    private func isAccessibleDirectory(_ item: FinderSidebarItem) -> Bool {
        guard let location = item.location else {
            return false
        }

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: location.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return false
        }

        return fileManager.isReadableFile(atPath: location.path)
    }
}

private enum Windows98Layout {
    static let sidebarWidth: CGFloat = 176
    static let raisedDividerWidth: CGFloat = 2
}

struct Windows98ChromeMetrics {
    static let titleBarContentHeight: CGFloat = 26

    static func titleBarHeight(topInset: CGFloat) -> CGFloat {
        titleBarContentHeight + max(0, topInset)
    }

    static func pixelAlignedTopInset(_ topInset: CGFloat, displayScale: CGFloat) -> CGFloat {
        let positiveInset = max(0, topInset)
        guard displayScale > 0 else {
            return positiveInset
        }

        return ceil(positiveInset * displayScale) / displayScale
    }
}

struct Windows98ListColumns {
    static let minimumScrollableWidth: CGFloat = 750

    let name: CGFloat
    let type: CGFloat
    let size: CGFloat
    let modified: CGFloat

    var totalWidth: CGFloat {
        name + type + size + modified
    }

    init(availableWidth: CGFloat) {
        let effectiveWidth = max(Self.minimumScrollableWidth, availableWidth)
        size = 120
        modified = min(280, max(220, effectiveWidth * 0.24))
        type = min(220, max(150, effectiveWidth * 0.19))
        name = max(260, effectiveWidth - type - size - modified)
    }
}

private enum Windows98Palette {
    static let surface = Color(nsColor: NSColor(calibratedRed: 0.75, green: 0.75, blue: 0.75, alpha: 1))
    static let sidebar = Color(nsColor: NSColor(calibratedRed: 0.86, green: 0.86, blue: 0.86, alpha: 1))
    static let titleBlue = Color(nsColor: NSColor(calibratedRed: 0.0, green: 0.0, blue: 0.5, alpha: 1))
    static let titleBlueLight = Color(nsColor: NSColor(calibratedRed: 0.07, green: 0.35, blue: 0.76, alpha: 1))
    static let selection = Color(nsColor: NSColor(calibratedRed: 0.0, green: 0.0, blue: 0.5, alpha: 1))
    static let highlight = Color.white
    static let shadow = Color(nsColor: NSColor(calibratedWhite: 0.5, alpha: 1))
    static let darkShadow = Color.black
}

private struct Windows98ButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11 : 12))
            .foregroundStyle(.black)
            .padding(.horizontal, compact ? 7 : 10)
            .frame(height: compact ? 19 : 23)
            .background(Windows98Palette.surface)
            .overlay {
                if configuration.isPressed {
                    Windows98InsetBorder()
                } else {
                    Windows98RaisedBorder()
                }
            }
    }
}

private struct Windows98TitleButtonStyle: ButtonStyle {
    var isCloseButton = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: isCloseButton ? 11 : 12, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: 16, height: 16)
            .background(Windows98Palette.surface)
            .overlay {
                if configuration.isPressed {
                    Windows98InsetBorder()
                } else {
                    Windows98RaisedBorder()
                }
            }
            .offset(x: configuration.isPressed ? 1 : 0, y: configuration.isPressed ? 1 : 0)
    }
}

private struct Windows98RaisedDivider: View {
    enum Axis {
        case horizontal
        case vertical
    }

    let axis: Axis

    var body: some View {
        switch axis {
        case .horizontal:
            VStack(spacing: 0) {
                Windows98Palette.highlight.frame(height: 1)
                Windows98Palette.shadow.frame(height: 1)
            }
        case .vertical:
            HStack(spacing: 0) {
                Windows98Palette.highlight.frame(width: 1)
                Windows98Palette.shadow.frame(width: 1)
            }
        }
    }
}

private struct Windows98RaisedBorder: View {
    var body: some View {
        Rectangle()
            .strokeBorder(Windows98Palette.highlight, lineWidth: 1)
            .overlay(alignment: .trailing) {
                Windows98Palette.darkShadow.frame(width: 1)
            }
            .overlay(alignment: .bottom) {
                Windows98Palette.darkShadow.frame(height: 1)
            }
            .overlay(alignment: .trailing) {
                Windows98Palette.shadow
                    .frame(width: 1)
                    .padding(.bottom, 1)
            }
            .overlay(alignment: .bottom) {
                Windows98Palette.shadow
                    .frame(height: 1)
                    .padding(.trailing, 1)
            }
    }
}

private struct Windows98InsetBorder: View {
    var body: some View {
        Rectangle()
            .strokeBorder(Windows98Palette.darkShadow, lineWidth: 1)
            .overlay(alignment: .trailing) {
                Windows98Palette.highlight.frame(width: 1)
            }
            .overlay(alignment: .bottom) {
                Windows98Palette.highlight.frame(height: 1)
            }
            .overlay(alignment: .top) {
                Windows98Palette.shadow
                    .frame(height: 1)
                    .padding(.leading, 1)
            }
            .overlay(alignment: .leading) {
                Windows98Palette.shadow
                    .frame(width: 1)
                    .padding(.top, 1)
            }
    }
}
