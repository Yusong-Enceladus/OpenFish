import Foundation

// MARK: - JSON wire value

/// Lossless JSON value used at DSH's merge-extensible event and projection boundaries.
///
/// The native client deliberately keeps unknown fields instead of copying every plugin's
/// business schema into Swift. Stable RPC responses below remain strongly typed.
enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
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

    subscript(key: String) -> JSONValue? {
        guard case let .object(value) = self else { return nil }
        return value[key]
    }

    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        guard case let .number(value) = self, value.rounded() == value else { return nil }
        return Int(value)
    }

    var doubleValue: Double? {
        guard case let .number(value) = self else { return nil }
        return value
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(type, from: data)
    }

    var prettyJSON: String {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8) else { return "{}" }
        return text
    }
}

// MARK: - RPC envelopes

struct EmptyPayload: Encodable, Sendable {}

private struct RpcRequestEnvelope<Payload: Encodable>: Encodable {
    let type = "client-request"
    let rpcId: String
    let method: String
    let payload: Payload
}

private struct RpcResponseEnvelope<Value: Decodable>: Decodable {
    struct Result: Decodable {
        struct Failure: Decodable {
            let code: String
            let message: String
            let details: JSONValue?
        }

        let ok: Bool
        let value: Value?
        let error: Failure?
    }

    let type: String
    let rpcId: String
    let result: Result
}

private struct ClientResponseEnvelope<Payload: Encodable>: Encodable {
    struct Result: Encodable {
        let ok = true
        let value: Payload
    }

    let type = "client-response"
    let rpcId: String
    let result: Result
}

struct DshServerRequest: Decodable, Sendable {
    let type: String
    let rpcId: String
    let method: String
    let payload: JSONValue
}

struct DshResponseReceipt: Decodable, Sendable {
    let accepted: Bool
    let reason: String?
}

// MARK: - Stable DSH projections

struct WorkspaceView: Codable, Identifiable, Equatable, Sendable {
    let workspaceId: String
    let path: String
    let title: String
    let sessionIds: [String]
    let createdAt: String
    let updatedAt: String

    var id: String { workspaceId }
}

struct WorkspaceList: Decodable, Sendable {
    let items: [WorkspaceView]
    let archivedSessionIds: [String]
}

struct HostDirectoryEntry: Codable, Identifiable, Equatable, Sendable {
    let name: String
    let path: String
    let hidden: Bool

    var id: String { path }
}

struct HostDirectoryListing: Codable, Equatable, Sendable {
    let path: String
    let home: String
    let crumbs: [HostDirectoryEntry]
    let entries: [HostDirectoryEntry]
    let truncated: Bool
}

struct SessionProjectionsBlock: Codable, Equatable, Sendable {
    let asOfSeq: Int
    let values: [String: JSONValue]
}

struct SessionSummary: Codable, Identifiable, Equatable, Sendable {
    let sessionId: String
    let harnessId: String?
    var updatedAt: Double
    var running: Bool
    var blank: Bool
    let parentSessionId: String?
    let origin: String?
    let cwd: String?
    let agentPreset: String?
    let projections: SessionProjectionsBlock?

    var id: String { sessionId }
}

struct SessionEvent: Codable, Identifiable, Equatable, Sendable {
    let type: String
    let seq: Int
    let time: Double
    let data: JSONValue
    let sourceEventSeqs: [Int]?
    let surfaceOp: JSONValue?
    let ignorable: Bool?

    var id: Int { seq }
}

struct SessionEventRecord: Codable, Identifiable, Equatable, Sendable {
    let event: SessionEvent
    let view: JSONValue?

    var id: Int { event.seq }
}

struct SessionHistory: Decodable, Sendable {
    let events: [SessionEventRecord]
    let hasMore: Bool
    let projections: SessionProjectionsBlock?
}

struct SessionImportItem: Decodable, Identifiable, Sendable {
    let sessionId: String
    let sourceSessionId: String?
    let source: String
    let root: Bool

    var id: String { sessionId }
}

struct HostDescription: Decodable, Equatable, Sendable {
    let version: String
    let cwd: String
    let provider: String?
    let model: String?
    let attachedSessions: Int
    let canOpenPath: Bool
}

struct ModelSelection: Codable, Equatable, Sendable {
    let provider: String
    let model: String
    let reasoningEffort: String?
}

