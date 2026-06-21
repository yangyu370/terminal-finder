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
    private let workspaceAlertPresenter: any WorkspaceAlertPresenting
    private var loadTask: Task<Void, Never>?
    private var shouldReloadInitialState = false

    let sidebarLocations: [WorkspaceSidebarLocation]

    init(
        backendClient: (any BackendClientProtocol)? = nil,
        workspaceItemOpener: (any WorkspaceItemOpening)? = nil,
        workspaceAlertPresenter: (any WorkspaceAlertPresenting)? = nil,
        initialPath: String = WorkspaceBrowserViewModel.defaultInitialPath()
    ) {
        self.backendClient = backendClient ?? FFIBackendClient()
        self.workspaceItemOpener = workspaceItemOpener ?? WorkspaceItemOpener()
        self.workspaceAlertPresenter = workspaceAlertPresenter ?? WorkspaceAlertPresenter()
        self.path = initialPath
        sidebarLocations = WorkspaceBrowserViewModel.defaultSidebarLocations(homePath: initialPath)
    }

    deinit {
        loadTask?.cancel()
    }

    var currentDirectoryName: String {
        let name = URL(fileURLWithPath: terminalCwdPath).lastPathComponent
        return name.isEmpty ? terminalCwdPath : name
    }

    var terminalCwdPath: String {
        currentDirectoryPath ?? path
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
                let result = try await backendClient.listDirectory(
                    path: state.currentDirectory,
                    connectionId: state.connectionId
                )
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

        navigate(
            to: destination,
            mode: .back(origin: origin, destination: destination),
            connection: .inherit
        )
    }

    func goForward() {
        guard let origin = currentDirectoryPath,
              let destination = forwardHistory.last
        else {
            return
        }

        navigate(
            to: destination,
            mode: .forward(origin: origin, destination: destination),
            connection: .inherit
        )
    }

    func goUp() {
        guard let destination = parentDirectoryPath else {
            return
        }

        navigate(
            to: destination,
            mode: .new(origin: currentDirectoryPath),
            connection: .inherit
        )
    }

    func open(_ entry: DirectoryEntry) {
        guard !isLoading else {
            return
        }

        if entry.isDirectory {
            navigate(
                to: entry.path,
                mode: .new(origin: currentDirectoryPath),
                connection: .inherit
            )
            return
        }

        if let connectionId = workspaceState?.connectionId {
            openRemoteFile(entry: entry, connectionId: connectionId)
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

    private func openRemoteFile(entry: DirectoryEntry, connectionId: String) {
        fileOpenErrorText = nil
        let backendClient = backendClient
        let opener = workspaceItemOpener
        Task { @MainActor in
            do {
                let cacheBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSTemporaryDirectory())
                let cacheDir = cacheBase
                    .appendingPathComponent("com.terminal-finder", isDirectory: true)
                    .appendingPathComponent("downloads", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: cacheDir,
                    withIntermediateDirectories: true
                )
                // Sanitize the basename so a malicious key like "../escape"
                // can't smuggle the download outside the cache directory.
                let fileName = URL(fileURLWithPath: entry.name).lastPathComponent
                let safeFileName = fileName.isEmpty ? UUID().uuidString : fileName
                let localURL = cacheDir.appendingPathComponent(safeFileName)
                try await backendClient.downloadFile(
                    connectionId: connectionId,
                    remotePath: entry.path,
                    localDestination: localURL.path
                )
                try opener.openFile(atPath: localURL.path)
            } catch {
                fileOpenErrorText = error.localizedDescription
            }
        }
    }

    func open(_ location: WorkspaceSidebarLocation) {
        // Local sidebar entries are always Phase-0 LocalFsProvider routes.
        // Force-clear the carry-over so a prior S3 navigation does not leak.
        navigate(
            to: location.path,
            mode: .new(origin: currentDirectoryPath),
            connection: .local
        )
    }

    /// Open the root of the given S3 connection. `""` is the bucket root in
    /// the S3 provider's relative-path convention.
    func openConnection(_ connectionId: String) {
        navigate(
            to: "",
            mode: .new(origin: currentDirectoryPath),
            connection: .connection(connectionId),
            allowEmptyPath: true
        )
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

    /// Lazily fetches the contents of a subdirectory for inline expansion in the
    /// outline view. Applies the same hidden-file filtering as the top-level list.
    func loadChildren(path: String) async throws -> [DirectoryEntry] {
        let result = try await backendClient.listDirectory(
            path: path,
            connectionId: workspaceState?.connectionId
        )
        guard !showsHiddenFiles else {
            return result.entries
        }

        return result.entries.filter { !$0.name.hasPrefix(".") }
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
            workspaceAlertPresenter.showWarning(
                message: "Enter a folder path to continue.",
                informativeText: "Terminal Finder kept your current folder open.",
                recoverySuggestion: "Type or paste a valid file or folder path, then try again."
            )
            restoreCurrentPathInput()
            return
        }

        navigate(
            to: resolvedPath,
            mode: .new(origin: currentDirectoryPath),
            connection: .local,
            openFileWhenNotDirectory: true
        )
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
        connection: ConnectionContext,
        openFileWhenNotDirectory: Bool = false,
        allowEmptyPath: Bool = false
    ) {
        guard !isLoading else {
            return
        }

        let trimmedPath = targetPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !allowEmptyPath {
            guard !trimmedPath.isEmpty else {
                workspaceAlertPresenter.showWarning(
                    message: "Enter a folder path to continue.",
                    informativeText: "Terminal Finder kept your current folder open.",
                    recoverySuggestion: "Type or paste a valid file or folder path, then try again."
                )
                restoreCurrentPathInput()
                return
            }
        }

        let resolvedConnectionId = connection.resolve(carryOver: workspaceState?.connectionId)

        isLoading = true
        errorText = nil

        loadTask = Task { [backendClient, workspaceItemOpener, workspaceAlertPresenter] in
            do {
                let result = try await backendClient.openDirectory(
                    path: trimmedPath,
                    connectionId: resolvedConnectionId
                )
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
                        listing = try await backendClient.listDirectory(
                            path: result.state.currentDirectory,
                            connectionId: result.state.connectionId
                        )
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

                workspaceAlertPresenter.showWarning(
                    message: "The folder can’t be opened.",
                    informativeText: "Terminal Finder kept your current folder open and refreshed it.",
                    detailText: error.localizedDescription,
                    recoverySuggestion: "Check the path, permissions, or whether the folder still exists."
                )
                await refreshCurrentDirectoryAfterNavigationFailure(using: backendClient)
            }

            guard !Task.isCancelled else {
                return
            }

            finishLoading()
        }
    }

    private func refreshCurrentDirectoryAfterNavigationFailure(
        using backendClient: any BackendClientProtocol
    ) async {
        guard let currentDirectoryPath else {
            return
        }

        do {
            let refreshedListing = try await backendClient.listDirectory(
                path: currentDirectoryPath,
                connectionId: workspaceState?.connectionId
            )
            guard !Task.isCancelled else {
                return
            }

            path = currentDirectoryPath
            listing = refreshedListing

            if let selectedEntryPath,
               !refreshedListing.entries.contains(where: { $0.path == selectedEntryPath }) {
                self.selectedEntryPath = nil
            }
        } catch {
            guard !Task.isCancelled else {
                return
            }

            restoreCurrentPathInput()
            workspaceAlertPresenter.showWarning(
                message: "The folder couldn’t be refreshed.",
                informativeText: "The current location is unchanged, but Terminal Finder couldn’t reload its contents.",
                detailText: error.localizedDescription,
                recoverySuggestion: "Try refreshing again or choose another folder from the sidebar."
            )
        }
    }

    private func restoreCurrentPathInput() {
        if let currentDirectoryPath {
            path = currentDirectoryPath
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

        let resolvedConnectionId = workspaceState?.connectionId

        isLoading = true
        errorText = nil

        loadTask = Task { [backendClient] in
            do {
                let result = try await backendClient.listDirectory(
                    path: targetPath,
                    connectionId: resolvedConnectionId
                )
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

/// How a navigation call should resolve its `connection_id`.
///
/// - `inherit`: carry over the currently-open workspace's connection id (so
///   drilling into a subfolder of an S3 bucket stays inside that bucket).
/// - `local`: explicitly switch back to the Phase-0 LocalFsProvider, dropping
///   any stale carry-over (sidebar Home/Desktop/path-input, etc).
/// - `connection(id)`: open a specific registered connection by id.
enum ConnectionContext {
    case inherit
    case local
    case connection(String)

    func resolve(carryOver: String?) -> String? {
        switch self {
        case .inherit: return carryOver
        case .local: return nil
        case .connection(let id): return id
        }
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
