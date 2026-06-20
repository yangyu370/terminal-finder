import Foundation

/// Non-sensitive connection configuration persisted to disk.
///
/// Credentials are deliberately ABSENT — they live only in the Keychain
/// (`KeychainService`), keyed by `connectionId`. This struct mirrors the
/// Rust `S3ConnectionConfig` minus the credential fields, plus identity
/// (`connectionId`) and a `kind` discriminator for future non-S3 variants.
public struct StoredConnection: Codable, Equatable {
    public let connectionId: String
    public let kind: String          // "s3" for Phase 1
    public let displayName: String
    public let endpoint: String
    public let region: String
    public let bucket: String
    public let basePrefix: String
    public let pathStyle: Bool

    public init(
        connectionId: String,
        kind: String = "s3",
        displayName: String,
        endpoint: String,
        region: String,
        bucket: String,
        basePrefix: String,
        pathStyle: Bool
    ) {
        self.connectionId = connectionId
        self.kind = kind
        self.displayName = displayName
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.basePrefix = basePrefix
        self.pathStyle = pathStyle
    }
}

/// Persistence protocol so callers (and tests) can inject a fake.
public protocol ConnectionStoring {
    /// Returns the persisted connections. Corruption / missing file yields [].
    func load() -> [StoredConnection]
    /// Insert or replace by `connectionId`, then persist atomically.
    func upsert(_ connection: StoredConnection) throws
    /// Remove by `connectionId` (no-op if absent), then persist atomically.
    func remove(connectionId: String) throws
}

/// JSON-file-backed connection store.
///
/// File: `~/Library/Application Support/TerminalFinder/connections.json`
/// Schema: `{ "version": 1, "connections": [StoredConnection...] }`
/// - Atomic writes (`.atomic`) so a crash mid-write can't corrupt the file.
/// - Load is corruption-tolerant: a missing or unparseable file yields `[]`
///   rather than throwing, so a bad file never blocks app startup.
public final class ConnectionStore: ConnectionStoring {
    private struct StoreFile: Codable {
        var version: Int
        var connections: [StoredConnection]
    }

    private static let currentVersion = 1

    private let fileURL: URL
    private let fileManager: FileManager

    /// - Parameter fileURL: override the JSON path (tests inject a temp dir).
    ///   When nil, defaults to Application Support/TerminalFinder/connections.json.
    public init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = fileManager
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!
            self.fileURL = base
                .appendingPathComponent("TerminalFinder", isDirectory: true)
                .appendingPathComponent("connections.json", isDirectory: false)
        }
    }

    public func load() -> [StoredConnection] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let file = try? JSONDecoder().decode(StoreFile.self, from: data) else { return [] }
        return file.connections
    }

    public func upsert(_ connection: StoredConnection) throws {
        var connections = load()
        if let index = connections.firstIndex(where: { $0.connectionId == connection.connectionId }) {
            connections[index] = connection
        } else {
            connections.append(connection)
        }
        try persist(connections)
    }

    public func remove(connectionId: String) throws {
        var connections = load()
        connections.removeAll { $0.connectionId == connectionId }
        try persist(connections)
    }

    private func persist(_ connections: [StoredConnection]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = StoreFile(version: Self.currentVersion, connections: connections)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: fileURL, options: [.atomic])
    }
}