struct PermissionOption: Codable, Identifiable, Equatable, Sendable {
    let value: String
    let name: String
    let description: String?

    var id: String { value }
}

struct PermissionSelect: Codable, Equatable, Sendable {
    let options: [PermissionOption]
    let currentValue: String
}

struct ModelReasoningEffort: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let isDefault: Bool
    let name: String
    let description: String?

    private enum CodingKeys: String, CodingKey {
        case id, isDefault, name, description
    }

    init(id: String, isDefault: Bool = false, name: String, description: String?) {
        self.id = id
        self.isDefault = isDefault
        self.name = name
        self.description = description
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        description = try container.decodeIfPresent(String.self, forKey: .description)
    }
}

struct ModelReasoning: Decodable, Equatable, Sendable {
    let efforts: [ModelReasoningEffort]
    let defaultEffort: String?
}

struct CatalogModel: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String?
    let reasoning: ModelReasoning?
}

struct ModelProviderGroup: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let models: [CatalogModel]
}

struct ModelCatalogFailure: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let message: String
}

struct HarnessConfigValue: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String?
    let group: String?
    let groupName: String?
}

struct HarnessConfigOption: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String?
    let category: String?
    let type: String
    let currentValue: JSONValue
    let values: [HarnessConfigValue]
}

struct SessionModels: Decodable, Equatable, Sendable {
    let current: ModelSelection
    let routable: Bool
    let groups: [ModelProviderGroup]
    let failures: [ModelCatalogFailure]
    let harnessOptions: [HarnessConfigOption]?

    init(
        current: ModelSelection,
        routable: Bool,
        groups: [ModelProviderGroup],
        failures: [ModelCatalogFailure],
        harnessOptions: [HarnessConfigOption]? = nil
    ) {
        self.current = current
        self.routable = routable
        self.groups = groups
        self.failures = failures
        self.harnessOptions = harnessOptions
    }
}

struct HostModelCatalog: Decodable, Equatable, Sendable {
    let groups: [ModelProviderGroup]
    let failures: [ModelCatalogFailure]
}

struct SessionSearchItem: Decodable, Identifiable, Equatable, Sendable {
    let sessionId: String
    let snippet: String
    var id: String { sessionId }
}

struct SessionSearchResults: Decodable, Equatable, Sendable {
    let items: [SessionSearchItem]
    let hasMore: Bool
}

struct PromptImage: Encodable, Equatable, Sendable {
    let mediaType: String
    let data: String
    let name: String?
}

struct QueuedInboxItem: Identifiable, Equatable, Sendable {
    let id: String
    let placement: String
    let message: JSONValue

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue,
              let placement = json["placement"]?.stringValue,
              let message = json["message"] else { return nil }
        self.id = id
        self.placement = placement
        self.message = message
    }

    var text: String {
        let content = message["content"]?.arrayValue ?? []
        return content.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
    }
}

struct BackgroundJob: Identifiable, Equatable, Sendable {
    let id: String
    let kind: String
    let label: String
    let status: String
    let detail: String?
    let startedAt: Double
    let finishedAt: Double?

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue,
              let kind = json["kind"]?.stringValue,
              let label = json["label"]?.stringValue,
              let status = json["status"]?.stringValue else { return nil }
        self.id = id
        self.kind = kind
        self.label = label
        self.status = status
        self.detail = json["detail"]?.stringValue
        self.startedAt = json["startedAt"]?.doubleValue ?? 0
        self.finishedAt = json["finishedAt"]?.doubleValue
    }
}

struct QuestionOption: Codable, Identifiable, Equatable, Sendable {
    let label: String
    let description: String?
    var id: String { label }
}

struct QuestionItem: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let question: String
    let detail: String?
    let header: String?
    let options: [QuestionOption]?
    let multiSelect: Bool?
    let intent: JSONValue?
}

struct PendingQuestion: Identifiable, Equatable, Sendable {
    let rpcId: String
    let sessionId: String
    let questions: [QuestionItem]
    var id: String { rpcId }
}

struct QuestionAnswerItem: Encodable, Equatable, Sendable {
    let id: String
    let selected: [String]
    let custom: String?
}

struct GoalRef: Codable, Equatable, Sendable {
    let id: String
    let revision: Int
}

struct GoalView: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let revision: Int
    let objective: String
    let phase: String
    let maxGoalRounds: Int?
    let activation: String?
}

