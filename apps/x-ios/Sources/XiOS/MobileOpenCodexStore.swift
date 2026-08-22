import Foundation
import UIKit

private func isOpenFishCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
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

@MainActor
final class MobileOpenCodexStore: ObservableObject {
    let voice = MobileLocalVoice()
    private let notifications = MobileNotificationService()
    private let cache = MobileProjectionCache()
    @Published private(set) var connectionState: MobileConnectionState = .connecting
    @Published private(set) var profile: MobileConnectionProfile
    @Published private(set) var workspaces: [MobileWorkspace] = []
    @Published private(set) var sessions: [MobileSession] = []
    @Published private(set) var archived: Set<String> = []
    @Published private(set) var approvals: [String: MobileApproval] = [:]
    @Published private(set) var questions: [String: MobilePendingQuestion] = [:]
    @Published private(set) var queuedItems: [String: [MobileQueuedItem]] = [:]
    @Published private(set) var sessionModels: MobileSessionModels?
    @Published private(set) var agentPresets: MobileAgentPresetCatalog?
    @Published private(set) var harnesses: [MobileHarness] = []
    @Published private(set) var selectedHarnessId = ""
    @Published private(set) var draftHarnessId: String?
    @Published private(set) var skills: [MobileSkillEntry] = []
    @Published private(set) var commands: [MobileJSONValue] = []
    @Published private(set) var subagents: [MobileSubagentEntry] = []
    @Published private(set) var settingsCatalog: MobileSettingsCatalog?
    @Published private(set) var providers: [MobileConfigurableProvider] = []
    @Published private(set) var plugins: [MobilePluginInventoryEntry] = []
    @Published private(set) var pairedDevices: [MobileNativeDevice] = []
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
    @Published var selectedSessionId: String?
    @Published private(set) var draftSessionId: String?
    @Published var activeSubagent: MobileActiveSubagent?
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
    private var draftPreparationGeneration = 0
    private var records: [String: [MobileEventRecord]] = [:]
    private var historyHasMore: [String: Bool] = [:]
    private var projections: [String: [String: MobileJSONValue]] = [:]
    private var booted = false
    private var voiceConversationSessionId: String?
    private var lastVoiceTurnEndSeq = -1
    private var loadingAttachments: Set<String> = []
    private var readTimestamps: [String: Double] = UserDefaults.standard
        .dictionary(forKey: "OpenFish.readTimestamps.ios")?
        .compactMapValues { ($0 as? NSNumber)?.doubleValue } ?? [:]

    init(profile: MobileConnectionProfile = .restored()) {
        self.profile = profile
        api = XIOSClient(baseURL: profile.baseURL, bearerToken: profile.bearerToken)
        connection = MobileLiveConnection(baseURL: profile.baseURL, token: profile.bearerToken)
    }

