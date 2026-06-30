//
//  TerminalSessionViewModel.swift
//  MacOS
//
//  Created by Codex on 2026/6/7.
//

import Combine
import Foundation

@MainActor
protocol TerminalRendering: AnyObject {
    func write(_ bytes: [UInt8])
    func reset()
}

enum TerminalSessionStatus: Equatable {
    case idle
    case connecting
    case active
    case resizing
    case closing
    case exited
    case error
}

enum WorkspaceTerminalSyncMode: CaseIterable, Hashable {
    case locked
    case synced

    var displayTitle: String {
        switch self {
        case .locked:
            return "锁定"
        case .synced:
            return "同步"
        }
    }
}

enum WorkspaceTerminalStatus: Equatable {
    case inactive
    case inSync
    case differentDirectory
    case syncPending
    case unsupported
    case blocked

    var displayText: String? {
        switch self {
        case .inactive:
            return nil
        case .inSync:
            return "已同步"
        case .differentDirectory:
            return "目录不同"
        case .syncPending:
            return "同步中"
        case .unsupported:
            return "不支持同步"
        case .blocked:
            return "同步受阻"
        }
    }
}

@MainActor
final class TerminalSessionViewModel: ObservableObject {
    nonisolated static let defaultColumns = 80
    nonisolated static let defaultRows = 24

    @Published private(set) var status: TerminalSessionStatus = .idle
    @Published private(set) var sessionId: String?
    @Published private(set) var cwd: String?
    @Published private(set) var connectionId: String?
    @Published private(set) var cols = TerminalSessionViewModel.defaultColumns
    @Published private(set) var rows = TerminalSessionViewModel.defaultRows
    @Published private(set) var errorText: String?
    @Published private(set) var exitCode: Int?
    @Published private(set) var exitSignal: Int?
    @Published var workspaceTerminalSyncMode: WorkspaceTerminalSyncMode = .locked
    @Published private(set) var workspaceTerminalStatus: WorkspaceTerminalStatus = .inactive
    @Published private(set) var workspaceTerminalBinding: WorkspaceTerminalBinding?
    @Published private(set) var workspaceTerminalCapability: WorkspaceTerminalSyncCapability?

    var onSessionEnded: (() -> Void)?
    var onOpenDirectoryFromTerminal: ((String) -> Void)?

    private let terminalClient: any TerminalClientProtocol
    private let requestIdGenerator: () -> String
    private weak var renderer: TerminalRendering?
    private var pendingRequests: [String: PendingTerminalRequest] = [:]
    private var pendingOutput: [[UInt8]] = []
    private var commandTask: Task<Void, Never>?
    private var inputBuffer: [UInt8] = []
    private var inputTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?

    init(
        terminalClient: (any TerminalClientProtocol)? = nil,
        requestIdGenerator: @escaping () -> String = { UUID().uuidString }
    ) {
        self.terminalClient = terminalClient ?? FFITerminalClient()
        self.requestIdGenerator = requestIdGenerator
    }

    deinit {
        commandTask?.cancel()
        inputTask?.cancel()
        resizeTask?.cancel()
        let terminalClient = terminalClient
        Task { @MainActor in
            terminalClient.disconnect()
        }
    }

    var isActive: Bool {
        status == .active || status == .resizing
    }

    func attachRenderer(_ renderer: TerminalRendering) {
        self.renderer = renderer
        flushPendingOutput()
    }

    func start(
        cwd: String,
        cols initialCols: Int = TerminalSessionViewModel.defaultColumns,
        rows initialRows: Int = TerminalSessionViewModel.defaultRows
    ) {
        guard status != .connecting,
              status != .active,
              status != .resizing,
              status != .closing
        else {
            return
        }

        resetLocalState()
        self.cwd = cwd
        cols = Self.normalizedColumns(initialCols)
        rows = Self.normalizedRows(initialRows)
        status = .connecting

        terminalClient.connect { [weak self] event in
            self?.handle(event)
        } onError: { [weak self] error in
            self?.handleTransportError(error)
        }

        let requestId = requestIdGenerator()
        pendingRequests[requestId] = .create
        commandTask = Task { [weak self] in
            await self?.sendCreate(requestId: requestId)
        }
    }

