//
//  CoreFFIClients.swift
//  MacOS
//
//  进程内 Rust core 的客户端实现：替代 HTTP /rpc、WebSocket /events 与 /terminal。
//  协议（BackendClientProtocol / EventClientProtocol / TerminalClientProtocol）保持不变，
//  ViewModel 无感切换。
//

import Foundation

/// 全 App 共享的 Rust core 句柄。core 是状态容器（workspace state、terminal registry），
/// 必须单例共享，与旧架构「单个 backend 进程」语义一致。
nonisolated enum CoreFFI {
    static let handle = CoreHandle()
}

// MARK: - Backend RPC

/// `BackendClientProtocol` 的进程内实现。错误统一映射为 `BackendClientError.rpcError`，
/// 保持 ViewModel 现有错误处理路径（如 `rpcCode`）不变。
nonisolated struct FFIBackendClient: BackendClientProtocol {
    private let core: CoreHandle

    init(core: CoreHandle = CoreFFI.handle) {
        self.core = core
    }

    /// 进程内没有「连接」可探活：库可调用即健康，等价于 ping。
    func health() async throws -> PingResult {
        pingResult()
    }

    func ping() async throws -> PingResult {
        pingResult()
    }

    func getState() async throws -> WorkspaceState {
        WorkspaceState(from: core.workspaceState())
    }

    func openDirectory(path: String, connectionId: String?) async throws -> OpenDirectoryResult {
        do {
            let result = try await core.openDirectory(path: path, connectionId: connectionId)
            return OpenDirectoryResult(
                state: WorkspaceState(from: result.state),
                listing: DirectoryListing(from: result.listing)
            )
        } catch {
            throw Self.mapError(error)
        }
    }

    func listDirectory(path: String, connectionId: String?) async throws -> DirectoryListing {
        do {
            return DirectoryListing(
                from: try await core.listDirectory(path: path, connectionId: connectionId)
            )
        } catch {
            throw Self.mapError(error)
        }
    }

    func downloadFile(
        connectionId: String?,
        remotePath: String,
        localDestination: String
    ) async throws {
        do {
            try await core.downloadFile(
                connectionId: connectionId,
                remotePath: remotePath,
                localDestination: localDestination
            )
        } catch {
            throw Self.mapError(error)
        }
    }

    func uploadFile(
        connectionId: String?,
        remotePath: String,
        localSource: String
    ) async throws {
        do {
            try await core.uploadFile(
                connectionId: connectionId,
                remotePath: remotePath,
                localSource: localSource
            )
        } catch {
            throw Self.mapError(error)
        }
    }

    func deleteEntry(connectionId: String?, path: String) async throws {
        do {
            try await core.deleteEntry(connectionId: connectionId, path: path)
        } catch {
            throw Self.mapError(error)
        }
    }

    func createRemoteDirectory(connectionId: String?, path: String) async throws {
        do {
            try await core.createRemoteDirectory(connectionId: connectionId, path: path)
        } catch {
            throw Self.mapError(error)
        }
    }

    func renameEntry(connectionId: String?, from: String, to: String) async throws {
        do {
            try await core.renameEntry(connectionId: connectionId, from: from, to: to)
        } catch {
            throw Self.mapError(error)
        }
    }

    func connectionCapabilities(connectionId: String) throws -> ProviderCapsDto {
        do {
            return try core.connectionCapabilities(connectionId: connectionId)
        } catch {
            throw Self.mapError(error)
        }
    }

    private func pingResult() -> PingResult {
        let info = core.ping()
        return PingResult(service: info.service, version: info.version)
    }

    static func mapError(_ error: Error) -> Error {
        if case let CoreError.Rpc(code, message) = error {
            return BackendClientError.rpcError(code: code, message: message)
        }
        return error
    }
}

private extension WorkspaceState {
    init(from dto: WorkspaceStateDto) {
        self.init(
            currentDirectory: dto.currentDirectory,
            workspaceRoot: dto.workspaceRoot,
            scheme: dto.scheme,
            connectionId: dto.connectionId
        )
    }
}

private extension DirectoryListing {
    init(from dto: DirectoryListingDto) {
        self.init(path: dto.path, entries: dto.entries.map(DirectoryEntry.init(from:)))
    }
}

private extension DirectoryEntry {
    init(from dto: DirectoryEntryDto) {
        self.init(
            name: dto.name,
            path: dto.path,
            kind: EntryKind(from: dto.kind),
            isDirectory: dto.isDirectory,
            size: dto.size,
            modifiedAt: dto.modifiedAt
        )
    }
}

private extension EntryKind {
    init(from dto: EntryKindDto) {
        switch dto {
        case .directory: self = .directory
        case .file: self = .file
        case .symlink: self = .symlink
        case .other: self = .other
        }
    }
}

// MARK: - Connection registry

