import Foundation

nonisolated struct FFICommandClient {
    private let core: CoreHandle

    init(core: CoreHandle = CoreFFI.handle) {
        self.core = core
    }

    func invoke<P: Encodable, R: Decodable>(_ id: String, _ params: P) async throws -> R {
        do {
            let resultJson = try await invokeRaw(id, params)
            return try JSONDecoder().decode(R.self, from: Data(resultJson.utf8))
        } catch {
            throw FFIBackendClient.mapError(error)
        }
    }

    func invokeVoid<P: Encodable>(_ id: String, _ params: P) async throws {
        do {
            _ = try await invokeRaw(id, params)
        } catch {
            throw FFIBackendClient.mapError(error)
        }
    }

    private func invokeRaw<P: Encodable>(_ id: String, _ params: P) async throws -> String {
        let paramsData = try JSONEncoder().encode(params)
        let paramsJson = String(decoding: paramsData, as: UTF8.self)
        return try await core.commandInvoke(id: id, paramsJson: paramsJson)
    }
}