struct GoalProjection: Codable, Equatable, Sendable {
    let goal: GoalView?
    let roundsStarted: Int?
    let createdAt: Double?
    let updatedAt: Double?
}

struct PlanProjection: Codable, Equatable, Sendable {
    let active: Bool
    let pending: Bool
}

struct SkillEntry: Decodable, Identifiable, Equatable, Sendable {
    let name: String
    let description: String
    let whenToUse: String?
    let modelInvocable: Bool
    var id: String { name }
}

struct AgentPresetEntry: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let trust: String
    let isDefault: Bool
    let name: String?
    let description: String?
    let broken: String?
}

struct AgentPresetCatalog: Decodable, Equatable, Sendable {
    let presets: [AgentPresetEntry]
    let authorable: Bool
    let hasDocument: Bool
}

struct HarnessGraphNode: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let kind: String
    let title: String
    let editable: Bool
    let config: [String: JSONValue]?
}

struct HarnessGraphEdge: Codable, Equatable, Sendable {
    let from: String
    let to: String
}

struct HarnessGraph: Codable, Equatable, Sendable {
    let level: String
    let nodes: [HarnessGraphNode]
    let edges: [HarnessGraphEdge]
}

struct HarnessCatalogEntry: Decodable, Identifiable, Equatable, Sendable {
    struct Installation: Decodable, Equatable, Sendable {
        let status: String
        let installedVersion: String?
        let availableVersion: String
        let previousVersions: [String]
        let error: String?
    }
    struct Authentication: Decodable, Equatable, Sendable {
        struct Field: Decodable, Identifiable, Equatable, Sendable {
            let ref: String
            let name: String
            let env: String?
            let required: Bool
            let secret: Bool
            let placeholder: String?
            var id: String { ref }
        }
        struct Method: Decodable, Identifiable, Equatable, Sendable {
            struct Terminal: Decodable, Equatable, Sendable {
                let args: [String]
                let env: [String: String]
            }
            let id: String
            let name: String
            let kind: String
            let fields: [Field]
            let terminal: Terminal?

            private enum CodingKeys: String, CodingKey {
                case id, name, kind, fields, terminal
            }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                id = try values.decode(String.self, forKey: .id)
                name = try values.decode(String.self, forKey: .name)
                kind = try values.decode(String.self, forKey: .kind)
                fields = try values.decodeIfPresent([Field].self, forKey: .fields) ?? []
                terminal = try values.decodeIfPresent(Terminal.self, forKey: .terminal)
            }
        }
        let methods: [Method]
        let selectedMethod: String?
        let status: String
        let missingFields: [String]
    }
    struct Compatibility: Decodable, Equatable, Sendable {
        let status: String
        let checkedAt: String?
        let message: String?
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
    let graph: HarnessGraph
    let available: Bool
    let unavailableReason: String?
    let installation: Installation
    let auth: Authentication
    let compatibility: Compatibility

    enum CodingKeys: String, CodingKey {
        case id, isDefault, name, version, description, publisher, verified, source, graph, available, unavailableReason, installation, auth, compatibility
        case protocolName = "protocol"
    }
}

struct SubagentEntry: Identifiable, Equatable, Sendable {
    let id: String
    let kind: String
    let activity: String?
    let hasChildren: Bool
    let mode: String?
    let label: String?
    let reason: String?

