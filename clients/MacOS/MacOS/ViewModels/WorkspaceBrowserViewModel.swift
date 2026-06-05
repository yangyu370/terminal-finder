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
    @Published private(set) var path: String
    @Published private(set) var workspaceState: WorkspaceState?
    @Published private(set) var listing: DirectoryListing?
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?
    @Published private(set) var fileOpenErrorText: String?
    @Published private(set) var selectedEntryPath: String?
    @Published private(set) var showsHiddenFiles = false
    @Published private var backHistory: [String] = []
    @Published private var forwardHistory: [String] = []

    private let backendClient: any BackendClientProtocol
    private let workspaceItemOpener: any WorkspaceItemOpening
    private var loadTask: Task<Void, Never>?
    private var shouldReloadInitialState = false

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
        let allEntries = listing?.entries ?? []
        guard !showsHiddenFiles else {
            return allEntries
        }

        return allEntries.filter { !$0.name.hasPrefix(".") }
    }

    var canGoBack: Bool {
        !isLoading && !backHistory.isEmpty
    }

    var canGoForward: Bool {
        !isLoading && !forwardHistory.isEmpty
    }

    var canGoUp: Bool {
        !isLoading && parentDirectoryPath != nil
    }

    var canOpen: Bool {
        !isLoading && (selectedEntry != nil || !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func loadInitialState() {
        guard !isLoading else {
            shouldReloadInitialState = true
            return
        }

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
                selectedEntryPath = nil
                backHistory.removeAll()
                forwardHistory.removeAll()
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

            finishLoading()
        }
    }

    func openCurrentPath() {
        openPath(path)
    }

    func openSelectedItemOrCurrentPath() {
        if let selectedEntry {
            open(selectedEntry)
            return
        }

        openCurrentPath()
    }

    func updatePathInput(_ value: String) {
        path = value
        selectedEntryPath = nil
    }

    func refresh() {
        guard !isLoading else {
            return
        }

        let targetPath = workspaceState?.currentDirectory ?? path
        loadListing(path: targetPath)
    }

    func toggleHiddenFiles() {
        let selectedEntryIsHidden = listing?.entries.first {
            $0.path == selectedEntryPath
        }?.name.hasPrefix(".") == true

        showsHiddenFiles.toggle()

        if !showsHiddenFiles, selectedEntryIsHidden {
            selectedEntryPath = nil
        }
    }

    func goBack() {
        guard let origin = currentDirectoryPath,
              let destination = backHistory.last
        else {
            return
        }

        navigate(to: destination, mode: .back(origin: origin, destination: destination))
    }

    func goForward() {
        guard let origin = currentDirectoryPath,
              let destination = forwardHistory.last
        else {
            return
        }

        navigate(to: destination, mode: .forward(origin: origin, destination: destination))
    }

    func goUp() {
        guard let destination = parentDirectoryPath else {
            return
        }

        navigate(to: destination, mode: .new(origin: currentDirectoryPath))
    }

    func open(_ entry: DirectoryEntry) {
        guard !isLoading else {
            return
        }

        if entry.isDirectory {
            navigate(to: entry.path, mode: .new(origin: currentDirectoryPath))
            return
        }

        errorText = nil
        do {
            try workspaceItemOpener.openFile(atPath: entry.path)
            fileOpenErrorText = nil
        } catch {
            fileOpenErrorText = error.localizedDescription
        }
    }

    func open(_ location: WorkspaceSidebarLocation) {
        navigate(to: location.path, mode: .new(origin: currentDirectoryPath))
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

    private var currentDirectoryPath: String? {
        workspaceState?.currentDirectory ?? listing?.path
    }

    private var selectedEntry: DirectoryEntry? {
        guard let selectedEntryPath else {
            return nil
        }

        return entries.first { $0.path == selectedEntryPath }
    }

    private var parentDirectoryPath: String? {
        guard let currentDirectoryPath else {
            return nil
        }

        let currentURL = URL(fileURLWithPath: currentDirectoryPath).standardizedFileURL
        let parentURL = currentURL.deletingLastPathComponent().standardizedFileURL
        guard parentURL.path != currentURL.path else {
            return nil
        }

        return parentURL.path
    }

    private func openPath(_ targetPath: String) {
        let resolvedPath = resolvedInputPath(targetPath)
        guard !resolvedPath.isEmpty else {
            errorText = "Enter a file or directory path."
            return
        }

        navigate(to: resolvedPath, mode: .new(origin: currentDirectoryPath), openFileWhenNotDirectory: true)
    }

    private func resolvedInputPath(_ input: String) -> String {
        let trimmedPath = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return ""
        }

        let expandedPath = NSString(string: trimmedPath).expandingTildeInPath
        guard !expandedPath.hasPrefix("/") else {
            return URL(fileURLWithPath: expandedPath).standardizedFileURL.path
        }

        let basePath = currentDirectoryPath ?? path
        return URL(fileURLWithPath: basePath)
            .appendingPathComponent(expandedPath)
            .standardizedFileURL
            .path
    }

    private func navigate(
        to targetPath: String,
        mode: NavigationMode,
        openFileWhenNotDirectory: Bool = false
    ) {
        guard !isLoading else {
            return
        }

        let trimmedPath = targetPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            errorText = "Enter a file or directory path."
            return
        }

        isLoading = true
        errorText = nil

        loadTask = Task { [backendClient, workspaceItemOpener] in
            do {
                let result = try await backendClient.openDirectory(path: trimmedPath)
                guard !Task.isCancelled else {
                    return
                }

                workspaceState = result.state
                path = result.state.currentDirectory
                selectedEntryPath = nil
                updateHistory(openedPath: result.state.currentDirectory, mode: mode)

                if let resultListing = result.listing {
                    listing = resultListing
                } else {
                    listing = nil
                    do {
                        listing = try await backendClient.listDirectory(path: result.state.currentDirectory)
                    } catch {
                        errorText = error.localizedDescription
                    }
                }
            } catch is CancellationError {
                return
            } catch let backendError as BackendClientError
                where openFileWhenNotDirectory && backendError.rpcCode == "not_directory" {
                do {
                    try workspaceItemOpener.openFile(atPath: trimmedPath)
                    fileOpenErrorText = nil
                } catch {
                    fileOpenErrorText = error.localizedDescription
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }

                errorText = error.localizedDescription
            }

            guard !Task.isCancelled else {
                return
            }

            finishLoading()
        }
    }

    private func updateHistory(openedPath: String, mode: NavigationMode) {
        switch mode {
        case .new(let origin):
            guard let origin, origin != openedPath else {
                return
            }

            backHistory.append(origin)
            forwardHistory.removeAll()

        case .back(let origin, let destination):
            guard backHistory.last == destination else {
                return
            }

            backHistory.removeLast()
            if origin != openedPath {
                forwardHistory.append(origin)
            }

        case .forward(let origin, let destination):
            guard forwardHistory.last == destination else {
                return
            }

            forwardHistory.removeLast()
            if origin != openedPath {
                backHistory.append(origin)
            }
        }
    }

    private func loadListing(path targetPath: String) {
        guard !isLoading else {
            return
        }

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

            finishLoading()
        }
    }

    private func finishLoading() {
        isLoading = false
        guard shouldReloadInitialState else {
            return
        }

        shouldReloadInitialState = false
        loadInitialState()
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

private enum NavigationMode {
    case new(origin: String?)
    case back(origin: String, destination: String)
    case forward(origin: String, destination: String)
}

struct WorkspaceSidebarLocation: Identifiable {
    let title: String
    let systemImageName: String
    let path: String

    var id: String {
        path
    }
}
