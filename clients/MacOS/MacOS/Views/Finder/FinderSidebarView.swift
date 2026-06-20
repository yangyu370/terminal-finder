//
//  FinderSidebarView.swift
//  MacOS
//
//  Created by Claude on 2026/6/11.
//

import SwiftUI

/// Sidebar content rendered with SwiftUI `List(.sidebar)` inside the
/// AppKit sidebar split view item (which provides the glass material).
/// Selection is derived from backend workspace state; clicking a row only
/// requests navigation and never switches the selection locally.
struct FinderSidebarView: View {
    @ObservedObject var workspaceVM: WorkspaceBrowserViewModel

    private var items: [FinderSidebarItem] {
        FinderSidebarItem.makeItems(from: workspaceVM.sidebarLocations)
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: {
                guard let currentDirectory = workspaceVM.workspaceState?.currentDirectory else {
                    return nil
                }

                return items.first { $0.location?.path == currentDirectory }?.id
            },
            set: { newValue in
                guard let newValue,
                      let item = items.first(where: { $0.id == newValue }),
                      let location = item.location
                else {
                    return
                }

                workspaceVM.open(location)
            }
        )
    }

    var body: some View {
        let items = items
        List(selection: selectionBinding) {
            Section {
                rows(for: .general, in: items)
            }
            Section("个人收藏") {
                rows(for: .favorites, in: items)
            }
            Section("位置") {
                rows(for: .locations, in: items)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func rows(for group: FinderSidebarGroup, in items: [FinderSidebarItem]) -> some View {
        ForEach(items.filter { $0.group == group }) { item in
            row(for: item)
                .tag(item.id)
                .selectionDisabled(!item.isEnabled)
        }
    }

    @ViewBuilder
    private func row(for item: FinderSidebarItem) -> some View {
        if let tagColor = item.tagColor {
            HStack(spacing: 8) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(color(for: tagColor))
                    .frame(width: 22)

                Text(item.title)
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: item.systemImageName)
                    .font(.system(size: 17, weight: .regular))
                    .frame(width: 22)

                Text(item.title)
            }
            .foregroundStyle(.secondary)
            .opacity(item.isEnabled ? 1 : 0.82)
            .accessibilityLabel(item.title)
        }
    }

    private func color(for tagColor: FinderSidebarTagColor) -> Color {
        switch tagColor {
        case .red: return Color(nsColor: .systemRed)
        case .orange: return Color(nsColor: .systemOrange)
        case .yellow: return Color(nsColor: .systemYellow)
        case .green: return Color(nsColor: .systemGreen)
        case .blue: return Color(nsColor: .systemBlue)
        case .purple: return Color(nsColor: .systemPurple)
        case .gray: return Color(nsColor: .systemGray)
        }
    }
}
