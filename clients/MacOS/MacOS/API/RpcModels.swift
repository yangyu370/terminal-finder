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

struct ListDirectoryParams: Encodable {
    let path: String
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
