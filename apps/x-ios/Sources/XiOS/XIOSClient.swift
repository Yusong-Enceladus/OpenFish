import Foundation

enum MobileJSONValue: Codable, Equatable, Sendable {
    case object([String: MobileJSONValue])
    case array([MobileJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([MobileJSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: MobileJSONValue].self) { self = .object(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    subscript(_ key: String) -> MobileJSONValue? {
        guard case let .object(value) = self else { return nil }
        return value[key]
    }

    var stringValue: String? { if case let .string(value) = self { value } else { nil } }
    var boolValue: Bool? { if case let .bool(value) = self { value } else { nil } }
    var intValue: Int? {
        guard case let .number(value) = self, value.rounded() == value else { return nil }
        return Int(value)
    }
    var arrayValue: [MobileJSONValue]? { if case let .array(value) = self { value } else { nil } }
    var objectValue: [String: MobileJSONValue]? { if case let .object(value) = self { value } else { nil } }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}

struct MobileWorkspace: Codable, Identifiable, Equatable, Sendable {
    let workspaceId: String
    let path: String
    let title: String
    let sessionIds: [String]
    let createdAt: String
    let updatedAt: String
    var id: String { workspaceId }
}

struct MobileDirectoryEntry: Codable, Identifiable, Equatable, Sendable {
    let name: String
    let path: String
    let hidden: Bool
    var id: String { path }
}

struct MobileDirectoryListing: Codable, Equatable, Sendable {
    let path: String
    let home: String
    let crumbs: [MobileDirectoryEntry]
    let entries: [MobileDirectoryEntry]
    let truncated: Bool
}

struct MobileSession: Codable, Identifiable, Equatable, Sendable {
    let sessionId: String
    let harnessId: String
    var updatedAt: Double
    var running: Bool
    var blank: Bool
    let parentSessionId: String?
    let origin: String?
    let cwd: String?
    let agentPreset: String?
    let projections: MobileProjectionBlock?
    var id: String { sessionId }
}

struct MobileProjectionBlock: Codable, Equatable, Sendable {
    let asOfSeq: Int
    let values: [String: MobileJSONValue]
}

struct MobileHarnessRuntimeProjection: Codable, Equatable, Sendable {
    struct Node: Codable, Equatable, Sendable {
        let status: String; let activity: String; let seq: Int; let time: Double
    }
    let nodes: [String: Node]
}

struct MobileSessionEvent: Codable, Identifiable, Equatable, Sendable {
    let type: String
    let seq: Int
    let time: Double
    let data: MobileJSONValue
    let sourceEventSeqs: [Int]?
    let surfaceOp: MobileJSONValue?
    let ignorable: Bool?
    var id: Int { seq }
}

struct MobileEventRecord: Codable, Identifiable, Equatable, Sendable {
    let event: MobileSessionEvent
    let view: MobileJSONValue?
    var id: Int { event.seq }
}

struct MobileHistory: Decodable, Sendable {
    let events: [MobileEventRecord]
    let hasMore: Bool
    let projections: MobileProjectionBlock?
}

struct MobileModelSelection: Codable, Equatable, Sendable {
    let provider: String
    let model: String
    let reasoningEffort: String?
}

struct MobileModelReasoningEffort: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String?
}

struct MobileModelReasoning: Decodable, Equatable, Sendable {
    let efforts: [MobileModelReasoningEffort]
    let defaultEffort: String?
}

struct MobileCatalogModel: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String?
    let reasoning: MobileModelReasoning?
}

struct MobileModelGroup: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let models: [MobileCatalogModel]
}

struct MobileModelFailure: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let message: String
}

struct MobileHarnessConfigValue: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String?
    let group: String?
    let groupName: String?
}

struct MobileHarnessConfigOption: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String?
    let category: String?
    let type: String
    let currentValue: MobileJSONValue
    let values: [MobileHarnessConfigValue]
}

struct MobileSessionModels: Decodable, Equatable, Sendable {
    let current: MobileModelSelection
    let routable: Bool
    let groups: [MobileModelGroup]
    let failures: [MobileModelFailure]
    let harnessOptions: [MobileHarnessConfigOption]?

    init(
        current: MobileModelSelection,
        routable: Bool,
        groups: [MobileModelGroup],
        failures: [MobileModelFailure],
        harnessOptions: [MobileHarnessConfigOption]? = nil
    ) {
        self.current = current
        self.routable = routable
        self.groups = groups
        self.failures = failures
        self.harnessOptions = harnessOptions
    }
}

