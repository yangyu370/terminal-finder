//
//  ClientShellMode.swift
//  MacOS
//
//  Created by Codex on 2026/6/14.
//

import AppKit
import Combine
import Foundation
import SwiftUI

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
    static let initialModeArgumentName = "--terminal-finder-shell"
    static let initialModeDefaultsKey = "TerminalFinderInitialShellMode"

    case nativeFinder = "native-finder"
    case windows98 = "windows-98"
    case windowsXP = "windows-xp"

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .nativeFinder:
            return "Native Finder"
        case .windows98:
            return "Windows 98"
        case .windowsXP:
            return "Windows XP"
        }
    }

    static func initialMode(
        arguments: [String] = CommandLine.arguments,
        defaults: UserDefaults = .standard
    ) -> ClientShellMode {
        if let mode = initialMode(from: arguments) {
            return mode
        }

        if let rawValue = defaults.string(forKey: initialModeDefaultsKey),
           let mode = ClientShellMode(rawValue: rawValue) {
            return mode
        }

        return .nativeFinder
    }

    private static func initialMode(from arguments: [String]) -> ClientShellMode? {
        for (index, argument) in arguments.enumerated() {
            if argument == initialModeArgumentName,
               arguments.indices.contains(index + 1),
               let mode = ClientShellMode(rawValue: arguments[index + 1]) {
                return mode
            }

            let prefix = "\(initialModeArgumentName)="
            if argument.hasPrefix(prefix) {
                let rawValue = String(argument.dropFirst(prefix.count))
                if let mode = ClientShellMode(rawValue: rawValue) {
                    return mode
                }
            }
        }

        return nil
    }
}

@MainActor
enum ClientShellModeMenuPresenter {
    static func popUp(
        currentMode: ClientShellMode,
        anchoredTo anchorView: NSView?,
        onSelect: @escaping (ClientShellMode) -> Void
    ) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for mode in ClientShellMode.allCases {
            let item = ClientShellModeMenuItem(mode: mode, currentMode: currentMode) {
                guard mode != currentMode else {
                    return
                }

                onSelect(mode)
            }
            menu.addItem(item)
        }

        if let anchorView {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: anchorView)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }
}

struct ClientShellModeMenuAnchorView: NSViewRepresentable {
    @Binding var view: NSView?

    func makeNSView(context: Context) -> NSView {
        let nsView = NSView()
        DispatchQueue.main.async {
            view = nsView
        }
        return nsView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard view !== nsView else {
            return
        }

        DispatchQueue.main.async {
            view = nsView
        }
    }
}

private final class ClientShellModeMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(mode: ClientShellMode, currentMode: ClientShellMode, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: mode.displayName, action: #selector(performSelection), keyEquivalent: "")
        target = self
        state = mode == currentMode ? .on : .off
        isEnabled = true
        representedObject = mode.rawValue
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func performSelection() {
        handler()
    }
}
