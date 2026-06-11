//
//  FinderSidebarItem.swift
//  MacOS
//
//  Created by Claude on 2026/6/11.
//

import Foundation

/// Sidebar group buckets matching the Finder reference layout.
enum FinderSidebarGroup: CaseIterable {
    /// Untitled top section (最近使用 / 共享).
    case general
    case favorites
    case locations
    case tags
}

/// Finder tag colors, rendered as colored dots in the sidebar.
enum FinderSidebarTagColor: String, CaseIterable {
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case gray

    var title: String {
        switch self {
        case .red: return "红色"
        case .orange: return "橙色"
        case .yellow: return "黄色"
        case .green: return "绿色"
        case .blue: return "蓝色"
        case .purple: return "紫色"
        case .gray: return "灰色"
        }
    }
}

/// Pure presentation model for one sidebar row. Navigable rows carry a
/// `WorkspaceSidebarLocation` from the ViewModel; placeholder rows hold no path.
struct FinderSidebarItem: Identifiable {
    let id: String
    let title: String
    let systemImageName: String
    let group: FinderSidebarGroup
    let tagColor: FinderSidebarTagColor?
    let location: WorkspaceSidebarLocation?

    var isEnabled: Bool {
        location != nil
    }

    init(
        id: String,
        title: String,
        systemImageName: String,
        group: FinderSidebarGroup,
        tagColor: FinderSidebarTagColor? = nil,
        location: WorkspaceSidebarLocation? = nil
    ) {
        self.id = id
        self.title = title
        self.systemImageName = systemImageName
        self.group = group
        self.tagColor = tagColor
        self.location = location
    }

    /// Maps the ViewModel's sidebar locations (Home/Desktop/Downloads/Documents)
    /// onto the Finder reference structure, mixing in disabled placeholders.
    /// Paths only ever come from `locations`; no path is derived locally.
    static func makeItems(from locations: [WorkspaceSidebarLocation]) -> [FinderSidebarItem] {
        let home = locations.first { $0.title == "Home" }
        let desktop = locations.first { $0.title == "Desktop" }
        let downloads = locations.first { $0.title == "Downloads" }
        let documents = locations.first { $0.title == "Documents" }

        let homeTitle = home.map { location -> String in
            let name = URL(fileURLWithPath: location.path).lastPathComponent
            return name.isEmpty ? location.path : name
        } ?? "个人"

        var items: [FinderSidebarItem] = [
            FinderSidebarItem(
                id: "general.recents",
                title: "最近使用",
                systemImageName: "clock",
                group: .general
            ),
            FinderSidebarItem(
                id: "general.shared",
                title: "共享",
                systemImageName: "folder.badge.person.crop",
                group: .general
            ),
            FinderSidebarItem(
                id: "favorites.desktop",
                title: "桌面",
                systemImageName: "menubar.dock.rectangle",
                group: .favorites,
                location: desktop
            ),
            FinderSidebarItem(
                id: "favorites.documents",
                title: "文稿",
                systemImageName: "doc",
                group: .favorites,
                location: documents
            ),
            FinderSidebarItem(
                id: "favorites.downloads",
                title: "下载",
                systemImageName: "arrow.down.circle",
                group: .favorites,
                location: downloads
            ),
            FinderSidebarItem(
                id: "locations.icloud",
                title: "iCloud云盘",
                systemImageName: "cloud",
                group: .locations
            ),
            FinderSidebarItem(
                id: "locations.home",
                title: homeTitle,
                systemImageName: "house",
                group: .locations,
                location: home
            ),
            FinderSidebarItem(
                id: "locations.airdrop",
                title: "隔空投送",
                systemImageName: "wave.3.right.circle",
                group: .locations
            ),
            FinderSidebarItem(
                id: "locations.network",
                title: "网络",
                systemImageName: "globe",
                group: .locations
            ),
            FinderSidebarItem(
                id: "locations.trash",
                title: "废纸篓",
                systemImageName: "trash",
                group: .locations
            )
        ]

        for color in FinderSidebarTagColor.allCases {
            items.append(
                FinderSidebarItem(
                    id: "tags.\(color.rawValue)",
                    title: color.title,
                    systemImageName: "circle.fill",
                    group: .tags,
                    tagColor: color
                )
            )
        }

        return items
    }
}