struct MobilePermissionOption: Codable, Identifiable, Equatable, Sendable {
    let value: String
    let name: String
    let description: String?
    var id: String { value }
}

struct MobilePermissionSelect: Codable, Equatable, Sendable {
    let options: [MobilePermissionOption]
    let currentValue: String
}

struct MobileAgentPreset: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let trust: String
    let isDefault: Bool
    let name: String?
    let description: String?
    let broken: String?
}

struct MobileAgentPresetCatalog: Decodable, Equatable, Sendable {
    let presets: [MobileAgentPreset]
    let authorable: Bool
    let hasDocument: Bool
}

struct MobileHarness: Decodable, Identifiable, Equatable, Sendable {
    struct Capability: Decodable, Identifiable, Equatable, Sendable {
        let id: String; let status: String; let source: String; let detail: String?
    }
    struct Driver: Decodable, Equatable, Sendable {
        let apiVersion: Int; let `protocol`: String; let loaded: Bool
    }
    struct GraphEvidence: Decodable, Identifiable, Equatable, Sendable {
        let kind: String; let source: String; let version: String?
        var id: String { "\(kind):\(source):\(version ?? "")" }
    }
    struct GraphNode: Decodable, Identifiable, Equatable, Sendable {
        let id: String; let kind: String; let title: String; let editable: Bool
        var responsibility: String? = nil; var inputs: [String]? = nil; var outputs: [String]? = nil
        var evidence: [GraphEvidence]? = nil; let config: [String: MobileJSONValue]?
    }
    struct GraphEdge: Decodable, Equatable, Sendable { let from: String; let to: String }
    struct Graph: Decodable, Equatable, Sendable {
        let level: String; var manifestVersion: Int? = nil; var boundary: String? = nil
        var evidence: [GraphEvidence]? = nil; let nodes: [GraphNode]; let edges: [GraphEdge]
    }
    struct Installation: Decodable, Equatable, Sendable {
        let status: String
        let installedVersion: String?
        let availableVersion: String
        let previousVersions: [String]
        let error: String?
    }
    struct Authentication: Decodable, Equatable, Sendable {
        struct Field: Decodable, Identifiable, Equatable, Sendable {
            let ref: String; let name: String; let env: String?; let required: Bool; let secret: Bool; let placeholder: String?
            var id: String { ref }
        }
        struct Method: Decodable, Identifiable, Equatable, Sendable {
            let id: String; let name: String; let kind: String; let fields: [Field]
        }
        let methods: [Method]; let selectedMethod: String?; let status: String; let missingFields: [String]
    }
    struct Compatibility: Decodable, Equatable, Sendable {
        let status: String; let checkedAt: String?; let message: String?
    }
    let id: String
    let isDefault: Bool
    let name: String
    let version: String
    let description: String?
    let publisher: String
    let verified: Bool
    let protocolName: String
    let source: String
    let graph: Graph
    let available: Bool
    let unavailableReason: String?
    let installation: Installation
    let auth: Authentication
    let compatibility: Compatibility
    let capabilities: [Capability]
    let driver: Driver
    enum CodingKeys: String, CodingKey {
        case id, isDefault, name, version, description, publisher, verified, source, graph, available, unavailableReason, installation, auth, compatibility, capabilities, driver
        case protocolName = "protocol"
    }
}

struct MobileCommandResult: Decodable, Equatable, Sendable {
    let kind: String
    let text: String?
}

struct MobileCommandExecution: Decodable, Equatable, Sendable {
    let commandId: String
    let result: MobileCommandResult
}

struct MobileQueuedItem: Identifiable, Equatable, Sendable {
    let id: String
    let placement: String
    let message: MobileJSONValue

    init?(json: MobileJSONValue) {
        guard let id = json["id"]?.stringValue,
              let placement = json["placement"]?.stringValue,
              let message = json["message"] else { return nil }
        self.id = id
        self.placement = placement
        self.message = message
    }

    var text: String {
        message["content"]?.arrayValue?.compactMap { block in
            block["type"]?.stringValue == "text" ? block["text"]?.stringValue : nil
        }.joined(separator: "\n") ?? ""
    }
}

struct MobileQuestionAnswer: Encodable, Equatable, Sendable {
    let id: String
    let selected: [String]
    let custom: String?
}

struct MobileApproval: Identifiable, Equatable, Sendable {
    let rpcId: String
    let sessionId: String
    let approvalId: String
    let toolName: String
    let reason: String?
    var id: String { approvalId }
}

