import Combine
import Foundation

/// FFI-level connection summary (no credentials). Mirrors `ConnectionInfoDto`.
public struct CoreConnectionSummary: Equatable {
    public let connectionId: String
    public let displayName: String
    public let endpoint: String
    public let bucket: String
    public let basePrefix: String

    public init(
        connectionId: String,
        displayName: String,
        endpoint: String,
        bucket: String,
        basePrefix: String
    ) {
        self.connectionId = connectionId
        self.displayName = displayName
        self.endpoint = endpoint
        self.bucket = bucket
        self.basePrefix = basePrefix
    }
}

/// UI row model: what the sidebar renders. Identifiable by connection id.
public struct ConnectionListItem: Identifiable, Equatable {
    public let id: String
    public let displayName: String
    public let endpoint: String
    public let bucket: String

    public init(id: String, displayName: String, endpoint: String, bucket: String) {
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint
        self.bucket = bucket
    }
}

/// Protocol used by `ConnectionViewModel` so tests can swap a mock for the
/// real FFI adapter (`FFIConnectionClient`).
public protocol CoreConnectionClientProtocol {
    func create(
        displayName: String,
        endpoint: String,
        region: String,
        bucket: String,
        basePrefix: String,
        pathStyle: Bool,
        accessKeyId: String,
        secretAccessKey: String
    ) async throws -> String
    func list() async throws -> [CoreConnectionSummary]
    func remove(connectionId: String) async throws
}

/// Orchestrates the three connection stores:
/// - core in-memory `ConnectionRegistry` (mints ids; lives for the session)
/// - macOS Keychain (`KeychainServicing`) for credentials
/// - `ConnectionStoring` JSON file for non-sensitive config metadata
///
/// SECURITY: credentials are passed by value through `create(...)` and forwarded
/// to core + Keychain. They are NEVER cached on `self`, NEVER persisted to the
/// JSON store, and NEVER logged.
/// Protocol the ViewModel uses to fetch provider caps. Decoupled from
/// `CoreConnectionClientProtocol` so tests can stub caps independently of
/// the create/list/remove flow.
public protocol CoreCapabilitiesClientProtocol {
    func connectionCapabilities(connectionId: String) throws -> ProviderCapsDto
}

@MainActor
public final class ConnectionViewModel: ObservableObject {
    @Published public private(set) var connections: [ConnectionListItem] = []
    @Published public private(set) var capabilities: [String: ProviderCapsDto] = [:]
    @Published public var errorText: String?

    private let core: CoreConnectionClientProtocol
    private let capabilitiesClient: CoreCapabilitiesClientProtocol?
    private let keychain: KeychainServicing
    private let store: ConnectionStoring

    public init(
        core: CoreConnectionClientProtocol,
        capabilitiesClient: CoreCapabilitiesClientProtocol? = nil,
        keychain: KeychainServicing,
        store: ConnectionStoring
    ) {
        self.core = core
        self.capabilitiesClient = capabilitiesClient
        self.keychain = keychain
        self.store = store
    }

    /// Boot path: rebuild core's in-memory registry from the persistent store
    /// + Keychain. Entries whose Keychain credentials are missing (orphan
    /// metadata) are silently skipped so a bad single entry never blocks app
    /// startup. The store remains the source of truth — orphan rows are not
    /// purged here, leaving the user free to repair them.
    public func load() async throws {
        let persisted = store.load()
        var items: [ConnectionListItem] = []
        for entry in persisted {
            guard let creds = try? keychain.load(connectionId: entry.connectionId) else {
                continue
            }
            _ = try await core.create(
                displayName: entry.displayName,
                endpoint: entry.endpoint,
                region: entry.region,
                bucket: entry.bucket,
                basePrefix: entry.basePrefix,
                pathStyle: entry.pathStyle,
                accessKeyId: creds.accessKeyId,
                secretAccessKey: creds.secretAccessKey
            )
            items.append(
                ConnectionListItem(
                    id: entry.connectionId,
                    displayName: entry.displayName,
                    endpoint: entry.endpoint,
                    bucket: entry.bucket
                )
            )
        }
        connections = items
    }

    /// Register a new connection: core mints the id, credentials land in
    /// Keychain, config metadata lands in the JSON store. The four-step
    /// ordering ensures we never have a Keychain or JSON record for an id
    /// that core does not know about.
    public func create(
        displayName: String,
        endpoint: String,
        region: String,
        bucket: String,
        basePrefix: String,
        pathStyle: Bool,
        accessKeyId: String,
        secretAccessKey: String
    ) async throws {
        let id = try await core.create(
            displayName: displayName,
            endpoint: endpoint,
            region: region,
            bucket: bucket,
            basePrefix: basePrefix,
            pathStyle: pathStyle,
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey
        )
        try keychain.save(
            connectionId: id,
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey
        )
        try store.upsert(
            StoredConnection(
                connectionId: id,
                displayName: displayName,
                endpoint: endpoint,
                region: region,
                bucket: bucket,
                basePrefix: basePrefix,
                pathStyle: pathStyle
            )
        )
        connections.append(
            ConnectionListItem(
                id: id,
                displayName: displayName,
                endpoint: endpoint,
                bucket: bucket
            )
        )
    }

    /// Forget a connection across all three stores. The Keychain / JSON deletes
    /// are best-effort: a leftover orphan is less harmful than failing to remove
    /// the active core entry, so only the `core.remove` failure propagates.
    public func remove(id: String) async throws {
        try await core.remove(connectionId: id)
        try? keychain.delete(connectionId: id)
        try? store.remove(connectionId: id)
        connections.removeAll { $0.id == id }
        capabilities.removeValue(forKey: id)
    }

    /// Pull provider capability flags for `id` into the published `capabilities`
    /// map so UI can gate destructive/non-atomic actions. Caps lookup forces the
    /// provider into core's cache (via resolve_provider) — it can fail if the
    /// connection id is not registered. Failures clear the entry rather than
    /// throw, so a connect-then-loading-spinner state collapses gracefully.
    public func loadCapabilities(for id: String) {
        guard let client = capabilitiesClient else { return }
        do {
            capabilities[id] = try client.connectionCapabilities(connectionId: id)
        } catch {
            capabilities[id] = nil
        }
    }
}
