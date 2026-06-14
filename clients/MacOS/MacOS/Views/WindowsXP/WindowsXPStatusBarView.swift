//
//  WindowsXPStatusBarView.swift
//  MacOS
//
//  Created by Claude on 2026/6/14.
//
//  Beige status bar with soft sunken cells: object count, selection, shell name.

import SwiftUI

struct WindowsXPStatusBarView: View {
    @ObservedObject var workspaceVM: WorkspaceBrowserViewModel
    @ObservedObject var shellModeState: ClientShellModeState

    var body: some View {
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
}
