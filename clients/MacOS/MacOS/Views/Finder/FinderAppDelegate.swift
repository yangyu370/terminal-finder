//
//  FinderAppDelegate.swift
//  MacOS
//
//  Created by Claude on 2026/6/11.
//

import AppKit

/// Application delegate for the Finder-style main window lifecycle.
/// Owns the single `FinderWindowController` and installs the main menu.
final class FinderAppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: FinderWindowController?
    private let shutdownWorkspace: @Sendable () async -> Void

    override convenience init() {
        self.init(shutdownWorkspace: Self.shutdownCoreWorkspace)
    }

    init(shutdownWorkspace: @escaping @Sendable () async -> Void) {
        self.shutdownWorkspace = shutdownWorkspace
        super.init()
    }

    private static func shutdownCoreWorkspace() async {
        try? await CoreFFI.handle.shutdownWorkspace()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = FinderWindowController()
        windowController = controller
        controller.showWindow(nil)

        let mainMenu = FinderMainMenuBuilder.buildMainMenu(for: controller)
        NSApp.mainMenu = mainMenu
        // The SwiftUI App lifecycle installs its own menu around launch time;
        // reassert ours on the next runloop turn so it wins deterministically.
        DispatchQueue.main.async {
            NSApp.mainMenu = mainMenu
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        let shutdownWorkspace = shutdownWorkspace
        let group = DispatchGroup()
        group.enter()
        Task.detached {
            await shutdownWorkspace()
            group.leave()
        }
        _ = group.wait(timeout: .now() + 3)
    }
}
