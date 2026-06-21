//
//  BackendClient.swift
//  MacOS
//
//  Created by Wang on 2026/6/1.
import Foundation

protocol BackendClientProtocol {
    func health() async throws -> PingResult
    func ping() async throws -> PingResult
    func getState() async throws -> WorkspaceState
    /// `connectionId == nil` 走本地 workspace；传入注册过的 S3 连接 id 时路由到对应 S3Provider。
    func openDirectory(path: String, connectionId: String?) async throws -> OpenDirectoryResult
    /// 见 `openDirectory(path:connectionId:)` 的路由规则。
    func listDirectory(path: String, connectionId: String?) async throws -> DirectoryListing
    /// 把 `remotePath` 内容写到 `localDestination`。S3 通过注册的连接读取，
    /// `connectionId == nil` 走本地。50 MiB 上限由 core 强制。
    func downloadFile(
        connectionId: String?,
        remotePath: String,
        localDestination: String
    ) async throws
}

struct BackendClient: BackendClientProtocol {
    static let defaultHealthEndpoint = URL(string: "http://127.0.0.1:3587/health")!
    static let defaultEndpoint = URL(string: "http://127.0.0.1:3587/rpc")!

    private let healthEndpoint: URL
    private let endpoint: URL
    private let session: URLSession

    init(
        healthEndpoint: URL = BackendClient.defaultHealthEndpoint,
        endpoint: URL = BackendClient.defaultEndpoint,
        session: URLSession = .shared
    ) {
        self.healthEndpoint = healthEndpoint
        self.endpoint = endpoint
        self.session = session
    }

    func health() async throws -> PingResult {
        var request = URLRequest(url: healthEndpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 1

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw BackendClientError.unhealthyStatus(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(PingResult.self, from: data)
    }

    func ping() async throws -> PingResult {
        try await send(method: "core.ping", params: EmptyParams())
    }

    func getState() async throws -> WorkspaceState {
        let result: WorkspaceStateResult = try await send(
            method: "workspace.getState",
            params: EmptyParams()
        )

        return result.state
    }

    func openDirectory(path: String, connectionId: String?) async throws -> OpenDirectoryResult {
        try await send(
            method: "workspace.openDirectory",
            params: OpenDirectoryParams(path: path, connectionId: connectionId)
        )
    }

    func listDirectory(path: String, connectionId: String?) async throws -> DirectoryListing {
        try await send(
            method: "workspace.listDirectory",
            params: ListDirectoryParams(path: path, connectionId: connectionId)
        )
    }

    /// download_file is FFI-only in Phase 1; the legacy HTTP backend never
    /// shipped a matching JSON-RPC method, so the HTTP client surfaces a
    /// stable `unsupported` rpc error rather than silently no-op'ing.
    func downloadFile(
        connectionId: String?,
        remotePath: String,
        localDestination: String
    ) async throws {
        throw BackendClientError.rpcError(
            code: "unsupported",
            message: "downloadFile is not exposed by the HTTP backend; use the in-process FFI client."
        )
    }

    private func send<Params: Encodable, Result: Decodable>(
        method: String,
        params: Params
    ) async throws -> Result {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RpcRequest(method: method, params: params))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if let rpcError = try? JSONDecoder().decode(RpcErrorResponse.self, from: data) {
                throw BackendClientError.rpcError(
                    code: rpcError.error.code,
                    message: rpcError.error.message
                )
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
    case rpcError(code: String, message: String)

    var rpcCode: String? {
        guard case .rpcError(let code, _) = self else {
            return nil
        }

        return code
    }

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Core returned an invalid response."
        case .rejectedResponse:
            return "Core rejected the request."
        case .unhealthyStatus(let statusCode):
            return "Core returned HTTP \(statusCode)."
        case .rpcError(_, let message):
            return message
        }
    }
}
