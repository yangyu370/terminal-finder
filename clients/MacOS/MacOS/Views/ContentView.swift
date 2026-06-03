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
        .onChange(of: connectionViewModel.status) { _, status in
            guard status == .connected else {
                return
            }

            browserViewModel.loadInitialState()
        }
    }

    private var mainInterface: some View {
        HStack(spacing: 0) {
            sidebar

            Divider()

            VStack(spacing: 0) {
                toolbar

                Divider()

                directoryBrowser
            }
        }
    }

    private var startupView: some View {
        VStack(spacing: 18) {
            if connectionViewModel.isConnecting {
                ProgressView()
                    .controlSize(.large)
            }

            BackendStatusView(
                status: connectionViewModel.status,
                detailText: connectionViewModel.detailText
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
                detailText: connectionViewModel.detailText
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

                Text("\(browserViewModel.entries.count) items")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)

                TextField("Directory path", text: $browserViewModel.path)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        browserViewModel.openCurrentPath()
                    }

                Button {
                    browserViewModel.openCurrentPath()
                } label: {
                    Label("Open", systemImage: "arrow.right.circle")
                }
                .disabled(browserViewModel.isLoading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
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