/// `CoreCapabilitiesClientProtocol` 的进程内实现：转调 `connectionCapabilities`，
/// 把 `CoreError.Rpc` 透传为 `BackendClientError.rpcError`，与其余 client 一致。
nonisolated struct FFICapabilitiesClient: CoreCapabilitiesClientProtocol {
    private let core: CoreHandle

    init(core: CoreHandle = CoreFFI.handle) {
        self.core = core
    }

    func connectionCapabilities(connectionId: String) throws -> ProviderCapsDto {
        do {
            return try core.connectionCapabilities(connectionId: connectionId)
        } catch {
            throw FFIBackendClient.mapError(error)
        }
    }
}

/// `CoreConnectionClientProtocol` 的进程内实现。直接转调 `CoreHandle` 上的
/// `connectionCreate / connectionList / connectionRemove`，并把 uniffi 的
/// `CoreError.Rpc` 翻译成 `BackendClientError.rpcError`，与其它客户端保持一致。
nonisolated struct FFIConnectionClient: CoreConnectionClientProtocol {
    private let core: CoreHandle

    init(core: CoreHandle = CoreFFI.handle) {
        self.core = core
    }

    func create(
        displayName: String,
        endpoint: String,
        region: String,
        bucket: String,
        basePrefix: String,
        pathStyle: Bool,
        accessKeyId: String,
        secretAccessKey: String
    ) async throws -> String {
        core.connectionCreate(
            displayName: displayName,
            endpoint: endpoint,
            region: region,
            bucket: bucket,
            basePrefix: basePrefix,
            pathStyle: pathStyle,
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey
        )
    }

    func restore(
        connectionId: String,
        displayName: String,
        endpoint: String,
        region: String,
        bucket: String,
        basePrefix: String,
        pathStyle: Bool,
        accessKeyId: String,
        secretAccessKey: String
    ) async throws {
        do {
            try core.connectionRestore(
                connectionId: connectionId,
                displayName: displayName,
                endpoint: endpoint,
                region: region,
                bucket: bucket,
                basePrefix: basePrefix,
                pathStyle: pathStyle,
                accessKeyId: accessKeyId,
                secretAccessKey: secretAccessKey
            )
        } catch {
            throw FFIBackendClient.mapError(error)
        }
    }

    func list() async throws -> [CoreConnectionSummary] {
        core.connectionList().map { dto in
            CoreConnectionSummary(
                connectionId: dto.connectionId,
                displayName: dto.displayName,
                endpoint: dto.endpoint,
                bucket: dto.bucket,
                basePrefix: dto.basePrefix
            )
        }
    }

    func remove(connectionId: String) async throws {
        do {
            try await core.connectionRemove(connectionId: connectionId)
        } catch {
            throw FFIBackendClient.mapError(error)
        }
    }
}

// MARK: - Event channel

/// `EventClientProtocol` 的进程内实现。库随进程存活，「连接」恒成立：
/// 连接即上报 ready，并按固定间隔合成 heartbeat 维持 ViewModel 现有 watchdog 逻辑。
@MainActor
final class FFIEventClient: EventClientProtocol {
    private let core: CoreHandle
    private let heartbeatIntervalNanoseconds: UInt64
    private var heartbeatTask: Task<Void, Never>?

    init(
        core: CoreHandle = CoreFFI.handle,
        heartbeatIntervalNanoseconds: UInt64 = 5_000_000_000
    ) {
        self.core = core
        self.heartbeatIntervalNanoseconds = heartbeatIntervalNanoseconds
    }

    deinit {
        heartbeatTask?.cancel()
    }

    func connect(
        onEvent: @escaping @MainActor (BackendEvent) -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        disconnect()
        let info = core.ping()
        onEvent(.backendReady(service: info.service, version: info.version))

        let interval = heartbeatIntervalNanoseconds
        heartbeatTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                onEvent(.heartbeat)
            }
        }
    }

    func disconnect() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }
}

// MARK: - Terminal channel

/// `TerminalClientProtocol` 的进程内实现：`create` 直接拿到 sessionId 并合成
/// `.created` 应答；输出/退出经 `TerminalEventListener` 回调送达并切回主线程。
@MainActor
final class FFITerminalClient: TerminalClientProtocol {
    private let core: CoreHandle
    private var onEvent: (@MainActor (TerminalServerEvent) -> Void)?
    private var onError: (@MainActor (Error) -> Void)?
    private var activeSessionIds: Set<String> = []

    init(core: CoreHandle = CoreFFI.handle) {
        self.core = core
    }

    func connect(
        onEvent: @escaping @MainActor (TerminalServerEvent) -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        self.onEvent = onEvent
        self.onError = onError
    }

    /// 镜像 WebSocket 断开语义：连接拥有的 session 一并关闭。
    func disconnect() {
        let sessions = activeSessionIds
        activeSessionIds.removeAll()
        for sessionId in sessions {
            try? core.closeTerminal(sessionId: sessionId)
        }
        onEvent = nil
        onError = nil
    }

