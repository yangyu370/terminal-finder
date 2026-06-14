//
//  WindowsXPSidebarItemFilter.swift
//  MacOS
//
//  Created by Claude on 2026/6/14.
//
//  Independent copy of the Win98 filter (approach A: decoupled shells). Keeps
//  only sidebar entries that resolve to an existing, readable directory.

import Foundation

struct WindowsXPSidebarItemFilter {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func accessibleItems(from locations: [WorkspaceSidebarLocation]) -> [FinderSidebarItem] {
        FinderSidebarItem.makeItems(from: locations)
            .filter(isAccessibleDirectory)
    }

    private func isAccessibleDirectory(_ item: FinderSidebarItem) -> Bool {
        guard let location = item.location else {
            return false
        }

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: location.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return false
        }

        return fileManager.isReadableFile(atPath: location.path)
    }
}
