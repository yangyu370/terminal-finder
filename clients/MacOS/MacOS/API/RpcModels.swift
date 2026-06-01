//
//  RpcModels.swift
//  MacOS
//
//  Created by Wang on 2026/6/1.
//

struct RpcRequest: Encodable {
    let method: String
    let params: [String: String] = [:]
}

struct RpcResponse<Result: Decodable>: Decodable {
    let ok: Bool
    let result: Result
}

struct PingResult: Decodable {
    let service: String
    let version: String
}
