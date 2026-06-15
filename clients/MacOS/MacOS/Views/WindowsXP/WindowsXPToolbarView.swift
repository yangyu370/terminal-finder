//
//  WindowsXPToolbarView.swift
//  MacOS
//
//  Created by Claude on 2026/6/14.
//
//  Luna toolbar: navigation + refresh + dotfiles + terminal. Reads navigation
//  state straight from the shared ViewModel; the terminal toggle is delegated
//  upward so the shell owns terminal lifecycle.

import SwiftUI

struct WindowsXPToolbarView: View {
    @ObservedObject var workspaceVM: WorkspaceBrowserViewModel
    @ObservedObject var panelLayout: PseudoTerminalPanelLayoutState
    let onToggleTerminal: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button("Back") {
                workspaceVM.goBack()
            }
            .disabled(!workspaceVM.canGoBack)
            .buttonStyle(WindowsXPButtonStyle())

            Button("Forward") {
                workspaceVM.goForward()
            }
            .disabled(!workspaceVM.canGoForward)
            .buttonStyle(WindowsXPButtonStyle())

            Button("Up") {
                workspaceVM.goUp()
            }
            .disabled(!workspaceVM.canGoUp)
            .buttonStyle(WindowsXPButtonStyle())

            WindowsXPRaisedDivider(axis: .vertical)
                .frame(height: 22)

            Button("Refresh") {
                workspaceVM.refresh()
            }
            .disabled(workspaceVM.isLoading)
            .buttonStyle(WindowsXPButtonStyle())

            Button(workspaceVM.showsHiddenFiles ? "Hide Dotfiles" : "Show Dotfiles") {
                workspaceVM.toggleHiddenFiles()
            }
            .buttonStyle(WindowsXPButtonStyle())

            Spacer()

            Button(panelLayout.isOpen ? "Hide Terminal" : "Terminal") {
                onToggleTerminal()
            }
            .buttonStyle(WindowsXPButtonStyle())
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(height: 36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [WindowsXPPalette.toolbarTop, WindowsXPPalette.toolbarBottom],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(alignment: .bottom) {
            WindowsXPPalette.shadow.opacity(0.75)
                .frame(height: 1)
        }
    }
}
