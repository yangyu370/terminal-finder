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
    @Published private(set) var listing: DirectoryListing?
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?

    private let backendClient: any BackendClientProtocol
    private var loadTask: Task<Void, Never>?

    init(
        backendClient: (any BackendClientProtocol)? = nil,
        initialPath: String = WorkspaceBrowserViewModel.defaultInitialPath()
    ) {
        self.backendClient = backendClient ?? BackendClient()
        self.path = initialPath
    }

    deinit {
        loadTask?.cancel()
    }

    func loadCurrentPath() {
        load(path: path)
    }

    func open(_ entry: DirectoryEntry) {
        guard entry.isDirectory else {
            return
        }

        load(path: entry.path)
    }

    private func load(path targetPath: String) {
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
                let result = try await backendClient.listDirectory(path: trimmedPath)
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
}