struct MobileQuestion: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let question: String
    let detail: String?
    let options: [MobileQuestionOption]?
    let multiSelect: Bool?
}

struct MobileQuestionOption: Identifiable, Codable, Equatable, Sendable {
    let label: String
    let description: String?
    var id: String { label }
}

struct MobilePendingQuestion: Identifiable, Equatable, Sendable {
    let rpcId: String
    let sessionId: String
    let questions: [MobileQuestion]
    var id: String { rpcId }
}

struct MobileImportItem: Decodable, Sendable {
    let sessionId: String
    let sourceSessionId: String?
    let source: String
    let root: Bool
}

struct MobileGoalRef: Codable, Equatable, Sendable {
    let id: String
    let revision: Int
}

struct MobileGoalView: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let revision: Int
    let objective: String
    let phase: String
    let maxGoalRounds: Int?
    let activation: String?
}

struct MobileGoalProjection: Codable, Equatable, Sendable {
    let goal: MobileGoalView?
    let roundsStarted: Int?
    let createdAt: Double?
    let updatedAt: Double?
}

struct MobilePlanProjection: Codable, Equatable, Sendable {
    let active: Bool
    let pending: Bool
}

struct MobileSkillEntry: Decodable, Identifiable, Equatable, Sendable {
    let name: String
    let description: String
    let whenToUse: String?
    let modelInvocable: Bool
    var id: String { name }
}

struct MobileSubagentEntry: Identifiable, Equatable, Sendable {
    let id: String
    let kind: String
    let activity: String?
    let hasChildren: Bool
    let mode: String?
    let label: String?
    let reason: String?

    init?(json: MobileJSONValue) {
        guard let id = json["id"]?.stringValue,
              let kind = json["kind"]?.stringValue else { return nil }
        self.id = id
        self.kind = kind
        self.activity = json["activity"]?.stringValue
        self.hasChildren = json["hasChildren"]?.boolValue ?? false
        self.mode = json["mode"]?.stringValue
        self.label = json["label"]?.stringValue
        self.reason = json["reason"]?.stringValue
    }
}

struct MobileSubagentCatalog: Equatable, Sendable {
    let entries: [MobileSubagentEntry]
    let parentAvailable: Bool
}

struct MobileSettingsSecret: Codable, Equatable, Sendable {
    let path: [String]
    let set: Bool
}

struct MobileSettingsNamespace: Codable, Identifiable, Equatable, Sendable {
    let ns: String
    let schema: MobileJSONValue
    let value: MobileJSONValue
    let base: MobileJSONValue?
    let user: MobileJSONValue?
    let applies: String
    let secrets: [MobileSettingsSecret]
    let revision: Int
    var id: String { ns }
}

struct MobileSettingsCatalog: Decodable, Equatable, Sendable {
    let writable: Bool
    let hasDocument: Bool
    let namespaces: [MobileSettingsNamespace]
}

struct MobileConfigurableProvider: Decodable, Identifiable, Equatable, Sendable {
    let provider: String
    let displayName: String
    let settingsNs: String
    let settingsPath: [String]
    let active: Bool
    let declared: Bool?
    var id: String { provider }
}

struct MobilePluginInventoryEntry: Identifiable, Equatable, Sendable {
    let entryId: String
    let moduleName: String?
    let enabled: Bool
    let fiberPhase: String?
    var id: String { entryId }

    init?(json: MobileJSONValue) {
        guard let entryId = json["entryId"]?.stringValue,
              let enabled = json["enabled"]?.boolValue else { return nil }
        self.entryId = entryId
        self.moduleName = json["moduleName"]?.stringValue
        self.enabled = enabled
        self.fiberPhase = json["fiberPhase"]?.stringValue
    }
}

struct MobileNativeDevice: Codable, Identifiable, Equatable, Sendable {
    let deviceId: String
    let name: String
    let surface: String
    let appVersion: String?
    let createdAt: Double
    let expiresAt: Double
    let lastSeenAt: Double
    var id: String { deviceId }
}

struct MobileServerRequest: Decodable, Sendable {
    let type: String
    let rpcId: String
    let method: String
    let payload: MobileJSONValue
}

public struct XHandshake: Codable, Sendable {
    public let ok: Bool
    public let product: String
    public let protocolVersion: String
    public let minimumClientProtocol: String
    public let host: String
    public let surface: String
    public let embeddedRuntimeId: String?
    public let embeddedProcessId: Int32?
}

