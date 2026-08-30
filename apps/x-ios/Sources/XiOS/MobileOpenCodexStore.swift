import Foundation
import UIKit

private struct MobileOpenFishDemoHarnessCatalog: Decodable {
    let version: Int
    let items: [MobileHarness]
}

private struct MobileOpenFishDemoRuntimeStep {
    let kind: String
    let id: String
    let from: String?
    let to: String?
    let status: String
    let activity: String
    let signal: String

    static func node(_ id: String, _ status: String, _ activity: String, _ signal: String) -> Self {
        Self(kind: "node", id: id, from: nil, to: nil, status: status, activity: activity, signal: signal)
    }

    static func edge(_ from: String, _ to: String, _ status: String, _ activity: String, _ signal: String) -> Self {
        Self(
            kind: "edge", id: from + "\u{0}\u{0}" + to + "\u{0}", from: from, to: to,
            status: status, activity: activity, signal: signal
        )
    }
}

private func isOpenFishCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let apiError = error as? MobileApiError {
        switch apiError {
        case let .host(code, _): if code == "cancelled" { return true }
        case let .transport(message): if message.localizedCaseInsensitiveContains("cancelled") { return true }
        case .invalidResponse: break
        }
    }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
}

private func mobileVisualFixtureRecords(now: Double) -> [MobileEventRecord] {
    func event(_ seq: Int, _ type: String, _ data: [String: MobileJSONValue]) -> MobileEventRecord {
        MobileEventRecord(
            event: MobileSessionEvent(
                type: type,
                seq: seq,
                time: now - Double(12 - seq) * 1_000,
                data: .object(data),
                sourceEventSeqs: nil,
                surfaceOp: nil,
                ignorable: nil
            ),
            view: nil
        )
    }

    return [
        event(1, "user/message", [
            "content": .array([.object([
                "type": .string("text"),
                "text": .string("Design an offline-first sync flow for notes. Keep every recovery action reversible."),
            ])]),
            "source": .object(["kind": .string("user")]),
        ]),
        event(5, "assistant/message", [
            "turn": .number(1),
            "step": .number(1),
            "message": .object([
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string("I split the flow into local commit, background sync, and conflict review. Notes stay immediately editable while their sync state remains visible."),
                ])]),
            ]),
        ]),
        event(9, "assistant/message", [
            "turn": .number(1),
            "step": .number(2),
            "message": .object([
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string("Offline writes, reconnect replay, and conflict recovery now pass. The conflict screen explains what changed before the user chooses a version."),
                ])]),
            ]),
        ]),
    ]
}

struct MobilePendingImage: Identifiable, Equatable, Sendable {
    let id = UUID()
    let name: String
    let mediaType: String
    let data: Data
}

struct MobileActiveSubagent: Equatable, Sendable {
    let parentSessionId: String
    let childSessionId: String
    let mode: String
    let label: String
}

enum MobileHostIssueKind: String, Equatable, Sendable {
    case recoverable
    case incompatible
}

struct MobileHostIssue: Equatable, Sendable {
    let kind: MobileHostIssueKind
    let title: String
    let message: String
}

enum MobileHostPresentationState: Equatable, Sendable {
    case loading
    case ready
    case cached(MobileHostIssue?)
    case recoverable(MobileHostIssue?)
    case fatal(MobileHostIssue)

    var blocksTaskList: Bool {
        switch self {
        case .loading, .recoverable, .fatal: true
        case .ready, .cached: false
        }
    }
}

@MainActor
final class MobileOpenCodexStore: ObservableObject {
    let voice = MobileLocalVoice()
    private let notifications = MobileNotificationService()
    private let cache = MobileProjectionCache()
    @Published private(set) var connectionState: MobileConnectionState = .connecting
    @Published private(set) var connectionProblem: String?
    @Published private(set) var hostIssue: MobileHostIssue?
    @Published private(set) var hasLiveBaseline = false
    @Published private(set) var profile: MobileConnectionProfile
    @Published private(set) var workspaces: [MobileWorkspace] = []
    @Published private(set) var sessions: [MobileSession] = []
    @Published private(set) var archived: Set<String> = []
    @Published private(set) var approvals: [String: MobileApproval] = [:]
    @Published private(set) var questions: [String: MobilePendingQuestion] = [:]
    @Published private(set) var queuedItems: [String: [MobileQueuedItem]] = [:]
    @Published private(set) var sessionModels: MobileSessionModels?
    @Published private(set) var isLoadingSessionModels = false
    @Published private(set) var isChangingModel = false
    @Published private(set) var isChangingHarnessConfig = false
    @Published private(set) var sessionModelsError: String?
    @Published private(set) var agentPresets: MobileAgentPresetCatalog?
    @Published private(set) var harnesses: [MobileHarness] = []
    @Published private(set) var harnessOperationId: String?
    @Published private(set) var harnessOperationPhase: String?
    @Published private(set) var selectedHarnessId = ""
    @Published private(set) var draftHarnessId: String?
    @Published private(set) var skills: [MobileSkillEntry] = []
    @Published private(set) var commands: [MobileJSONValue] = []
    @Published private(set) var subagents: [MobileSubagentEntry] = []
    @Published private(set) var providers: [MobileConfigurableProvider] = []
    @Published private(set) var plugins: [MobilePluginInventoryEntry] = []
    @Published private(set) var nativeCapabilities: XCapabilities?
    @Published private(set) var attachmentData: [String: Data] = [:]
    @Published private(set) var isSending = false
    @Published private(set) var isImporting = false
    @Published private(set) var isLoadingOlder = false
    @Published private(set) var exportURL: URL?
    @Published private(set) var directoryListing: MobileDirectoryListing?
    @Published private(set) var isBrowsingDirectories = false
    @Published private(set) var isLoadingSettings = false
    @Published var selectedWorkspaceId: String?
    @Published var selectedSessionId: String? {
        didSet {
            guard booted else { return }
            scheduleCache()
            guard activeSubagent == nil else { return }
            let selected = selectedSessionId
            let liveConnection = connection
            Task { await liveConnection.selectSession(selected) }
        }
    }
    @Published private(set) var draftSessionId: String?
    @Published var activeSubagent: MobileActiveSubagent? {
        didSet {
            guard booted else { return }
            let selection = activeSubagent
            let parent = selectedSessionId
            let liveConnection = connection
            Task {
                if let selection {
                    await liveConnection.selectSession(
                        selection.childSessionId,
                        parentSessionId: selection.parentSessionId,
                        mode: selection.mode
                    )
                } else {
                    await liveConnection.selectSession(parent)
                }
            }
        }
    }
    @Published var draft = ""
    @Published var pendingImages: [MobilePendingImage] = []
    @Published var promptMode = "queue"
    @Published var errorMessage: String?
    @Published var showsConnection = false
    @Published var showsTaskInspector = false
    @Published var showsWorkspaceBrowser = false
    @Published var showsVoiceConversation = false
    @Published private(set) var voiceConversationStatus = "Ready"
    @Published private(set) var voiceConversationTranscript = ""
    @Published private(set) var isDemoMode = false

    private var api: XIOSClient
    private var connection: MobileLiveConnection
    private var connectionTask: Task<Void, Never>?
    private var cacheTask: Task<Void, Never>?
    private var draftPreparationTask: Task<Void, Never>?
    private var harnessOperationCancellation: (() -> Void)?
    private var draftPreparationGeneration = 0
    private var records: [String: [MobileEventRecord]] = [:]
    private var historyHasMore: [String: Bool] = [:]
    private var projections: [String: [String: MobileJSONValue]] = [:]
    private var harnessesBySession: [String: MobileHarness] = [:]
    private var booted = false
    private var wasSuspendedForBackground = false
    private var remoteEventClientId: String?
    private var voiceConversationSessionId: String?
    private var lastVoiceTurnEndSeq = -1
    private var loadingAttachments: Set<String> = []
    private static let debugConnectionStateKey = "OpenFish.connection.hardwareSmoke.lastState"
#if DEBUG
    private var hardwareBaselineGeneration = 0
    private var hardwareProjectlessTask: (sessionId: String, harnessId: String, model: MobileModelSelection)?
#endif
    private var readTimestamps: [String: Double] = UserDefaults.standard
        .dictionary(forKey: "OpenFish.readTimestamps.ios")?
        .compactMapValues { ($0 as? NSNumber)?.doubleValue } ?? [:]

    init(profile: MobileConnectionProfile = .restored()) {
        self.profile = profile
        api = XIOSClient(
            baseURL: profile.baseURL,
            bearerToken: profile.bearerToken,
            tlsFingerprint: profile.tlsFingerprint
        )
        connection = MobileLiveConnection(
            baseURL: profile.baseURL,
            token: profile.bearerToken,
            tlsFingerprint: profile.tlsFingerprint
        )
    }

    func cancelHarnessOperation() {
        guard let cancel = harnessOperationCancellation else { return }
        harnessOperationPhase = "Cancelling safely…"
        cancel()
    }

    var canCancelHarnessOperation: Bool { harnessOperationCancellation != nil }

