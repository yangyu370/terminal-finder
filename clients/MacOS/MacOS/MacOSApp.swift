//
//  MacOSApp.swift
//  MacOS
//
//  Created by Wang on 2026/6/1.
//

import SwiftUI

@main
struct MacOSApp: App {
    @NSApplicationDelegateAdaptor(FinderAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