public struct XCapabilities: Codable, Sendable {
    public struct Api: Codable, Sendable {
        public let base: String
        public let hostEvents: String
        public let muxEvents: String
    }
    public struct Features: Codable, Sendable {
        public let apiProxy: Bool
        public let typert: Bool
        public let remotePlugin: Bool
        public let voicePlugin: Bool
        public let localVoice: Bool
        public let imageGenerationExtension: Bool?
    }
    public struct Pairing: Codable, Sendable {
        public let supported: Bool
        public let kind: String
        public let durable: Bool
    }
    public struct Contracts: Codable, Sendable {
        public let sessions: Bool
        public let workspaces: Bool
        public let interactions: Bool
        public let settings: Bool
        public let providers: Bool
        public let migration: Bool
        public let sandbox: Bool
    }
    public struct Transports: Codable, Sendable {
        public let lan: Bool
        public let tailscale: Bool
        public let relay: Bool
    }
    public struct Voice: Codable, Sendable {
        public struct Provider: Codable, Sendable, Identifiable {
            public let id: String
            public let name: String
            public let platforms: [String]
            public let operations: [String]
            public let locality: String
            public let streaming: Bool
            public let interruptible: Bool
            public let quality: String
        }
        public let contract: String
        public let transcriptAuthority: String
        public let providers: [Provider]
    }
    public let product: String
    public let protocolVersion: String
    public let host: String
    public let surface: String
    public let api: Api
    public let features: Features
    public let contracts: Contracts
    public let voice: Voice?
    public let pairing: Pairing
    public let transports: Transports
    public let surfaces: [String]
}

struct MobilePairReceipt: Decodable, Sendable {
    let deviceId: String
    let token: String
    let expiresAt: Double
    let createdAt: Double
}

private struct MobileEmpty: Encodable, Sendable {}

private struct MobileRpcRequest<Payload: Encodable>: Encodable {
    let type = "client-request"
    let rpcId: String
    let method: String
    let payload: Payload
}

private struct MobileRpcResponse<Value: Decodable>: Decodable {
    struct Result: Decodable {
        struct Failure: Decodable { let code: String; let message: String }
        let ok: Bool
        let value: Value?
        let error: Failure?
    }
    let type: String
    let rpcId: String
    let result: Result
}

private struct MobileClientResponse<Payload: Encodable>: Encodable {
    struct Result: Encodable { let ok = true; let value: Payload }
    let type = "client-response"
    let rpcId: String
    let result: Result
}

enum MobileApiError: Error, LocalizedError, Sendable {
    case transport(String)
    case host(String, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case let .transport(message): message
        case let .host(code, message): "\(code): \(message)"
        case .invalidResponse: "The DSH Host returned an invalid response."
        }
    }
}