    func startConnection(
        connectionId: String,
        cols initialCols: Int = TerminalSessionViewModel.defaultColumns,
        rows initialRows: Int = TerminalSessionViewModel.defaultRows
    ) {
        guard status != .connecting,
              status != .active,
              status != .resizing,
              status != .closing
        else {
            return
        }

        resetLocalState()
        self.connectionId = connectionId
        cols = Self.normalizedColumns(initialCols)
        rows = Self.normalizedRows(initialRows)
        status = .connecting

        terminalClient.connect { [weak self] event in
            self?.handle(event)
        } onError: { [weak self] error in
            self?.handleTransportError(error)
        }

        let requestId = requestIdGenerator()
        pendingRequests[requestId] = .create
        commandTask = Task { [weak self] in
            await self?.sendCreateConnection(requestId: requestId)
        }
    }

    func startForWorkspace(
        _ workspaceState: WorkspaceState?,
        fallbackCwd: String,
        cols initialCols: Int = TerminalSessionViewModel.defaultColumns,
        rows initialRows: Int = TerminalSessionViewModel.defaultRows
    ) {
        if workspaceState?.scheme == "s3",
           let connectionId = workspaceState?.connectionId
        {
            startConnection(connectionId: connectionId, cols: initialCols, rows: initialRows)
            return
        }

        startWorkspace(cwd: fallbackCwd, cols: initialCols, rows: initialRows)
    }

    func handleHostCurrentDirectoryUpdate(_ directory: String?) {
        guard let sessionId,
              let directory,
              !directory.isEmpty
        else {
            return
        }

        commandTask = Task { [weak self, sessionId, directory] in
            guard let self else {
                return
            }
            do {
                let result = try await terminalClient.updateWorkingDirectory(
                    sessionId: sessionId,
                    directoryUrl: directory
                )
                applyWorkingDirectoryUpdate(result)
            } catch {
                handleWorkspaceTerminalError(error)
            }
        }
    }

    func finderDidOpenDirectory(_ directory: String) {
        guard let sessionId,
              workspaceTerminalCapability == .bidirectionalLocal
        else {
            return
        }

        switch workspaceTerminalSyncMode {
        case .locked:
            refreshWorkspaceTerminalComparison()
        case .synced:
            workspaceTerminalStatus = .syncPending
            commandTask = Task { [weak self, sessionId, directory] in
                guard let self else {
                    return
                }
                do {
                    let result = try await terminalClient.changeDirectory(
                        sessionId: sessionId,
                        targetDirectory: directory
                    )
                    workspaceTerminalBinding = result.binding
                    workspaceTerminalStatus = result.queued ? .syncPending : .blocked
                } catch {
                    handleWorkspaceTerminalError(error)
                }
            }
        }
    }

    func refreshWorkspaceTerminalComparison() {
        guard let sessionId,
              workspaceTerminalCapability == .bidirectionalLocal
        else {
            return
        }

        commandTask = Task { [weak self, sessionId] in
            guard let self else {
                return
            }
            do {
                let result = try await terminalClient.compareWorkingDirectory(sessionId: sessionId)
                applyWorkingDirectoryUpdate(result)
            } catch {
                handleWorkspaceTerminalError(error)
            }
        }
    }

    func sendInput(_ bytes: [UInt8]) {
        guard isActive,
              let sessionId,
              !bytes.isEmpty
        else {
            return
        }

        inputBuffer.append(contentsOf: bytes)
        guard inputTask == nil else {
            return
        }

        inputTask = Task { [weak self, sessionId] in
            guard let self else {
                return
            }

            await drainInput(sessionId: sessionId)
        }
    }

    func resize(cols newCols: Int, rows newRows: Int) {
        guard status == .connecting || status == .active || status == .resizing
        else {
            return
        }

        let normalizedCols = Self.normalizedColumns(newCols)
        let normalizedRows = Self.normalizedRows(newRows)
        guard normalizedCols != cols || normalizedRows != rows else {
            return
        }

        cols = normalizedCols
        rows = normalizedRows
        guard let sessionId else {
            return
        }

        status = .resizing
        resizeTask?.cancel()
        resizeTask = Task { [weak self, sessionId, normalizedCols, normalizedRows] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else {
                return
            }
            await self?.sendResize(
                sessionId: sessionId,
                cols: normalizedCols,
                rows: normalizedRows
            )
        }
    }

