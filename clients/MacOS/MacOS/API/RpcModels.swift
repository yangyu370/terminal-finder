//
//  RpcModels.swift
//  MacOS
//
//  Created by Wang on 2026/6/1.
//

struct RpcRequest<Params: Encodable>: Encodable {
    let method: String
    let params: Params
}

struct EmptyParams: Encodable {
}

struct RpcResponse<Result: Decodable>: Decodable {
    let ok: Bool
    let result: Result
}

struct PingResult: Decodable {
    let service: String
    let version: String
}

struct WorkspaceState: Decodable {
    let currentDirectory: String
    let workspaceRoot: String?
    let version: UInt64?

    init(currentDirectory: String, workspaceRoot: String? = nil, version: UInt64? = nil) {
        self.currentDirectory = currentDirectory
        self.workspaceRoot = workspaceRoot
        self.version = version
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentDirectory = try container.decodeFirstPresentString(
            for: [.currentDirectory, .currentPath, .path, .cwd]
        )
        workspaceRoot = try container.decodeFirstPresentStringIfPresent(
            for: [.workspaceRoot, .rootPath, .root]
        )
        version = try container.decodeFirstPresentUInt64IfPresent(
            for: [.version, .revision]
        )
    }

    private enum CodingKeys: String, CodingKey {
        case currentDirectory
        case currentPath
        case path
        case cwd
        case workspaceRoot
        case rootPath
        case root
        case version
        case revision
    }
}

struct WorkspaceStateResult: Decodable {
    let state: WorkspaceState

    init(from decoder: any Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        if let state = try container?.decodeIfPresent(WorkspaceState.self, forKey: .state) {
            self.state = state
            return
        }

        state = try WorkspaceState(from: decoder)
    }

    private enum CodingKeys: String, CodingKey {
        case state
    }
}

struct OpenDirectoryParams: Encodable {
    let path: String
    let connectionId: String?

    enum CodingKeys: String, CodingKey {
        case path
        case connectionId = "connection_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(connectionId, forKey: .connectionId)
    }
}

struct OpenDirectoryResult: Decodable {
    let state: WorkspaceState
    let listing: DirectoryListing?

    init(state: WorkspaceState, listing: DirectoryListing?) {
        self.state = state
        self.listing = listing
    }

    init(from decoder: any Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        if let state = try container?.decodeIfPresent(WorkspaceState.self, forKey: .state) {
            self.state = state
            listing = try container?.decodeIfPresent(DirectoryListing.self, forKey: .listing)
            return
        }

        if let listing = try? DirectoryListing(from: decoder) {
            state = WorkspaceState(currentDirectory: listing.path)
            self.listing = listing
            return
        }

        state = try WorkspaceState(from: decoder)
        listing = nil
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case listing
    }
}

struct ListDirectoryParams: Encodable {
    let path: String
    let connectionId: String?

    enum CodingKeys: String, CodingKey {
        case path
        case connectionId = "connection_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(connectionId, forKey: .connectionId)
    }
}

struct DirectoryListing: Decodable {
    let path: String
    let entries: [DirectoryEntry]
}

struct DirectoryEntry: Decodable, Identifiable {
    let name: String
    let path: String
    let kind: EntryKind
    let isDirectory: Bool
    let size: UInt64?
    let modifiedAt: String?

    var id: String {
        path
    }
}

enum EntryKind: String, Decodable {
    case directory
    case file
    case symlink
    case other
}

struct RpcErrorResponse: Decodable {
    let ok: Bool
    let error: RpcErrorBody
}

struct RpcErrorBody: Decodable {
    let code: String
    let message: String
}

private extension KeyedDecodingContainer {
    func decodeFirstPresentString(for keys: [Key]) throws -> String {
        for key in keys {
            if let value = try decodeIfPresent(String.self, forKey: key) {
                return value
            }
        }

        throw DecodingError.keyNotFound(
            keys[0],
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Expected one of: \(keys.map(\.stringValue).joined(separator: ", "))."
            )
        )
    }

    func decodeFirstPresentStringIfPresent(for keys: [Key]) throws -> String? {
        for key in keys {
            if let value = try decodeIfPresent(String.self, forKey: key) {
                return value
            }
        }

        return nil
    }

    func decodeFirstPresentUInt64IfPresent(for keys: [Key]) throws -> UInt64? {
        for key in keys {
            if let value = try decodeIfPresent(UInt64.self, forKey: key) {
                return value
            }
        }

        return nil
    }
}
