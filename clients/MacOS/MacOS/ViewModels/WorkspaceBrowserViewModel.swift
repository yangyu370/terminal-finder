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
    private let transferActivityVM: TransferActivityViewModel?
    private let openedDirectorySubject = PassthroughSubject<String, Never>()
    private var loadTask: Task<Void, Never>?
    private var shouldReloadInitialState = false

    let sidebarLocations: [WorkspaceSidebarLocation]

    init(
        backendClient: (any BackendClientProtocol)? = nil,
        workspaceItemOpener: (any WorkspaceItemOpening)? = nil,
        workspaceAlertPresenter: (any WorkspaceAlertPresenting)? = nil,
        transferActivityVM: TransferActivityViewModel? = nil,
        initialPath: String = WorkspaceBrowserViewModel.defaultInitialPath()
    ) {
        self.backendClient = backendClient ?? FFIBackendClient()
        self.workspaceItemOpener = workspaceItemOpener ?? WorkspaceItemOpener()
        self.workspaceAlertPresenter = workspaceAlertPresenter ?? WorkspaceAlertPresenter()
        self.transferActivityVM = transferActivityVM
        self.path = initialPath
        sidebarLocations = WorkspaceBrowserViewModel.defaultSidebarLocations(homePath: initialPath)
    }

    var currentConnectionId: String? {
        workspaceState?.connectionId
    }

    var openedDirectoryPublisher: AnyPublisher<String, Never> {
        openedDirectorySubject.eraseToAnyPublisher()
    }

    var selectedEntryForActions: DirectoryEntry? {
        selectedEntry
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

    func openTerminalDirectory(_ directory: String) {
        navigate(
            to: directory,
            mode: .new(origin: currentDirectoryPath),
            connection: .local
        )
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

        // S3 connection 的 root path 是空字符串，已被记进 history；navigate
        // 默认 `allowEmptyPath: false`（防用户空输入），这里要显式放行——
        // history 里的 path 都是之前 navigate 成功落地的，必然合法。
        navigate(
            to: destination,
            mode: .back(origin: origin, destination: destination),
            connection: .inherit,
            allowEmptyPath: true
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
            connection: .inherit,
            allowEmptyPath: true
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

    /// Upload `localSource` into `remotePath` of the current workspace's
    /// connection (or local FS if no connection). Refreshes the listing
    /// on success so the new entry surfaces immediately.
    func uploadFile(localSource: String, remotePath: String) async {
        let activityId = "upload|\(remotePath)"
        let title = (localSource as NSString).lastPathComponent
        transferActivityVM?.start(id: activityId, title: "上传 \(title)", kind: .upload)
        defer { transferActivityVM?.finish(id: activityId) }
        do {
            try await backendClient.uploadFile(
                connectionId: workspaceState?.connectionId,
                remotePath: remotePath,
                localSource: localSource
            )
            refresh()
        } catch {
            reportWriteOpFailure(operation: "上传文件", target: title, error: error)
        }
    }

    /// Delete a single entry (file/object). For local directories the core
    /// recursively removes; for S3 only the named key is dropped.
    func deleteEntry(path entryPath: String) async {
        let activityId = "delete|\(entryPath)"
        let title = (entryPath as NSString).lastPathComponent
        transferActivityVM?.start(id: activityId, title: "删除 \(title)", kind: .delete)
        defer { transferActivityVM?.finish(id: activityId) }
        do {
            try await backendClient.deleteEntry(
                connectionId: workspaceState?.connectionId,
                path: entryPath
            )
            refresh()
        } catch {
            reportWriteOpFailure(operation: "删除", target: title, error: error)
        }
    }

    /// Create a directory at `path`. On S3 this writes a zero-byte marker —
    /// callers should already have surfaced the non-native-directory warning
    /// via `ConnectionViewModel.capabilities`.
    func createDirectory(path directoryPath: String) async {
        let activityId = "mkdir|\(directoryPath)"
        let title = (directoryPath as NSString).lastPathComponent
        transferActivityVM?.start(id: activityId, title: "新建文件夹 \(title)", kind: .createDirectory)
        defer { transferActivityVM?.finish(id: activityId) }
        do {
            try await backendClient.createRemoteDirectory(
                connectionId: workspaceState?.connectionId,
                path: directoryPath
            )
            refresh()
        } catch {
            reportWriteOpFailure(operation: "新建文件夹", target: title, error: error)
        }
    }

    /// Rename / move `from` → `to` within the current workspace's connection.
    /// On S3 this is a non-atomic copy + delete; callers should surface the
    /// warning from `ConnectionViewModel.capabilities` before calling.
    func renameEntry(from: String, to: String) async {
        let activityId = "rename|\(from)"
        let title = (from as NSString).lastPathComponent
        transferActivityVM?.start(id: activityId, title: "重命名 \(title)", kind: .rename)
        defer { transferActivityVM?.finish(id: activityId) }
        do {
            try await backendClient.renameEntry(
                connectionId: workspaceState?.connectionId,
                from: from,
                to: to
            )
            refresh()
        } catch {
            reportWriteOpFailure(operation: "重命名", target: title, error: error)
        }
    }

    /// Download `entry` to a caller-chosen local URL (Save Panel flow).
    /// Distinct from `openRemoteFile` which downloads to a sandboxed cache
    /// and then asks NSWorkspace to open it.
    func downloadEntry(_ entry: DirectoryEntry, to localURL: URL) async {
        let activityId = "download|\(entry.path)"
        transferActivityVM?.start(id: activityId, title: "下载 \(entry.name)", kind: .download)
        defer { transferActivityVM?.finish(id: activityId) }
        do {
            try await backendClient.downloadFile(
                connectionId: workspaceState?.connectionId,
                remotePath: entry.path,
                localDestination: localURL.path
            )
        } catch {
            reportWriteOpFailure(operation: "下载", target: entry.name, error: error)
        }
    }

    /// Surface a write-op failure via both `errorText` (for empty-folder
    /// overlay) and a user-facing alert. The bare `errorText` path was
    /// invisible whenever the directory had other entries — the alert
    /// guarantees the user sees the failure regardless of UI state.
    private func reportWriteOpFailure(operation: String, target: String, error: Error) {
        let detail = error.localizedDescription
        errorText = detail
        workspaceAlertPresenter.showWarning(
            message: "\(operation)失败",
            informativeText: "无法\(operation) \(target)。",
            detailText: detail,
            recoverySuggestion: "检查路径、权限或网络连接后重试。"
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
            var openedDirectory: String?
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
                openedDirectory = result.state.currentDirectory
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

            if let openedDirectory {
                openedDirectorySubject.send(openedDirectory)
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