    private func runHarnessOperationStep<Value: Sendable>(
        _ phase: String,
        pollInstallationFor harnessId: String? = nil,
        cancellable: Bool = true,
        operation: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        harnessOperationPhase = phase
        let poller: Task<Void, Never>? = harnessId.map { id in
            Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled, let self else { return }
                    guard let rows = try? await self.api.harnesses(),
                          let detail = rows.first(where: { $0.id == id })?.installation.operationDetail else { continue }
                    self.harnessOperationPhase = detail
                }
            }
        }
        let task = Task { @MainActor in try await operation() }
        harnessOperationCancellation = cancellable ? { task.cancel() } : nil
        defer {
            poller?.cancel()
            harnessOperationCancellation = nil
        }
        return try await task.value
    }

    private func livePreflightIfNeeded(_ harness: MobileHarness) async throws -> MobileHarness {
        if harness.compatibility.status == "compatible" { return harness }
        let rows = try await runHarnessOperationStep(
            "Checking \(harness.name) against its live protocol…"
        ) {
            try await self.api.mutateHarness(action: "probe", id: harness.id)
        }
        harnesses = rows
        guard let verified = rows.first(where: { $0.id == harness.id }) else {
            throw MobileApiError.host(
                "harness-missing-after-preflight",
                "The checked Harness disappeared from the Host catalog."
            )
        }
        return verified
    }

    /// Deterministic, network-isolated state for screenshots and product demos.
    static func visualFixture() -> MobileOpenCodexStore {
        let profile = MobileConnectionProfile(
            baseURL: URL(string: "openfish-demo://fixture")!,
            bearerToken: nil
        )
        let store = MobileOpenCodexStore(profile: profile)
        let now = Date().timeIntervalSince1970 * 1_000
        let workspace = MobileWorkspace(
            workspaceId: "workspace-aurora",
            path: "/Demo/AuroraNotes",
            title: "Aurora Notes",
            sessionIds: ["session-sync", "session-export", "session-accessibility"],
            createdAt: "2026-08-22T00:00:00.000Z",
            updatedAt: "2026-08-22T01:00:00.000Z"
        )
        store.workspaces = [workspace]
        store.sessions = [
            MobileSession(
                sessionId: "session-sync", harnessId: "codex", updatedAt: now,
                running: true, blank: false, parentSessionId: nil, origin: nil,
                cwd: workspace.path, agentPreset: nil, projections: nil
            ),
            MobileSession(
                sessionId: "session-export", harnessId: "omp-acp", updatedAt: now - 3_600_000,
                running: false, blank: false, parentSessionId: nil, origin: nil,
                cwd: workspace.path, agentPreset: nil, projections: nil
            ),
            MobileSession(
                sessionId: "session-accessibility", harnessId: "dsh", updatedAt: now - 86_400_000,
                running: false, blank: false, parentSessionId: nil, origin: nil,
                cwd: workspace.path, agentPreset: "anchored", projections: nil
            ),
        ]
        store.projections = [
            "session-sync": [
                "title": .string("Design the offline sync flow"),
                "harnessRuntime": Self.visualHarnessRuntimeProjection(now: now),
            ],
            "session-export": ["title": .string("Add export progress")],
            "session-accessibility": ["title": .string("Review accessibility labels")],
        ]
        store.records["session-sync"] = mobileVisualFixtureRecords(now: now)
        store.sessionModels = MobileSessionModels(
            current: .init(provider: "openai", model: "gpt-5.6-sol", reasoningEffort: "medium"),
            routable: true,
            groups: [
                .init(
                    id: "openai", name: "OpenAI",
                    models: [
                        .init(
                            id: "gpt-5.6-sol", name: "GPT-5.6-Sol", description: "Demo model",
                            providerId: "openai", providerName: "OpenAI",
                            reasoning: .init(
                                efforts: [
                                    .init(id: "low", name: "Low", description: nil),
                                    .init(id: "medium", name: "Medium", description: nil),
                                    .init(id: "high", name: "High", description: nil),
                                ],
                                defaultEffort: "medium"
                            )
                        ),
                    ]
                ),
            ],
            failures: [],
            account: MobileHarness.AccountDescriptor(
                label: "ChatGPT · Pro",
                billing: "subscription",
                detail: "Demo data: the official Codex app-server reported a ChatGPT Pro route. OpenFish retained neither email nor credentials."
            )
        )
        store.harnesses = Self.generatedVisualHarnesses().filter { $0.id == "codex" }
        store.selectedHarnessId = "codex"
        store.selectedWorkspaceId = workspace.workspaceId
        store.selectedSessionId = "session-sync"
        store.connectionState = .connected
        store.hasLiveBaseline = true
        store.booted = true
        store.isDemoMode = true
        return store
    }

    /// Content-free, deterministic evidence used only by the isolated demo
    /// transport. It mirrors the order emitted by the real Codex Driver while
    /// deliberately containing no prompt, output, path, command, or identity.
    private static func visualHarnessRuntimeProjection(now: Double) -> MobileJSONValue {
        let steps: [MobileOpenFishDemoRuntimeStep] = [
            .node("app-server", "completed", "Protocol boundary ready", "protocol.ready"),
            .node("thread", "waiting", "Session ready", "session.ready"),
            .edge("app-server", "thread", "waiting", "Session ready", "session.ready"),
            .node("thread", "active", "Turn started", "turn.started"),
            .edge("thread", "context", "active", "Turn started", "turn.started"),
            .edge("context", "model", "active", "Turn started", "turn.started"),
            .node("tools", "active", "Tool activity observed", "tool.activity"),
            .edge("model", "tools", "active", "Tool activity observed", "tool.activity"),
            .edge("tools", "output", "active", "Tool activity observed", "tool.activity"),
            .node("approvals", "active", "Approval requested", "approval.requested"),
            .edge("tools", "approvals", "active", "Approval requested", "approval.requested"),
            .node("approvals", "completed", "Approval resolved", "approval.resolved"),
            .node("model", "completed", "Model response completed", "model.completed"),
            .edge("model", "output", "completed", "Model response completed", "model.completed"),
            .node("output", "active", "Output activity observed", "output.activity"),
            .edge("model", "output", "active", "Output activity observed", "output.activity"),
            .node("thread", "waiting", "Turn completed", "turn.completed"),
        ]
        var nodes: [String: MobileJSONValue] = [:]
        var edges: [String: MobileJSONValue] = [:]
        var observations: [MobileJSONValue] = []
        for (offset, step) in steps.enumerated() {
            let seq = 20 + offset
            let time = now - Double(steps.count - offset) * 420
            var value: [String: MobileJSONValue] = [
                "kind": .string(step.kind),
                "id": .string(step.id),
                "status": .string(step.status),
                "activity": .string(step.activity),
                "signal": .string(step.signal),
                "seq": .number(Double(seq)),
                "time": .number(time),
            ]
            if let from = step.from { value["from"] = .string(from) }
            if let to = step.to { value["to"] = .string(to) }
            observations.append(.object(value))
            let state: MobileJSONValue = .object([
                "status": .string(step.status),
                "activity": .string(step.activity),
                "signal": .string(step.signal),
                "seq": .number(Double(seq)),
                "time": .number(time),
            ])
            if step.kind == "node" {
                nodes[step.id] = state
            } else if let from = step.from, let to = step.to {
                edges[step.id] = .object([
                    "from": .string(from),
                    "to": .string(to),
                    "status": .string(step.status),
                    "activity": .string(step.activity),
                    "signal": .string(step.signal),
                    "seq": .number(Double(seq)),
                    "time": .number(time),
                ])
            }
        }
        return .object([
            "harnessId": .string("codex"),
            "version": .string("0.150.1"),
            "nodes": .object(nodes),
            "edges": .object(edges),
            "observations": .array(observations),
        ])
    }

    static func visualLoadingFixture() -> MobileOpenCodexStore {
        let store = MobileOpenCodexStore(profile: .init(
            baseURL: URL(string: "openfish-demo://fixture")!,
            bearerToken: nil
        ))
        store.connectionState = .connecting
        store.booted = true
        store.isDemoMode = true
        return store
    }

    static func visualRecoverableFixture() -> MobileOpenCodexStore {
        let store = visualLoadingFixture()
        store.connectionState = .reconnecting(3)
        store.hostIssue = .init(
            kind: .recoverable,
            title: "Could not reach this Mac",
            message: "OpenFish will keep retrying. Check that the Mac Host is running or pair with another Mac."
        )
        store.connectionProblem = store.hostIssue?.message
        return store
    }

    static func visualFatalFixture() -> MobileOpenCodexStore {
        let store = visualLoadingFixture()
        store.connectionState = .connected
        store.hostIssue = .init(
            kind: .incompatible,
            title: "This Mac Host is not compatible",
            message: "The demo Host does not implement the OpenFish native protocol required by this iPhone build."
        )
        store.connectionProblem = store.hostIssue?.message
        return store
    }

    static func visualOfflineFixture() -> MobileOpenCodexStore {
        let store = visualFixture()
        store.connectionState = .reconnecting(2)
        store.hasLiveBaseline = false
        store.hostIssue = .init(
            kind: .recoverable,
            title: "Reconnecting to the Mac Host",
            message: "Cached tasks remain readable. Sending and approvals resume after the Host reconnects."
        )
        store.connectionProblem = store.hostIssue?.message
        return store
    }

    static func visualEmptyFixture() -> MobileOpenCodexStore {
        let store = visualFixture()
        store.workspaces = []
        store.sessions = []
        store.archived = []
        store.records = [:]
        store.projections = [:]
        store.selectedWorkspaceId = nil
        store.selectedSessionId = nil
        store.draftSessionId = nil
        return store
    }

    static func visualHarnessSetupFixture() -> MobileOpenCodexStore {
        let store = visualEmptyFixture()
        store.harnesses = Self.generatedVisualHarnesses()
        store.selectedHarnessId = ""
        return store
    }

    /// Network-isolated interaction state used to exercise the exact approval
    /// and structured-question UI on a simulator or physical iPhone. The Host
    /// mux contract that feeds these cards is covered independently by the
    /// api-proxy integration suite.
    static func visualInteractionFixture() -> MobileOpenCodexStore {
        let store = visualFixture()
        let sessionId = "session-sync"
        store.approvals["approval-demo"] = MobileApproval(
            clientId: "demo",
            rpcId: "rpc-approval-demo",
            sessionId: sessionId,
            approvalId: "approval-demo",
            toolName: "write_file",
            reason: "This demo action would update a file in the selected project."
        )
        store.questions["rpc-question-demo"] = MobilePendingQuestion(
            clientId: "demo",
            rpcId: "rpc-question-demo",
            sessionId: sessionId,
            questions: [
                MobileQuestion(
                    id: "delivery",
                    question: "How should OpenFish continue?",
                    detail: "Choose one option before the Harness resumes.",
                    options: [
                        MobileQuestionOption(label: "Keep changes", description: "Continue with the current draft."),
                        MobileQuestionOption(label: "Revise first", description: "Return to the plan before editing."),
                    ],
                    multiSelect: false
                ),
            ]
        )
        return store
    }

    private static func generatedVisualHarnesses() -> [MobileHarness] {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "openfish-demo-harnesses", withExtension: "json") else {
            preconditionFailure("The generated OpenFish Demo Harness catalog is missing from the iPhone app bundle")
        }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return try JSONDecoder().decode(MobileOpenFishDemoHarnessCatalog.self, from: data).items
        } catch {
            preconditionFailure("The generated OpenFish Demo Harness catalog is invalid: \(error)")
        }
    }

    var selectedSession: MobileSession? {
        guard let selectedSessionId else { return nil }
        return sessions.first { $0.sessionId == selectedSessionId }
    }

    private var controlSessionId: String? { selectedSessionId ?? draftSessionId }

    private var controlSession: MobileSession? {
        guard let controlSessionId else { return nil }
        return sessions.first { $0.sessionId == controlSessionId }
    }

    var currentAgentPreset: String? { controlSession?.agentPreset }
    var currentHarnessId: String { controlSession?.harnessId ?? draftHarnessId ?? selectedHarnessId }
    var currentHarnessAuthMethod: String? { controlSession?.harnessAuthMethod }
    var currentHarness: MobileHarness? {
        if let controlSessionId, let pinned = harnessesBySession[controlSessionId] { return pinned }
        return harnesses.first { $0.id == currentHarnessId }
    }
    private func isRunnableDefault(_ harness: MobileHarness) -> Bool {
        let installed = harness.installation.status == "builtin" || harness.installation.status == "installed"
        let authenticated = harness.auth.status == "not-required" || harness.auth.status == "configured"
        return harness.available && installed && authenticated
    }
    func harnessCapability(_ id: String) -> String? {
        if let snapshot = controlSession?.harnessCapabilities {
            return snapshot.contains(id) ? "supported" : "unsupported"
        }
        return currentHarness?.capabilities.first(where: { $0.id == id })?.status
    }
    func harnessCan(_ id: String) -> Bool { harnessCapability(id) != nil && harnessCapability(id) != "unsupported" }
    var canAttachImages: Bool { harnessCan("interaction.files") }
    var canChooseWorkspace: Bool { selectedSessionId == nil || controlSession?.blank == true }
    var canChooseHarness: Bool { selectedSessionId == nil && (controlSession?.blank ?? true) }
    var canChooseAgentPreset: Bool { controlSession?.blank == true && harnessCan("configuration.agent-presets") }

    var selectedWorkspace: MobileWorkspace? {
        if let selectedSessionId {
            return workspaces.first { $0.sessionIds.contains(selectedSessionId) }
        }
        if let selectedWorkspaceId { return workspaces.first { $0.workspaceId == selectedWorkspaceId } }
        return nil
    }

    var conversation: [MobileConversationItem] {
        guard let conversationSessionId else { return [] }
        return MobileConversationProjector.project(records[conversationSessionId] ?? [])
    }

    var visibleCommands: [MobileJSONValue] {
        var native: [MobileJSONValue] = []
        if let id = conversationSessionId {
            for record in (records[id] ?? []).sorted(by: { $0.event.seq < $1.event.seq }) {
                guard record.event.type == "harness/native-event",
                      let event = record.event.data["event"],
                      event["sessionUpdate"]?.stringValue == "available_commands_update" else { continue }
                native = event["availableCommands"]?.arrayValue ?? []
            }
        }
        guard !native.isEmpty else { return commands }
        let nativeNames = Set(native.compactMap { $0["name"]?.stringValue })
        return commands.filter { row in
            guard let name = row["name"]?.stringValue else { return true }
            return !nativeNames.contains(name)
        } + native
    }

    var canLoadOlder: Bool {
        guard let conversationSessionId else { return false }
        return historyHasMore[conversationSessionId] == true && !isLoadingOlder
    }

    var conversationSessionId: String? { activeSubagent?.childSessionId ?? selectedSessionId }

    func cachedAttachment(sessionId: String, attachmentId: String) -> Data? {
        attachmentData[attachmentCacheKey(sessionId: sessionId, attachmentId: attachmentId)]
    }

    func loadAttachment(sessionId: String, attachmentId: String) async {
        let key = attachmentCacheKey(sessionId: sessionId, attachmentId: attachmentId)
        guard attachmentData[key] == nil, loadingAttachments.insert(key).inserted else { return }
        defer { loadingAttachments.remove(key) }
        do {
            attachmentData[key] = try await api.attachmentData(sessionId: sessionId, attachmentId: attachmentId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func attachmentCacheKey(sessionId: String, attachmentId: String) -> String {
        "\(sessionId):\(attachmentId)"
    }

    var selectedApprovals: [MobileApproval] {
        guard let conversationSessionId else { return [] }
        return approvals.values.filter { $0.sessionId == conversationSessionId }.sorted { $0.id < $1.id }
    }

    var currentPermissions: MobilePermissionSelect? {
        guard let controlSessionId,
              let value = projections[controlSessionId]?["permissions"] else { return nil }
        return try? value.decode(MobilePermissionSelect.self)
    }

    var currentGoal: MobileGoalProjection? {
        guard let conversationSessionId,
              let value = projections[conversationSessionId]?["goal"] else { return nil }
        return try? value.decode(MobileGoalProjection.self)
    }

    var currentPlan: MobilePlanProjection? {
        guard let conversationSessionId,
              let value = projections[conversationSessionId]?["plan"] else { return nil }
        return try? value.decode(MobilePlanProjection.self)
    }

    var currentTodos: MobileJSONValue? {
        guard let conversationSessionId else { return nil }
        return projections[conversationSessionId]?["todos"]
    }

    var currentHarnessRuntime: MobileHarnessRuntimeProjection? {
        guard let conversationSessionId,
              let value = projections[conversationSessionId]?["harnessRuntime"] else { return nil }
        return try? value.decode(MobileHarnessRuntimeProjection.self)
    }

    var currentModelName: String {
        guard let sessionModels else {
            if isLoadingSessionModels { return "Discovering models…" }
            if sessionModelsError != nil { return "Models unavailable" }
            return "Model not discovered"
        }
        let advertised = sessionModels.groups
            .first(where: { $0.id == sessionModels.current.provider })?
            .models.first(where: { $0.id == sessionModels.current.model })?.name
        if let advertised { return advertised }
        return sessionModels.current.provider == "harness" && sessionModels.groups.isEmpty
            ? "Harness-managed model"
            : sessionModels.current.model
    }

    var currentModelLabel: String {
        guard let effort = sessionModels?.current.reasoningEffort,
              !effort.isEmpty else { return currentModelName }
        let effortName = sessionModels?.groups
            .first(where: { $0.id == sessionModels?.current.provider })?
            .models.first(where: { $0.id == sessionModels?.current.model })?
            .reasoning?.efforts.first(where: { $0.id == effort })?.name
            ?? effort
        return "\(currentModelName) · \(effortName)"
    }

    var currentModel: MobileCatalogModel? {
        guard let sessionModels else { return nil }
        return sessionModels.groups
            .first(where: { $0.id == sessionModels.current.provider })?
            .models.first(where: { $0.id == sessionModels.current.model })
    }

    var currentReasoningOptions: [MobileModelReasoningEffort] {
        currentModel?.reasoning?.efforts ?? []
    }

    var currentReasoningName: String? {
        guard let effort = sessionModels?.current.reasoningEffort else { return nil }
        return currentReasoningOptions.first(where: { $0.id == effort })?.name ?? effort
    }

    var currentReasoningLabel: String {
        if let currentReasoningName { return currentReasoningName }
        if isLoadingSessionModels, sessionModels == nil { return "Discovering reasoning…" }
        if sessionModelsError != nil { return "Reasoning unavailable" }
        if sessionModels == nil { return "Reasoning not discovered" }
        return currentReasoningOptions.isEmpty ? "Reasoning fixed by Harness" : "Reasoning"
    }

    var selectedQuestions: [MobilePendingQuestion] {
        guard let conversationSessionId else { return [] }
        return questions.values.filter { $0.sessionId == conversationSessionId }.sorted { $0.id < $1.id }
    }

    var selectedQueue: [MobileQueuedItem] {
        guard let conversationSessionId else { return [] }
        return queuedItems[conversationSessionId] ?? []
    }

    var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty)
            && (pendingImages.isEmpty || canAttachImages)
            && (activeSubagent != nil || sessionModels?.routable == true)
            && canStartNewTask
            && !isSending
    }

    var hostPresentationState: MobileHostPresentationState {
        let hasCachedProjection = !workspaces.isEmpty || !sessions.isEmpty
        if connectionState == .connected && hasLiveBaseline { return .ready }
        if hasCachedProjection { return .cached(hostIssue) }
        if let hostIssue {
            return hostIssue.kind == .incompatible ? .fatal(hostIssue) : .recoverable(hostIssue)
        }
        if case .reconnecting = connectionState { return .recoverable(nil) }
        return .loading
    }

    var canStartNewTask: Bool {
        if case .ready = hostPresentationState { return true }
        return false
    }

    var conversationRunning: Bool {
        if let activeSubagent {
            return subagents.first(where: { $0.id == activeSubagent.childSessionId })?.activity == "running"
        }
        return selectedSession?.running == true
    }

    func sessions(in workspace: MobileWorkspace?) -> [MobileSession] {
        let visible = sessions.filter {
            $0.origin != "subagent" && !$0.blank && !archived.contains($0.sessionId)
        }
        guard let workspace else {
            let known = Set(workspaces.flatMap(\.sessionIds))
            return visible.filter {
                !known.contains($0.sessionId) && $0.workspaceMode == "no-project"
            }.sorted { $0.updatedAt > $1.updatedAt }
        }
        let byId = visible.reduce(into: [String: MobileSession]()) { result, session in
            if let current = result[session.sessionId], current.updatedAt > session.updatedAt { return }
            result[session.sessionId] = session
        }
        return workspace.sessionIds.compactMap { byId[$0] }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var otherLocationSessions: [MobileSession] {
        let known = Set(workspaces.flatMap(\.sessionIds))
        return sessions.filter {
            $0.origin != "subagent"
                && !$0.blank
                && !archived.contains($0.sessionId)
                && !known.contains($0.sessionId)
                && $0.workspaceMode != "no-project"
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var orderedWorkspaces: [MobileWorkspace] {
        workspaces.sorted { left, right in
            let leftUpdated = sessions(in: left).first?.updatedAt ?? 0
            let rightUpdated = sessions(in: right).first?.updatedAt ?? 0
            if leftUpdated != rightUpdated { return leftUpdated > rightUpdated }
            return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
        }
    }

    var visibleSessionsByRecency: [MobileSession] {
        (orderedWorkspaces.flatMap { sessions(in: $0) } + sessions(in: nil) + otherLocationSessions)
            .reduce(into: [String: MobileSession]()) { $0[$1.sessionId] = $1 }
            .values.sorted { $0.updatedAt > $1.updatedAt }
    }

    func hasAttention(_ sessionId: String) -> Bool {
        sessions.first(where: { $0.sessionId == sessionId })?.running == true
            || approvals.values.contains { $0.sessionId == sessionId }
            || questions.values.contains { $0.sessionId == sessionId }
    }

    func isUnread(_ session: MobileSession) -> Bool {
        session.updatedAt > (readTimestamps[session.sessionId] ?? 0)
    }

    func markRead(_ session: MobileSession) {
        readTimestamps[session.sessionId] = session.updatedAt
        UserDefaults.standard.set(readTimestamps, forKey: "OpenFish.readTimestamps.ios")
        objectWillChange.send()
    }

    func workspaceTitle(for session: MobileSession) -> String {
        if let title = workspaces.first(where: { $0.sessionIds.contains(session.sessionId) })?.title {
            return title
        }
        if session.workspaceMode == "no-project" { return "No Project" }
        if let cwd = session.cwd {
            let base = cwd.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)
            if let base, !base.isEmpty { return "External · \(base)" }
        }
        return "Unfiled"
    }

    var archivedSessions: [MobileSession] {
        sessions
            .filter { archived.contains($0.sessionId) && $0.origin != "subagent" && !$0.blank }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func setArchived(_ sessionId: String, archived shouldArchive: Bool) async {
        do {
            archived = try await api.setArchived(sessionId: sessionId, archived: shouldArchive)
            if shouldArchive, selectedSessionId == sessionId { newTask(in: selectedWorkspaceId) }
            if !shouldArchive { await select(sessionId) }
            errorMessage = nil
            scheduleCache()
        } catch {
            errorMessage = "Could not \(shouldArchive ? "archive" : "restore") this task: \(error.localizedDescription)"
        }
    }

    func browseHostDirectory(_ path: String? = nil) async {
        guard !isBrowsingDirectories else { return }
        isBrowsingDirectories = true
        defer { isBrowsingDirectories = false }
        do {
            directoryListing = try await api.listDirectory(path: path)
            showsWorkspaceBrowser = true
            errorMessage = nil
        } catch {
            errorMessage = "Could not browse the Host: \(error.localizedDescription)"
        }
    }

    func createHostFolder(_ name: String) async {
        guard let parent = directoryListing?.path else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let path = try await api.createDirectory(parent: parent, name: trimmed)
            directoryListing = try await api.listDirectory(path: path)
            errorMessage = nil
        } catch {
            errorMessage = "Could not create the folder: \(error.localizedDescription)"
        }
    }

    func addCurrentHostDirectory() async {
        guard let path = directoryListing?.path else { return }
        do {
            let workspace = try await api.createWorkspace(path: path)
            await refresh()
            selectedWorkspaceId = workspace.workspaceId
            showsWorkspaceBrowser = false
            newTask(in: workspace.workspaceId)
            errorMessage = nil
            scheduleCache()
        } catch {
            errorMessage = "Could not add this project: \(error.localizedDescription)"
        }
    }

    func title(for session: MobileSession) -> String {
        if session.blank { return "New task" }
        if let title = projections[session.sessionId]?["title"]?.stringValue, !title.isEmpty { return title }
        if let title = session.projections?.values["title"]?.stringValue, !title.isEmpty { return title }
        if let cwd = session.cwd { return URL(fileURLWithPath: cwd).lastPathComponent }
        return String(session.sessionId.prefix(10))
    }

    func boot() async {
        guard !booted else { return }
        booted = true
        resetConnectionDiagnostic()
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let host = environment["OPENCODEX_DEBUG_HOST"]
            ?? environment["DEVICECTL_CHILD_OPENCODEX_DEBUG_HOST"],
           let pairingCode = environment["OPENCODEX_DEBUG_PAIRING_CODE"]
            ?? environment["DEVICECTL_CHILD_OPENCODEX_DEBUG_PAIRING_CODE"],
           !host.isEmpty,
           !pairingCode.isEmpty {
            recordConnectionDiagnostic("boot:debug-pairing-started")
            await connect(host: host, pairingCode: pairingCode)
            return
        }
#endif
        recordConnectionDiagnostic(profile.requiresPairing ? "boot:pairing-required" : "boot:profile-restored")
        if let snapshot = await cache.load(matching: profile.baseURL) {
            restore(snapshot)
        }
        await startConnection()
    }

    func enableNotifications() async {
        await notifications.requestAuthorization()
    }

    func shutdown() async {
        stopVoiceConversation()
        connectionTask?.cancel()
        connectionTask = nil
        cacheTask?.cancel()
        draftPreparationTask?.cancel()
        await cache.save(cacheSnapshot())
        await connection.stop()
    }

    func enteredBackground() async {
        recordConnectionDiagnostic("lifecycle:background")
        wasSuspendedForBackground = true
        stopVoiceConversation()
        cacheTask?.cancel()
        draftPreparationTask?.cancel()
        await cache.save(cacheSnapshot())
        await connection.stop()
    }

    func becameActive() async {
        recordConnectionDiagnostic("lifecycle:active")
        guard booted else { return }
        // SwiftUI also reports `.active` during the initial foreground boot.
        // Treat only a real background -> active transition as a reconnect;
        // otherwise clearing the freshly loaded baseline can strand the UI
        // while the already-running socket correctly ignores a duplicate start.
        guard wasSuspendedForBackground else { return }
        wasSuspendedForBackground = false
        connectionState = .connecting
        hasLiveBaseline = false
        await startConnection()
        // The live connection publishes Connected only after its authenticated
        // Gateway stream is open. Its state handler owns the authoritative
        // baseline refresh, avoiding a guaranteed early HTTP race here.
    }

#if DEBUG
    /// Exercises the production background/foreground connection handlers on
    /// an installed device without depending on XCTest's device-control DTX
    /// channel. It writes only coarse state names to the app cache.
    func runPhysicalLifecycleSmokeTest() async {
        recordConnectionDiagnostic("lifecycle-self-test:started")
        guard await waitForLiveBaseline() else {
            recordConnectionDiagnostic("lifecycle-self-test:failed-initial-connect")
            return
        }
        recordConnectionDiagnostic("lifecycle-self-test:initial-connected")
        let generation = hardwareBaselineGeneration
        await enteredBackground()
        recordConnectionDiagnostic("lifecycle-self-test:background-quiescent")
        await becameActive()
        guard await waitForLiveBaseline(after: generation) else {
            recordConnectionDiagnostic("lifecycle-self-test:failed-reconnect")
            return
        }
        recordConnectionDiagnostic("lifecycle-self-test:passed")
    }

    /// Prepares a real blank task but never sends a prompt. The next OS-driven
    /// foreground refresh verifies that its identity, Harness and model survive.
    /// Refuse to replace an unsent message or attachment during this check.
    func runPhysicalProjectlessSmokeTest() async {
        recordConnectionDiagnostic("projectless-self-test:started")
        guard !isDemoMode, await waitForLiveBaseline() else {
            recordConnectionDiagnostic("projectless-self-test:failed-initial-connect")
            return
        }
        await draftPreparationTask?.value
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, pendingImages.isEmpty else {
            recordConnectionDiagnostic("projectless-self-test:skipped-unsent-draft")
            return
        }
        guard canStartNewTask, !selectedHarnessId.isEmpty else {
            recordConnectionDiagnostic("projectless-self-test:failed-no-default-harness")
            return
        }
        newTask(in: nil)
        await draftPreparationTask?.value
        guard let sessionId = draftSessionId, let harnessId = draftHarnessId,
              let models = sessionModels else {
            recordConnectionDiagnostic("projectless-self-test:failed-prepare")
            return
        }
        hardwareProjectlessTask = (sessionId, harnessId, models.current)
        if let failure = projectlessHardwareFailure() {
            recordConnectionDiagnostic("projectless-self-test:failed-\(failure)")
            hardwareProjectlessTask = nil
            return
        }
        recordConnectionDiagnostic("projectless-self-test:ready-for-os-background")
    }

    private func projectlessHardwareFailure() -> String? {
        guard let expected = hardwareProjectlessTask else { return "not-prepared" }
        guard selectedSessionId == nil, draftSessionId == expected.sessionId else { return "task-identity" }
        guard selectedWorkspaceId == nil,
              !workspaces.contains(where: { $0.sessionIds.contains(expected.sessionId) }) else { return "workspace" }
        guard draftHarnessId == expected.harnessId,
              sessions.contains(where: { $0.sessionId == expected.sessionId && $0.blank && $0.harnessId == expected.harnessId }) else { return "harness" }
        guard !isLoadingSessionModels, sessionModelsError == nil,
              let models = sessionModels, models.routable,
              models.groups.contains(where: { !$0.models.isEmpty }) else { return "models-unavailable" }
        guard models.current == expected.model else { return "model-selection" }
        return nil
    }

    private func waitForLiveBaseline(after generation: Int = 0) async -> Bool {
        for _ in 0..<100 {
            guard !Task.isCancelled else { return false }
            if connectionState == .connected && hasLiveBaseline && hardwareBaselineGeneration > generation { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }
#endif

    private func startConnection() async {
        guard !profile.requiresPairing else {
            recordConnectionDiagnostic("connection:pairing-required")
            connectionState = .reconnecting(0)
            hasLiveBaseline = false
            connectionProblem = "Pair this iPhone with the Mac Host before reconnecting."
            hostIssue = .init(
                kind: .recoverable,
                title: "Pair this iPhone",
                message: "Enter a fresh one-time code from the Mac Host. OpenFish will keep the resulting device credential in this iPhone's Keychain."
            )
            return
        }
        if connectionTask == nil {
            let stream = connection.updates
            connectionTask = Task { [weak self] in
                for await update in stream { await self?.handle(update) }
            }
        }
        recordConnectionDiagnostic("connection:sockets-starting")
        await connection.selectSession(selectedSessionId)
        await connection.start()
    }

    func refresh(selectRemembered: Bool = false) async {
        do {
            async let handshakeRequest = api.handshake()
            async let capabilitiesRequest = api.capabilities()
            async let workspaceRows = api.workspaces()
            async let sessionRows = api.sessions()
            async let harnessRows = api.harnesses()
            let (handshake, capabilities, workspaceSnapshot, sessionSnapshot, harnessSnapshot) = try await (
                handshakeRequest, capabilitiesRequest, workspaceRows, sessionRows, harnessRows
            )
            guard handshake.ok,
                  handshake.product == "opencodex",
                  handshake.host == "dsh",
                  handshake.protocolVersion == "v2",
                  handshake.minimumClientProtocol == "v2" else {
                throw MobileApiError.host(
                    "native-protocol-incompatible",
                    "This app requires the OpenFish native bootstrap protocol v2."
                )
            }
            guard capabilities.product == "opencodex",
                  capabilities.host == "dsh",
                  capabilities.surface == "native",
                  capabilities.protocolVersion == "v2",
                  capabilities.features.gateway,
                  capabilities.features.typert,
                  capabilities.contracts.sessions,
                  capabilities.contracts.workspaces,
                  capabilities.contracts.interactions,
                  capabilities.contracts.settings,
                  capabilities.contracts.providers,
                  capabilities.features.localVoice,
                  capabilities.voice?.contract == "dsh.voice.v1",
                  capabilities.voice?.transcriptAuthority == "session.prompt",
                  capabilities.voice?.providers.contains(where: {
                      $0.id == voice.providerID
                          && $0.platforms.contains("iphone")
                          && $0.operations.contains("speech-to-text")
                          && $0.operations.contains("text-to-speech")
                          && $0.locality == "device"
                  }) == true else {
                throw MobileApiError.host(
                    "native-capability-incompatible",
                    "This OpenFish Host is missing the iPhone or local-voice composition."
                )
            }
            nativeCapabilities = capabilities
            connectionProblem = nil
            hostIssue = nil
            hasLiveBaseline = true
            workspaces = workspaceSnapshot.items
            archived = workspaceSnapshot.archived
            for session in sessionSnapshot {
                if let values = session.projections?.values {
                    projections[session.sessionId, default: [:]].merge(values) { _, new in new }
                }
            }
            sessions = sessionSnapshot
            if let selectedSessionId {
                selectedWorkspaceId = workspaces.first(where: { $0.sessionIds.contains(selectedSessionId) })?.workspaceId
            }
            harnesses = harnessSnapshot
            if let sharedDefault = harnesses.first(where: { $0.isDefault && isRunnableDefault($0) }) {
                selectedHarnessId = sharedDefault.id
            } else {
                selectedHarnessId = ""
            }
            agentPresets = try? await api.agentPresets()
            if selectRemembered,
               let remembered = UserDefaults.standard.string(forKey: "OpenCodex.iPhone.lastSession"),
               sessions.contains(where: { $0.sessionId == remembered }) {
                await select(remembered)
            } else if selectRemembered, await resumePreparedDraftIfPossible() {
                // Continue the exact blank provider task restored from cache.
            } else if selectRemembered, selectedSessionId == nil {
                newTask(in: selectedWorkspaceId)
            }
            errorMessage = nil
            scheduleCache()
        } catch {
            nativeCapabilities = nil
            hasLiveBaseline = false
            // The live connection owns automatic retry. A temporary Wi-Fi or
            // app-background transition is connection state, not a blocking
            // task error, so keep cached tasks visible and report it inline.
            let incompatible: Bool
            let detail: String
            if case let MobileApiError.host(code, message) = error {
                incompatible = code == "native-protocol-incompatible" || code == "native-capability-incompatible"
                detail = message
            } else {
                incompatible = false
                detail = error.localizedDescription
            }
            hostIssue = .init(
                kind: incompatible ? .incompatible : .recoverable,
                title: incompatible ? "This Mac Host is not compatible" : "Could not reach this Mac",
                message: detail
            )
            connectionProblem = hostIssue?.message
        }
    }

    func select(_ sessionId: String) async {
        if isDemoMode {
            guard sessions.contains(where: { $0.sessionId == sessionId }) else { return }
            selectedSessionId = sessionId
            activeSubagent = nil
            selectedWorkspaceId = workspaces.first(where: { $0.sessionIds.contains(sessionId) })?.workspaceId
            return
        }
        if let abandonedDraft = draftSessionId, abandonedDraft != sessionId {
            draftSessionId = nil
            draftHarnessId = nil
            try? await api.discardSession(abandonedDraft)
        }
        selectedSessionId = sessionId
        activeSubagent = nil
        // Never leave the previous task's model catalog on screen while the
        // selected Harness is resuming or its own catalog is being resolved.
        sessionModels = nil
        sessionModelsError = nil
        isLoadingSessionModels = true
        selectedWorkspaceId = workspaces.first(where: { $0.sessionIds.contains(sessionId) })?.workspaceId
        UserDefaults.standard.set(sessionId, forKey: "OpenCodex.iPhone.lastSession")
        do {
            async let historyRequest = api.history(sessionId: sessionId)
            async let modelsRequest: Void = loadModels(sessionId: sessionId)
            async let skillsRequest = try? api.skills(sessionId: sessionId)
            async let commandsRequest = try? api.commandDirectory(sessionId: sessionId)
            async let subagentsRequest = try? api.subagents(parentSessionId: sessionId)
            let history = try await historyRequest
            records[sessionId] = merge(records[sessionId] ?? [], history.events)
            historyHasMore[sessionId] = history.hasMore
            if let values = history.projections?.values {
                projections[sessionId, default: [:]].merge(values) { _, new in new }
            }
            await resolveHarnessSnapshot(sessionId: sessionId, history: history)
            let (_, loadedSkills, loadedCommands, loadedSubagents) = await (
                modelsRequest,
                skillsRequest,
                commandsRequest,
                subagentsRequest
            )
            guard selectedSessionId == sessionId else { return }
            skills = loadedSkills ?? []
            commands = loadedCommands ?? []
            subagents = loadedSubagents?.entries ?? []
            objectWillChange.send()
            scheduleCache()
        } catch {
            guard !Task.isCancelled, !isOpenFishCancellation(error) else { return }
            errorMessage = "Could not load this task: \(error.localizedDescription)"
        }
    }

    func loadOlder() async {
        guard let conversationSessionId,
              historyHasMore[conversationSessionId] == true,
              !isLoadingOlder,
              let beforeSeq = records[conversationSessionId]?.first?.event.seq else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let history: MobileHistory
            if let activeSubagent {
                history = try await api.subagentHistory(
                    parentSessionId: activeSubagent.parentSessionId,
                    childSessionId: activeSubagent.childSessionId,
                    mode: activeSubagent.mode,
                    beforeSeq: beforeSeq
                )
            } else {
                history = try await api.history(sessionId: conversationSessionId, beforeSeq: beforeSeq)
            }
            records[conversationSessionId] = merge(records[conversationSessionId] ?? [], history.events)
            historyHasMore[conversationSessionId] = history.hasMore
            errorMessage = nil
            objectWillChange.send()
            scheduleCache()
        } catch {
            errorMessage = "Could not load earlier messages: \(error.localizedDescription)"
        }
    }

    func newTask(in workspaceId: String?, harnessId requestedHarnessId: String? = nil) {
        guard canStartNewTask else { return }
        if isDemoMode {
            selectedWorkspaceId = workspaceId
            selectedSessionId = nil
            draftHarnessId = requestedHarnessId ?? selectedHarnessId
            draftSessionId = "demo-draft"
            activeSubagent = nil
            draft = ""
            pendingImages = []
            errorMessage = nil
            return
        }
        draftPreparationTask?.cancel()
        draftPreparationGeneration += 1
        let generation = draftPreparationGeneration
        let abandonedDraft = draftSessionId
        let harnessId = requestedHarnessId ?? selectedHarnessId
        draftSessionId = nil
        draftHarnessId = harnessId
        selectedWorkspaceId = workspaceId
        selectedSessionId = nil
        activeSubagent = nil
        draft = ""
        pendingImages = []
        sessionModels = nil
        sessionModelsError = nil
        skills = []
        commands = []
        subagents = []
        UserDefaults.standard.removeObject(forKey: "OpenCodex.iPhone.lastSession")
        scheduleCache()
        if let abandonedDraft {
            Task { [weak self] in
                guard let self else { return }
                try? await self.api.discardSession(abandonedDraft)
            }
        }
        guard !harnessId.isEmpty else {
            isLoadingSessionModels = false
            errorMessage = "Choose and configure a default Harness before starting a task."
            return
        }
        isLoadingSessionModels = true
        draftPreparationTask = Task { [weak self] in
            await self?.prepareNewTaskControls(
                generation: generation,
                workspaceId: workspaceId,
                harnessId: harnessId
            )
        }
    }

    func changeNewTaskWorkspace(to workspaceId: String?) {
        let harnessId = currentHarnessId
        newTask(in: workspaceId, harnessId: harnessId)
    }

    private func prepareNewTaskControls(generation: Int, workspaceId: String?, harnessId: String) async {
        guard !Task.isCancelled,
              generation == draftPreparationGeneration,
              selectedSessionId == nil,
              draftSessionId == nil else { return }
        let requestedSessionId = UUID().uuidString.lowercased()
        draftSessionId = requestedSessionId
        scheduleCache()
        do {
            let sessionId = try await api.createSession(
                workspaceId: workspaceId,
                harnessId: harnessId,
                sessionId: requestedSessionId
            )
            guard sessionId == requestedSessionId else {
                throw MobileApiError.host(
                    "session-identity-mismatch",
                    "The Mac returned a different id for the prepared task."
                )
            }
            guard !Task.isCancelled,
                  generation == draftPreparationGeneration,
                  selectedWorkspaceId == workspaceId,
                  (draftHarnessId ?? selectedHarnessId) == harnessId,
                  selectedSessionId == nil,
                  draftSessionId == requestedSessionId else {
                try? await api.discardSession(sessionId)
                return
            }
            await refresh()
            async let historyRequest = api.history(sessionId: sessionId)
            async let modelsRequest: Void = loadModels(sessionId: sessionId)
            async let presetsRequest = try? api.agentPresets()
            let history = try await historyRequest
            records[sessionId] = merge(records[sessionId] ?? [], history.events)
            historyHasMore[sessionId] = history.hasMore
            if let values = history.projections?.values {
                projections[sessionId, default: [:]].merge(values) { _, new in new }
            }
            await resolveHarnessSnapshot(sessionId: sessionId, history: history)
            await modelsRequest
            agentPresets = await presetsRequest
            objectWillChange.send()
            scheduleCache()
        } catch {
            guard !Task.isCancelled,
                  !isOpenFishCancellation(error),
                  generation == draftPreparationGeneration else { return }
            isLoadingSessionModels = false
            sessionModelsError = error.localizedDescription
            errorMessage = "Could not prepare a new task: \(error.localizedDescription)"
            scheduleCache()
        }
    }

    /// Reconcile a cached or response-lost prepared task with the Mac Host.
    /// The client-generated session id makes creation idempotent across iOS
    /// background cancellation, Wi-Fi loss, and app relaunch.
    private func resumePreparedDraftIfPossible() async -> Bool {
        guard selectedSessionId == nil,
              let draftSessionId,
              let harnessId = draftHarnessId,
              !harnessId.isEmpty else { return false }

        var summary = sessions.first(where: { $0.sessionId == draftSessionId })
        if summary == nil {
            do {
                let recovered = try await api.createSession(
                    workspaceId: selectedWorkspaceId,
                    harnessId: harnessId,
                    sessionId: draftSessionId
                )
                guard recovered == draftSessionId else {
                    throw MobileApiError.host(
                        "session-identity-mismatch",
                        "The Mac returned a different id while recovering the prepared task."
                    )
                }
                let authoritative = try await api.sessions()
                for session in authoritative {
                    if let values = session.projections?.values {
                        projections[session.sessionId, default: [:]].merge(values) { _, new in new }
                    }
                }
                sessions = authoritative
                summary = sessions.first(where: { $0.sessionId == draftSessionId })
            } catch {
                sessionModels = nil
                isLoadingSessionModels = false
                sessionModelsError = error.localizedDescription
                errorMessage = "Could not recover the prepared task: \(error.localizedDescription)"
                scheduleCache()
                return true
            }
        }

        guard let summary,
              summary.origin != "subagent",
              !archived.contains(summary.sessionId) else {
            self.draftSessionId = nil
            draftHarnessId = nil
            scheduleCache()
            return false
        }
        if !summary.blank {
            self.draftSessionId = nil
            draftHarnessId = nil
            await select(summary.sessionId)
            return true
        }

        selectedWorkspaceId = workspaces.first(where: { $0.sessionIds.contains(summary.sessionId) })?.workspaceId
        draftHarnessId = summary.harnessId
        sessionModels = nil
        sessionModelsError = nil
        isLoadingSessionModels = true
        do {
            async let historyRequest = api.history(sessionId: summary.sessionId)
            async let modelsRequest: Void = loadModels(sessionId: summary.sessionId)
            async let presetsRequest = try? api.agentPresets()
            let history = try await historyRequest
            records[summary.sessionId] = merge(records[summary.sessionId] ?? [], history.events)
            historyHasMore[summary.sessionId] = history.hasMore
            if let values = history.projections?.values {
                projections[summary.sessionId, default: [:]].merge(values) { _, new in new }
            }
            await resolveHarnessSnapshot(sessionId: summary.sessionId, history: history)
            await modelsRequest
            agentPresets = await presetsRequest
        } catch {
            guard !Task.isCancelled, !isOpenFishCancellation(error) else { return true }
            sessionModelsError = error.localizedDescription
            errorMessage = "Could not restore the prepared task controls: \(error.localizedDescription)"
        }
        objectWillChange.send()
        scheduleCache()
        return true
    }

    private func resolveHarnessSnapshot(sessionId: String, history: MobileHistory) async {
        let selected = history.events.last(where: { $0.event.type == "harness/selected" })?.event.data
        let summary = sessions.first(where: { $0.sessionId == sessionId })
        let harnessId = selected?["harnessId"]?.stringValue ?? summary?.harnessId ?? "dsh"
        let version = selected?["version"]?.stringValue ?? summary?.harnessVersion
        let authMethod = selected?["authMethod"]?.stringValue ?? summary?.harnessAuthMethod
        do {
            harnessesBySession[sessionId] = try await api.resolveHarness(
                id: harnessId,
                version: version,
                authMethod: authMethod
            )
            objectWillChange.send()
        } catch {
            harnessesBySession[sessionId] = nil
            errorMessage = "This task is pinned to a Harness setup that is not available: \(error.localizedDescription)"
        }
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !pendingImages.isEmpty), !isSending else { return }
        if isDemoMode {
            draft = ""
            pendingImages = []
            errorMessage = "Demo State is read-only and never sends prompts to a Mac Host or provider."
            return
        }
        guard pendingImages.isEmpty || canAttachImages else {
            errorMessage = "\(currentHarness?.name ?? "This Harness") does not accept image input through its current Driver. Remove the images or choose a compatible Harness."
            return
        }
        guard activeSubagent != nil || sessionModels?.routable == true else {
            errorMessage = sessionModels == nil
                ? "OpenFish is still checking this Harness's model and account. Wait or refresh model discovery."
                : "The selected model cannot run. Choose a configured model before sending."
            return
        }
        guard activeSubagent != nil || selectedSessionId != nil || draftSessionId != nil
                || draftHarnessId != nil || !selectedHarnessId.isEmpty else {
            errorMessage = "Choose and configure a default Harness on your Mac before starting a task."
            return
        }
        isSending = true
        let images = pendingImages
        draft = ""
        pendingImages = []
        let firstTurnHarnessId = draftHarnessId ?? selectedHarnessId
        var firstTurnSessionId: String?
        do {
            let id: String
            if let activeSubagent {
                guard images.isEmpty else {
                    throw MobileApiError.host(
                        "subagent-images-unsupported",
                        "Attach images to the parent task; continuable subagent follow-ups currently accept text."
                    )
                }
                guard activeSubagent.mode == "continuable" else {
                    throw MobileApiError.host("subagent-read-only", "This one-shot subagent cannot accept follow-up prompts.")
                }
                id = activeSubagent.childSessionId
                try await api.promptSubagent(
                    parentSessionId: activeSubagent.parentSessionId,
                    childSessionId: activeSubagent.childSessionId,
                    text: text
                )
                errorMessage = nil
                scheduleCache()
                isSending = false
                return
            } else if let selectedSessionId { id = selectedSessionId }
            else if let draftSessionId {
                id = draftSessionId
                firstTurnSessionId = id
                self.draftSessionId = nil
                self.draftHarnessId = nil
                selectedSessionId = id
                UserDefaults.standard.set(id, forKey: "OpenCodex.iPhone.lastSession")
                scheduleCache()
            }
            else {
                let requestedSessionId = UUID().uuidString.lowercased()
                id = try await api.createSession(
                    workspaceId: selectedWorkspaceId,
                    harnessId: draftHarnessId ?? selectedHarnessId,
                    sessionId: requestedSessionId
                )
                guard id == requestedSessionId else {
                    throw MobileApiError.host(
                        "session-identity-mismatch",
                        "The Mac returned a different id for the task."
                    )
                }
                firstTurnSessionId = id
                selectedSessionId = id
                UserDefaults.standard.set(id, forKey: "OpenCodex.iPhone.lastSession")
                await refresh()
            }
            try await api.prompt(sessionId: id, text: text, images: images, mode: promptMode)
            errorMessage = nil
            scheduleCache()
        } catch {
            if let firstTurnSessionId {
                await reconcileFailedFirstTurn(
                    sessionId: firstTurnSessionId,
                    harnessId: firstTurnHarnessId
                )
            }
            draft = text
            pendingImages = images
            errorMessage = "Could not send: \(error.localizedDescription)"
        }
        isSending = false
    }

    private func reconcileFailedFirstTurn(sessionId: String, harnessId: String) async {
        do {
            let authoritative = try await api.sessions()
            sessions = authoritative
            guard let summary = authoritative.first(where: { $0.sessionId == sessionId }),
                  summary.blank,
                  summary.origin != "subagent",
                  !archived.contains(sessionId) else { return }
            selectedSessionId = nil
            draftSessionId = sessionId
            draftHarnessId = summary.harnessId.isEmpty ? harnessId : summary.harnessId
            UserDefaults.standard.removeObject(forKey: "OpenCodex.iPhone.lastSession")
            scheduleCache()
        } catch {
            // Preserve the selected identity until the Mac can answer whether
            // the turn was admitted; never risk creating a duplicate task.
        }
    }

    func cancel() async {
        guard let conversationSessionId else { return }
        do {
            if let activeSubagent {
                try await api.interruptSubagent(
                    parentSessionId: activeSubagent.parentSessionId,
                    childSessionId: activeSubagent.childSessionId
                )
            } else {
                try await api.cancel(sessionId: conversationSessionId)
            }
        }
        catch { errorMessage = error.localizedDescription }
    }

    func mutateQueue(_ item: MobileQueuedItem, action: String, replacement: String? = nil) async {
        guard let conversationSessionId else { return }
        let value: MobileJSONValue
        switch action {
        case "remove": value = .object(["kind": .string("remove")])
        case "steer": value = .object(["kind": .string("steer")])
        case "edit":
            value = .object([
                "kind": .string("edit"),
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string(replacement ?? item.text),
                ])]),
            ])
        default: return
        }
        do {
            try await api.updateQueue(sessionId: conversationSessionId, itemId: item.id, action: value)
            errorMessage = nil
        } catch { errorMessage = "Could not update queued work: \(error.localizedDescription)" }
    }

    @discardableResult
    func chooseModel(provider: String, model: MobileCatalogModel, effort: String? = nil) async -> Bool {
        guard let selectedSessionId = controlSessionId, !isChangingModel else { return false }
        isChangingModel = true
        defer { isChangingModel = false }
        if isDemoMode {
            if let catalog = sessionModels {
                sessionModels = MobileSessionModels(
                    current: MobileModelSelection(
                        provider: provider,
                        model: model.id,
                        reasoningEffort: effort ?? model.reasoning?.defaultEffort
                    ),
                    routable: catalog.routable,
                    groups: catalog.groups,
                    failures: catalog.failures,
                    account: catalog.account,
                    harnessOptions: catalog.harnessOptions
                )
            }
            return true
        }
        do {
            let selected = try await api.selectModel(
                sessionId: selectedSessionId,
                selection: MobileModelSelection(provider: provider, model: model.id, reasoningEffort: effort)
            )
            if let catalog = sessionModels {
                sessionModels = MobileSessionModels(
                    current: selected,
                    routable: catalog.routable,
                    groups: catalog.groups,
                    failures: catalog.failures,
                    account: catalog.account,
                    harnessOptions: catalog.harnessOptions
                )
            }
            // Model changes may replace the Harness's reasoning levels and
            // other configuration directory. Always reload its authority.
            await loadModels(sessionId: selectedSessionId)
            errorMessage = nil
            scheduleCache()
            return true
        } catch {
            await loadModels(sessionId: selectedSessionId)
            errorMessage = "Could not switch models: \(error.localizedDescription)"
            return false
        }
    }

    func chooseReasoningEffort(_ effort: String) async {
        guard let models = sessionModels,
              let model = currentModel else { return }
        await chooseModel(provider: models.current.provider, model: model, effort: effort)
    }

    func refreshCurrentModels() async {
        guard let selectedSessionId = controlSessionId else { return }
        if self.selectedSessionId == nil,
           draftSessionId == selectedSessionId,
           !sessions.contains(where: { $0.sessionId == selectedSessionId }) {
            _ = await resumePreparedDraftIfPossible()
            return
        }
        await loadModels(sessionId: selectedSessionId)
    }

    private func loadModels(sessionId: String) async {
        guard controlSessionId == sessionId else { return }
        isLoadingSessionModels = true
        sessionModelsError = nil
        defer {
            if controlSessionId == sessionId { isLoadingSessionModels = false }
        }
        do {
            let models = try await api.models(sessionId: sessionId)
            if controlSessionId == sessionId {
                sessionModels = models
                sessionModelsError = nil
            }
        } catch {
            guard !Task.isCancelled, !isOpenFishCancellation(error) else { return }
            if controlSessionId == sessionId {
                sessionModels = nil
                sessionModelsError = error.localizedDescription
            }
        }
    }

    func chooseHarnessConfig(_ option: MobileHarnessConfigOption, value: MobileJSONValue) async {
        guard let selectedSessionId = controlSessionId, !isChangingHarnessConfig else { return }
        isChangingHarnessConfig = true
        defer { isChangingHarnessConfig = false }
        do {
            let options = try await api.setHarnessConfig(
                sessionId: selectedSessionId,
                configId: option.id,
                value: value
            )
            if let catalog = sessionModels {
                sessionModels = MobileSessionModels(
                    current: catalog.current,
                    routable: catalog.routable,
                    groups: catalog.groups,
                    failures: catalog.failures,
                    account: catalog.account,
                    harnessOptions: options
                )
            }
            // ACP options can be interdependent, so consume the complete
            // directory returned after every change.
            await loadModels(sessionId: selectedSessionId)
            errorMessage = nil
            scheduleCache()
        } catch {
            await loadModels(sessionId: selectedSessionId)
            errorMessage = "Could not change \(option.name): \(error.localizedDescription)"
        }
    }

    func choosePermission(_ option: MobilePermissionOption) async {
        guard let selectedSessionId = controlSessionId, option.value != "custom" else { return }
        do {
            let execution = try await api.executeCommand(
                sessionId: selectedSessionId,
                line: "/permission \(option.value)"
            )
            guard execution.result.kind == "success" else {
                throw MobileApiError.host("command-error", execution.result.text ?? "Permission change failed")
            }
            let history = try await api.history(sessionId: selectedSessionId)
            records[selectedSessionId] = merge(records[selectedSessionId] ?? [], history.events)
            historyHasMore[selectedSessionId] = history.hasMore
            if let values = history.projections?.values {
                projections[selectedSessionId, default: [:]].merge(values) { _, new in new }
            }
            errorMessage = nil
            objectWillChange.send()
            scheduleCache()
        } catch { errorMessage = "Could not change access: \(error.localizedDescription)" }
    }

    func requiresMacCodeConsent(_ harness: MobileHarness) -> Bool {
        !harness.verified
            && harness.source != "user"
            && (harness.installation.status != "installed"
                || harness.installation.installedVersion != harness.installation.availableVersion)
    }

    func explainRequiredMacSetup(for harness: MobileHarness) {
        errorMessage = requiresMacCodeConsent(harness)
            ? "Open \(harness.name) in OpenFish on the Host Mac to review and admit its exact third-party code first. A paired iPhone cannot grant Host code execution."
            : "Finish setting up \(harness.name) in OpenFish on the connected Mac."
    }

    func chooseHarness(_ harness: MobileHarness, force: Bool = false) async {
        guard canChooseHarness, harnessOperationId == nil else { return }
        let samePinnedIdentity = harness.id == currentHarnessId
            && harness.auth.selectedMethod == currentHarnessAuthMethod
        guard force || !samePinnedIdentity else { return }
        guard !requiresMacCodeConsent(harness) else {
            explainRequiredMacSetup(for: harness)
            return
        }
        guard harness.available else {
            errorMessage = harness.unavailableReason ?? "This Harness is not available on the connected Mac."
            return
        }
        harnessOperationId = harness.id
        harnessOperationPhase = "Checking \(harness.name) on the connected Mac…"
        defer {
            harnessOperationId = nil
            harnessOperationPhase = nil
            harnessOperationCancellation = nil
        }
        do {
            let current = harnesses.first(where: { $0.id == harness.id }) ?? harness
            if current.installation.status != "builtin" && current.installation.status != "installed" {
                harnesses = try await runHarnessOperationStep(
                    "Installing exact \(harness.name) \(harness.version) on the Host Mac…",
                    pollInstallationFor: harness.id
                ) {
                    try await self.api.installHarness(harness.id)
                }
            }
            var configured = harnesses.first(where: { $0.id == harness.id }) ?? current
            guard configured.auth.status == "not-required" || configured.auth.status == "configured" else {
                errorMessage = "Configure \(harness.name) authentication on your Mac first."
                return
            }
            configured = try await livePreflightIfNeeded(configured)
            harnessOperationPhase = "Preparing a task pinned to \(configured.name) \(configured.version)…"
            draftPreparationTask?.cancel()
            draftPreparationGeneration += 1
            if let abandonedDraft = draftSessionId { try? await api.discardSession(abandonedDraft) }
            draftSessionId = nil
            selectedSessionId = nil
            draftHarnessId = harness.id
            sessionModels = nil
            sessionModelsError = nil
            isLoadingSessionModels = true
            let generation = draftPreparationGeneration
            let workspaceId = selectedWorkspaceId
            draftPreparationTask = Task { [weak self] in
                await self?.prepareNewTaskControls(generation: generation, workspaceId: workspaceId, harnessId: harness.id)
            }
            errorMessage = nil
        } catch {
            if isOpenFishCancellation(error) {
                errorMessage = nil
            } else {
                errorMessage = "Could not use \(harness.name) for this task: \(error.localizedDescription)"
            }
            harnesses = (try? await api.harnesses()) ?? harnesses
        }
    }

    func selectDefaultHarness(_ harness: MobileHarness) async {
        guard harnessOperationId == nil else { return }
        guard !requiresMacCodeConsent(harness) else {
            explainRequiredMacSetup(for: harness)
            return
        }
        guard harness.available else {
            errorMessage = harness.unavailableReason ?? "This Harness is not available on the connected Mac."
            return
        }
        harnessOperationId = harness.id
        harnessOperationPhase = "Checking \(harness.name) on the connected Mac…"
        defer {
            harnessOperationId = nil
            harnessOperationPhase = nil
            harnessOperationCancellation = nil
        }
        do {
            if harness.installation.status != "builtin" && harness.installation.status != "installed" {
                harnesses = try await runHarnessOperationStep(
                    "Installing exact \(harness.name) \(harness.version) on the Host Mac…",
                    pollInstallationFor: harness.id
                ) {
                    try await self.api.installHarness(harness.id)
                }
            }
            var configured = harnesses.first(where: { $0.id == harness.id }) ?? harness
            guard configured.auth.status == "not-required" || configured.auth.status == "configured" else {
                errorMessage = "Configure \(harness.name) authentication on your Mac first."
                return
            }
            configured = try await livePreflightIfNeeded(configured)
            harnesses = try await runHarnessOperationStep(
                "Saving \(configured.name) as the default Harness…",
                cancellable: false
            ) {
                try await self.api.selectDefaultHarness(configured.id)
            }
            selectedHarnessId = harness.id
            errorMessage = nil
        } catch {
            if isOpenFishCancellation(error) {
                errorMessage = nil
            } else {
                errorMessage = "Could not select \(harness.name): \(error.localizedDescription)"
            }
            harnesses = (try? await api.harnesses()) ?? harnesses
        }
    }

    @discardableResult
    func configureHarness(
        _ harness: MobileHarness,
        method: MobileHarness.Authentication.Method,
        makeDefault: Bool
    ) async -> Bool {
        guard harnessOperationId == nil else { return false }
        guard !requiresMacCodeConsent(harness) else {
            explainRequiredMacSetup(for: harness)
            return false
        }
        guard method.kind != "terminal" else {
            errorMessage = "This sign-in opens an interactive terminal on the connected Mac. Finish it from OpenFish on that Mac."
            return false
        }
        guard method.fields.isEmpty else {
            errorMessage = "This sign-in needs credentials. Configure them on the connected Mac; OpenFish never sends Host secrets from an iPhone."
            return false
        }
        harnessOperationId = harness.id
        harnessOperationPhase = "Checking \(harness.name) on the connected Mac…"
        defer {
            harnessOperationId = nil
            harnessOperationPhase = nil
            harnessOperationCancellation = nil
        }
        do {
            let current = harnesses.first(where: { $0.id == harness.id }) ?? harness
            if current.installation.status != "builtin" && current.installation.status != "installed" {
                harnesses = try await runHarnessOperationStep(
                    "Installing exact \(harness.name) \(harness.version) on the Host Mac…",
                    pollInstallationFor: harness.id
                ) {
                    try await self.api.installHarness(harness.id)
                }
            }
            harnesses = try await runHarnessOperationStep(
                "Confirming \(method.name) on the Host Mac…",
                cancellable: false
            ) {
                try await self.api.mutateHarness(action: "auth", id: harness.id, authMethod: method.id)
            }
            guard var configured = harnesses.first(where: { $0.id == harness.id }), configured.auth.status == "configured" else {
                throw MobileApiError.host(
                    "credential-unavailable",
                    "The Host could not resolve all required credentials for \(harness.name)"
                )
            }
            configured = try await livePreflightIfNeeded(configured)
            if makeDefault {
                harnesses = try await runHarnessOperationStep(
                    "Saving \(configured.name) as the default Harness…",
                    cancellable: false
                ) {
                    try await self.api.selectDefaultHarness(configured.id)
                }
                selectedHarnessId = harness.id
            }
            errorMessage = nil
            scheduleCache()
            return true
        } catch {
            if isOpenFishCancellation(error) {
                errorMessage = nil
            } else {
                errorMessage = "Could not configure \(harness.name): \(error.localizedDescription)"
            }
            harnesses = (try? await api.harnesses()) ?? harnesses
            return false
        }
    }

    func chooseAgentPreset(_ preset: MobileAgentPreset) async {
        guard let selectedSessionId = controlSessionId, controlSession?.blank == true, preset.broken == nil else { return }
        do {
            let selected = try await api.selectAgentPreset(sessionId: selectedSessionId, agentPreset: preset.id)
            if let index = sessions.firstIndex(where: { $0.sessionId == selectedSessionId }) {
                let current = sessions[index]
                sessions[index] = MobileSession(
                    sessionId: current.sessionId,
                    harnessId: current.harnessId,
                    updatedAt: current.updatedAt,
                    running: current.running,
                    blank: current.blank,
                    parentSessionId: current.parentSessionId,
                    origin: current.origin,
                    cwd: current.cwd,
                    agentPreset: selected,
                    projections: current.projections
                )
            }
            errorMessage = nil
            scheduleCache()
        } catch { errorMessage = "Could not switch agent preset: \(error.localizedDescription)" }
    }

    func renameCurrent(_ title: String) async {
        guard let selectedSessionId else { return }
        do {
            let renamed = try await api.renameSession(selectedSessionId, title: title)
            projections[selectedSessionId, default: [:]]["title"] = .string(renamed.title)
            errorMessage = nil
            objectWillChange.send()
            scheduleCache()
        } catch { errorMessage = "Could not rename this task: \(error.localizedDescription)" }
    }

    func forkCurrent() async {
        guard let selectedSessionId else { return }
        guard harnessCan("session.fork") else {
            errorMessage = "\(currentHarness?.name ?? "This Harness") does not expose a real session fork. Start a new task instead."
            return
        }
        do {
            let child = try await api.forkSession(selectedSessionId)
            await refresh()
            await select(child)
            errorMessage = nil
        } catch { errorMessage = "Could not fork this task: \(error.localizedDescription)" }
    }

    func openSubagent(_ entry: MobileSubagentEntry) async {
        guard let parentSessionId = selectedSessionId,
              entry.kind == "child",
              let mode = entry.mode else { return }
        let selection = MobileActiveSubagent(
            parentSessionId: parentSessionId,
            childSessionId: entry.id,
            mode: mode,
            label: entry.label ?? "Subagent"
        )
        activeSubagent = selection
        do {
            let history = try await api.subagentHistory(
                parentSessionId: parentSessionId,
                childSessionId: entry.id,
                mode: mode
            )
            records[entry.id] = merge(records[entry.id] ?? [], history.events)
            historyHasMore[entry.id] = history.hasMore
            if let values = history.projections?.values {
                projections[entry.id, default: [:]].merge(values) { _, new in new }
            }
            errorMessage = nil
            objectWillChange.send()
            scheduleCache()
        } catch {
            activeSubagent = nil
            errorMessage = "Could not open this subagent: \(error.localizedDescription)"
        }
    }

    func closeSubagent() {
        activeSubagent = nil
        objectWillChange.send()
    }

    func createGoal(objective: String, maxRounds: Int?) async {
        guard let conversationSessionId else { return }
        let objective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty else { return }
        do {
            _ = try await api.createGoal(
                sessionId: conversationSessionId,
                objective: objective,
                maxRounds: maxRounds
            )
            await reloadSelectedHistory()
            errorMessage = nil
        } catch { errorMessage = "Could not create this goal: \(error.localizedDescription)" }
    }

    func mutateGoal(_ verb: String) async {
        guard let conversationSessionId, let goal = currentGoal?.goal else { return }
        do {
            _ = try await api.mutateGoal(
                sessionId: conversationSessionId,
                verb: verb,
                ref: MobileGoalRef(id: goal.id, revision: goal.revision)
            )
            await reloadSelectedHistory()
            errorMessage = nil
        } catch { errorMessage = "Could not \(verb) this goal: \(error.localizedDescription)" }
    }

    func setPlanEnabled(_ enabled: Bool) async {
        guard let conversationSessionId else { return }
        do {
            let execution = try await api.executeCommand(
                sessionId: conversationSessionId,
                line: enabled ? "/plan" : "/plan off"
            )
            guard execution.result.kind == "success" else {
                throw MobileApiError.host("command-error", execution.result.text ?? "Plan change failed")
            }
            await reloadSelectedHistory()
            errorMessage = nil
        } catch { errorMessage = "Could not change plan mode: \(error.localizedDescription)" }
    }

    func loadHostInventory() async {
        guard !isLoadingSettings else { return }
        isLoadingSettings = true
        defer { isLoadingSettings = false }
        do {
            async let providersRequest = api.configurableProviders()
            async let pluginsRequest = api.pluginInventory()
            let (providerRows, pluginRows) = try await (
                providersRequest,
                pluginsRequest
            )
            providers = providerRows
            plugins = pluginRows
            errorMessage = nil
        } catch { errorMessage = "Could not load the remote Host inventory: \(error.localizedDescription)" }
    }

    func unpairThisDevice() async {
        guard !profile.isLocal else {
            errorMessage = "The local simulator connection has no paired device credential to revoke."
            return
        }
        do {
            if let abandonedDraft = draftSessionId {
                try? await api.discardSession(abandonedDraft)
                draftSessionId = nil
                draftHarnessId = nil
            }
            guard try await api.revokeCurrentDevice() else {
                throw MobileApiError.host("device-not-found", "This iPhone's pairing no longer exists")
            }
            let forgotten = profile.forgetAuthorization()
            await reconfigure(forgotten, preservesPreviousCache: false)
            showsConnection = true
            errorMessage = nil
        } catch { errorMessage = "Could not unpair this iPhone: \(error.localizedDescription)" }
    }

    private func reloadSelectedHistory() async {
        guard let conversationSessionId else { return }
        do {
            let history: MobileHistory
            if let activeSubagent {
                history = try await api.subagentHistory(
                    parentSessionId: activeSubagent.parentSessionId,
                    childSessionId: activeSubagent.childSessionId,
                    mode: activeSubagent.mode
                )
            } else {
                history = try await api.history(sessionId: conversationSessionId)
            }
            records[conversationSessionId] = merge(records[conversationSessionId] ?? [], history.events)
            historyHasMore[conversationSessionId] = history.hasMore
            if let values = history.projections?.values {
                projections[conversationSessionId, default: [:]].merge(values) { _, new in new }
            }
            objectWillChange.send()
            scheduleCache()
        } catch {
            errorMessage = "Could not refresh this task: \(error.localizedDescription)"
        }
    }

    func answer(_ approval: MobileApproval, allow: Bool) async {
        if isDemoMode {
            approvals[approval.approvalId] = nil
            return
        }
        do {
            try await api.answer(approval, allow: allow)
            approvals[approval.approvalId] = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func answer(_ question: MobilePendingQuestion, answers: [MobileQuestionAnswer]) async {
        if isDemoMode {
            questions[question.rpcId] = nil
            return
        }
        do {
            try await api.answer(question, answers: answers)
            questions[question.rpcId] = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func toggleDictation() async {
        guard !isDemoMode || ProcessInfo.processInfo.arguments.contains("--openfish-voice-smoke") else {
            errorMessage = "Microphone access is disabled in the network-isolated Demo State."
            return
        }
        let prefix = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        await voice.toggle { [weak self] transcript, _ in
            self?.draft = prefix.isEmpty ? transcript : "\(prefix) \(transcript)"
        }
        if let error = voice.errorMessage {
            errorMessage = error
        } else {
            errorMessage = nil
        }
    }

    func startVoiceConversation() async {
        guard canStartNewTask else { return }
        guard !isDemoMode || ProcessInfo.processInfo.arguments.contains("--openfish-voice-smoke") else {
            errorMessage = "Microphone access is disabled in the network-isolated Demo State."
            return
        }
        guard activeSubagent != nil || sessionModels?.routable == true else {
            errorMessage = sessionModels == nil
                ? "OpenFish is still checking this Harness's model and account."
                : "Choose a configured model before starting voice conversation."
            return
        }
        showsVoiceConversation = true
        voiceConversationStatus = "Listening"
        voiceConversationTranscript = ""
        await listenForVoiceConversation()
    }

    func stopVoiceConversation() {
        showsVoiceConversation = false
        voiceConversationStatus = "Ready"
        voiceConversationTranscript = ""
        voiceConversationSessionId = nil
        voice.stopListening()
        voice.stopSpeaking()
    }

    func interruptVoiceConversation() async {
        guard showsVoiceConversation else { return }
        voice.stopSpeaking()
        voiceConversationStatus = "Listening"
        voiceConversationTranscript = ""
        await listenForVoiceConversation()
    }

    private func listenForVoiceConversation() async {
        guard showsVoiceConversation, !voice.isListening else { return }
        await voice.startListening { [weak self] transcript, isFinal in
            guard let self, self.showsVoiceConversation else { return }
            self.voiceConversationTranscript = transcript
            self.voiceConversationStatus = isFinal ? "Sending to the selected Harness" : "Listening"
            if isFinal {
                Task { @MainActor [weak self] in await self?.submitVoiceTranscript(transcript) }
            }
        }
        if let error = voice.errorMessage, showsVoiceConversation {
            voiceConversationStatus = error
        }
    }

    private func submitVoiceTranscript(_ transcript: String) async {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard showsVoiceConversation, !text.isEmpty else {
            if showsVoiceConversation { await listenForVoiceConversation() }
            return
        }
        guard activeSubagent != nil || selectedSessionId != nil || draftHarnessId != nil || !selectedHarnessId.isEmpty else {
            voiceConversationStatus = "Choose a default Harness on your Mac first"
            return
        }
        let firstTurnHarnessId = draftHarnessId ?? selectedHarnessId
        var firstTurnSessionId: String?
        do {
            let sessionId: String
            if let activeSubagent {
                sessionId = activeSubagent.childSessionId
            } else if let selectedSessionId {
                sessionId = selectedSessionId
            } else if let draftSessionId {
                sessionId = draftSessionId
                firstTurnSessionId = sessionId
                self.draftSessionId = nil
                self.draftHarnessId = nil
                self.selectedSessionId = sessionId
                UserDefaults.standard.set(sessionId, forKey: "OpenCodex.iPhone.lastSession")
                scheduleCache()
            } else {
                let requestedSessionId = UUID().uuidString.lowercased()
                sessionId = try await api.createSession(
                    workspaceId: selectedWorkspaceId,
                    harnessId: draftHarnessId ?? selectedHarnessId,
                    sessionId: requestedSessionId
                )
                guard sessionId == requestedSessionId else {
                    throw MobileApiError.host(
                        "session-identity-mismatch",
                        "The Mac returned a different id for the voice task."
                    )
                }
                firstTurnSessionId = sessionId
                self.selectedSessionId = sessionId
                UserDefaults.standard.set(sessionId, forKey: "OpenCodex.iPhone.lastSession")
                await refresh()
            }
            voiceConversationSessionId = sessionId
            lastVoiceTurnEndSeq = records[sessionId]?.last(where: { $0.event.type == "turn/end" })?.event.seq ?? -1
            let running = conversationRunning
            voiceConversationStatus = running ? "Steering current task" : "OpenFish is working"
            if let activeSubagent {
                guard activeSubagent.mode == "continuable" else {
                    throw MobileApiError.host("subagent-read-only", "This one-shot subagent cannot accept follow-up prompts.")
                }
                try await api.promptSubagent(
                    parentSessionId: activeSubagent.parentSessionId,
                    childSessionId: activeSubagent.childSessionId,
                    text: text
                )
            } else {
                try await api.prompt(sessionId: sessionId, text: text, images: [], mode: running ? "steer" : "queue")
            }
            errorMessage = nil
            scheduleCache()
        } catch {
            if let firstTurnSessionId {
                await reconcileFailedFirstTurn(
                    sessionId: firstTurnSessionId,
                    harnessId: firstTurnHarnessId
                )
            }
            voiceConversationStatus = "Could not send"
            errorMessage = "Could not send the voice transcript: \(error.localizedDescription)"
            try? await Task.sleep(for: .milliseconds(800))
            if showsVoiceConversation {
                voiceConversationStatus = "Listening"
                voiceConversationTranscript = ""
                await listenForVoiceConversation()
            }
        }
    }

    private func finishVoiceTurn(sessionId: String, endSeq: Int) {
        guard showsVoiceConversation,
              voiceConversationSessionId == sessionId,
              endSeq > lastVoiceTurnEndSeq else { return }
        lastVoiceTurnEndSeq = endSeq
        let response = MobileConversationProjector.project(records[sessionId] ?? [])
            .last(where: { $0.kind == .assistant && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .text
        guard let response else {
            voiceConversationStatus = "Listening"
            Task { await listenForVoiceConversation() }
            return
        }
        voiceConversationStatus = "Speaking"
        voice.speak(response) { [weak self] in
            guard let self, self.showsVoiceConversation else { return }
            self.voiceConversationStatus = "Listening"
            self.voiceConversationTranscript = ""
            Task { @MainActor [weak self] in await self?.listenForVoiceConversation() }
        }
    }

    func addImage(data: Data, name: String, mediaType: String) {
        guard canAttachImages else {
            errorMessage = "\(currentHarness?.name ?? "This Harness") does not advertise image input through its current Driver."
            return
        }
        pendingImages.append(MobilePendingImage(name: name, mediaType: mediaType, data: data))
    }

    func removeImage(_ id: UUID) { pendingImages.removeAll { $0.id == id } }

    func connect(host: String, pairingCode: String) async {
        guard let url = MobileConnectionProfile.normalizedURL(host) else {
            recordConnectionDiagnostic("pair:failed-normalize-host")
            errorMessage = "Enter the Host's https:// address. Remote OpenFish traffic is never sent over plain HTTP."
            return
        }
        var stage = "prepare"
        do {
            let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
            let token: String?
            let tlsFingerprint: String?
            var persistentURL = url
            if !code.isEmpty {
                stage = "request"
                recordConnectionDiagnostic("pair:request-started")
                let result = try await XIOSClient(
                    baseURL: url,
                    permitsBootstrapTrust: true
                ).pair(
                    deviceName: UIDevice.current.name,
                    code: code
                )
                stage = "receipt"
                recordConnectionDiagnostic("pair:receipt-received")
                token = result.receipt.token
                tlsFingerprint = result.tlsFingerprint
                if let advertised = result.receipt.hostURL {
                    guard let canonical = MobileConnectionProfile.normalizedURL(advertised),
                          canonical.scheme == "https" else {
                        throw MobileApiError.transport("The paired Host returned an invalid persistent address.")
                    }
                    persistentURL = canonical
                }
            } else if url == MobileConnectionProfile.local.baseURL {
                token = nil
                tlsFingerprint = nil
            } else {
                throw MobileApiError.host("pairing-required", "Enter the one-time code shown by OpenFish on the Host Mac.")
            }
            let next = MobileConnectionProfile(
                baseURL: persistentURL,
                bearerToken: token,
                tlsFingerprint: tlsFingerprint
            )
            stage = "persist"
            try next.persist()
            if persistentURL != url {
                MobileConnectionProfile.removeAuthorization(for: url)
            }
            recordConnectionDiagnostic("pair:profile-persisted")
            stage = "reconfigure"
            await reconfigure(next)
            recordConnectionDiagnostic("pair:reconfigured")
            showsConnection = false
        } catch {
            recordConnectionDiagnostic("pair:failed-\(stage)-\(connectionDiagnosticCode(for: error))")
            errorMessage = "Could not pair: \(error.localizedDescription)"
        }
    }

    private func reconfigure(
        _ next: MobileConnectionProfile,
        preservesPreviousCache: Bool = true
    ) async {
        recordConnectionDiagnostic("reconfigure:stopping-previous")
        stopVoiceConversation()
        connectionProblem = nil
        hostIssue = nil
        hasLiveBaseline = false
        connectionTask?.cancel()
        cacheTask?.cancel()
        draftPreparationTask?.cancel()
        if let abandonedDraft = draftSessionId {
            do {
                try await api.discardSession(abandonedDraft)
                draftSessionId = nil
                draftHarnessId = nil
            } catch {
                // Keep the old Host's host-keyed recovery snapshot.
            }
        }
        if preservesPreviousCache {
            await cache.save(cacheSnapshot())
        } else {
            await cache.clear(matching: profile.baseURL)
        }
        await connection.stop()
        profile = next
        api = XIOSClient(
            baseURL: next.baseURL,
            bearerToken: next.bearerToken,
            tlsFingerprint: next.tlsFingerprint
        )
        connection = MobileLiveConnection(
            baseURL: next.baseURL,
            token: next.bearerToken,
            tlsFingerprint: next.tlsFingerprint
        )
        recordConnectionDiagnostic("reconfigure:profile-active")
        purgeHostProjection()
        isLoadingSessionModels = false
        connectionState = .connecting
        if let snapshot = await cache.load(matching: next.baseURL) {
            restore(snapshot)
        }
        recordConnectionDiagnostic("reconfigure:starting-connection")
        await startConnection()
    }

    func retryHostConnection() async {
        guard !isDemoMode else { return }
        guard !profile.requiresPairing else {
            showsConnection = true
            return
        }
        connectionTask?.cancel()
        connectionTask = nil
        await connection.stop()
        connectionState = .connecting
        connectionProblem = nil
        hostIssue = nil
        hasLiveBaseline = false
        await startConnection()
    }

    func importURLs(_ urls: [URL]) async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            let files = try urls.map { url -> (String, Data) in
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                return (url.lastPathComponent, try Data(contentsOf: url, options: .mappedIfSafe))
            }
            let imported = try await api.importFiles(files, workspaceId: selectedWorkspaceId)
            await refresh()
            if let root = imported.first(where: \.root) ?? imported.first { await select(root.sessionId) }
            scheduleCache()
        } catch { errorMessage = "Import failed: \(error.localizedDescription)" }
    }

    func prepareExport() async {
        guard let selectedSessionId else { return }
        do {
            let data = try await api.exportSession(selectedSessionId)
            let url = FileManager.default.temporaryDirectory
                .appending(path: "OpenFish-\(selectedSessionId).zip")
            try data.write(to: url, options: .atomic)
            exportURL = url
        } catch { errorMessage = "Export failed: \(error.localizedDescription)" }
    }

    private func handle(_ update: MobileLiveUpdate) async {
        switch update {
        case .authorizationRevoked:
            recordConnectionDiagnostic("connection:authorization-revoked")
            let revokedHost = profile.baseURL
            profile = profile.forgetAuthorization()
            purgeHostProjection()
            cacheTask?.cancel()
            await cache.clear(matching: revokedHost)
            connectionState = .reconnecting(0)
            hasLiveBaseline = false
            connectionProblem = "This iPhone was unpaired. Enter a new one-time code from the Mac Host."
            hostIssue = .init(
                kind: .recoverable,
                title: "This iPhone was unpaired",
                message: connectionProblem ?? "Pair this iPhone again."
            )
            await connection.stop()
            connectionTask?.cancel()
            connectionTask = nil
        case let .state(state):
            connectionState = state
            switch state {
            case .connecting:
                recordConnectionDiagnostic("connection:connecting")
            case .connected:
                recordConnectionDiagnostic("connection:connected")
            case let .reconnecting(attempt):
                recordConnectionDiagnostic("connection:reconnecting-\(attempt)")
            }
            if state != .connected { hasLiveBaseline = false }
            if state == .connected {
                approvals = [:]
                questions = [:]
                queuedItems = [:]
                let selected = selectedSessionId
                await refresh(selectRemembered: selected == nil)
                if let selected, sessions.contains(where: { $0.sessionId == selected }) {
                    await select(selected)
                }
#if DEBUG
                if connectionState == .connected && hasLiveBaseline {
                    hardwareBaselineGeneration += 1
                    if hardwareProjectlessTask != nil {
                        let state = projectlessHardwareFailure().map { "failed-\($0)" } ?? "foreground-restored"
                        recordConnectionDiagnostic("projectless-self-test:\(state)")
                    }
                }
#endif
            }
        case let .feed(frame):
            handleFeed(frame)
            scheduleCache()
        }
    }

    private func handleFeed(_ frame: MobileJSONValue) {
        guard let channel = frame["channel"]?.stringValue,
              let value = frame["value"] else { return }
        switch channel {
        case "remote-events": handleRemoteEvents(value)
        case "workspace": handleWorkspaceFeed(value)
        case "control": handleControlFeed(value)
        case "session":
            guard let sessionId = frame["sessionId"]?.stringValue else { return }
            handleSessionFeed(value, sessionId: sessionId)
        default: break
        }
    }

    private func handleRemoteEvents(_ frame: MobileJSONValue) {
        switch frame["type"]?.stringValue {
        case "ready":
            remoteEventClientId = frame["clientId"]?.stringValue
            approvals.removeAll(keepingCapacity: true)
            questions.removeAll(keepingCapacity: true)
        case "emit":
            guard let event = frame["event"]?.stringValue else { return }
            let args = frame["args"]?.arrayValue ?? []
            switch event {
            case "api-session/added":
                guard let value = args.first, let session = try? value.decode(MobileSession.self) else { return }
                if let index = sessions.firstIndex(where: { $0.sessionId == session.sessionId }) {
                    sessions[index] = session
                } else {
                    sessions.append(session)
                }
            case "api-session/removed":
                guard let id = args.first?.stringValue else { return }
                removeSessionProjection(id)
            case "api-session/status":
                guard args.count >= 2,
                      let id = args[0].stringValue,
                      let running = args[1].boolValue,
                      let index = sessions.firstIndex(where: { $0.sessionId == id }) else { return }
                let wasRunning = sessions[index].running
                sessions[index].running = running
                if running { sessions[index].blank = false }
                sessions[index].updatedAt = Date().timeIntervalSince1970 * 1_000
                if wasRunning && !running && UIApplication.shared.applicationState != .active {
                    let taskTitle = title(for: sessions[index])
                    Task { await notifications.post(title: taskTitle, body: "Task finished", sessionId: id) }
                }
            case "api-session/activity":
                guard args.count >= 2,
                      let id = args[0].stringValue,
                      case let .number(updatedAt) = args[1],
                      let index = sessions.firstIndex(where: { $0.sessionId == id }) else { return }
                sessions[index].updatedAt = updatedAt
                sessions[index].blank = false
            case "api-session/error":
                guard args.count >= 2,
                      let id = args[0].stringValue,
                      let message = args[1].stringValue else { return }
                if id == selectedSessionId { errorMessage = message }
                if id == voiceConversationSessionId { voiceConversationStatus = "Task failed" }
            case "agent-preset/selected", "commands/change", "credentials/reference-updated",
                 "llm/adapters-updated":
                Task { await refreshLiveCatalogs(after: event) }
            default: break
            }
        case "waterfall":
            guard let clientId = remoteEventClientId,
                  let event = frame["event"]?.stringValue,
                  let eventId = frame["eventId"]?.stringValue,
                  let sessionId = frame["agentId"]?.stringValue,
                  let request = frame["request"] else { return }
            switch event {
            case "approval/request":
                guard let toolName = request["toolName"]?.stringValue else { return }
                approvals[eventId] = MobileApproval(
                    clientId: clientId,
                    rpcId: eventId,
                    sessionId: sessionId,
                    approvalId: eventId,
                    toolName: toolName,
                    reason: request["reason"]?.stringValue
                )
                if sessionId == voiceConversationSessionId {
                    voiceConversationStatus = "Approval required"
                    voice.stopSpeaking()
                }
            case "user-questions/request":
                let values = request["questions"]
                let decoded = (try? values?.decode([MobileQuestion].self)) ?? []
                questions[eventId] = MobilePendingQuestion(
                    clientId: clientId,
                    rpcId: eventId,
                    sessionId: sessionId,
                    questions: decoded
                )
                if sessionId == voiceConversationSessionId {
                    voiceConversationStatus = "Answer required"
                    voice.stopSpeaking()
                }
            default: break
            }
        case "cancel":
            guard let eventId = frame["eventId"]?.stringValue else { return }
            approvals[eventId] = nil
            questions[eventId] = nil
        default: break
        }
    }

    private func refreshLiveCatalogs(after event: String) async {
        switch event {
        case "agent-preset/selected": agentPresets = try? await api.agentPresets()
        case "commands/change":
            if let sessionId = controlSessionId { commands = (try? await api.commandDirectory(sessionId: sessionId)) ?? [] }
        case "credentials/reference-updated": providers = (try? await api.configurableProviders()) ?? providers
        case "llm/adapters-updated":
            if let sessionId = controlSessionId { await loadModels(sessionId: sessionId) }
        default: break
        }
    }

    private func handleWorkspaceFeed(_ frame: MobileJSONValue) {
        switch frame["type"]?.stringValue {
        case "baseline":
            guard let value = frame["value"] else { return }
            workspaces = value["items"]?.arrayValue?.compactMap { try? $0.decode(MobileWorkspace.self) } ?? []
            archived = Set(value["archivedSessionIds"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        case "upsert":
            guard let value = frame["workspace"], let workspace = try? value.decode(MobileWorkspace.self) else { return }
            if let index = workspaces.firstIndex(where: { $0.workspaceId == workspace.workspaceId }) {
                workspaces[index] = workspace
            } else {
                workspaces.append(workspace)
            }
        case "remove":
            guard let id = frame["workspaceId"]?.stringValue else { return }
            workspaces.removeAll { $0.workspaceId == id }
            if selectedWorkspaceId == id { selectedWorkspaceId = nil }
        case "order":
            guard let ids = frame["workspaceIds"]?.arrayValue?.compactMap(\.stringValue) else { return }
            let byId = workspaces.reduce(into: [String: MobileWorkspace]()) { $0[$1.workspaceId] = $1 }
            workspaces = ids.compactMap { byId[$0] }
        case "archived":
            archived = Set(frame["archivedSessionIds"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        default: break
        }
    }

    private func handleControlFeed(_ frame: MobileJSONValue) {
        switch frame["type"]?.stringValue {
        case "baseline":
            guard let value = frame["value"] else { return }
            queuedItems = (value["queues"]?.objectValue ?? [:]).mapValues {
                $0.arrayValue?.compactMap(MobileQueuedItem.init(json:)) ?? []
            }
            for (sessionId, blockValue) in value["projections"]?.objectValue ?? [:] {
                if let block = try? blockValue.decode(MobileProjectionBlock.self) {
                    projections[sessionId, default: [:]].merge(block.values) { _, new in new }
                }
            }
        case "queue":
            guard let id = frame["sessionId"]?.stringValue else { return }
            queuedItems[id] = frame["items"]?.arrayValue?.compactMap(MobileQueuedItem.init(json:)) ?? []
        case "projection":
            guard let id = frame["sessionId"]?.stringValue,
                  let key = frame["key"]?.stringValue,
                  let value = frame["value"] else { return }
            projections[id, default: [:]][key] = value
            objectWillChange.send()
        default: break
        }
    }

    private func handleSessionFeed(_ frame: MobileJSONValue, sessionId: String) {
        switch frame["type"]?.stringValue {
        case "snapshot":
            let incoming = frame["events"]?.arrayValue?.compactMap { entry -> MobileEventRecord? in
                guard let value = entry["event"], let event = try? value.decode(MobileSessionEvent.self) else { return nil }
                return MobileEventRecord(event: event, view: nil)
            } ?? []
            records[sessionId] = merge(incoming, records[sessionId] ?? [])
            historyHasMore[sessionId] = frame["hasMore"]?.boolValue ?? false
            if let value = frame["projections"], let block = try? value.decode(MobileProjectionBlock.self) {
                projections[sessionId, default: [:]].merge(block.values) { _, new in new }
            }
        case "event":
            guard let value = frame["event"], let event = try? value.decode(MobileSessionEvent.self) else { return }
            records[sessionId] = merge(records[sessionId] ?? [], [MobileEventRecord(event: event, view: nil)])
            if let index = sessions.firstIndex(where: { $0.sessionId == sessionId }) {
                sessions[index].updatedAt = event.time
                if event.type == "turn/start" || event.type == "user/message" { sessions[index].blank = false }
            }
            if event.type == "turn/end" { finishVoiceTurn(sessionId: sessionId, endSeq: event.seq) }
        default: return
        }
        objectWillChange.send()
    }

    private func removeSessionProjection(_ id: String) {
        sessions.removeAll { $0.sessionId == id }
        records[id] = nil
        historyHasMore[id] = nil
        projections[id] = nil
        approvals = approvals.filter { $0.value.sessionId != id }
        questions = questions.filter { $0.value.sessionId != id }
        queuedItems[id] = nil
        if selectedSessionId == id { newTask(in: selectedWorkspaceId) }
    }

    private func recordConnectionDiagnostic(_ state: String) {
#if DEBUG
        UserDefaults.standard.set(state, forKey: Self.debugConnectionStateKey)
        if let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let historyURL = directory.appending(path: "openfish-connection-history.txt")
            var history = (try? Data(contentsOf: historyURL)) ?? Data()
            history.append(Data("\(state)\n".utf8))
            try? history.write(to: historyURL, options: .atomic)
            try? Data(state.utf8).write(
                to: directory.appending(path: "openfish-connection-stage.txt"),
                options: .atomic
            )
        }
#endif
    }

    private func resetConnectionDiagnostic() {
#if DEBUG
        if let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            try? Data("run-started at=\(Date().ISO8601Format())\n".utf8).write(
                to: directory.appending(path: "openfish-connection-history.txt"),
                options: .atomic
            )
        }
#endif
    }

    private func connectionDiagnosticCode(for error: Error) -> String {
        if let error = error as? URLError { return "url-\(error.errorCode)" }
        guard let error = error as? MobileApiError else { return "other" }
        switch error {
        case .invalidResponse:
            return "invalid-response"
        case let .host(code, _):
            let safe = code.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-")
            }
            return safe && code.count <= 40 ? "host-\(code)" : "host-error"
        case let .transport(message):
            guard message.hasPrefix("HTTP ") else { return "transport" }
            let status = message.dropFirst(5).prefix(while: \.isNumber)
            guard !status.isEmpty else { return "transport" }
            let marker = message.split(separator: "[", maxSplits: 1).dropFirst().first?
                .split(separator: "]", maxSplits: 1).first
            let safeMarker: String
            if let marker,
               marker.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) {
                safeMarker = "-\(marker)"
            } else {
                safeMarker = ""
            }
            return "http-\(status)\(safeMarker)"
        }
    }

    private func handleHost(_ envelope: MobileServerRequest) {
        let frame = envelope.payload
        switch frame["type"]?.stringValue ?? envelope.method {
        case "host/session-status":
            guard let id = frame["sessionId"]?.stringValue,
                  let running = frame["running"]?.boolValue,
                  let index = sessions.firstIndex(where: { $0.sessionId == id }) else { return }
            let wasRunning = sessions[index].running
            sessions[index].running = running
            if running { sessions[index].blank = false }
            sessions[index].updatedAt = Date().timeIntervalSince1970 * 1_000
            if wasRunning && !running && UIApplication.shared.applicationState != .active {
                let title = title(for: sessions[index])
                Task { await notifications.post(title: title, body: "Task finished", sessionId: id) }
            }
            scheduleCache()
        case "host/session-added", "host/session-removed", "host/workspace-changed", "host/workspace-removed", "host/archived-sessions-changed":
            Task { await refresh() }
        case "host/agent-error":
            errorMessage = frame["message"]?.stringValue ?? "The DSH agent reported an error."
            if frame["sessionId"]?.stringValue == voiceConversationSessionId {
                voiceConversationStatus = "Task failed"
            }
        default: break
        }
    }

    private func handleMux(_ envelope: MobileServerRequest) {
        let frame = envelope.payload
        switch frame["type"]?.stringValue ?? envelope.method {
        case "session/event":
            guard let id = frame["sessionId"]?.stringValue,
                  let value = frame["event"],
                  let event = try? value.decode(MobileSessionEvent.self) else { return }
            records[id] = merge(records[id] ?? [], [MobileEventRecord(event: event, view: frame["view"])])
            if event.type == "turn/end" {
                finishVoiceTurn(sessionId: id, endSeq: event.seq)
            }
            objectWillChange.send()
            scheduleCache()
        case "session/projection":
            guard let id = frame["sessionId"]?.stringValue,
                  let key = frame["key"]?.stringValue,
                  let value = frame["value"] else { return }
            projections[id, default: [:]][key] = value
            objectWillChange.send()
            scheduleCache()
        case "session/queue":
            guard let id = frame["sessionId"]?.stringValue else { return }
            queuedItems[id] = frame["items"]?.arrayValue?.compactMap(MobileQueuedItem.init(json:)) ?? []
        case "approval/requested":
            guard let sessionId = frame["sessionId"]?.stringValue,
                  let approvalId = frame["approvalId"]?.stringValue,
                  let toolName = frame["toolName"]?.stringValue else { return }
            approvals[approvalId] = MobileApproval(
                clientId: remoteEventClientId ?? "",
                rpcId: envelope.rpcId,
                sessionId: sessionId,
                approvalId: approvalId,
                toolName: toolName,
                reason: frame["reason"]?.stringValue
            )
            if sessionId == voiceConversationSessionId {
                voiceConversationStatus = "Approval required"
                voice.stopSpeaking()
            }
        case "approval/resolved":
            if let id = frame["approvalId"]?.stringValue { approvals[id] = nil }
        case "question/requested":
            guard let sessionId = frame["sessionId"]?.stringValue,
                  let values = frame["questions"],
                  let decoded = try? values.decode([MobileQuestion].self) else { return }
            questions[envelope.rpcId] = MobilePendingQuestion(
                clientId: remoteEventClientId ?? "",
                rpcId: envelope.rpcId,
                sessionId: sessionId,
                questions: decoded
            )
            if sessionId == voiceConversationSessionId {
                voiceConversationStatus = "Answer required"
                voice.stopSpeaking()
            }
        case "question/resolved":
            if let id = frame["questionRpcId"]?.stringValue { questions[id] = nil }
        default: break
        }
    }

    private func restore(_ snapshot: MobileProjectionSnapshot) {
        workspaces = snapshot.workspaces
        sessions = snapshot.sessions.map { cached in
            var session = cached
            session.running = false
            return session
        }
        archived = snapshot.archived
        records = snapshot.records
        historyHasMore = snapshot.historyHasMore
        projections = snapshot.projections
        selectedWorkspaceId = snapshot.selectedWorkspaceId.flatMap { id in
            workspaces.contains(where: { $0.workspaceId == id }) ? id : nil
        }
        selectedSessionId = snapshot.selectedSessionId.flatMap { id in
            sessions.contains(where: { $0.sessionId == id }) ? id : nil
        }
        if selectedSessionId == nil,
           let cachedDraft = snapshot.draftSessionId,
           let harnessId = snapshot.draftHarnessId
               ?? sessions.first(where: { $0.sessionId == cachedDraft })?.harnessId,
           !harnessId.isEmpty {
            draftSessionId = cachedDraft
            draftHarnessId = harnessId
        } else {
            draftSessionId = nil
            draftHarnessId = nil
        }
        if let selectedSessionId {
            selectedWorkspaceId = workspaces.first(where: { $0.sessionIds.contains(selectedSessionId) })?.workspaceId
        }
        objectWillChange.send()
    }

    private func purgeHostProjection() {
        remoteEventClientId = nil
        workspaces = []
        sessions = []
        archived = []
        approvals = [:]
        questions = [:]
        queuedItems = [:]
        records = [:]
        historyHasMore = [:]
        projections = [:]
        harnessesBySession = [:]
        harnesses = []
        providers = []
        plugins = []
        skills = []
        commands = []
        subagents = []
        agentPresets = nil
        sessionModels = nil
        sessionModelsError = nil
        nativeCapabilities = nil
        directoryListing = nil
        exportURL = nil
        attachmentData = [:]
        pendingImages = []
        draft = ""
        draftSessionId = nil
        draftHarnessId = nil
        selectedSessionId = nil
        selectedWorkspaceId = nil
        activeSubagent = nil
        UserDefaults.standard.removeObject(forKey: "OpenCodex.iPhone.lastSession")
        objectWillChange.send()
    }

    private func scheduleCache() {
        cacheTask?.cancel()
        let snapshot = cacheSnapshot()
        let cache = cache
        cacheTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await cache.save(snapshot)
        }
    }

    private func cacheSnapshot() -> MobileProjectionSnapshot {
        var retained = Set(
            sessions
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(24)
                .map(\.sessionId)
        )
        if let selectedSessionId { retained.insert(selectedSessionId) }
        if let draftSessionId { retained.insert(draftSessionId) }
        let boundedSessions = sessions.filter { retained.contains($0.sessionId) }
        let boundedRecords = records.reduce(into: [String: [MobileEventRecord]]()) { result, pair in
            guard retained.contains(pair.key) else { return }
            result[pair.key] = Array(pair.value.suffix(1_200))
        }
        let boundedHistory = historyHasMore.filter { retained.contains($0.key) }
        let boundedProjections = projections.filter { retained.contains($0.key) }
        return MobileProjectionSnapshot(
            version: 2,
            host: profile.baseURL.absoluteString,
            savedAt: Date(),
            workspaces: workspaces,
            sessions: boundedSessions,
            archived: archived,
            records: boundedRecords,
            historyHasMore: boundedHistory,
            projections: boundedProjections,
            selectedWorkspaceId: selectedWorkspaceId,
            selectedSessionId: selectedSessionId,
            draftSessionId: draftSessionId,
            draftHarnessId: draftHarnessId
        )
    }

    private func merge(_ left: [MobileEventRecord], _ right: [MobileEventRecord]) -> [MobileEventRecord] {
        var bySeq = left.reduce(into: [Int: MobileEventRecord]()) { result, record in
            result[record.event.seq] = record
        }
        for item in right { bySeq[item.event.seq] = item }
        return bySeq.values.sorted { $0.event.seq < $1.event.seq }
    }
}
