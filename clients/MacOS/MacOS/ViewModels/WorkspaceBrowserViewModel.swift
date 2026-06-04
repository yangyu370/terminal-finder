//
//  WorkspaceBrowserViewModel.swift
//  MacOS
//
//  Created by Wang on 2026/6/2.
//

import Combine
import Darwin
import Foundation

@MainActor
final class WorkspaceBrowserViewModel: ObservableObject {
    @Published var path: String
    @Published private(set) var workspaceState: WorkspaceState?
    @Published private(set) var listing: DirectoryListing?
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?
    @Published private(set) var fileOpenErrorText: String?
    @Published private(set) var selectedEntryPath: String?

    private let backendClient: any BackendClientProtocol
    private let workspaceItemOpener: any WorkspaceItemOpening
    private var loadTask: Task<Void, Never>?

    let sidebarLocations: [WorkspaceSidebarLocation]

    init(
        backendClient: (any BackendClientProtocol)? = nil,
        workspaceItemOpener: (any WorkspaceItemOpening)? = nil,
        initialPath: String = WorkspaceBrowserViewModel.defaultInitialPath()
    ) {
        self.backendClient = backendClient ?? BackendClient()
        self.workspaceItemOpener = workspaceItemOpener ?? WorkspaceItemOpener()
        self.path = initialPath
        sidebarLocations = WorkspaceBrowserViewModel.defaultSidebarLocations(homePath: initialPath)
    }

    deinit {
        loadTask?.cancel()
    }

    var currentDirectoryName: String {
        let currentPath = workspaceState?.currentDirectory ?? listing?.path ?? path
        let name = URL(fileURLWithPath: currentPath).lastPathComponent
        return name.isEmpty ? currentPath : name
    }

    var entries: [DirectoryEntry] {
        listing?.entries ?? []
    }

    func loadInitialState() {
        loadTask?.cancel()
        isLoading = true
        errorText = nil

        loadTask = Task { [backendClient] in
            do {
                let state = try await backendClient.getState()
                let result = try await backendClient.listDirectory(path: state.currentDirectory)
                guard !Task.isCancelled else {
                    return
                }

                workspaceState = state
                path = state.currentDirectory
                listing = result
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }

                errorText = error.localizedDescription
            }

            guard !Task.isCancelled else {
                return
            }

            isLoading = false
        }
    }

    func openCurrentPath() {
        openDirectory(path: path)
    }

    func refresh() {
        let targetPath = workspaceState?.currentDirectory ?? path
        loadListing(path: targetPath)
    }

    func open(_ entry: DirectoryEntry) {
        if entry.isDirectory {
            openDirectory(path: entry.path)
            return
        }

        do {
            try workspaceItemOpener.openFile(atPath: entry.path)
            fileOpenErrorText = nil
        } catch {
            fileOpenErrorText = error.localizedDescription
        }
    }

    func open(_ location: WorkspaceSidebarLocation) {
        openDirectory(path: location.path)
    }

    func dismissFileOpenError() {
        fileOpenErrorText = nil
    }

    func selectEntry(path: String?) {
        guard selectedEntryPath != path else {
            return
        }

        selectedEntryPath = path
    }

    private func openDirectory(path targetPath: String) {
        let trimmedPath = targetPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            loadTask?.cancel()
            isLoading = false
            errorText = "Enter a directory path."
            return
        }

        loadTask?.cancel()
        isLoading = true
        errorText = nil

        loadTask = Task { [backendClient] in
            do {
                let result = try await backendClient.openDirectory(path: trimmedPath)
                let listingResult: DirectoryListing
                if let listing = result.listing {
                    listingResult = listing
                } else {
                    listingResult = try await backendClient.listDirectory(path: result.state.currentDirectory)
                }
                guard !Task.isCancelled else {
                    return
                }

                workspaceState = result.state
                path = result.state.currentDirectory
                listing = listingResult
                selectedEntryPath = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }

                errorText = error.localizedDescription
            }

            guard !Task.isCancelled else {
                return
            }

            isLoading = false
        }
    }

    private func loadListing(path targetPath: String) {
        loadTask?.cancel()
        isLoading = true
        errorText = nil

        loadTask = Task { [backendClient] in
            do {
                let result = try await backendClient.listDirectory(path: targetPath)
                guard !Task.isCancelled else {
                    return
                }

                path = result.path
                listing = result
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }

                errorText = error.localizedDescription
            }

            guard !Task.isCancelled else {
                return
            }

            isLoading = false
        }
    }

    private nonisolated static func defaultInitialPath() -> String {
        guard let passwordRecord = getpwuid(getuid()),
              let homeDirectory = passwordRecord.pointee.pw_dir
        else {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }

        return String(cString: homeDirectory)
    }

    private nonisolated static func defaultSidebarLocations(homePath: String) -> [WorkspaceSidebarLocation] {
        [
            WorkspaceSidebarLocation(title: "Home", systemImageName: "house", path: homePath),
            WorkspaceSidebarLocation(title: "Desktop", systemImageName: "desktopcomputer", path: "\(homePath)/Desktop"),
            WorkspaceSidebarLocation(title: "Downloads", systemImageName: "arrow.down.circle", path: "\(homePath)/Downloads"),
            WorkspaceSidebarLocation(title: "Documents", systemImageName: "doc.text", path: "\(homePath)/Documents")
        ]
    }
}

struct WorkspaceSidebarLocation: Identifiable {
    let title: String
    let systemImageName: String
    let path: String

    var id: String {
        path
    }
}
