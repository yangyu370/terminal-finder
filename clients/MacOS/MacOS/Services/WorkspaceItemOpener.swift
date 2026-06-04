//
//  WorkspaceItemOpener.swift
//  MacOS
//
//  Created by Codex on 2026/6/4.
//

import AppKit
import Foundation

protocol WorkspaceItemOpening: AnyObject {
    func openFile(atPath path: String) throws
}

final class WorkspaceItemOpener: WorkspaceItemOpening {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    func openFile(atPath path: String) throws {
        let fileURL = URL(fileURLWithPath: path)
        guard workspace.open(fileURL) else {
            throw WorkspaceItemOpenerError.openFailed(path)
        }
    }
}

enum WorkspaceItemOpenerError: LocalizedError {
    case openFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let path):
            return "macOS could not open \(path) with its default application."
        }
    }
}
