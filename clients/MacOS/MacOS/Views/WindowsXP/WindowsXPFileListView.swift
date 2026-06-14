//
//  WindowsXPFileListView.swift
//  MacOS
//
//  Created by Claude on 2026/6/14.
//
//  Luna details view: flat clickable-looking column header (hover + separators),
//  rows with hover highlight and #316AC5 selection, plus centered loading /
//  error / empty panels. Column widths adapt to available width.

import AppKit
import SwiftUI

struct WindowsXPFileListView: View {
    @ObservedObject var workspaceVM: WorkspaceBrowserViewModel
    let iconProvider: WindowsXPIconProvider
    let availableWidth: CGFloat

    @State private var hoveredPath: String?
    @State private var hoveredColumn: String?

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
                    loadingPanel
                } else if let errorText = workspaceVM.errorText, workspaceVM.entries.isEmpty {
                    messageBlock(iconKind: .other, title: "Unable to load folder", detail: errorText)
                } else if workspaceVM.entries.isEmpty {
                    messageBlock(iconKind: .folder, title: "This folder is empty", detail: workspaceVM.path)
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
        .overlay(alignment: .bottom) {
            WindowsXPPalette.fieldBorder.frame(height: 1)
        }
    }

    private func headerCell(_ title: String, width: CGFloat) -> some View {
        let isHovered = hoveredColumn == title

        return Text(title)
            .padding(.horizontal, 6)
            .frame(width: width, height: 24, alignment: .leading)
            .background(isHovered ? WindowsXPPalette.headerHover : Color.clear)
            .overlay(alignment: .trailing) {
                WindowsXPPalette.fieldBorder
                    .frame(width: 1)
                    .padding(.vertical, 4)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    hoveredColumn = title
                } else if hoveredColumn == title {
                    hoveredColumn = nil
                }
            }
    }

    private func fileRow(_ entry: DirectoryEntry, columns: WindowsXPListColumns) -> some View {
        let isSelected = workspaceVM.selectedEntryPath == entry.path
        let isHovered = hoveredPath == entry.path
        let background: Color = isSelected
            ? WindowsXPPalette.selection
            : (isHovered ? WindowsXPPalette.rowHover : WindowsXPPalette.contentBackground)

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
        .background(background)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                hoveredPath = entry.path
            } else if hoveredPath == entry.path {
                hoveredPath = nil
            }
        }
        .onTapGesture {
            workspaceVM.selectEntry(path: entry.path)
        }
        .onTapGesture(count: 2) {
            workspaceVM.open(entry)
        }
    }

    private var loadingPanel: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Loading…")
                .font(.system(size: 12))
                .foregroundStyle(WindowsXPPalette.text)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(WindowsXPPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(WindowsXPPalette.fieldBorder, lineWidth: 1)
        }
    }

    private func messageBlock(iconKind: WindowsXPIconKind, title: String, detail: String) -> some View {
        let largeIcon = WindowsXPIconProvider(size: NSSize(width: 32, height: 32))

        return VStack(spacing: 10) {
            Image(nsImage: largeIcon.icon(kind: iconKind))
                .resizable()
                .interpolation(.none)
                .frame(width: 32, height: 32)

            Text(title)
                .font(.system(size: 13, weight: .bold))
            Text(detail)
                .font(.system(size: 12))
                .lineLimit(2)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .foregroundStyle(WindowsXPPalette.text)
        .background(WindowsXPPalette.contentBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(WindowsXPPalette.fieldBorder, lineWidth: 1)
        }
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
