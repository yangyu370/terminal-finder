//
//  ClientShellMode.swift
//  MacOS
//
//  Created by Codex on 2026/6/14.
//

import Combine

@MainActor
final class ClientShellModeState: ObservableObject {
    @Published private(set) var mode: ClientShellMode

    init(mode: ClientShellMode = .nativeFinder) {
        self.mode = mode
    }

    func select(_ mode: ClientShellMode) {
        guard self.mode != mode else {
            return
        }

        self.mode = mode
    }
}

enum ClientShellMode: String, CaseIterable, Identifiable {
    case nativeFinder = "native-finder"
    case windows98 = "windows-98"

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .nativeFinder:
            return "Native Finder"
        case .windows98:
            return "Windows 98"
        }
    }
}
