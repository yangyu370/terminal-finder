import Foundation
import Security

/// Plaintext credentials a client re-passes to core when binding a connection at app start.
public struct KeychainCredential: Equatable {
    public let accessKeyId: String
    public let secretAccessKey: String

    public init(accessKeyId: String, secretAccessKey: String) {
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
    }
}

/// Protocol so tests can swap a real Keychain for an in-memory one.
public protocol KeychainServicing {
    func save(connectionId: String, accessKeyId: String, secretAccessKey: String) throws
    func load(connectionId: String) throws -> KeychainCredential
    func delete(connectionId: String) throws
}

public enum KeychainServiceError: Error {
    case osStatus(OSStatus)
    case malformedData
    case notFound
}

/// Real Keychain implementation using the Security framework.
///
/// Layout:
///   service = "com.terminal-finder.connection"
///   account = "<connection_id>::<label>" where label is one of {access_key_id, secret_access_key}
///
/// SECURITY: never log credential strings. Error paths surface OSStatus only.
public final class KeychainService: KeychainServicing {
    private static let service = "com.terminal-finder.connection"

    public init() {}

    public func save(connectionId: String, accessKeyId: String, secretAccessKey: String) throws {
        try saveItem(connectionId: connectionId, label: "access_key_id", value: accessKeyId)
        try saveItem(connectionId: connectionId, label: "secret_access_key", value: secretAccessKey)
    }

    public func load(connectionId: String) throws -> KeychainCredential {
        let access = try loadItem(connectionId: connectionId, label: "access_key_id")
        let secret = try loadItem(connectionId: connectionId, label: "secret_access_key")
        return KeychainCredential(accessKeyId: access, secretAccessKey: secret)
    }

    public func delete(connectionId: String) throws {
        try deleteItem(connectionId: connectionId, label: "access_key_id")
        try deleteItem(connectionId: connectionId, label: "secret_access_key")
    }

    private func account(_ connectionId: String, _ label: String) -> String {
        "\(connectionId)::\(label)"
    }

    private func saveItem(connectionId: String, label: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainServiceError.malformedData
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account(connectionId, label),
        ]
        // Delete any existing entry first (so add succeeds cleanly).
        SecItemDelete(query as CFDictionary)

        var insertQuery = query
        insertQuery[kSecValueData as String] = data
        let status = SecItemAdd(insertQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainServiceError.osStatus(status)
        }
    }

    private func loadItem(connectionId: String, label: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account(connectionId, label),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainServiceError.notFound
            }
            throw KeychainServiceError.osStatus(status)
        }
        guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
            throw KeychainServiceError.malformedData
        }
        return string
    }

    private func deleteItem(connectionId: String, label: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account(connectionId, label),
        ]
        let status = SecItemDelete(query as CFDictionary)
        // errSecItemNotFound is OK on delete (idempotent).
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainServiceError.osStatus(status)
        }
    }
}

/// In-memory implementation for tests. NEVER use in production.
public final class InMemoryKeychainService: KeychainServicing {
    private var storage: [String: KeychainCredential] = [:]

    public init() {}

    public func save(connectionId: String, accessKeyId: String, secretAccessKey: String) throws {
        storage[connectionId] = KeychainCredential(
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey
        )
    }

    public func load(connectionId: String) throws -> KeychainCredential {
        guard let cred = storage[connectionId] else {
            throw KeychainServiceError.notFound
        }
        return cred
    }

    public func delete(connectionId: String) throws {
        storage.removeValue(forKey: connectionId)
    }
}
