//
//  BackendClient.swift
//  MacOS
//
//  Created by Wang on 2026/6/1.
//
import Foundation

struct BackendClient {
    private let endpoint = URL(string: "http://127.0.0.1:3587/rpc")!
    func ping() async throws -> PingResult {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RpcRequest(method: "core.ping"))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw BackendClientError.unhealthyStatus(httpResponse.statusCode)
        }

        let rpcResponse = try JSONDecoder().decode(RpcResponse<PingResult>.self, from: data)
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

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Core returned an invalid response."
        case .rejectedResponse:
            return "Core rejected the request."
        case .unhealthyStatus(let statusCode):
            return "Core returned HTTP \(statusCode)."
        }
    }
}