    func close() {
        guard let sessionId,
              status != .idle,
              status != .closing,
              status != .exited
        else {
            finishClosedSession()
            return
        }

        status = .closing
        let requestId = requestIdGenerator()
        pendingRequests[requestId] = .close
        commandTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                try await terminalClient.close(sessionId: sessionId, requestId: requestId)
            } catch {
                pendingRequests.removeValue(forKey: requestId)
                handleTransportError(error)
            }
        }
    }

    func disconnect() {
        terminalClient.disconnect()
        resetLocalState()
        status = .idle
    }

    private func sendCreate(requestId: String) async {
        guard let cwd else {
            return
        }

        do {
            try await terminalClient.create(
                cwd: cwd,
                cols: cols,
                rows: rows,
                requestId: requestId
            )
        } catch is CancellationError {
            pendingRequests.removeValue(forKey: requestId)
        } catch {
            pendingRequests.removeValue(forKey: requestId)
            handleTransportError(error)
        }
    }

    private func sendCreateConnection(requestId: String) async {
        guard let connectionId else {
            return
        }

        do {
            try await terminalClient.createConnection(
                connectionId: connectionId,
                cols: cols,
                rows: rows,
                requestId: requestId
            )
        } catch is CancellationError {
            pendingRequests.removeValue(forKey: requestId)
        } catch {
            pendingRequests.removeValue(forKey: requestId)
            handleTransportError(error)
        }
    }

    private func startWorkspace(
        cwd: String,
        cols initialCols: Int = TerminalSessionViewModel.defaultColumns,
        rows initialRows: Int = TerminalSessionViewModel.defaultRows
    ) {
        guard status != .connecting,
              status != .active,
              status != .resizing,
              status != .closing
        else {
            return
        }

        resetLocalState()
        self.cwd = cwd
        cols = Self.normalizedColumns(initialCols)
        rows = Self.normalizedRows(initialRows)
        status = .connecting

        terminalClient.connect { [weak self] event in
            self?.handle(event)
        } onError: { [weak self] error in
            self?.handleTransportError(error)
        }

        let requestId = requestIdGenerator()
        pendingRequests[requestId] = .create
        commandTask = Task { [weak self] in
            await self?.sendCreateWorkspace(requestId: requestId)
        }
    }

    private func sendCreateWorkspace(requestId: String) async {
        do {
            let result = try await terminalClient.createWorkspace(
                cols: cols,
                rows: rows,
                requestId: requestId
            )
            workspaceTerminalBinding = result.binding
            workspaceTerminalCapability = result.binding.syncCapability
            workspaceTerminalStatus = result.binding.syncCapability == .launchOnly ? .unsupported : .differentDirectory
        } catch is CancellationError {
            pendingRequests.removeValue(forKey: requestId)
        } catch {
            pendingRequests.removeValue(forKey: requestId)
            handleTransportError(error)
        }
    }

    private func handle(_ event: TerminalServerEvent) {
        switch event {
        case .created(let sessionId, let id, let cols, let rows):
            guard requestIsExpected(id, kind: .create) else {
                return
            }
            let desiredCols = self.cols
            let desiredRows = self.rows
            self.sessionId = sessionId
            self.cols = Self.normalizedColumns(cols)
            self.rows = Self.normalizedRows(rows)
            status = .active
            if desiredCols != self.cols || desiredRows != self.rows {
                resize(cols: desiredCols, rows: desiredRows)
            }
        case .output(let sessionId, let bytes):
            guard sessionId == self.sessionId else {
                return
            }
            if let renderer {
                renderer.write(bytes)
            } else {
                pendingOutput.append(bytes)
            }
        case .resized(let sessionId, let id, let cols, let rows):
            guard sessionId == self.sessionId,
                  requestIsExpected(id, kind: .resize)
            else {
                return
            }
            self.cols = Self.normalizedColumns(cols)
            self.rows = Self.normalizedRows(rows)
            if status == .resizing {
                status = .active
            }
        case .closed(let sessionId, let id):
            guard sessionId == self.sessionId,
                  requestIsExpected(id, kind: .close)
            else {
                return
            }
            status = .closing
        case .exit(let sessionId, let code, let signal):
            guard sessionId == self.sessionId else {
                return
            }
            exitCode = code
            exitSignal = signal
            finishClosedSession()
        case .error(let sessionId, let id, let code, let message):
            if let sessionId,
               sessionId != self.sessionId
            {
                return
            }
            if let id {
                pendingRequests.removeValue(forKey: id)
            }
            errorText = "\(code): \(message)"
            status = .error
        case .unknown:
            return
        }
    }

    private func requestIsExpected(_ id: String?, kind: PendingTerminalRequest) -> Bool {
        guard let id,
              pendingRequests[id] == kind
        else {
            return false
        }

        pendingRequests.removeValue(forKey: id)
        return true
    }

    private func handleTransportError(_ error: Error) {
        let wasClosing = status == .closing
        commandTask?.cancel()
        commandTask = nil
        terminalClient.disconnect()
        inputTask?.cancel()
        inputTask = nil
        inputBuffer.removeAll()
        resizeTask?.cancel()
        resizeTask = nil
        sessionId = nil
        pendingRequests.removeAll()
        errorText = error.localizedDescription
        status = .error
        if wasClosing {
            onSessionEnded?()
        }
    }

    private func handleWorkspaceTerminalError(_ error: Error) {
        errorText = error.localizedDescription
        workspaceTerminalStatus = .blocked
    }

    private func applyWorkingDirectoryUpdate(_ result: TerminalWorkingDirectoryUpdate) {
        workspaceTerminalBinding = result.binding
        workspaceTerminalCapability = result.binding.syncCapability

        guard result.binding.syncCapability == .bidirectionalLocal else {
            workspaceTerminalStatus = .unsupported
            return
        }
        guard result.openable else {
            workspaceTerminalStatus = .blocked
            return
        }

        if workspaceTerminalSyncMode == .synced && !result.matchesCurrent {
            workspaceTerminalStatus = .syncPending
            onOpenDirectoryFromTerminal?(result.reportedDirectory)
            return
        }

        workspaceTerminalStatus = result.matchesCurrent ? .inSync : .differentDirectory
    }

    private func finishClosedSession() {
        commandTask?.cancel()
        commandTask = nil
        terminalClient.disconnect()
        inputTask?.cancel()
        inputTask = nil
        inputBuffer.removeAll()
        resizeTask?.cancel()
        resizeTask = nil
        sessionId = nil
        pendingRequests.removeAll()
        status = .exited
        workspaceTerminalStatus = .inactive
        workspaceTerminalBinding = nil
        workspaceTerminalCapability = nil
        onSessionEnded?()
    }

    private func resetLocalState() {
        commandTask?.cancel()
        commandTask = nil
        inputTask?.cancel()
        inputTask = nil
        inputBuffer.removeAll()
        resizeTask?.cancel()
        resizeTask = nil
        pendingRequests.removeAll()
        pendingOutput.removeAll()
        renderer?.reset()
        sessionId = nil
        cwd = nil
        connectionId = nil
        cols = Self.defaultColumns
        rows = Self.defaultRows
        errorText = nil
        exitCode = nil
        exitSignal = nil
        workspaceTerminalStatus = .inactive
        workspaceTerminalBinding = nil
        workspaceTerminalCapability = nil
    }

    private nonisolated static func normalizedColumns(_ cols: Int) -> Int {
        min(max(cols, 1), Int(UInt16.max))
    }

    private nonisolated static func normalizedRows(_ rows: Int) -> Int {
        min(max(rows, 1), Int(UInt16.max))
    }

    private func drainInput(sessionId: String) async {
        while !Task.isCancelled {
            guard self.sessionId == sessionId,
                  isActive
            else {
                inputBuffer.removeAll()
                inputTask = nil
                return
            }

            let bytes = inputBuffer
            inputBuffer.removeAll(keepingCapacity: true)
            guard !bytes.isEmpty else {
                inputTask = nil
                return
            }

            do {
                try await terminalClient.sendInput(sessionId: sessionId, bytes: bytes)
            } catch {
                inputBuffer.removeAll()
                inputTask = nil
                handleTransportError(error)
                return
            }

            await Task.yield()
        }

        inputTask = nil
    }

    private func sendResize(sessionId: String, cols: Int, rows: Int) async {
        guard self.sessionId == sessionId,
              status == .active || status == .resizing
        else {
            return
        }

        let requestId = requestIdGenerator()
        pendingRequests[requestId] = .resize

        do {
            try await terminalClient.resize(
                sessionId: sessionId,
                cols: cols,
                rows: rows,
                requestId: requestId
            )
        } catch {
            pendingRequests.removeValue(forKey: requestId)
            handleTransportError(error)
        }
    }

    private func flushPendingOutput() {
        guard let renderer,
              !pendingOutput.isEmpty
        else {
            return
        }

        let bytes = pendingOutput.reduce(into: [UInt8]()) { combined, chunk in
            combined.append(contentsOf: chunk)
        }
        pendingOutput.removeAll(keepingCapacity: true)
        renderer.write(bytes)
    }
}

private enum PendingTerminalRequest: Equatable {
    case create
    case resize
    case close
}