    init?(json: JSONValue) {
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

struct SubagentCatalog: Equatable, Sendable {
    let entries: [SubagentEntry]
    let parentAvailable: Bool
}

struct SettingsSecretView: Codable, Equatable, Sendable {
    let path: [String]
    let set: Bool
}

struct SettingsNamespaceView: Codable, Identifiable, Equatable, Sendable {
    let ns: String
    let schema: JSONValue
    let value: JSONValue
    let base: JSONValue?
    let user: JSONValue?
    let applies: String
    let secrets: [SettingsSecretView]
    let revision: Int
    var id: String { ns }
}

struct SettingsCatalog: Decodable, Equatable, Sendable {
    let writable: Bool
    let hasDocument: Bool
    let namespaces: [SettingsNamespaceView]
}

struct ConfigurableProvider: Decodable, Identifiable, Equatable, Sendable {
    let provider: String
    let displayName: String
    let settingsNs: String
    let settingsPath: [String]
    let active: Bool
    let declared: Bool?
    var id: String { provider }
}

struct PluginInventoryEntry: Identifiable, Equatable, Sendable {
    let entryId: String
    let moduleName: String?
    let enabled: Bool
    let fiberPhase: String?
    var id: String { entryId }

    init?(json: JSONValue) {
        guard let entryId = json["entryId"]?.stringValue,
              let enabled = json["enabled"]?.boolValue else { return nil }
        self.entryId = entryId
        self.moduleName = json["moduleName"]?.stringValue
        self.enabled = enabled
        self.fiberPhase = json["fiberPhase"]?.stringValue
    }
}

struct SessionPromptReceipt: Sendable {
    let rpcId: String
}

struct DshCommandResult: Decodable, Equatable, Sendable {
    let kind: String
    let text: String?
    let sourceEventSeq: Int?
}

struct DshCommandExecution: Decodable, Equatable, Sendable {
    let commandId: String
    let result: DshCommandResult
}

struct PendingApproval: Identifiable, Equatable, Sendable {
    let rpcId: String
    let sessionId: String
    let approvalId: String
    let toolName: String
    let callId: String?
    let reason: String?

    var id: String { approvalId }
}

// MARK: - DSH API carrier

/// Typed client for the existing DSH `/api` Host assembly.
///
/// This is a transport adapter only. It owns no session, workspace, approval, model,
/// or persistence state; those stay authoritative in DSH.
actor DshApiClient {
    nonisolated let baseURL: URL
    private let bearerToken: String?
    private let session: URLSession

    init(
        baseURL: URL = URL(string: "http://127.0.0.1:3080")!,
        bearerToken: String? = nil
    ) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    func rpc<Payload: Encodable & Sendable, Value: Decodable & Sendable>(
        _ method: String,
        _ payload: Payload,
        timeout: TimeInterval? = nil
    ) async throws -> Value {
        let rpcId = UUID().uuidString
        var request = URLRequest(url: baseURL.appending(path: "/api/\(method)"))
        request.httpMethod = "POST"
        if let timeout { request.timeoutInterval = timeout }
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        authorize(&request)
        request.httpBody = try JSONEncoder().encode(
            RpcRequestEnvelope(rpcId: rpcId, method: method, payload: payload)
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DshApiError.transport("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) for \(method)")
        }

        let envelope = try JSONDecoder().decode(RpcResponseEnvelope<Value>.self, from: data)
        guard envelope.type == "server-response", envelope.rpcId == rpcId else {
            throw DshApiError.rpcIdMismatch
        }
        if envelope.result.ok, let value = envelope.result.value { return value }
        throw DshApiError.host(
            envelope.result.error?.code ?? "unknown",
            envelope.result.error?.message ?? "RPC failed"
        )
    }

    func hostDescription() async throws -> HostDescription {
        try await rpc("host.describe", EmptyPayload())
    }

    func workspaces() async throws -> WorkspaceList {
        try await rpc("workspace.list", EmptyPayload())
    }

    func createWorkspace(path: String) async throws -> WorkspaceView {
        struct Payload: Encodable, Sendable { let path: String }
        struct Value: Decodable, Sendable { let workspace: WorkspaceView; let created: Bool }
        let value: Value = try await rpc("workspace.create", Payload(path: path))
        return value.workspace
    }

    func pickDirectory() async throws -> String? {
        struct Value: Decodable, Sendable { let path: String? }
        let value: Value = try await rpc("host.pickDirectory", EmptyPayload())
        return value.path
    }

    func listDirectory(path: String? = nil) async throws -> HostDirectoryListing {
        struct Payload: Encodable, Sendable { let path: String? }
        return try await rpc("host.listDirectory", Payload(path: path))
    }

    func createDirectory(parent: String, name: String) async throws -> String {
        struct Payload: Encodable, Sendable { let path: String; let name: String }
        struct Value: Decodable, Sendable { let path: String }
        let value: Value = try await rpc("host.createDirectory", Payload(path: parent, name: name))
        return value.path
    }

    func archiveSession(_ sessionId: String) async throws -> [String] {
        struct Payload: Encodable, Sendable { let sessionId: String }
        struct Value: Decodable, Sendable { let archivedSessionIds: [String] }
        let value: Value = try await rpc("workspace.archiveSession", Payload(sessionId: sessionId))
        return value.archivedSessionIds
    }

    func unarchiveSession(_ sessionId: String) async throws -> [String] {
        struct Payload: Encodable, Sendable { let sessionId: String }
        struct Value: Decodable, Sendable { let archivedSessionIds: [String] }
        let value: Value = try await rpc("workspace.unarchiveSession", Payload(sessionId: sessionId))
        return value.archivedSessionIds
    }

    func renameWorkspace(_ workspaceId: String, title: String) async throws -> WorkspaceView {
        struct Payload: Encodable, Sendable { let workspaceId: String; let title: String }
        struct Value: Decodable, Sendable { let workspace: WorkspaceView }
        let value: Value = try await rpc("workspace.rename", Payload(workspaceId: workspaceId, title: title))
        return value.workspace
    }

    func deleteWorkspace(_ workspaceId: String) async throws {
        struct Payload: Encodable, Sendable { let workspaceId: String }
        struct Value: Decodable, Sendable { let deleted: Bool }
        let value: Value = try await rpc("workspace.delete", Payload(workspaceId: workspaceId))
        guard value.deleted else { throw DshApiError.host("workspace-delete-rejected", "Workspace was not removed") }
    }

    func moveWorkspace(_ workspaceId: String, before: String?) async throws -> [String] {
        struct Payload: Encodable, Sendable { let workspaceId: String; let beforeWorkspaceId: String? }
        struct Value: Decodable, Sendable { let workspaceIds: [String] }
        let value: Value = try await rpc(
            "workspace.insertBefore",
            Payload(workspaceId: workspaceId, beforeWorkspaceId: before)
        )
        return value.workspaceIds
    }

    func sessions() async throws -> [SessionSummary] {
        struct Payload: Encodable, Sendable { let cursor: String? = nil }
        struct Value: Decodable, Sendable { let items: [SessionSummary] }
        let value: Value = try await rpc("session.list", Payload())
        return value.items
    }

    func searchSessions(_ query: String) async throws -> SessionSearchResults {
        struct Payload: Encodable, Sendable { let query: String }
        return try await rpc("session.search", Payload(query: query))
    }

    func createSession(workspaceId: String? = nil, cwd: String? = nil, agentPreset: String? = nil, harnessId: String? = nil) async throws -> String {
        struct Payload: Encodable, Sendable {
            let workspaceId: String?
            let cwd: String?
            let agentPreset: String?
            let harnessId: String?
        }
        struct Value: Decodable, Sendable { let sessionId: String; let harnessId: String; let agentPreset: String? }
        let value: Value = try await rpc(
            "session.create",
            Payload(workspaceId: workspaceId, cwd: cwd, agentPreset: agentPreset, harnessId: harnessId)
        )
        return value.sessionId
    }

    func importSessions(
        files: [(name: String, data: Data)],
        workspaceId: String?,
        format: String = "auto"
    ) async throws -> [SessionImportItem] {
        struct ImportFile: Encodable, Sendable {
            let name: String
            let data: String
        }
        struct Payload: Encodable, Sendable {
            let workspaceId: String?
            let format: String
            let files: [ImportFile]
        }
        struct Value: Decodable, Sendable { let items: [SessionImportItem] }
        let value: Value = try await rpc(
            "session.import",
            Payload(
                workspaceId: workspaceId,
                format: format,
                files: files.map { ImportFile(name: $0.name, data: $0.data.base64EncodedString()) }
            ),
            timeout: 300
        )
        return value.items
    }

    func history(sessionId: String, beforeSeq: Int? = nil, maxMessages: Int = 100) async throws -> SessionHistory {
        struct Payload: Encodable, Sendable {
            let sessionId: String
            let beforeSeq: Int?
            let maxMessages: Int
        }
        return try await rpc(
            "session.history",
            Payload(sessionId: sessionId, beforeSeq: beforeSeq, maxMessages: maxMessages)
        )
    }

    func renameSession(_ sessionId: String, title: String) async throws -> (title: String, seq: Int) {
        struct Payload: Encodable, Sendable { let sessionId: String; let title: String }
        struct Value: Decodable, Sendable { let title: String; let seq: Int }
        let value: Value = try await rpc("session.rename", Payload(sessionId: sessionId, title: title))
        return (value.title, value.seq)
    }

    func forkSession(_ sessionId: String, atSeq: Int? = nil) async throws -> String {
        struct Payload: Encodable, Sendable { let sessionId: String; let atSeq: Int? }
        struct Value: Decodable, Sendable { let sessionId: String }
        let value: Value = try await rpc("session.fork", Payload(sessionId: sessionId, atSeq: atSeq))
        return value.sessionId
    }

    func models(sessionId: String) async throws -> SessionModels {
        struct Payload: Encodable, Sendable { let sessionId: String }
        return try await rpc("session.models", Payload(sessionId: sessionId))
    }

    func hostModels() async throws -> HostModelCatalog {
        try await rpc("llm.models", EmptyPayload())
    }

    func selectModel(sessionId: String, selection: ModelSelection) async throws -> ModelSelection {
        struct Payload: Encodable, Sendable {
            let sessionId: String
            let provider: String
            let model: String
            let reasoningEffort: String?
        }
        struct Value: Decodable, Sendable { let selected: ModelSelection }
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

    func setHarnessConfig(sessionId: String, configId: String, value: JSONValue) async throws -> [HarnessConfigOption] {
        struct Payload: Encodable, Sendable {
            let sessionId: String
            let configId: String
            let value: JSONValue
        }
        struct Value: Decodable, Sendable { let options: [HarnessConfigOption] }
        let response: Value = try await rpc(
            "session.setHarnessConfig",
            Payload(sessionId: sessionId, configId: configId, value: value)
        )
        return response.options
    }

    func executeCommand(sessionId: String, line: String) async throws -> DshCommandExecution {
        struct Arguments: Encodable, Sendable {
            let agentId: String
            let line: String
            let images: [JSONValue]
        }
        struct Payload: Encodable, Sendable { let args: Arguments }
        return try await rpc(
            "commands/execute",
            Payload(args: Arguments(agentId: sessionId, line: line, images: []))
        )
    }

    func prompt(
        sessionId: String,
        text: String,
        images: [PromptImage] = [],
        mode: String = "queue"
    ) async throws -> SessionPromptReceipt {
        struct Payload: Encodable, Sendable {
            let sessionId: String
            let mode: String
            let content: [JSONValue]
            let clientTimeZone: String?
        }
        struct Value: Decodable, Sendable { let accepted: Bool }

        // Keep the prompt id so a later optimistic projection can reconcile against the
        // durable user/message source without inventing a second message identity.
        let rpcId = UUID().uuidString
        var content: [JSONValue] = [
            .object(["type": .string("text"), "text": .string(text)]),
        ]
        content.append(contentsOf: images.map { image in
            .object([
                "type": .string("image"),
                "mediaType": .string(image.mediaType),
                "data": .string(image.data),
                "name": image.name.map(JSONValue.string) ?? .null,
            ])
        })
        let payload = Payload(
            sessionId: sessionId,
            mode: mode,
            content: content,
            clientTimeZone: TimeZone.current.identifier
        )
        var request = URLRequest(url: baseURL.appending(path: "/api/session.prompt"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        authorize(&request)
        request.httpBody = try JSONEncoder().encode(
            RpcRequestEnvelope(rpcId: rpcId, method: "session.prompt", payload: payload)
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DshApiError.transport("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) for session.prompt")
        }
        let envelope = try JSONDecoder().decode(RpcResponseEnvelope<Value>.self, from: data)
        guard envelope.type == "server-response", envelope.rpcId == rpcId else {
            throw DshApiError.rpcIdMismatch
        }
        guard envelope.result.ok, envelope.result.value?.accepted == true else {
            throw DshApiError.host(
                envelope.result.error?.code ?? "unknown",
                envelope.result.error?.message ?? "Prompt was not accepted"
            )
        }
        return SessionPromptReceipt(rpcId: rpcId)
    }

    func updateQueue(sessionId: String, itemId: String, action: JSONValue) async throws {
        struct Payload: Encodable, Sendable { let sessionId: String; let itemId: String; let action: JSONValue }
        struct Value: Decodable, Sendable { let accepted: Bool }
        let value: Value = try await rpc(
            "session.updateQueue",
            Payload(sessionId: sessionId, itemId: itemId, action: action)
        )
        guard value.accepted else { throw DshApiError.host("queue-rejected", "Queue mutation was not accepted") }
    }

    func cancel(sessionId: String) async throws {
        struct Payload: Encodable, Sendable { let sessionId: String }
        struct Value: Decodable, Sendable { let accepted: Bool }
        let value: Value = try await rpc("session.cancel", Payload(sessionId: sessionId))
        guard value.accepted else { throw DshApiError.host("cancel-rejected", "Cancel was not accepted") }
    }

    func skills(sessionId: String) async throws -> [SkillEntry] {
        struct Payload: Encodable, Sendable { let sessionId: String }
        struct Value: Decodable, Sendable { let skills: [SkillEntry] }
        let value: Value = try await rpc("skill.list", Payload(sessionId: sessionId))
        return value.skills
    }

    func commandDirectory(sessionId: String) async throws -> [JSONValue] {
        struct Arguments: Encodable, Sendable { let agentId: String }
        struct Payload: Encodable, Sendable { let args: Arguments }
        return try await rpc("commands/list", Payload(args: Arguments(agentId: sessionId)))
    }

    func agentPresets() async throws -> AgentPresetCatalog {
        try await rpc("agentPreset.list", EmptyPayload())
    }

    func harnesses(query: String? = nil) async throws -> [HarnessCatalogEntry] {
        struct Payload: Encodable, Sendable { let query: String? }
        struct Value: Decodable, Sendable { let items: [HarnessCatalogEntry] }
        let value: Value = try await rpc("harness.list", Payload(query: query))
        return value.items
    }

    func refreshHarnesses() async throws -> [HarnessCatalogEntry] {
        struct Value: Decodable, Sendable { let items: [HarnessCatalogEntry] }
        let value: Value = try await rpc("harness.refresh", EmptyPayload())
        return value.items
    }

    func mutateHarness(action: String, id: String? = nil, authMethod: String? = nil, pack: JSONValue? = nil) async throws -> [HarnessCatalogEntry] {
        struct Payload: Encodable, Sendable {
            let action: String
            let id: String?
            let authMethod: String?
            let pack: JSONValue?
        }
        struct Value: Decodable, Sendable { let items: [HarnessCatalogEntry] }
        let value: Value = try await rpc("harness.mutate", Payload(action: action, id: id, authMethod: authMethod, pack: pack))
        return value.items
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

    func subagents(parentSessionId: String) async throws -> SubagentCatalog {
        struct Payload: Encodable, Sendable { let parentSessionId: String }
        let value: JSONValue = try await rpc("subagent.list", Payload(parentSessionId: parentSessionId))
        return SubagentCatalog(
            entries: value["entries"]?.arrayValue?.compactMap(SubagentEntry.init(json:)) ?? [],
            parentAvailable: value["parentAvailable"]?.boolValue ?? false
        )
    }

    func subagentHistory(
        parentSessionId: String,
        childSessionId: String,
        mode: String,
        beforeSeq: Int? = nil
    ) async throws -> SessionHistory {
        struct Payload: Encodable, Sendable {
            let parentSessionId: String
            let childSessionId: String
            let mode: String
            let beforeSeq: Int?
            let maxMessages: Int
        }
        return try await rpc(
            "subagent.history",
            Payload(
                parentSessionId: parentSessionId,
                childSessionId: childSessionId,
                mode: mode,
                beforeSeq: beforeSeq,
                maxMessages: 100
            )
        )
    }

    func promptSubagent(
        parentSessionId: String,
        childSessionId: String,
        text: String
    ) async throws {
        struct Payload: Encodable, Sendable {
            let parentSessionId: String
            let childSessionId: String
            let mode = "continuable"
            let content: [JSONValue]
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
        guard value.accepted else { throw DshApiError.host("subagent-rejected", "Interrupt was not accepted") }
    }

    func createGoal(sessionId: String, objective: String, maxRounds: Int?) async throws -> GoalRef {
        struct Payload: Encodable, Sendable { let sessionId: String; let objective: String; let maxGoalRounds: Int? }
        struct Value: Decodable, Sendable { let ref: GoalRef }
        let value: Value = try await rpc(
            "goal.create",
            Payload(sessionId: sessionId, objective: objective, maxGoalRounds: maxRounds)
        )
        return value.ref
    }

    func mutateGoal(sessionId: String, verb: String, ref: GoalRef) async throws -> GoalRef? {
        struct Payload: Encodable, Sendable { let sessionId: String; let ref: GoalRef }
        if verb == "clear" {
            struct Value: Decodable, Sendable { let cleared: Bool }
            let _: Value = try await rpc("goal.clear", Payload(sessionId: sessionId, ref: ref))
            return nil
        }
        struct Value: Decodable, Sendable { let ref: GoalRef }
        let value: Value = try await rpc("goal.\(verb)", Payload(sessionId: sessionId, ref: ref))
        return value.ref
    }

    func settings() async throws -> SettingsCatalog {
        try await rpc("settings.describe", EmptyPayload())
    }

    func replaceSettings(namespace: String, section: JSONValue, revision: Int) async throws -> SettingsNamespaceView {
        struct Payload: Encodable, Sendable {
            let ns: String
            let section: JSONValue
            let expectedRevision: Int
        }
        return try await rpc(
            "settings.replace",
            Payload(ns: namespace, section: section, expectedRevision: revision)
        )
    }

    func credentialState(refs: [String]) async throws -> [String: JSONValue] {
        struct Payload: Encodable, Sendable { let refs: [String] }
        let value: JSONValue = try await rpc("credentials.describe", Payload(refs: refs))
        return value["credentials"]?.objectValue ?? [:]
    }

    func setCredential(ref: String, value: String) async throws {
        struct Payload: Encodable, Sendable { let ref: String; let value: String }
        let _: JSONValue = try await rpc("credentials.set", Payload(ref: ref, value: value))
    }

    func unsetCredential(ref: String) async throws {
        struct Payload: Encodable, Sendable { let ref: String }
        let _: JSONValue = try await rpc("credentials.unset", Payload(ref: ref))
    }

    func configurableProviders() async throws -> [ConfigurableProvider] {
        struct Value: Decodable, Sendable { let providers: [ConfigurableProvider] }
        let value: Value = try await rpc("llm.providers", EmptyPayload())
        return value.providers
    }

    func pluginInventory() async throws -> [PluginInventoryEntry] {
        struct Payload: Encodable, Sendable { let args: JSONValue = .object([:]) }
        let value: JSONValue = try await rpc("pluginInventory/list", Payload())
        return value["entries"]?.arrayValue?.compactMap(PluginInventoryEntry.init(json:)) ?? []
    }

    func sessionExport(sessionId: String) async throws -> Data {
        var components = URLComponents(
            url: baseURL.appending(path: "/api/session.export"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "sessionId", value: sessionId),
            URLQueryItem(name: "includeDescendants", value: "true"),
        ]
        var request = URLRequest(url: components.url!)
        authorize(&request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DshApiError.transport("Session export failed")
        }
        return data
    }

    func respond(to approval: PendingApproval, outcome: String) async throws -> DshResponseReceipt {
        struct ApprovalPayload: Encodable, Sendable {
            let sessionId: String
            let approvalId: String
            let outcome: String
        }

        let envelope = ClientResponseEnvelope(
            rpcId: approval.rpcId,
            result: .init(
                value: ApprovalPayload(
                    sessionId: approval.sessionId,
                    approvalId: approval.approvalId,
                    outcome: outcome
                )
            )
        )
        var request = URLRequest(url: baseURL.appending(path: "/api/respond"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        authorize(&request)
        request.httpBody = try JSONEncoder().encode(envelope)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DshApiError.transport("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) for respond")
        }
        return try JSONDecoder().decode(DshResponseReceipt.self, from: data)
    }

    func respond(to question: PendingQuestion, answers: [QuestionAnswerItem]) async throws -> DshResponseReceipt {
        struct Answer: Encodable, Sendable { let answers: [QuestionAnswerItem] }
        struct QuestionPayload: Encodable, Sendable { let sessionId: String; let answer: Answer }
        let envelope = ClientResponseEnvelope(
            rpcId: question.rpcId,
            result: .init(value: QuestionPayload(sessionId: question.sessionId, answer: Answer(answers: answers)))
        )
        var request = URLRequest(url: baseURL.appending(path: "/api/respond"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        authorize(&request)
        request.httpBody = try JSONEncoder().encode(envelope)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DshApiError.transport("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) for respond")
        }
        return try JSONDecoder().decode(DshResponseReceipt.self, from: data)
    }

    private func authorize(_ request: inout URLRequest) {
        guard let bearerToken, !bearerToken.isEmpty else { return }
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "authorization")
    }
}

enum DshApiError: Error, CustomStringConvertible, Sendable {
    case rpcIdMismatch
    case transport(String)
    case host(String, String)

    var description: String {
        switch self {
        case .rpcIdMismatch:
            return "The DSH host returned a mismatched RPC id."
        case let .transport(message):
            return message
        case let .host(code, message):
            return "\(code): \(message)"
        }
    }
}
