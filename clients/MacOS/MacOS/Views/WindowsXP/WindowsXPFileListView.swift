//
//  WindowsXPFileListView.swift
//  MacOS
//
//  Created by Claude on 2026/6/14.
//
//  Luna details view: column header + rows with #316AC5 selection, plus
//  loading / error / empty states. Column widths adapt to available width.

import SwiftUI

struct WindowsXPFileListView: View {
    @ObservedObject var workspaceVM: WorkspaceBrowserViewModel
    let iconProvider: WindowsXPIconProvider
    let availableWidth: CGFloat

    var body: some View {
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
