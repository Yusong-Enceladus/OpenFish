import Foundation

/// Bootstrap-only wire models exposed before a native client joins the ordinary DSH API.
struct BootstrapHandshake: Codable {
    let ok: Bool
    let product: String
    let protocolVersion: String
    let minimumClientProtocol: String
    let host: String
    let surface: String
    let embeddedRuntimeId: String?
    let embeddedProcessId: Int32?
}

struct NativeBootstrapCapabilities: Codable {
    let product: String
    let protocolVersion: String
    let host: String
    let surface: String
    let api: ApiFacts
    let features: FeatureFacts
    let contracts: ContractFacts
    let voice: VoiceFacts?
    let pairing: PairingFacts
    let transports: TransportFacts
    let surfaces: [String]

    struct ApiFacts: Codable {
        let base: String
        let hostEvents: String
        let muxEvents: String
    }

    struct FeatureFacts: Codable {
        let apiProxy: Bool
        let typert: Bool
        let remotePlugin: Bool
        let voicePlugin: Bool
        let localVoice: Bool
        let imageGenerationExtension: Bool?
    }

    struct VoiceFacts: Codable {
        let contract: String
        let transcriptAuthority: String
        let providers: [Provider]

        struct Provider: Codable, Identifiable {
            let id: String
            let name: String
            let platforms: [String]
            let operations: [String]
            let locality: String
            let streaming: Bool
            let interruptible: Bool
            let quality: String
        }
    }

    struct ContractFacts: Codable {
        let sessions: Bool
        let workspaces: Bool
        let interactions: Bool
        let settings: Bool
        let providers: Bool
        let migration: Bool
        let sandbox: Bool
    }

    struct PairingFacts: Codable {
        let supported: Bool
        let kind: String
        let durable: Bool
    }

    struct TransportFacts: Codable {
        let lan: Bool
        let tailscale: Bool
        let relay: Bool
    }
}

struct NativePairingCode: Codable, Equatable, Sendable {
    let code: String
    let expiresAt: Double
}

struct NativePairingReceipt: Codable, Equatable, Sendable {
    let deviceId: String
    let token: String
    let expiresAt: Double
    let createdAt: Double
}

struct NativeDevice: Codable, Identifiable, Equatable, Sendable {
    let deviceId: String
    let name: String
    let surface: String
    let appVersion: String?
    let createdAt: Double
    let expiresAt: Double
    let lastSeenAt: Double

    var id: String { deviceId }
}

struct BootstrapMethod: Codable, Identifiable {
    var id: String { endpoint }
    let endpoint: String
    let service: String
    let namespace: String
    let method: String
    let parameters: [String]
    let implementation: String?
    let cancellation: String?
    let scope: Scope?

    struct Scope: Codable {
        let context: String
        let wire: String
    }
}

/// Bootstrap discovery client. Session and other business calls belong to `DshApiClient`.
actor DshBootstrapClient {
    let baseURL: URL
    private let session: URLSession
    private let bearerToken: String?

    init(
        baseURL: URL = URL(string: "http://127.0.0.1:3080")!,
        bearerToken: String? = nil
    ) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        session = URLSession(configuration: config)
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)
        authorize(&request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(type, from: data)
    }

    func handshake() async throws -> BootstrapHandshake {
        try await get("/x-native/v2/health", as: BootstrapHandshake.self)
    }

    func capabilities() async throws -> NativeBootstrapCapabilities {
        try await get("/x-native/v2/capabilities", as: NativeBootstrapCapabilities.self)
    }

    func methods() async throws -> [BootstrapMethod] {
        try await get("/x-native/v2/methods", as: [BootstrapMethod].self)
    }

    func createPairingCode() async throws -> NativePairingCode {
        try await post("/x-native/v2/pairing-code", payload: EmptyPayload(), as: NativePairingCode.self)
    }

    func pair(deviceName: String, code: String?) async throws -> NativePairingReceipt {
        struct Payload: Encodable, Sendable {
            let surface = "macos"
            let deviceName: String
            let appVersion: String
            let code: String?
        }
        return try await post(
            "/x-native/v2/pair",
            payload: Payload(deviceName: deviceName, appVersion: "0.1.0", code: code),
            as: NativePairingReceipt.self
        )
    }

    func devices() async throws -> [NativeDevice] {
        try await get("/x-native/v2/devices", as: [NativeDevice].self)
    }

    func revoke(deviceId: String) async throws -> Bool {
        struct Payload: Encodable, Sendable { let deviceId: String }
        struct Value: Decodable, Sendable { let revoked: Bool }
        let value: Value = try await post("/x-native/v2/revoke", payload: Payload(deviceId: deviceId), as: Value.self)
        return value.revoked
    }

    private func post<Payload: Encodable, Value: Decodable>(
        _ path: String,
        payload: Payload,
        as type: Value.Type
    ) async throws -> Value {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        authorize(&request)
        request.httpBody = try JSONEncoder().encode(payload)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw URLError(.userAuthenticationRequired)
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private func authorize(_ request: inout URLRequest) {
        guard let bearerToken, !bearerToken.isEmpty else { return }
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "authorization")
    }
}