    /// Deterministic, network-isolated state for screenshots and product demos.
    static func visualFixture() -> MobileOpenCodexStore {
        let profile = MobileConnectionProfile(
            baseURL: URL(string: "http://demo-mac.local:3080")!,
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
                sessionId: "session-sync", harnessId: "codex-acp", updatedAt: now,
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
            "session-sync": ["title": .string("Design the offline sync flow")],
            "session-export": ["title": .string("Add export progress")],
            "session-accessibility": ["title": .string("Review accessibility labels")],
        ]
        store.records["session-sync"] = mobileVisualFixtureRecords(now: now)
        store.sessionModels = MobileSessionModels(
            current: .init(provider: "openai-codex", model: "gpt-5.6-sol", reasoningEffort: "medium"),
            routable: true,
            groups: [
                .init(
                    id: "openai-codex", name: "ChatGPT",
                    models: [
                        .init(
                            id: "gpt-5.6-sol", name: "GPT-5.6-Sol", description: "Demo model",
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
            failures: []
        )
        store.harnesses = [MobileHarness(
            id: "codex-acp", isDefault: true, name: "Codex", version: "demo",
            description: "Codex through the OpenFish ACP bridge", publisher: "OpenAI", verified: true,
            protocolName: "acp", source: "acp-registry",
            graph: .init(
                level: "observable",
                manifestVersion: 1,
                boundary: "Codex ACP agent process",
                evidence: [.init(kind: "source-derived", source: "https://github.com/openai/codex", version: "demo")],
                nodes: [
                    .init(id: "acp", kind: "protocol-adapter", title: "ACP interface", editable: false, responsibility: "Translates client sessions and permissions for Codex.", evidence: [.init(kind: "declared", source: "ACP Registry codex-acp", version: "demo")], config: nil),
                    .init(id: "session", kind: "agent-session", title: "Thread & turn", editable: false, responsibility: "Owns the thread, current turn, and streamed items.", evidence: [.init(kind: "source-derived", source: "https://github.com/openai/codex", version: "demo")], config: nil),
                    .init(id: "context", kind: "context-runtime", title: "Context", editable: false, responsibility: "Builds model input from instructions, history, and environment.", evidence: [.init(kind: "source-derived", source: "https://github.com/openai/codex", version: "demo")], config: nil),
                    .init(id: "model", kind: "model-client", title: "Model client", editable: false, responsibility: "Streams inference through the selected Codex account and model.", evidence: [.init(kind: "source-derived", source: "https://github.com/openai/codex", version: "demo")], config: nil),
                    .init(id: "tools", kind: "tool-runtime", title: "Tools", editable: false, responsibility: "Dispatches enabled coding and computer tools.", evidence: [.init(kind: "source-derived", source: "https://github.com/openai/codex", version: "demo")], config: nil),
                    .init(id: "sandbox", kind: "execution-boundary", title: "Sandbox", editable: false, responsibility: "Constrains filesystem and network effects.", evidence: [.init(kind: "source-derived", source: "https://github.com/openai/codex", version: "demo")], config: nil),
                    .init(id: "approvals", kind: "permission-policy", title: "Approvals", editable: false, responsibility: "Stops boundary-crossing operations for review.", evidence: [.init(kind: "source-derived", source: "https://github.com/openai/codex", version: "demo")], config: nil),
                    .init(id: "persistence", kind: "session-storage", title: "Persistence", editable: false, responsibility: "Retains resumable thread identity and state.", evidence: [.init(kind: "source-derived", source: "https://github.com/openai/codex", version: "demo")], config: nil),
                ],
                edges: [
                    .init(from: "acp", to: "session"), .init(from: "session", to: "context"), .init(from: "context", to: "model"),
                    .init(from: "model", to: "session"), .init(from: "session", to: "tools"), .init(from: "tools", to: "approvals"),
                    .init(from: "approvals", to: "sandbox"), .init(from: "session", to: "persistence"),
                ]
            ),
            available: true, unavailableReason: nil,
            installation: .init(status: "installed", installedVersion: "demo", availableVersion: "demo", previousVersions: [], error: nil),
            auth: .init(methods: [], selectedMethod: "chat-gpt", status: "configured", missingFields: []),
            compatibility: .init(status: "compatible", checkedAt: nil, message: "Synthetic demo runtime"),
            capabilities: [
                .init(id: "lifecycle.install", status: "supported", source: "driver", detail: nil),
                .init(id: "lifecycle.update", status: "supported", source: "driver", detail: nil),
                .init(id: "lifecycle.rollback", status: "supported", source: "driver", detail: nil),
                .init(id: "lifecycle.uninstall", status: "supported", source: "driver", detail: nil),
                .init(id: "session.create", status: "supported", source: "driver", detail: nil),
                .init(id: "session.resume", status: "supported", source: "driver", detail: nil),
                .init(id: "session.cancel", status: "supported", source: "driver", detail: nil),
                .init(id: "session.fork", status: "supported", source: "driver", detail: nil),
                .init(id: "session.archive", status: "supported", source: "driver", detail: nil),
                .init(id: "workspace.project", status: "supported", source: "driver", detail: nil),
                .init(id: "workspace.no-project", status: "supported", source: "driver", detail: nil),
                .init(id: "configuration.models", status: "runtime", source: "runtime", detail: nil),
                .init(id: "configuration.reasoning", status: "runtime", source: "runtime", detail: nil),
                .init(id: "configuration.auth", status: "runtime", source: "runtime", detail: nil),
                .init(id: "interaction.tools", status: "supported", source: "driver", detail: nil),
                .init(id: "interaction.approvals", status: "supported", source: "driver", detail: nil),
                .init(id: "interaction.questions", status: "unsupported", source: "driver", detail: "Not advertised by the demo ACP agent."),
                .init(id: "interaction.files", status: "unsupported", source: "driver", detail: "Not advertised by the demo ACP agent."),
                .init(id: "interaction.events", status: "supported", source: "driver", detail: nil),
                .init(id: "architecture.manifest", status: "supported", source: "pack", detail: nil),
                .init(id: "architecture.runtime-observation", status: "runtime", source: "runtime", detail: nil),
                .init(id: "architecture.edit", status: "unsupported", source: "pack", detail: "This demo Pack is observable, not composable."),
                .init(id: "diagnostics.preflight", status: "supported", source: "driver", detail: nil),
                .init(id: "builder.manifest", status: "supported", source: "pack", detail: nil),
                .init(id: "builder.test", status: "supported", source: "driver", detail: nil),
                .init(id: "builder.publish", status: "unsupported", source: "pack", detail: "Publication export is prepared on the Mac."),
            ],
            driver: .init(apiVersion: 1, protocol: "acp", loaded: true)
        )]
        store.selectedHarnessId = "codex-acp"
        store.selectedWorkspaceId = workspace.workspaceId
        store.connectionState = .connected
        store.booted = true
        store.isDemoMode = true
        return store
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
    var currentHarness: MobileHarness? { harnesses.first { $0.id == currentHarnessId } }
    func harnessCapability(_ id: String) -> String? { currentHarness?.capabilities.first(where: { $0.id == id })?.status }
    func harnessCan(_ id: String) -> Bool { harnessCapability(id) != nil && harnessCapability(id) != "unsupported" }
    var canChooseHarness: Bool { selectedSessionId == nil && controlSession?.blank == true }
    var canChooseAgentPreset: Bool { controlSession?.blank == true && currentHarnessId == "dsh" }

    var selectedWorkspace: MobileWorkspace? {
        if let selectedWorkspaceId { return workspaces.first { $0.workspaceId == selectedWorkspaceId } }
        guard let selectedSessionId else { return nil }
        return workspaces.first { $0.sessionIds.contains(selectedSessionId) }
    }

    var conversation: [MobileConversationItem] {
        guard let conversationSessionId else { return [] }
        return MobileConversationProjector.project(records[conversationSessionId] ?? [])
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
        guard let sessionModels else { return "Default model" }
        return sessionModels.groups
            .first(where: { $0.id == sessionModels.current.provider })?
            .models.first(where: { $0.id == sessionModels.current.model })?.name
            ?? sessionModels.current.model
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

    var selectedQuestions: [MobilePendingQuestion] {
        guard let conversationSessionId else { return [] }
        return questions.values.filter { $0.sessionId == conversationSessionId }.sorted { $0.id < $1.id }
    }

    var selectedQueue: [MobileQueuedItem] {
        guard let conversationSessionId else { return [] }
        return queuedItems[conversationSessionId] ?? []
    }

    var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty) && !isSending
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
            return visible.filter { !known.contains($0.sessionId) }.sorted { $0.updatedAt > $1.updatedAt }
        }
        let byId = Dictionary(uniqueKeysWithValues: visible.map { ($0.sessionId, $0) })
        return workspace.sessionIds.compactMap { byId[$0] }.sorted { $0.updatedAt > $1.updatedAt }
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
        (orderedWorkspaces.flatMap { sessions(in: $0) } + sessions(in: nil))
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
        workspaces.first(where: { $0.sessionIds.contains(session.sessionId) })?.title ?? "No Project"
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
        await notifications.requestAuthorization()
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let host = environment["OPENCODEX_DEBUG_HOST"],
           let pairingCode = environment["OPENCODEX_DEBUG_PAIRING_CODE"],
           !host.isEmpty,
           !pairingCode.isEmpty {
            await connect(host: host, pairingCode: pairingCode)
            return
        }
#endif
        if let snapshot = await cache.load(matching: profile.baseURL) {
            restore(snapshot)
        }
        await startConnection()
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
        stopVoiceConversation()
        connectionTask?.cancel()
        connectionTask = nil
        cacheTask?.cancel()
        draftPreparationTask?.cancel()
        await cache.save(cacheSnapshot())
        await connection.stop()
    }

    func becameActive() async {
        guard booted, connectionTask == nil else { return }
        await startConnection()
        await refresh(selectRemembered: true)
    }

    private func startConnection() async {
        let stream = connection.updates
        connectionTask = Task { [weak self] in
            for await update in stream { await self?.handle(update) }
        }
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
                  capabilities.features.apiProxy,
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
                    "This DSH Host is missing the OpenFish iPhone or local-voice composition."
                )
            }
            nativeCapabilities = capabilities
            workspaces = workspaceSnapshot.items
            archived = workspaceSnapshot.archived
            for session in sessionSnapshot {
                if let values = session.projections?.values {
                    projections[session.sessionId, default: [:]].merge(values) { _, new in new }
                }
            }
            sessions = sessionSnapshot
            harnesses = harnessSnapshot
            if let sharedDefault = harnesses.first(where: \.isDefault), sharedDefault.available {
                selectedHarnessId = sharedDefault.id
            } else {
                selectedHarnessId = ""
            }
            agentPresets = try? await api.agentPresets()
            if selectRemembered,
               let remembered = UserDefaults.standard.string(forKey: "OpenCodex.iPhone.lastSession"),
               sessions.contains(where: { $0.sessionId == remembered }) {
                await select(remembered)
            }
            errorMessage = nil
            scheduleCache()
        } catch {
            nativeCapabilities = nil
            errorMessage = "Could not reach the DSH Host at \(profile.baseURL.host ?? profile.baseURL.absoluteString): \(error.localizedDescription)"
        }
    }

