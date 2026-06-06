//
//  ContentView.swift
//  MacOS
//
//  Created by Wang on 2026/6/1.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var connectionViewModel = BackendConnectionViewModel()
    @StateObject private var browserViewModel = WorkspaceBrowserViewModel()
    @StateObject private var terminalPanelLayout = PseudoTerminalPanelLayoutState()

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
        .overlay {
            terminalPanelShortcut
        }
        .onChange(of: connectionViewModel.status) { _, status in
            guard status == .connected else {
                return
            }

            browserViewModel.loadInitialState()
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
            withAnimation(.easeOut(duration: 0.18)) {
                terminalPanelLayout.open()
            }
        } label: {
            EmptyView()
        }
        .keyboardShortcut("k", modifiers: .command)
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

                    PseudoTerminalPanelView { viewportSize in
                        terminalPanelLayout.noteViewportSize(viewportSize)
                    }
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
        VStack(alignment: .leading, spacing: 14) {
            BackendStatusView(
                status: connectionViewModel.status,
                detailText: connectionViewModel.detailText,
                eventStatusText: connectionViewModel.eventStatusText
            )
            .padding(.horizontal, 14)
            .padding(.top, 16)

            Button {
                connectionViewModel.reconnect()
            } label: {
                Label("Reconnect", systemImage: "bolt.horizontal.circle")
            }
            .buttonStyle(.borderless)
            .disabled(connectionViewModel.isConnecting)
            .padding(.horizontal, 14)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Favorites")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)

                ForEach(browserViewModel.sidebarLocations) { location in
                    Button {
                        browserViewModel.open(location)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: location.systemImageName)
                                .frame(width: 18)
                                .foregroundStyle(.secondary)

                            Text(location.title)
                                .lineLimit(1)

                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(sidebarSelectionBackground(for: location))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .disabled(browserViewModel.isLoading)
                }
            }

            Spacer()
        }
        .frame(width: 220)
        .background(Color(nsColor: .controlBackgroundColor))
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

    private func sidebarSelectionBackground(for location: WorkspaceSidebarLocation) -> some ShapeStyle {
        let currentPath = browserViewModel.workspaceState?.currentDirectory ?? browserViewModel.path
        return currentPath == location.path ? Color.accentColor.opacity(0.16) : Color.clear
    }
}