    func create(cwd: String, cols: Int, rows: Int, requestId: String) async throws {
        let listener = FFITerminalSessionListener { [weak self] sessionId, event in
            Task { @MainActor [weak self] in
                self?.handleSessionEvent(sessionId: sessionId, event: event)
            }
        }

        do {
            let sessionId = try core.createTerminal(
                cwd: cwd,
                cols: UInt16(clamping: cols),
                rows: UInt16(clamping: rows),
                listener: listener
            )
            guard onEvent != nil else {
                try? core.closeTerminal(sessionId: sessionId)
                return
            }
            activeSessionIds.insert(sessionId)
            listener.activate(sessionId: sessionId)
            onEvent?(.created(sessionId: sessionId, id: requestId, cols: cols, rows: rows))
        } catch {
            throw FFIBackendClient.mapError(error)
        }
    }

    func createConnection(connectionId: String, cols: Int, rows: Int, requestId: String) async throws {
        let listener = FFITerminalSessionListener { [weak self] sessionId, event in
            Task { @MainActor [weak self] in
                self?.handleSessionEvent(sessionId: sessionId, event: event)
            }
        }

        do {
            let sessionId = try await core.createConnectionTerminal(
                connectionId: connectionId,
                cols: UInt16(clamping: cols),
                rows: UInt16(clamping: rows),
                listener: listener
            )
            guard onEvent != nil else {
                try? core.closeTerminal(sessionId: sessionId)
                return
            }
            activeSessionIds.insert(sessionId)
            listener.activate(sessionId: sessionId)
            onEvent?(.created(sessionId: sessionId, id: requestId, cols: cols, rows: rows))
        } catch {
            throw FFIBackendClient.mapError(error)
        }
    }

    func shutdownWorkspace() async {
        try? await core.shutdownWorkspace()
    }

    func sendInput(sessionId: String, bytes: [UInt8]) async throws {
        do {
            try core.sendTerminalInput(sessionId: sessionId, data: Data(bytes))
        } catch {
            throw FFIBackendClient.mapError(error)
        }
    }

    func resize(sessionId: String, cols: Int, rows: Int, requestId: String) async throws {
        do {
            try core.resizeTerminal(
                sessionId: sessionId,
                cols: UInt16(clamping: cols),
                rows: UInt16(clamping: rows)
            )
            onEvent?(.resized(sessionId: sessionId, id: requestId, cols: cols, rows: rows))
        } catch {
            throw FFIBackendClient.mapError(error)
        }
    }

    func close(sessionId: String, requestId: String) async throws {
        do {
            try core.closeTerminal(sessionId: sessionId)
            activeSessionIds.remove(sessionId)
            onEvent?(.closed(sessionId: sessionId, id: requestId))
        } catch {
            throw FFIBackendClient.mapError(error)
        }
    }

    private func handleSessionEvent(sessionId: String, event: FFITerminalSessionEvent) {
        switch event {
        case .output(let data):
            onEvent?(.output(sessionId: sessionId, bytes: [UInt8](data)))
        case .exit(let code, let signal):
            activeSessionIds.remove(sessionId)
            onEvent?(.exit(sessionId: sessionId, code: code.map(Int.init), signal: signal.map(Int.init)))
        case .error(let code, let message):
            onEvent?(.error(sessionId: sessionId, id: nil, code: code, message: message))
        }
    }
}

nonisolated enum FFITerminalSessionEvent {
    case output(Data)
    case exit(code: Int32?, signal: Int32?)
    case error(code: String, message: String)
}

/// Rust 事件转发线程 → 主线程的桥。sessionId 在 `createTerminal` 返回后才知道，
/// 而首批输出可能更早到达：激活前的事件先入队，激活时按序补发。
nonisolated final class FFITerminalSessionListener: TerminalEventListener, @unchecked Sendable {
    private let lock = NSLock()
    private var sessionId: String?
    private var pending: [FFITerminalSessionEvent] = []
    private let deliver: @Sendable (String, FFITerminalSessionEvent) -> Void

    init(deliver: @escaping @Sendable (String, FFITerminalSessionEvent) -> Void) {
        self.deliver = deliver
    }

    func activate(sessionId: String) {
        lock.lock()
        self.sessionId = sessionId
        let queued = pending
        pending.removeAll()
        lock.unlock()

        for event in queued {
            deliver(sessionId, event)
        }
    }

    func onOutput(data: Data) {
        emit(.output(data))
    }

    func onExit(code: Int32?, signal: Int32?) {
        emit(.exit(code: code, signal: signal))
    }

    func onError(code: String, message: String) {
        emit(.error(code: code, message: message))
    }

    private func emit(_ event: FFITerminalSessionEvent) {
        lock.lock()
        guard let sessionId else {
            pending.append(event)
            lock.unlock()
            return
        }
        lock.unlock()
        deliver(sessionId, event)
    }
}