    func select(_ sessionId: String) async {
        if let abandonedDraft = draftSessionId, abandonedDraft != sessionId {
            draftSessionId = nil
            _ = try? await api.setArchived(sessionId: abandonedDraft, archived: true)
        }
        selectedSessionId = sessionId
        activeSubagent = nil
        if let workspace = workspaces.first(where: { $0.sessionIds.contains(sessionId) }) {
            selectedWorkspaceId = workspace.workspaceId
        }
        UserDefaults.standard.set(sessionId, forKey: "OpenCodex.iPhone.lastSession")
        do {
            async let historyRequest = api.history(sessionId: sessionId)
            async let modelsRequest = try? api.models(sessionId: sessionId)
            async let skillsRequest = try? api.skills(sessionId: sessionId)
            async let commandsRequest = try? api.commandDirectory(sessionId: sessionId)
            async let subagentsRequest = try? api.subagents(parentSessionId: sessionId)
            let history = try await historyRequest
            records[sessionId] = merge(records[sessionId] ?? [], history.events)
            historyHasMore[sessionId] = history.hasMore
            if let values = history.projections?.values {
                projections[sessionId, default: [:]].merge(values) { _, new in new }
            }
            let (models, loadedSkills, loadedCommands, loadedSubagents) = await (
                modelsRequest,
                skillsRequest,
                commandsRequest,
                subagentsRequest
            )
            guard selectedSessionId == sessionId else { return }
            sessionModels = models
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

    func newTask(in workspaceId: String?) {
        draftPreparationTask?.cancel()
        draftPreparationGeneration += 1
        let generation = draftPreparationGeneration
        let abandonedDraft = draftSessionId
        draftSessionId = nil
        draftHarnessId = nil
        selectedWorkspaceId = workspaceId
        selectedSessionId = nil
        activeSubagent = nil
        draft = ""
        pendingImages = []
        sessionModels = nil
        skills = []
        commands = []
        subagents = []
        UserDefaults.standard.removeObject(forKey: "OpenCodex.iPhone.lastSession")
        scheduleCache()
        if let abandonedDraft {
            Task { [weak self] in
                guard let self else { return }
                _ = try? await self.api.setArchived(sessionId: abandonedDraft, archived: true)
            }
        }
        let harnessId = selectedHarnessId
        guard !harnessId.isEmpty else {
            errorMessage = "Choose and configure a default Harness before starting a task."
            return
        }
        draftPreparationTask = Task { [weak self] in
            await self?.prepareNewTaskControls(
                generation: generation,
                workspaceId: workspaceId,
                harnessId: harnessId
            )
        }
    }

    private func prepareNewTaskControls(generation: Int, workspaceId: String?, harnessId: String) async {
        guard !Task.isCancelled,
              generation == draftPreparationGeneration,
              selectedSessionId == nil,
              draftSessionId == nil else { return }
        do {
            let sessionId = try await api.createSession(workspaceId: workspaceId, harnessId: harnessId)
            guard !Task.isCancelled,
                  generation == draftPreparationGeneration,
                  selectedWorkspaceId == workspaceId,
                  (draftHarnessId ?? selectedHarnessId) == harnessId,
                  selectedSessionId == nil,
                  draftSessionId == nil else {
                _ = try? await api.setArchived(sessionId: sessionId, archived: true)
                return
            }
            draftSessionId = sessionId
            await refresh()
            async let historyRequest = api.history(sessionId: sessionId)
            async let modelsRequest = try? api.models(sessionId: sessionId)
            async let presetsRequest = try? api.agentPresets()
            let history = try await historyRequest
            records[sessionId] = merge(records[sessionId] ?? [], history.events)
            historyHasMore[sessionId] = history.hasMore
            if let values = history.projections?.values {
                projections[sessionId, default: [:]].merge(values) { _, new in new }
            }
            sessionModels = await modelsRequest
            agentPresets = await presetsRequest
            objectWillChange.send()
        } catch {
            guard !Task.isCancelled,
                  !isOpenFishCancellation(error),
                  generation == draftPreparationGeneration else { return }
            errorMessage = "Could not prepare a new task: \(error.localizedDescription)"
        }
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !pendingImages.isEmpty), !isSending else { return }
        guard activeSubagent != nil || selectedSessionId != nil || draftSessionId != nil
                || draftHarnessId != nil || !selectedHarnessId.isEmpty else {
            errorMessage = "Choose and configure a default Harness on your Mac before starting a task."
            return
        }
        isSending = true
        let images = pendingImages
        draft = ""
        pendingImages = []
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
                self.draftSessionId = nil
                selectedSessionId = id
                UserDefaults.standard.set(id, forKey: "OpenCodex.iPhone.lastSession")
            }
            else {
                id = try await api.createSession(workspaceId: selectedWorkspaceId, harnessId: draftHarnessId ?? selectedHarnessId)
                selectedSessionId = id
                UserDefaults.standard.set(id, forKey: "OpenCodex.iPhone.lastSession")
                await refresh()
            }
            try await api.prompt(sessionId: id, text: text, images: images, mode: promptMode)
            errorMessage = nil
            scheduleCache()
        } catch {
            draft = text
            pendingImages = images
            errorMessage = "Could not send: \(error.localizedDescription)"
        }
        isSending = false
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

