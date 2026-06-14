//
//  WindowsXPStatusBarView.swift
//  MacOS
//
//  Created by Claude on 2026/6/14.
//
//  Beige status bar with soft sunken cells: object count, selection detail
//  (kind + size), shell name, plus an XP-style resize grip in the corner.

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

            resizeGrip
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

        let kind = FinderListFormatters.kindDisplayText(for: entry)
        if entry.isDirectory {
            return "\(entry.name) — \(kind)"
        }

        let size = FinderListFormatters.sizeDisplayText(isDirectory: entry.isDirectory, size: entry.size)
        return "\(entry.name) — \(kind), \(size)"
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

    /// Lower-right triangular dot grid, echoing the XP window resize grip.
    private var resizeGrip: some View {
        Canvas { context, size in
            let dot: CGFloat = 2
            let step: CGFloat = 4
            for row in 0..<3 {
                for col in 0...row {
                    let x = size.width - step * CGFloat(row - col + 1)
                    let y = size.height - step * CGFloat(col + 1)
                    let rect = CGRect(x: x, y: y, width: dot, height: dot)
                    context.fill(Path(ellipseIn: rect), with: .color(WindowsXPPalette.shadow))
                }
            }
        }
        .frame(width: 16, height: 20)
        .allowsHitTesting(false)
    }
}
