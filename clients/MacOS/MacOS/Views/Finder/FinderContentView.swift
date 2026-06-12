//
//  FinderContentView.swift
//  MacOS
//
//  Created by Codex on 2026/6/11.
//

import Combine
import SwiftUI

@MainActor
final class FinderContentViewState: ObservableObject {
    @Published var isGoToFolderSheetPresented = false
}

struct FinderContentView: View {
    @ObservedObject var workspaceVM: WorkspaceBrowserViewModel
    @ObservedObject var terminalVM: TerminalSessionViewModel
    @ObservedObject var panelLayout: PseudoTerminalPanelLayoutState
    @ObservedObject var contentState: FinderContentViewState
    @ObservedObject var displayModeState: FinderDisplayModeState

    let onCloseTerminal: () -> Void

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                browserArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if panelLayout.isOpen {
                    FinderTerminalResizeHandle { verticalDrag in
                        panelLayout.resize(
                            byVerticalDrag: verticalDrag,
                            availableContentHeight: geometry.size.height
                        )
                    }

                    FinderTerminalPanelView(
                        terminalVM: terminalVM,
                        onClose: onCloseTerminal,
                        onViewportChanged: { size in
                            panelLayout.noteViewportSize(size)
                        }
                    )
                    .frame(
                        maxWidth: .infinity,
                        minHeight: panelLayout.height,
                        idealHeight: panelLayout.height,
                        maxHeight: panelLayout.height
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.16), value: panelLayout.isOpen)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .alert(
            "Unable to Open File",
            isPresented: Binding(
                get: { workspaceVM.fileOpenErrorText != nil },
                set: { isPresented in
                    if !isPresented {
                        workspaceVM.dismissFileOpenError()
                    }
                }
            )
        ) {
            Button("OK") {
                workspaceVM.dismissFileOpenError()
            }
        } message: {
            Text(workspaceVM.fileOpenErrorText ?? "macOS could not open this file.")
        }
        .sheet(isPresented: $contentState.isGoToFolderSheetPresented) {
            FinderGoToFolderSheet(initialPath: workspaceVM.path) { path in
                workspaceVM.updatePathInput(path)
                workspaceVM.openCurrentPath()
                contentState.isGoToFolderSheetPresented = false
            } onCancel: {
                contentState.isGoToFolderSheetPresented = false
            }
        }
    }

    private var browserArea: some View {
        ZStack {
            activeBrowserView

            if workspaceVM.isLoading {
                FinderLoadingOverlay()
            } else if let errorText = workspaceVM.errorText, workspaceVM.entries.isEmpty {
                FinderMessageOverlay(
                    systemImageName: "exclamationmark.triangle",
                    title: "无法载入文件夹",
                    message: errorText
                )
            } else if workspaceVM.entries.isEmpty {
                FinderMessageOverlay(
                    systemImageName: "folder",
                    title: "没有项目",
                    message: workspaceVM.path
                )
            }
        }
    }

    @ViewBuilder
    private var activeBrowserView: some View {
        switch displayModeState.mode {
        case .icon:
            FinderIconGridView(
                entries: workspaceVM.entries,
                selectedPath: workspaceVM.selectedEntryPath,
                onSelect: { path in
                    workspaceVM.selectEntry(path: path)
                },
                onOpen: { entry in
                    workspaceVM.open(entry)
                }
            )

        case .list, .column, .gallery:
            FinderListView(
                entries: workspaceVM.entries,
                selectedPath: workspaceVM.selectedEntryPath,
                isLoading: workspaceVM.isLoading,
                onSelect: { path in
                    workspaceVM.selectEntry(path: path)
                },
                onOpen: { entry in
                    workspaceVM.open(entry)
                },
                loadChildren: { path in
                    try await workspaceVM.loadChildren(path: path)
                }
            )
        }
    }
}

private struct FinderLoadingOverlay: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct FinderMessageOverlay: View {
    let systemImageName: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImageName)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.tertiary)

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(22)
    }
}

private struct FinderGoToFolderSheet: View {
    @State private var path: String

    let onOpen: (String) -> Void
    let onCancel: () -> Void

    init(
        initialPath: String,
        onOpen: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _path = State(initialValue: initialPath)
        self.onOpen = onOpen
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("前往文件夹")
                .font(.system(size: 17, weight: .semibold))

            TextField("输入路径", text: $path)
                .textFieldStyle(.roundedBorder)
                .frame(width: 440)
                .onSubmit {
                    onOpen(path)
                }

            HStack {
                Spacer()

                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button("前往") {
                    onOpen(path)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 488)
    }
}
