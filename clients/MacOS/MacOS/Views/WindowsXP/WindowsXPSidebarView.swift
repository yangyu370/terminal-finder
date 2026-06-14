//
//  WindowsXPSidebarView.swift
//  MacOS
//
//  Created by Claude on 2026/6/14.
//
//  Luna task pane: blue gradient background with a white rounded "Other Places"
//  panel of navigable, accessible locations.

import SwiftUI

struct WindowsXPSidebarView: View {
    @ObservedObject var workspaceVM: WorkspaceBrowserViewModel
    let iconProvider: WindowsXPIconProvider
    let sidebarItemFilter: WindowsXPSidebarItemFilter

    var body: some View {
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
}
