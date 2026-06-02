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
        VStack(alignment: .leading, spacing: 16) {
            BackendStatusView(
                status: connectionViewModel.status,
                detailText: connectionViewModel.detailText
            )

            HStack {
                Button("Ping Core") {
                    connectionViewModel.ping()
                }
                .disabled(connectionViewModel.isConnecting)

                Spacer()
            }

            Divider()

            HStack(spacing: 8) {
                TextField("Directory path", text: $browserViewModel.path)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        browserViewModel.loadCurrentPath()
                    }

                Button("Load") {
                    browserViewModel.loadCurrentPath()
                }
                .disabled(browserViewModel.isLoading)
            }

            if let errorText = browserViewModel.errorText {
                Text(errorText)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            List(browserViewModel.listing?.entries ?? []) { entry in
                DirectoryEntryRow(entry: entry)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        browserViewModel.open(entry)
                    }
            }
            .overlay {
                if browserViewModel.isLoading {
                    ProgressView()
                } else if browserViewModel.listing?.entries.isEmpty ?? true {
                    Text("No entries loaded")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 520)
        .task {
            connectionViewModel.ping()
            browserViewModel.loadCurrentPath()
        }
    }
}

private struct DirectoryEntryRow: View {
    let entry: DirectoryEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                .frame(width: 18)

            Text(entry.name)
                .lineLimit(1)

            Spacer()

            Text(detailText)
                .foregroundStyle(.secondary)
                .font(.caption)
                .monospacedDigit()
        }
        .padding(.vertical, 3)
    }

    private var iconName: String {
        switch entry.kind {
        case .directory:
            return "folder"
        case .file:
            return "doc"
        case .symlink:
            return "arrowshape.turn.up.right"
        case .other:
            return "questionmark.square"
        }
    }

    private var detailText: String {
        if entry.isDirectory {
            return "Folder"
        }

        guard let size = entry.size else {
            return entry.kind.rawValue
        }

        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
