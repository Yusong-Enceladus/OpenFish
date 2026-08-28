import Foundation
import CryptoKit
import Security

/// Bootstrap-only wire models exposed before a native client joins the ordinary DSH API.
struct BootstrapHandshake: Codable {
    let ok: Bool
    let product: String
    let protocolVersion: String
    let minimumClientProtocol: String
    let host: String
    let surface: String
    let plainHost: String?
    let secureRemotePort: Int?
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
        let remoteMux: String
        let remoteEvents: String
        let nativeFeed: String
        let hostEvents: String?
        let muxEvents: String?
    }

    struct FeatureFacts: Codable {
        let apiProxy: Bool
        let gateway: Bool
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
    let codeId: String
    let expiresAt: Double
    let transport: String
    let hostURL: String?
}

struct NativePairingReceipt: Codable, Equatable, Sendable {
    let deviceId: String
    let token: String
    let expiresAt: Double
    let createdAt: Double
    let hostURL: String?
}

struct NativePairingResult: Sendable {
    let receipt: NativePairingReceipt
    let tlsFingerprint: String?
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
    let mode: String?
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
    private let trustDelegate: OpenFishTLSDelegate

    init(
        baseURL: URL = URL(string: "http://127.0.0.1:3080")!,
        bearerToken: String? = nil,
        tlsFingerprint: String? = nil,
        permitsBootstrapTrust: Bool = false
    ) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        let trustDelegate = OpenFishTLSDelegate(
            expectedFingerprint: tlsFingerprint,
            permitsBootstrapTrust: permitsBootstrapTrust
        )
        self.trustDelegate = trustDelegate
        session = URLSession(configuration: config, delegate: trustDelegate, delegateQueue: nil)
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

    func pair(deviceName: String, code: String?) async throws -> NativePairingResult {
        struct Payload: Encodable, Sendable {
            let surface = "macos"
            let deviceName: String
            let appVersion: String
            let codeId: String?
            let clientNonce: String?
            let proof: String?
        }
        let appVersion = "0.1.0"
        guard let code, !code.isEmpty else {
            let receipt = try await post(
                "/x-native/v2/pair",
                payload: Payload(
                    deviceName: deviceName,
                    appVersion: appVersion,
                    codeId: nil,
                    clientNonce: nil,
                    proof: nil
                ),
                as: NativePairingReceipt.self
            )
            return NativePairingResult(receipt: receipt, tlsFingerprint: nil)
        }
        guard baseURL.scheme == "https" else {
            throw NativeCredentialError.incompleteRemoteAuthorization
        }
        _ = try await handshake()
        guard let fingerprint = trustDelegate.acceptedFingerprint else {
            throw NativeCredentialError.incompleteRemoteAuthorization
        }
        let proof = try Self.pairingProof(
            code: code,
            certificateFingerprint: fingerprint,
            surface: "macos",
            deviceName: deviceName,
            appVersion: appVersion
        )
        let receipt = try await post(
            "/x-native/v2/pair",
            payload: Payload(
                deviceName: deviceName,
                appVersion: appVersion,
                codeId: proof.codeId,
                clientNonce: proof.clientNonce,
                proof: proof.proof
            ),
            as: NativePairingReceipt.self
        )
        return NativePairingResult(receipt: receipt, tlsFingerprint: fingerprint)
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

    private static func pairingProof(
        code: String,
        certificateFingerprint: String,
        surface: String,
        deviceName: String,
        appVersion: String
    ) throws -> (codeId: String, clientNonce: String, proof: String) {
        let normalized = code.uppercased().unicodeScalars.filter {
            $0.isASCII && (($0.value >= 65 && $0.value <= 90) || ($0.value >= 48 && $0.value <= 57))
        }.map(String.init).joined()
        guard normalized.count == 16 else {
            throw URLError(.userAuthenticationRequired)
        }
        let codeDigest = SHA256.hash(data: Data(normalized.utf8))
        let codeId = Data(codeDigest).map { String(format: "%02x", $0) }.joined()
        var nonceBytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes) == errSecSuccess else {
            throw URLError(.cannotCreateFile)
        }
        let clientNonce = Data(nonceBytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let message = [
            "openfish-pair-v1",
            certificateFingerprint.lowercased(),
            clientNonce,
            surface,
            deviceName,
            appVersion,
        ].joined(separator: "\0")
        let authentication = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: Data(normalized.utf8))
        )
        return (
            codeId,
            clientNonce,
            Data(authentication).map { String(format: "%02x", $0) }.joined()
        )
    }
}