public actor XIOSClient {
    public nonisolated let baseURL: URL
    private let bearerToken: String?
    private let session: URLSession

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:3080")!,
        bearerToken: String? = nil
    ) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        session = URLSession(configuration: configuration)
    }

    private func request(
        _ path: String,
        method: String = "GET",
        body: Data? = nil,
        authorize: Bool = false
    ) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "content-type") }
        if authorize, let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MobileApiError.transport("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) for \(path)")
        }
        return data
    }

    private func rpc<Payload: Encodable & Sendable, Value: Decodable & Sendable>(
        _ method: String,
        _ payload: Payload,
        timeout: TimeInterval? = nil
    ) async throws -> Value {
        let rpcId = UUID().uuidString
        var request = URLRequest(url: baseURL.appending(path: "/api/\(method)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let timeout { request.timeoutInterval = timeout }
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "authorization")
        }
        request.httpBody = try JSONEncoder().encode(MobileRpcRequest(rpcId: rpcId, method: method, payload: payload))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MobileApiError.transport("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) for \(method)")
        }
        let envelope = try JSONDecoder().decode(MobileRpcResponse<Value>.self, from: data)
        guard envelope.type == "server-response", envelope.rpcId == rpcId else { throw MobileApiError.invalidResponse }
        if envelope.result.ok, let value = envelope.result.value { return value }
        throw MobileApiError.host(
            envelope.result.error?.code ?? "unknown",
            envelope.result.error?.message ?? "RPC failed"
        )
    }

    public func handshake() async throws -> XHandshake {
        try JSONDecoder().decode(
            XHandshake.self,
            from: await request("/x-native/v2/health", authorize: true)
        )
    }

    public func capabilities() async throws -> XCapabilities {
        try JSONDecoder().decode(
            XCapabilities.self,
            from: await request("/x-native/v2/capabilities", authorize: true)
        )
    }

    func pair(deviceName: String, code: String) async throws -> MobilePairReceipt {
        struct Payload: Encodable, Sendable { let deviceName: String; let surface = "iphone"; let code: String }
        return try JSONDecoder().decode(
            MobilePairReceipt.self,
            from: await request(
                "/x-native/v2/pair",
                method: "POST",
                body: JSONEncoder().encode(Payload(deviceName: deviceName, code: code))
            )
        )
    }

    func workspaces() async throws -> (items: [MobileWorkspace], archived: Set<String>) {
        struct Value: Decodable, Sendable { let items: [MobileWorkspace]; let archivedSessionIds: [String] }
        let value: Value = try await rpc("workspace.list", MobileEmpty())
        return (value.items, Set(value.archivedSessionIds))
    }

    func listDirectory(path: String? = nil) async throws -> MobileDirectoryListing {
        struct Payload: Encodable, Sendable { let path: String? }
        return try await rpc("host.listDirectory", Payload(path: path))
    }

    func createDirectory(parent: String, name: String) async throws -> String {
        struct Payload: Encodable, Sendable { let path: String; let name: String }
        struct Value: Decodable, Sendable { let path: String }
        let value: Value = try await rpc("host.createDirectory", Payload(path: parent, name: name))
        return value.path
    }

    func createWorkspace(path: String) async throws -> MobileWorkspace {
        struct Payload: Encodable, Sendable { let path: String }
        struct Value: Decodable, Sendable { let workspace: MobileWorkspace }
        let value: Value = try await rpc("workspace.create", Payload(path: path))
        return value.workspace
    }

    func sessions() async throws -> [MobileSession] {
        struct Payload: Encodable, Sendable { let cursor: String? = nil }
        struct Value: Decodable, Sendable { let items: [MobileSession] }
        let value: Value = try await rpc("session.list", Payload())
        return value.items
    }

    func setArchived(sessionId: String, archived: Bool) async throws -> Set<String> {
        struct Payload: Encodable, Sendable { let sessionId: String }
        struct Value: Decodable, Sendable { let archivedSessionIds: [String] }
        let method = archived ? "workspace.archiveSession" : "workspace.unarchiveSession"
        let value: Value = try await rpc(method, Payload(sessionId: sessionId))
        return Set(value.archivedSessionIds)
    }

    func history(sessionId: String, beforeSeq: Int? = nil) async throws -> MobileHistory {
        struct Payload: Encodable, Sendable { let sessionId: String; let beforeSeq: Int?; let maxMessages = 100 }
        return try await rpc("session.history", Payload(sessionId: sessionId, beforeSeq: beforeSeq))
    }

    func attachmentData(sessionId: String, attachmentId: String) async throws -> Data {
        struct Payload: Encodable, Sendable { let sessionId: String; let attachmentId: String }
        struct Value: Decodable, Sendable { let data: String }
        let value: Value = try await rpc(
            "session.attachment",
            Payload(sessionId: sessionId, attachmentId: attachmentId)
        )
        guard let data = Data(base64Encoded: value.data) else {
            throw MobileApiError.host("attachment-error", "The attachment data is not valid base64")
        }
        return data
    }

    func models(sessionId: String) async throws -> MobileSessionModels {
        struct Payload: Encodable, Sendable { let sessionId: String }
        return try await rpc("session.models", Payload(sessionId: sessionId))
    }

    func selectModel(sessionId: String, selection: MobileModelSelection) async throws -> MobileModelSelection {
        struct Payload: Encodable, Sendable {
            let sessionId: String
            let provider: String
            let model: String
            let reasoningEffort: String?
        }
        struct Value: Decodable, Sendable { let selected: MobileModelSelection }
        let value: Value = try await rpc(
            "session.selectModel",
            Payload(
                sessionId: sessionId,
                provider: selection.provider,
                model: selection.model,
                reasoningEffort: selection.reasoningEffort
            )
        )
        return value.selected
    }

    func setHarnessConfig(
        sessionId: String,
        configId: String,
        value: MobileJSONValue
    ) async throws -> [MobileHarnessConfigOption] {
        struct Payload: Encodable, Sendable {
            let sessionId: String
            let configId: String
            let value: MobileJSONValue
        }
        struct Value: Decodable, Sendable { let options: [MobileHarnessConfigOption] }
        let result: Value = try await rpc(
            "session.setHarnessConfig",
            Payload(sessionId: sessionId, configId: configId, value: value)
        )
        return result.options
    }

    func renameSession(_ sessionId: String, title: String) async throws -> (title: String, seq: Int) {
        struct Payload: Encodable, Sendable { let sessionId: String; let title: String }
        struct Value: Decodable, Sendable { let title: String; let seq: Int }
        let value: Value = try await rpc("session.rename", Payload(sessionId: sessionId, title: title))
        return (value.title, value.seq)
    }

    func forkSession(_ sessionId: String) async throws -> String {
        struct Payload: Encodable, Sendable { let sessionId: String }
        struct Value: Decodable, Sendable { let sessionId: String }
        let value: Value = try await rpc("session.fork", Payload(sessionId: sessionId))
        return value.sessionId
    }

    func executeCommand(sessionId: String, line: String) async throws -> MobileCommandExecution {
        struct Arguments: Encodable, Sendable { let agentId: String; let line: String }
        struct Payload: Encodable, Sendable { let args: Arguments }
        return try await rpc(
            "commands/execute",
            Payload(args: Arguments(agentId: sessionId, line: line))
        )
    }

    func updateQueue(sessionId: String, itemId: String, action: MobileJSONValue) async throws {
        struct Payload: Encodable, Sendable {
            let sessionId: String
            let itemId: String
            let action: MobileJSONValue
        }
        struct Value: Decodable, Sendable { let accepted: Bool }
        let value: Value = try await rpc(
            "session.updateQueue",
            Payload(sessionId: sessionId, itemId: itemId, action: action)
        )
        guard value.accepted else { throw MobileApiError.host("queue-rejected", "Queue update was not accepted") }
    }

    func agentPresets() async throws -> MobileAgentPresetCatalog {
        try await rpc("agentPreset.list", MobileEmpty())
    }

    func selectAgentPreset(sessionId: String, agentPreset: String) async throws -> String {
        struct Payload: Encodable, Sendable { let sessionId: String; let agentPreset: String }
        struct Value: Decodable, Sendable { let agentPreset: String }
        let value: Value = try await rpc(
            "agentPreset.select",
            Payload(sessionId: sessionId, agentPreset: agentPreset)
        )
        return value.agentPreset
    }

    func harnesses() async throws -> [MobileHarness] {
        struct Payload: Encodable, Sendable { let query: String? = nil }
        struct Value: Decodable, Sendable { let items: [MobileHarness] }
        let value: Value = try await rpc("harness.list", Payload())
        return value.items
    }

    func selectDefaultHarness(_ id: String) async throws -> [MobileHarness] {
        struct Payload: Encodable, Sendable { let action = "default"; let id: String; let authMethod: String? = nil; let pack: MobileJSONValue? = nil }
        struct Value: Decodable, Sendable { let items: [MobileHarness] }
        let value: Value = try await rpc("harness.mutate", Payload(id: id))
        return value.items
    }

    func installHarness(_ id: String) async throws -> [MobileHarness] {
        struct Payload: Encodable, Sendable { let action = "install"; let id: String; let authMethod: String? = nil; let pack: MobileJSONValue? = nil }
        struct Value: Decodable, Sendable { let items: [MobileHarness] }
        let value: Value = try await rpc("harness.mutate", Payload(id: id))
        return value.items
    }

    func createSession(workspaceId: String?, harnessId: String? = nil) async throws -> String {
        struct Payload: Encodable, Sendable { let workspaceId: String?; let noProject: Bool?; let harnessId: String? }
        struct Value: Decodable, Sendable { let sessionId: String; let harnessId: String }
        let value: Value = try await rpc("session.create", Payload(workspaceId: workspaceId, noProject: workspaceId == nil ? true : nil, harnessId: harnessId))
        return value.sessionId
    }

    func prompt(sessionId: String, text: String, images: [MobilePendingImage], mode: String) async throws {
        struct Payload: Encodable, Sendable {
            let sessionId: String
            let mode: String
            let content: [MobileJSONValue]
            let clientTimeZone: String?
        }
        struct Value: Decodable, Sendable { let accepted: Bool }
        var content: [MobileJSONValue] = []
        if !text.isEmpty { content.append(.object(["type": .string("text"), "text": .string(text)])) }
        content.append(contentsOf: images.map { image in
            .object([
                "type": .string("image"),
                "mediaType": .string(image.mediaType),
                "data": .string(image.data.base64EncodedString()),
                "name": .string(image.name),
            ])
        })
        let value: Value = try await rpc(
            "session.prompt",
            Payload(sessionId: sessionId, mode: mode, content: content, clientTimeZone: TimeZone.current.identifier)
        )
        guard value.accepted else { throw MobileApiError.host("prompt-rejected", "Prompt was not accepted") }
    }

    func cancel(sessionId: String) async throws {
        struct Payload: Encodable, Sendable { let sessionId: String }
        struct Value: Decodable, Sendable { let accepted: Bool }
        let value: Value = try await rpc("session.cancel", Payload(sessionId: sessionId))
        guard value.accepted else { throw MobileApiError.host("cancel-rejected", "Cancel was not accepted") }
    }

    func skills(sessionId: String) async throws -> [MobileSkillEntry] {
        struct Payload: Encodable, Sendable { let sessionId: String }
        struct Value: Decodable, Sendable { let skills: [MobileSkillEntry] }
        let value: Value = try await rpc("skill.list", Payload(sessionId: sessionId))
        return value.skills
    }

    func commandDirectory(sessionId: String) async throws -> [MobileJSONValue] {
        struct Arguments: Encodable, Sendable { let agentId: String }
        struct Payload: Encodable, Sendable { let args: Arguments }
        return try await rpc("commands/list", Payload(args: Arguments(agentId: sessionId)))
    }

    func subagents(parentSessionId: String) async throws -> MobileSubagentCatalog {
        struct Payload: Encodable, Sendable { let parentSessionId: String }
        let value: MobileJSONValue = try await rpc(
            "subagent.list",
            Payload(parentSessionId: parentSessionId)
        )
        return MobileSubagentCatalog(
            entries: value["entries"]?.arrayValue?.compactMap(MobileSubagentEntry.init(json:)) ?? [],
            parentAvailable: value["parentAvailable"]?.boolValue ?? false
        )
    }

    func subagentHistory(
        parentSessionId: String,
        childSessionId: String,
        mode: String,
        beforeSeq: Int? = nil
    ) async throws -> MobileHistory {
        struct Payload: Encodable, Sendable {
            let parentSessionId: String
            let childSessionId: String
            let mode: String
            let beforeSeq: Int?
            let maxMessages = 100
        }
        return try await rpc(
            "subagent.history",
            Payload(
                parentSessionId: parentSessionId,
                childSessionId: childSessionId,
                mode: mode,
                beforeSeq: beforeSeq
            )
        )
    }

    func promptSubagent(parentSessionId: String, childSessionId: String, text: String) async throws {
        struct Payload: Encodable, Sendable {
            let parentSessionId: String
            let childSessionId: String
            let mode = "continuable"
            let content: [MobileJSONValue]
            let clientTimeZone: String?
        }
        struct Value: Decodable, Sendable { let messageId: String }
        let _: Value = try await rpc(
            "subagent.prompt",
            Payload(
                parentSessionId: parentSessionId,
                childSessionId: childSessionId,
                content: [.object(["type": .string("text"), "text": .string(text)])],
                clientTimeZone: TimeZone.current.identifier
            )
        )
    }

    func interruptSubagent(parentSessionId: String, childSessionId: String) async throws {
        struct Payload: Encodable, Sendable {
            let parentSessionId: String
            let childSessionId: String
            let mode = "continuable"
        }
        struct Value: Decodable, Sendable { let accepted: Bool }
        let value: Value = try await rpc(
            "subagent.interrupt",
            Payload(parentSessionId: parentSessionId, childSessionId: childSessionId)
        )
        guard value.accepted else {
            throw MobileApiError.host("subagent-rejected", "The subagent interrupt was not accepted")
        }
    }

    func createGoal(sessionId: String, objective: String, maxRounds: Int?) async throws -> MobileGoalRef {
        struct Payload: Encodable, Sendable {
            let sessionId: String
            let objective: String
            let maxGoalRounds: Int?
        }
        struct Value: Decodable, Sendable { let ref: MobileGoalRef }
        let value: Value = try await rpc(
            "goal.create",
            Payload(sessionId: sessionId, objective: objective, maxGoalRounds: maxRounds)
        )
        return value.ref
    }

    func mutateGoal(sessionId: String, verb: String, ref: MobileGoalRef) async throws -> MobileGoalRef? {
        struct Payload: Encodable, Sendable { let sessionId: String; let ref: MobileGoalRef }
        if verb == "clear" {
            struct Value: Decodable, Sendable { let cleared: Bool }
            let _: Value = try await rpc("goal.clear", Payload(sessionId: sessionId, ref: ref))
            return nil
        }
        struct Value: Decodable, Sendable { let ref: MobileGoalRef }
        let value: Value = try await rpc("goal.\(verb)", Payload(sessionId: sessionId, ref: ref))
        return value.ref
    }

    func settings() async throws -> MobileSettingsCatalog {
        try await rpc("settings.describe", MobileEmpty())
    }

    func replaceSettings(
        namespace: String,
        section: MobileJSONValue,
        revision: Int
    ) async throws -> MobileSettingsNamespace {
        struct Payload: Encodable, Sendable {
            let ns: String
            let section: MobileJSONValue
            let expectedRevision: Int
        }
        return try await rpc(
            "settings.replace",
            Payload(ns: namespace, section: section, expectedRevision: revision)
        )
    }

    func configurableProviders() async throws -> [MobileConfigurableProvider] {
        struct Value: Decodable, Sendable { let providers: [MobileConfigurableProvider] }
        let value: Value = try await rpc("llm.providers", MobileEmpty())
        return value.providers
    }

    func pluginInventory() async throws -> [MobilePluginInventoryEntry] {
        struct Payload: Encodable, Sendable { let args: MobileJSONValue = .object([:]) }
        let value: MobileJSONValue = try await rpc("pluginInventory/list", Payload())
        return value["entries"]?.arrayValue?.compactMap(MobilePluginInventoryEntry.init(json:)) ?? []
    }

    func setCredential(ref: String, value: String) async throws {
        struct Payload: Encodable, Sendable { let ref: String; let value: String }
        let _: MobileJSONValue = try await rpc("credentials.set", Payload(ref: ref, value: value))
    }

    func unsetCredential(ref: String) async throws {
        struct Payload: Encodable, Sendable { let ref: String }
        let _: MobileJSONValue = try await rpc("credentials.unset", Payload(ref: ref))
    }

    func devices() async throws -> [MobileNativeDevice] {
        try JSONDecoder().decode(
            [MobileNativeDevice].self,
            from: await request("/x-native/v2/devices", authorize: true)
        )
    }

    func revokeDevice(_ deviceId: String) async throws -> Bool {
        struct Payload: Encodable, Sendable { let deviceId: String }
        struct Value: Decodable, Sendable { let revoked: Bool }
        let data = try await request(
            "/x-native/v2/revoke",
            method: "POST",
            body: JSONEncoder().encode(Payload(deviceId: deviceId)),
            authorize: true
        )
        return try JSONDecoder().decode(Value.self, from: data).revoked
    }

    func answer(_ approval: MobileApproval, allow: Bool) async throws {
        struct Value: Encodable, Sendable { let sessionId: String; let approvalId: String; let outcome: String }
        let body = MobileClientResponse(
            rpcId: approval.rpcId,
            result: .init(value: Value(
                sessionId: approval.sessionId,
                approvalId: approval.approvalId,
                outcome: allow ? "allowed-once" : "rejected"
            ))
        )
        _ = try await request(
            "/api/respond",
            method: "POST",
            body: JSONEncoder().encode(body),
            authorize: true
        )
    }

    func answer(_ question: MobilePendingQuestion, answers: [MobileQuestionAnswer]) async throws {
        struct Wrapped: Encodable, Sendable { let answers: [MobileQuestionAnswer] }
        struct Value: Encodable, Sendable { let sessionId: String; let answer: Wrapped }
        let body = MobileClientResponse(
            rpcId: question.rpcId,
            result: .init(value: Value(
                sessionId: question.sessionId,
                answer: Wrapped(answers: answers)
            ))
        )
        _ = try await request(
            "/api/respond",
            method: "POST",
            body: JSONEncoder().encode(body),
            authorize: true
        )
    }

    func importFiles(_ files: [(String, Data)], workspaceId: String?) async throws -> [MobileImportItem] {
        struct File: Encodable, Sendable { let name: String; let data: String }
        struct Payload: Encodable, Sendable { let workspaceId: String?; let format = "auto"; let files: [File] }
        struct Value: Decodable, Sendable { let items: [MobileImportItem] }
        let value: Value = try await rpc(
            "session.import",
            Payload(
                workspaceId: workspaceId,
                files: files.map { File(name: $0.0, data: $0.1.base64EncodedString()) }
            ),
            timeout: 300
        )
        return value.items
    }

    func exportSession(_ sessionId: String) async throws -> Data {
        var components = URLComponents(
            url: baseURL.appending(path: "/api/session.export"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "sessionId", value: sessionId),
            URLQueryItem(name: "includeDescendants", value: "true"),
        ]
        var request = URLRequest(url: components.url!)
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw MobileApiError.transport("Session export failed")
        }
        return data
    }
}
