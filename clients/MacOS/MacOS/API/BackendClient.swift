//
//  BackendClient.swift
//  MacOS
//
//  Created by Wang on 2026/6/1.
//
import Foundation

protocol BackendClientProtocol {
    func ping() async throws -> PingResult
    func listDirectory(path: String) async throws -> DirectoryListing
}

struct BackendClient: BackendClientProtocol {
    static let defaultEndpoint = URL(string: "http://127.0.0.1:3587/rpc")!

    private let endpoint: URL
    private let session: URLSession

    init(
        endpoint: URL = BackendClient.defaultEndpoint,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.session = session
    }

    func ping() async throws -> PingResult {
        try await send(method: "core.ping", params: EmptyParams())
    }

    func listDirectory(path: String) async throws -> DirectoryListing {
        try await send(
            method: "workspace.listDirectory",
            params: ListDirectoryParams(path: path)
        )
    }

    private func send<Params: Encodable, Result: Decodable>(
        method: String,
        params: Params
    ) async throws -> Result {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RpcRequest(method: method, params: params))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if let rpcError = try? JSONDecoder().decode(RpcErrorResponse.self, from: data) {
                throw BackendClientError.rpcError(rpcError.error.message)
            }

            throw BackendClientError.unhealthyStatus(httpResponse.statusCode)
        }

        let rpcResponse = try JSONDecoder().decode(RpcResponse<Result>.self, from: data)
        guard rpcResponse.ok else {
            throw BackendClientError.rejectedResponse
        }

        return rpcResponse.result
    }
}
enum BackendClientError: LocalizedError {
    case invalidResponse
    case rejectedResponse
    case unhealthyStatus(Int)
    case rpcError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Core returned an invalid response."
        case .rejectedResponse:
            return "Core rejected the request."
        case .unhealthyStatus(let statusCode):
            return "Core returned HTTP \(statusCode)."
        case .rpcError(let message):
            return message
        }
    }
}
