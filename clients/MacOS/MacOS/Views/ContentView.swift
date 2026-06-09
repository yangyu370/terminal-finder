//
//  ContentView.swift
//  MacOS
//
//  Created by Wang on 2026/6/1.
//

import AppKit
import SwiftUI

/// Bridges `NSVisualEffectView` so the sidebar gets the native translucent Finder material.
private struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct ContentView: View {
    @StateObject private var connectionViewModel = BackendConnectionViewModel()
    @StateObject private var browserViewModel = WorkspaceBrowserViewModel()
    @StateObject private var terminalPanelLayout = PseudoTerminalPanelLayoutState()
    @StateObject private var terminalSessionViewModel = TerminalSessionViewModel()

    var body: some View {
        Group {
            if connectionViewModel.isConnected {
                mainInterface
            } else {
                startupView
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            connectionViewModel.connect()
        }
        .onAppear {
            terminalSessionViewModel.onSessionEnded = {
                withAnimation(.easeOut(duration: 0.18)) {
                    terminalPanelLayout.close()
                }
            }
        }
        .overlay {
            terminalPanelShortcut
        }
        .onChange(of: connectionViewModel.status) { _, status in
            if status == .connected {
                browserViewModel.loadInitialState()
                return
            }

            terminalSessionViewModel.disconnect()
            terminalPanelLayout.close()
        }
        .alert(
            "Unable to Open File",
            isPresented: Binding(
                get: { browserViewModel.fileOpenErrorText != nil },
                set: { isPresented in
                    if !isPresented {
                        browserViewModel.dismissFileOpenError()
                    }
                }
            )
        ) {
            Button("OK") {
                browserViewModel.dismissFileOpenError()
            }
        } message: {
            Text(browserViewModel.fileOpenErrorText ?? "macOS could not open this file.")
        }
    }

    private var terminalPanelShortcut: some View {
        Button {
            openTerminalPanel()
        } label: {
            EmptyView()
        }
        .keyboardShortcut("j", modifiers: .command)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private var mainInterface: some View {
        HStack(spacing: 0) {
            sidebar

            Divider()

            VStack(spacing: 0) {
                toolbar

                Divider()

                workspaceContent
            }
        }
    }

    private var workspaceContent: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                directoryBrowser
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if terminalPanelLayout.isOpen {
                    TerminalResizeHandle { verticalDrag in
                        terminalPanelLayout.resize(
                            byVerticalDrag: verticalDrag,
                            availableContentHeight: geometry.size.height
                        )
                    }

                    PseudoTerminalPanelView(
                        terminalSessionViewModel: terminalSessionViewModel,
                        onClose: {
                            terminalSessionViewModel.close()
                        },
                        onViewportChanged: { viewportSize in
                            terminalPanelLayout.noteViewportSize(viewportSize)
                        }
                    )
                    .frame(
                        maxWidth: .infinity,
                        minHeight: terminalPanelLayout.height,
                        idealHeight: terminalPanelLayout.height,
                        maxHeight: terminalPanelLayout.height
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .clipped()
    }

    private func openTerminalPanel() {
        withAnimation(.easeOut(duration: 0.18)) {
            terminalPanelLayout.open()
        }
        terminalSessionViewModel.start(cwd: browserViewModel.terminalCwdPath)
    }

    private var startupView: some View {
        VStack(spacing: 18) {
            if connectionViewModel.isConnecting {
                ProgressView()
                    .controlSize(.large)
            }

            BackendStatusView(
                status: connectionViewModel.status,
                detailText: connectionViewModel.detailText,
                eventStatusText: connectionViewModel.eventStatusText
            )
            .frame(maxWidth: 420, alignment: .leading)

            Button {
                connectionViewModel.reconnect()
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .disabled(connectionViewModel.isConnecting)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Favorites")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 6)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(browserViewModel.sidebarLocations) { location in
                    sidebarRow(for: location)
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            Divider()
                .padding(.horizontal, 12)

            BackendStatusView(
                status: connectionViewModel.status,
                detailText: connectionViewModel.detailText,
                eventStatusText: connectionViewModel.eventStatusText
            )
            .padding(.horizontal, 14)
            .padding(.top, 10)

            Button {
                connectionViewModel.reconnect()
            } label: {
                Label("Reconnect", systemImage: "bolt.horizontal.circle")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(connectionViewModel.isConnecting)
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 14)
        }
        .frame(width: 210)
        .background(VisualEffectView())
    }

    private func sidebarRow(for location: WorkspaceSidebarLocation) -> some View {
        let isSelected = isSidebarLocationSelected(location)

        return Button {
            browserViewModel.open(location)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: location.systemImageName)
                    .font(.system(size: 14))
                    .frame(width: 20)
                    .foregroundStyle(isSelected ? Color.white : Color.accentColor)

                Text(location.title)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isSelected ? Color.accentColor : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(browserViewModel.isLoading)
    }

    private func isSidebarLocationSelected(_ location: WorkspaceSidebarLocation) -> Bool {
        let currentPath = browserViewModel.workspaceState?.currentDirectory ?? browserViewModel.path
        return currentPath == location.path
    }

    private var toolbar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    browserViewModel.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .keyboardShortcut("[", modifiers: .command)
                .help("Back")
                .disabled(!browserViewModel.canGoBack)

                Button {
                    browserViewModel.goForward()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .keyboardShortcut("]", modifiers: .command)
                .help("Forward")
                .disabled(!browserViewModel.canGoForward)

                Button {
                    browserViewModel.goUp()
                } label: {
                    Image(systemName: "arrow.up")
                }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .help("Enclosing Folder")
                .disabled(!browserViewModel.canGoUp)

                Divider()
                    .frame(height: 18)

                Button {
                    browserViewModel.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
                .disabled(browserViewModel.isLoading)

                Text(browserViewModel.currentDirectoryName)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()
            }

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)

                TextField(
                    "File or directory path",
                    text: Binding(
                        get: { browserViewModel.path },
                        set: { browserViewModel.updatePathInput($0) }
                    )
                )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        browserViewModel.openCurrentPath()
                    }

                Button {
                    browserViewModel.openSelectedItemOrCurrentPath()
                } label: {
                    Label("Open", systemImage: "arrow.right.circle")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .help("Open the selected item, or open the entered path")
                .disabled(!browserViewModel.canOpen)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay {
            Button {
                browserViewModel.toggleHiddenFiles()
            } label: {
                EmptyView()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private var directoryBrowser: some View {
        ZStack {
            DirectoryTableView(
                entries: browserViewModel.entries,
                selectedPath: browserViewModel.selectedEntryPath,
                onSelect: { path in
                    browserViewModel.selectEntry(path: path)
                },
                onOpen: { entry in
                    browserViewModel.open(entry)
                },
                loadChildren: { path in
                    try await browserViewModel.loadChildren(path: path)
                }
            )

            if browserViewModel.isLoading {
                ProgressView()
                    .controlSize(.large)
                    .padding(18)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if let errorText = browserViewModel.errorText {
                ContentUnavailableView(
                    "Unable to Load Directory",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorText)
                )
            } else if browserViewModel.entries.isEmpty {
                ContentUnavailableView(
                    "No Entries",
                    systemImage: "folder",
                    description: Text(browserViewModel.path)
                )
            }
        }
    }
}
