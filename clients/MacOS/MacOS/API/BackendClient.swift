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

    /// 上传：读取 `localSource`，写到 `remotePath`。S3 走 PUT，Local 直接覆盖。
    /// 进度通过 `transfer_progress` 事件下发到 `EventClientProtocol`。
    func uploadFile(
        connectionId: String?,
        remotePath: String,
        localSource: String
    ) async throws

    /// 删除单个对象/文件。S3 仅删 key（不递归），Local 区分文件/目录递归删除。
    func deleteEntry(connectionId: String?, path: String) async throws

    /// 创建目录。S3 写入零字节 marker 对象，调用方需通过 caps 提示用户。
    func createRemoteDirectory(connectionId: String?, path: String) async throws

    /// 重命名/移动。S3 是 copy + delete（非原子）；客户端应在 UI 上提示。
    func renameEntry(connectionId: String?, from: String, to: String) async throws

    /// 同步取该 connection 的 provider 能力声明（write/rename/symlink/native dirs）。
    /// 用于 UI 灰显或加警告，例如 S3 上的 rename 显示"非原子"提示。
    func connectionCapabilities(connectionId: String) throws -> ProviderCapsDto
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
        throw Self.unsupportedFFIOnly("downloadFile")
    }

    func uploadFile(
        connectionId: String?,
        remotePath: String,
        localSource: String
    ) async throws {
        throw Self.unsupportedFFIOnly("uploadFile")
    }

    func deleteEntry(connectionId: String?, path: String) async throws {
        throw Self.unsupportedFFIOnly("deleteEntry")
    }

    func createRemoteDirectory(connectionId: String?, path: String) async throws {
        throw Self.unsupportedFFIOnly("createRemoteDirectory")
    }

    func renameEntry(connectionId: String?, from: String, to: String) async throws {
        throw Self.unsupportedFFIOnly("renameEntry")
    }

    func connectionCapabilities(connectionId: String) throws -> ProviderCapsDto {
        throw Self.unsupportedFFIOnly("connectionCapabilities")
    }

    private static func unsupportedFFIOnly(_ method: String) -> BackendClientError {
        BackendClientError.rpcError(
            code: "unsupported",
            message: "\(method) is FFI-only in Phase 1; the HTTP backend does not expose it."
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