    func chooseModel(provider: String, model: MobileCatalogModel, effort: String? = nil) async {
        guard let selectedSessionId = controlSessionId else { return }
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
                    harnessOptions: catalog.harnessOptions
                )
            }
            // Model changes may replace the Harness's reasoning levels and
            // other configuration directory. Always reload its authority.
            sessionModels = try await api.models(sessionId: selectedSessionId)
            errorMessage = nil
            scheduleCache()
        } catch { errorMessage = "Could not switch models: \(error.localizedDescription)" }
    }

    func chooseReasoningEffort(_ effort: String) async {
        guard let models = sessionModels,
              let model = currentModel else { return }
        await chooseModel(provider: models.current.provider, model: model, effort: effort)
    }

    func refreshCurrentModels() async {
        guard let selectedSessionId = controlSessionId else { return }
        do {
            sessionModels = try await api.models(sessionId: selectedSessionId)
            errorMessage = nil
        } catch {
            errorMessage = "Could not load model choices: \(error.localizedDescription)"
        }
    }

    func chooseHarnessConfig(_ option: MobileHarnessConfigOption, value: MobileJSONValue) async {
        guard let selectedSessionId = controlSessionId else { return }
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
                    harnessOptions: options
                )
            }
            // ACP options can be interdependent, so consume the complete
            // directory returned after every change.
            sessionModels = try await api.models(sessionId: selectedSessionId)
            errorMessage = nil
            scheduleCache()
        } catch { errorMessage = "Could not change \(option.name): \(error.localizedDescription)" }
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

    func chooseHarness(_ harness: MobileHarness) async {
        guard canChooseHarness else { return }
        guard harness.available else {
            errorMessage = harness.unavailableReason ?? "This Harness is not available on the connected Mac."
            return
        }
        do {
            let current = harnesses.first(where: { $0.id == harness.id }) ?? harness
            if current.installation.status != "builtin" && current.installation.status != "installed" {
                harnesses = try await api.installHarness(harness.id)
            }
            let configured = harnesses.first(where: { $0.id == harness.id }) ?? harness
            guard configured.auth.status == "not-required" || configured.auth.status == "configured" else {
                errorMessage = "Configure \(harness.name) authentication on your Mac first."
                return
            }
            draftPreparationTask?.cancel()
            draftPreparationGeneration += 1
            if let abandonedDraft = draftSessionId { _ = try? await api.setArchived(sessionId: abandonedDraft, archived: true) }
            draftSessionId = nil
            selectedSessionId = nil
            draftHarnessId = harness.id
            let generation = draftPreparationGeneration
            let workspaceId = selectedWorkspaceId
            draftPreparationTask = Task { [weak self] in
                await self?.prepareNewTaskControls(generation: generation, workspaceId: workspaceId, harnessId: harness.id)
            }
            errorMessage = nil
        } catch {
            errorMessage = "Could not use \(harness.name) for this task: \(error.localizedDescription)"
        }
    }

    func selectDefaultHarness(_ harness: MobileHarness) async {
        guard harness.available else {
            errorMessage = harness.unavailableReason ?? "This Harness is not available on the connected Mac."
            return
        }
        do {
            if harness.installation.status != "builtin" && harness.installation.status != "installed" {
                harnesses = try await api.installHarness(harness.id)
            }
            let configured = harnesses.first(where: { $0.id == harness.id }) ?? harness
            guard configured.auth.status == "not-required" || configured.auth.status == "configured" else {
                errorMessage = "Configure \(harness.name) authentication on your Mac first."
                return
            }
            harnesses = try await api.selectDefaultHarness(harness.id)
            selectedHarnessId = harness.id
            errorMessage = nil
        } catch {
            errorMessage = "Could not select \(harness.name): \(error.localizedDescription)"
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

    func loadSettings() async {
        guard !isLoadingSettings else { return }
        isLoadingSettings = true
        defer { isLoadingSettings = false }
        do {
            async let settingsRequest = api.settings()
            async let providersRequest = api.configurableProviders()
            async let pluginsRequest = api.pluginInventory()
            async let devicesRequest = try? api.devices()
            let (settings, providerRows, pluginRows, deviceRows) = try await (
                settingsRequest,
                providersRequest,
                pluginsRequest,
                devicesRequest
            )
            settingsCatalog = settings
            providers = providerRows
            plugins = pluginRows
            pairedDevices = deviceRows ?? []
            errorMessage = nil
        } catch { errorMessage = "Could not load Host settings: \(error.localizedDescription)" }
    }

    func replaceSettings(_ namespace: MobileSettingsNamespace, json: String) async {
        do {
            let section = try JSONDecoder().decode(MobileJSONValue.self, from: Data(json.utf8))
            guard section.objectValue != nil else {
                throw MobileApiError.host("settings-invalid", "A settings section must be a JSON object")
            }
            let updated = try await api.replaceSettings(
                namespace: namespace.ns,
                section: section,
                revision: namespace.revision
            )
            if let catalog = settingsCatalog,
               let index = catalog.namespaces.firstIndex(where: { $0.ns == updated.ns }) {
                var rows = catalog.namespaces
                rows[index] = updated
                settingsCatalog = MobileSettingsCatalog(
                    writable: catalog.writable,
                    hasDocument: catalog.hasDocument,
                    namespaces: rows
                )
            }
            errorMessage = nil
        } catch { errorMessage = "Could not save \(namespace.ns): \(error.localizedDescription)" }
    }

    func setCredential(ref: String, value: String) async {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try await api.setCredential(ref: ref, value: value)
            errorMessage = nil
            await loadSettings()
        } catch { errorMessage = "Could not store this credential: \(error.localizedDescription)" }
    }

    func unsetCredential(ref: String) async {
        do {
            try await api.unsetCredential(ref: ref)
            errorMessage = nil
            await loadSettings()
        } catch { errorMessage = "Could not remove this credential: \(error.localizedDescription)" }
    }

    func revoke(_ device: MobileNativeDevice) async {
        do {
            guard try await api.revokeDevice(device.deviceId) else {
                throw MobileApiError.host("device-not-found", "This paired device no longer exists")
            }
            pairedDevices.removeAll { $0.deviceId == device.deviceId }
            errorMessage = nil
        } catch { errorMessage = "Could not revoke this device: \(error.localizedDescription)" }
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
        do {
            try await api.answer(approval, allow: allow)
            approvals[approval.approvalId] = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func answer(_ question: MobilePendingQuestion, answers: [MobileQuestionAnswer]) async {
        do {
            try await api.answer(question, answers: answers)
            questions[question.rpcId] = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func toggleDictation() async {
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
            self.voiceConversationStatus = isFinal ? "Sending to DSH" : "Listening"
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
        do {
            let sessionId: String
            if let activeSubagent {
                sessionId = activeSubagent.childSessionId
            } else if let selectedSessionId {
                sessionId = selectedSessionId
            } else {
                sessionId = try await api.createSession(workspaceId: selectedWorkspaceId, harnessId: draftHarnessId ?? selectedHarnessId)
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
        pendingImages.append(MobilePendingImage(name: name, mediaType: mediaType, data: data))
    }

    func removeImage(_ id: UUID) { pendingImages.removeAll { $0.id == id } }

    func connect(host: String, pairingCode: String) async {
        guard let url = MobileConnectionProfile.normalizedURL(host) else {
            errorMessage = "Enter a valid DSH Host address."
            return
        }
        do {
            let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
            let token: String?
            if !code.isEmpty {
                token = try await XIOSClient(baseURL: url).pair(
                    deviceName: UIDevice.current.name,
                    code: code
                ).token
            } else if url == MobileConnectionProfile.local.baseURL {
                token = nil
            } else {
                throw MobileApiError.host("pairing-required", "Enter the one-time code shown by OpenFish on the Host Mac.")
            }
            let next = MobileConnectionProfile(baseURL: url, bearerToken: token)
            try next.persist()
            await reconfigure(next)
            showsConnection = false
        } catch { errorMessage = "Could not pair: \(error.localizedDescription)" }
    }

    private func reconfigure(_ next: MobileConnectionProfile) async {
        stopVoiceConversation()
        connectionTask?.cancel()
        cacheTask?.cancel()
        draftPreparationTask?.cancel()
        await connection.stop()
        await cache.clear()
        profile = next
        api = XIOSClient(baseURL: next.baseURL, bearerToken: next.bearerToken)
        connection = MobileLiveConnection(baseURL: next.baseURL, token: next.bearerToken)
        workspaces = []
        sessions = []
        sessionModels = nil
        agentPresets = nil
        skills = []
        commands = []
        subagents = []
        settingsCatalog = nil
        providers = []
        plugins = []
        pairedDevices = []
        nativeCapabilities = nil
        directoryListing = nil
        records = [:]
        historyHasMore = [:]
        projections = [:]
        queuedItems = [:]
        draftSessionId = nil
        selectedSessionId = nil
        selectedWorkspaceId = nil
        activeSubagent = nil
        connectionState = .connecting
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
        case let .state(state):
            connectionState = state
            if state == .connected {
                approvals = [:]
                questions = [:]
                queuedItems = [:]
                let selected = selectedSessionId
                await refresh(selectRemembered: selected == nil)
                if let selected, sessions.contains(where: { $0.sessionId == selected }) {
                    await select(selected)
                }
            }
        case let .host(envelope): handleHost(envelope)
        case let .mux(envelope): handleMux(envelope)
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
        let boundedSessions = sessions.filter { retained.contains($0.sessionId) }
        let boundedRecords = records.reduce(into: [String: [MobileEventRecord]]()) { result, pair in
            guard retained.contains(pair.key) else { return }
            result[pair.key] = Array(pair.value.suffix(1_200))
        }
        let boundedHistory = historyHasMore.filter { retained.contains($0.key) }
        let boundedProjections = projections.filter { retained.contains($0.key) }
        return MobileProjectionSnapshot(
            version: 1,
            host: profile.baseURL.absoluteString,
            savedAt: Date(),
            workspaces: workspaces,
            sessions: boundedSessions,
            archived: archived,
            records: boundedRecords,
            historyHasMore: boundedHistory,
            projections: boundedProjections,
            selectedWorkspaceId: selectedWorkspaceId,
            selectedSessionId: selectedSessionId
        )
    }

    private func merge(_ left: [MobileEventRecord], _ right: [MobileEventRecord]) -> [MobileEventRecord] {
        var bySeq = Dictionary(uniqueKeysWithValues: left.map { ($0.event.seq, $0) })
        for item in right { bySeq[item.event.seq] = item }
        return bySeq.values.sorted { $0.event.seq < $1.event.seq }
    }
}
