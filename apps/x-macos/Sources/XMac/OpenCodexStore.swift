import Foundation
import SwiftUI
import AppKit

private func isOpenFishCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
}

struct ProjectionCell: Codable, Sendable {
    let seq: Int
    let value: JSONValue
}

struct PendingPromptImage: Identifiable, Equatable, Sendable {
    let id = UUID()
    let name: String
    let mediaType: String
    let data: String
    let byteCount: Int
}

struct ActiveSubagent: Equatable, Sendable {
    let parentSessionId: String
    let childSessionId: String
    let mode: String
    let label: String
}

@MainActor
final class OpenCodexStore: ObservableObject {
    let voice = LocalVoiceService()
    private let notifications = LocalNotificationService()
    private let projectionCache = MacProjectionCache()
    @Published private(set) var workspaces: [WorkspaceView] = []
    @Published private(set) var sessions: [SessionSummary] = []
    @Published private(set) var archivedSessionIds: Set<String> = []
    @Published private(set) var connectionState: DshConnectionState = .connecting
    @Published private(set) var hostDescription: HostDescription?
    @Published private(set) var sessionModels: SessionModels?
    @Published private(set) var isLoadingSessionModels = false
    @Published private(set) var sessionModelsError: String?
    @Published private(set) var nativeCapabilities: NativeBootstrapCapabilities?
    @Published private(set) var pendingApprovals: [String: PendingApproval] = [:]
    @Published private(set) var pendingQuestions: [String: PendingQuestion] = [:]
    @Published private(set) var queuedItems: [String: [QueuedInboxItem]] = [:]
    @Published private(set) var backgroundJobs: [String: [BackgroundJob]] = [:]
    @Published private(set) var searchResults: [SessionSearchItem] = []
    @Published private(set) var skills: [SkillEntry] = []
    @Published private(set) var commands: [JSONValue] = []
    @Published private(set) var agentPresets: AgentPresetCatalog?
    @Published private(set) var harnesses: [HarnessCatalogEntry] = []
    @Published private(set) var harnessOperationId: String?
    @Published private(set) var isLoadingHarnessCatalog = false
    @Published private(set) var harnessCatalogError: String?
    // The Host is authoritative across Mac and iPhone. A cached client value
    // must never create a task before the shared catalog has loaded.
    @Published private(set) var selectedHarnessId = ""
    @Published private(set) var draftHarnessId: String?
    @Published private(set) var needsHarnessOnboarding = false
    @Published private(set) var subagents: [SubagentEntry] = []
    @Published private(set) var settingsCatalog: SettingsCatalog?
    @Published private(set) var providers: [ConfigurableProvider] = []
    @Published private(set) var hostModels = HostModelCatalog(groups: [], failures: [])
    @Published private(set) var plugins: [PluginInventoryEntry] = []
    @Published private(set) var pairedDevices: [NativeDevice] = []
    @Published private(set) var pairingCode: NativePairingCode?
    @Published private(set) var connectionProfile: NativeConnectionProfile
    @Published private(set) var isSearching = false
    @Published private(set) var isLoadingSettings = false
    @Published private(set) var isImporting = false
    @Published private(set) var isLoadingOlder = false
    @Published private(set) var lastImportSummary: String?
    @Published private(set) var isSubmitting = false
    @Published private(set) var isChangingPermission = false
    @Published private(set) var isAddingWorkspace = false
    @Published private(set) var isBrowsingWorkspace = false
    @Published private(set) var directoryListing: HostDirectoryListing?
    @Published var pendingImages: [PendingPromptImage] = []
    @Published var composerMode = "queue"
    @Published var activeSubagent: ActiveSubagent?
    @Published var selectedSessionId: String? {
        didSet { if hasBooted { scheduleProjectionCache() } }
    }
    @Published private(set) var draftSessionId: String?
    @Published var selectedWorkspaceId: String? {
        didSet { if hasBooted { scheduleProjectionCache() } }
    }
    @Published var draft = ""
    @Published var searchText = ""
    @Published var errorBanner: String?
    @Published var isInspectorPresented = false
    @Published var isSettingsPresented = false
    @Published var isWorkspaceBrowserPresented = false
    @Published var isVoiceConversationPresented = false
    @Published private(set) var voiceConversationStatus = "Ready"
    @Published private(set) var voiceConversationTranscript = ""
    @Published private(set) var isDemoMode = false

    private var api: DshApiClient
    private var connection: DshLiveConnection
    private let idleGuard = IdleGuard()
    private var recordsBySession: [String: [SessionEventRecord]] = [:]
    private var historyHasMoreBySession: [String: Bool] = [:]
    private var projectionsBySession: [String: [String: ProjectionCell]] = [:]
    private var connectionTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var projectionCacheTask: Task<Void, Never>?
    private var draftPreparationTask: Task<Void, Never>?
    private var draftPreparationGeneration = 0
    private var bufferedEnvelopes: [(DshDownlinkChannel, DshServerRequest)] = []
    private var readTimestamps: [String: Double] = UserDefaults.standard
        .dictionary(forKey: "OpenFish.readTimestamps.mac")?
        .compactMapValues { ($0 as? NSNumber)?.doubleValue } ?? [:]
    private var hasBooted = false
    private var hasBaseline = false
    private var isSynchronizingBaseline = true
    private var voiceConversationSessionId: String?
    private var lastVoiceTurnEndSeq = -1

    init(baseURL: URL? = nil, bearerToken: String? = nil) {
        let profile = baseURL.map { NativeConnectionProfile(baseURL: $0, bearerToken: bearerToken) }
            ?? NativeConnectionProfile.restored()
        connectionProfile = profile
        api = DshApiClient(baseURL: profile.baseURL, bearerToken: profile.bearerToken)
        connection = DshLiveConnection(baseURL: profile.baseURL, bearerToken: profile.bearerToken)
    }

    /// Deterministic, network-isolated state for screenshots and product demos.
    static func visualFixture() -> OpenCodexStore {
        let store = OpenCodexStore(baseURL: NativeConnectionProfile.local.baseURL)
        let now = Date().timeIntervalSince1970 * 1_000
        let workspace = WorkspaceView(
            workspaceId: "workspace-aurora",
            path: "/Demo/AuroraNotes",
            title: "Aurora Notes",
            sessionIds: ["session-live", "session-architecture", "session-voice"],
            createdAt: "2026-08-17T00:00:00.000Z",
            updatedAt: "2026-08-17T01:00:00.000Z"
        )
        let dsh = WorkspaceView(
            workspaceId: "workspace-studio",
            path: "/Demo/StudioWebsite",
            title: "Studio Website",
            sessionIds: ["session-plugin"],
            createdAt: "2026-08-16T00:00:00.000Z",
            updatedAt: "2026-08-17T01:00:00.000Z"
        )
        store.workspaces = [workspace, dsh]
        store.sessions = [
            SessionSummary(
                sessionId: "session-live", harnessId: "dsh", updatedAt: now, running: true, blank: false,
                parentSessionId: nil, origin: nil, cwd: workspace.path, agentPreset: "anchored", projections: nil
            ),
            SessionSummary(
                sessionId: "session-architecture", harnessId: "dsh", updatedAt: now - 3_600_000, running: false, blank: false,
                parentSessionId: nil, origin: nil, cwd: workspace.path, agentPreset: "anchored", projections: nil
            ),
            SessionSummary(
                sessionId: "session-voice", harnessId: "dsh", updatedAt: now - 86_400_000, running: false, blank: false,
                parentSessionId: nil, origin: nil, cwd: workspace.path, agentPreset: "anchored", projections: nil
            ),
            SessionSummary(
                sessionId: "session-plugin", harnessId: "dsh", updatedAt: now - 172_800_000, running: false, blank: false,
                parentSessionId: nil, origin: nil, cwd: dsh.path, agentPreset: "standard", projections: nil
            ),
        ]
        store.projectionsBySession = [
            "session-live": [
                "title": ProjectionCell(seq: 14, value: .string("Design the offline sync flow")),
                "permissions": ProjectionCell(
                    seq: 14,
                    value: .object([
                        "options": .array([
                            .object([
                                "value": .string("read-only"),
                                "name": .string("Read Only"),
                                "description": .string("Read files and inspect the project without making changes."),
                            ]),
                            .object([
                                "value": .string("workspace-write"),
                                "name": .string("Workspace Write"),
                                "description": .string("Edit files inside the current workspace."),
                            ]),
                            .object([
                                "value": .string("danger-full-access"),
                                "name": .string("Full Access"),
                                "description": .string("Run outside the workspace sandbox."),
                            ]),
                        ]),
                        "currentValue": .string("workspace-write"),
                    ])
                ),
            ],
            "session-architecture": ["title": ProjectionCell(seq: 8, value: .string("Add export progress"))],
            "session-voice": ["title": ProjectionCell(seq: 5, value: .string("Review accessibility labels"))],
            "session-plugin": ["title": ProjectionCell(seq: 11, value: .string("Polish the launch page"))],
        ]
        store.recordsBySession["session-live"] = visualFixtureRecords(now: now)
        store.pendingApprovals["approval-visual"] = PendingApproval(
            rpcId: "approval-rpc-visual",
            sessionId: "session-live",
            approvalId: "approval-visual",
            toolName: "bash",
            callId: "call-next",
            reason: "Allow OpenFish to update the local sync contract fixture?"
        )
        store.hostDescription = HostDescription(
            version: "demo", cwd: workspace.path, provider: "openai-codex",
            model: "gpt-5.6-sol", attachedSessions: 1, canOpenPath: true
        )
        store.sessionModels = SessionModels(
            current: ModelSelection(provider: "openai-codex", model: "gpt-5.6-sol", reasoningEffort: "medium"),
            routable: true,
            groups: [
                ModelProviderGroup(
                    id: "openai-codex",
                    name: "ChatGPT",
                    models: [
                        CatalogModel(
                            id: "gpt-5.6-sol", name: "GPT-5.6-Sol", description: "Demo model",
                            reasoning: ModelReasoning(
                                efforts: [
                                    ModelReasoningEffort(id: "low", name: "Low", description: nil),
                                    ModelReasoningEffort(id: "medium", name: "Medium", description: nil),
                                    ModelReasoningEffort(id: "high", name: "High", description: nil),
                                ],
                                defaultEffort: "medium"
                            )
                        ),
                    ]
                ),
            ],
            failures: []
        )
        store.harnesses = [HarnessCatalogEntry(
            id: "codex-acp", isDefault: true, name: "Codex", version: "demo", description: "Codex through the OpenFish ACP bridge",
            publisher: "OpenAI", license: nil, repository: "https://github.com/openai/codex", icon: nil,
            verified: true, protocolName: "acp", source: "acp-registry",
            distribution: HarnessDistribution(
                kind: "npx", package: "@zed-industries/codex-acp@0.10.0", archive: nil,
                sha256: nil, command: nil, args: [], env: [:]
            ),
            graph: HarnessGraph(level: "observable", nodes: [HarnessGraphNode(id: "runtime", kind: "runtime", title: "Codex ACP runtime", editable: false, config: nil)], edges: []),
            available: true, unavailableReason: nil,
            installation: .init(status: "builtin", installedVersion: "builtin", availableVersion: "builtin", previousVersions: [], error: nil),
            auth: .init(methods: [], selectedMethod: "chat-gpt", status: "configured", missingFields: []),
            compatibility: .init(status: "compatible", checkedAt: nil, message: "Built in")
        )]
        store.sessions = store.sessions.map { session in
            SessionSummary(
                sessionId: session.sessionId, harnessId: "codex-acp", updatedAt: session.updatedAt,
                running: session.running, blank: session.blank, parentSessionId: session.parentSessionId,
                origin: session.origin, cwd: session.cwd, agentPreset: nil, projections: session.projections
            )
        }
        store.selectedHarnessId = "codex-acp"
        store.selectedWorkspaceId = workspace.workspaceId
        store.selectedSessionId = "session-live"
        store.connectionState = .connected
        store.hasBooted = true
        store.hasBaseline = true
        store.isSynchronizingBaseline = false
        store.isDemoMode = true
        return store
    }

    static func visualNewTaskFixture() -> OpenCodexStore {
        let store = visualFixture()
        let draftId = "session-draft"
        store.selectedSessionId = nil
        store.draftSessionId = draftId
        store.sessions.append(SessionSummary(
            sessionId: draftId,
            harnessId: "codex-acp",
            updatedAt: Date().timeIntervalSince1970 * 1_000,
            running: false,
            blank: true,
            parentSessionId: nil,
            origin: nil,
            cwd: store.currentWorkspace?.path,
            agentPreset: nil,
            projections: nil
        ))
        store.projectionsBySession[draftId] = [
            "permissions": store.projectionsBySession["session-live"]?["permissions"]
        ].compactMapValues { $0 }
        return store
    }

    static func visualHarnessOnboardingFixture() -> OpenCodexStore {
        let store = visualFixture()
        let dsh = HarnessCatalogEntry(
            id: "dsh", isDefault: false, name: "DeepSeek Harness", version: "builtin",
            description: "Native plugin runtime with tools, permissions, and durable sessions.",
            publisher: "DeepSeek", license: "MIT", repository: "https://github.com/deepseek-ai/deepseek-harness", icon: nil,
            verified: true, protocolName: "dsh", source: "builtin", distribution: nil,
            graph: HarnessGraph(
                level: "observable",
                nodes: [
                    HarnessGraphNode(id: "plugins", kind: "plugin-runtime", title: "Cordis plugins", editable: false, config: nil),
                    HarnessGraphNode(id: "loop", kind: "agent-loop", title: "Agent loop", editable: false, config: nil),
                    HarnessGraphNode(id: "tools", kind: "tool-runtime", title: "Tools", editable: false, config: nil),
                ],
                edges: [HarnessGraphEdge(from: "plugins", to: "loop"), HarnessGraphEdge(from: "loop", to: "tools")]
            ),
            available: true, unavailableReason: nil,
            installation: .init(status: "builtin", installedVersion: "builtin", availableVersion: "builtin", previousVersions: [], error: nil),
            auth: .init(methods: [], selectedMethod: nil, status: "not-required", missingFields: []),
            compatibility: .init(status: "compatible", checkedAt: nil, message: "Built in")
        )
        let omp = HarnessCatalogEntry(
            id: "oh-my-pi", isDefault: false, name: "Oh My Pi", version: "17.4.0",
            description: "Community coding Harness with a native ACP mode and advanced tools.",
            publisher: "Oh My Pi contributors", license: "MIT", repository: "https://github.com/can1357/oh-my-pi", icon: nil,
            verified: false, protocolName: "acp", source: "builtin",
            distribution: HarnessDistribution(
                kind: "bunx", package: "@oh-my-pi/pi-coding-agent@17.4.0", archive: nil,
                sha256: nil, command: nil, args: ["acp"], env: [:]
            ),
            graph: HarnessGraph(
                level: "observable",
                nodes: [HarnessGraphNode(id: "runtime", kind: "harness-runtime", title: "OMP ACP", editable: false, config: nil)],
                edges: []
            ),
            available: true, unavailableReason: nil,
            installation: .init(status: "not-installed", installedVersion: nil, availableVersion: "17.4.0", previousVersions: [], error: nil),
            auth: .init(methods: [], selectedMethod: nil, status: "not-required", missingFields: []),
            compatibility: .init(status: "ready", checkedAt: nil, message: "Ready to install")
        )
        store.harnesses = [dsh] + store.harnesses + [omp]
        store.selectedSessionId = nil
        store.selectedHarnessId = ""
        store.needsHarnessOnboarding = true
        store.isLoadingHarnessCatalog = false
        return store
    }

    var currentSession: SessionSummary? {
        guard let selectedSessionId else { return nil }
        return sessions.first { $0.sessionId == selectedSessionId }
    }

    private var controlSessionId: String? { selectedSessionId ?? draftSessionId }

    private var controlSession: SessionSummary? {
        guard let controlSessionId else { return nil }
        return sessions.first { $0.sessionId == controlSessionId }
    }

    var currentAgentPreset: String? { controlSession?.agentPreset }
    var currentHarnessId: String { controlSession?.harnessId ?? draftHarnessId ?? selectedHarnessId }
    var currentHarness: HarnessCatalogEntry? { harnesses.first { $0.id == currentHarnessId } }
    var defaultHarness: HarnessCatalogEntry? { harnesses.first(where: \.isDefault) }
    var canChooseHarness: Bool { selectedSessionId == nil && controlSession?.blank == true }
    var canChooseAgentPreset: Bool { controlSession?.blank == true && currentHarnessId == "dsh" }

    var currentWorkspace: WorkspaceView? {
        if let selectedWorkspaceId,
           let workspace = workspaces.first(where: { $0.workspaceId == selectedWorkspaceId }) {
            return workspace
        }
        guard let sessionId = selectedSessionId else { return nil }
        return workspaces.first { $0.sessionIds.contains(sessionId) }
    }

    var conversation: [ConversationItem] {
        guard let conversationSessionId else { return [] }
        return ConversationProjector.project(recordsBySession[conversationSessionId] ?? [])
    }

    var conversationSessionId: String? {
        activeSubagent?.childSessionId ?? selectedSessionId
    }

    var canLoadOlder: Bool {
        guard let id = conversationSessionId else { return false }
        return historyHasMoreBySession[id] == true && !isLoadingOlder
    }

    var selectedApprovals: [PendingApproval] {
        guard let selectedSessionId = conversationSessionId else { return [] }
        return pendingApprovals.values
            .filter { $0.sessionId == selectedSessionId }
            .sorted { $0.approvalId < $1.approvalId }
    }

    var currentModelName: String {
        guard let models = sessionModels else {
            return hostDescription?.model ?? "Default model"
        }
        for group in models.groups {
            if group.id == models.current.provider,
               let model = group.models.first(where: { $0.id == models.current.model }) {
                return model.name
            }
        }
        return models.current.model
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

    var currentPermissions: PermissionSelect? {
        guard let controlSessionId,
              let value = projectionsBySession[controlSessionId]?["permissions"]?.value else { return nil }
        return try? value.decode(PermissionSelect.self)
    }

    var currentGoal: GoalProjection? {
        guard let id = conversationSessionId,
              let value = projectionsBySession[id]?["goal"]?.value else { return nil }
        return try? value.decode(GoalProjection.self)
    }

    var currentPlan: PlanProjection? {
        guard let id = conversationSessionId,
              let value = projectionsBySession[id]?["plan"]?.value else { return nil }
        return try? value.decode(PlanProjection.self)
    }

    var currentTodos: JSONValue? {
        guard let id = conversationSessionId else { return nil }
        return projectionsBySession[id]?["todos"]?.value
    }

    private var imageLimits: (maxCount: Int, maxImageBytes: Int, maxMessageBytes: Int) {
        guard let id = selectedSessionId,
              let value = projectionsBySession[id]?["imageLimits"]?.value else {
            return (10, 20 * 1_024 * 1_024, 100 * 1_024 * 1_024)
        }
        return (
            value["maxImagesPerMessage"]?.intValue ?? 10,
            value["maxImageBytes"]?.intValue ?? 20 * 1_024 * 1_024,
            value["maxMessageImageBytes"]?.intValue ?? 100 * 1_024 * 1_024
        )
    }

    var selectedQueue: [QueuedInboxItem] {
        guard let id = conversationSessionId else { return [] }
        return queuedItems[id] ?? []
    }

    var selectedJobs: [BackgroundJob] {
        guard let id = conversationSessionId else { return [] }
        return backgroundJobs[id] ?? []
    }

    var selectedQuestions: [PendingQuestion] {
        guard let id = conversationSessionId else { return [] }
        return pendingQuestions.values.filter { $0.sessionId == id }.sorted { $0.rpcId < $1.rpcId }
    }

    var currentPermissionName: String {
        guard let permissions = currentPermissions else { return "Access" }
        return permissions.options.first { $0.value == permissions.currentValue }?.name
            ?? permissions.currentValue
    }

    var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty) && !isSubmitting
    }

    func boot() async {
        guard !hasBooted else { return }
        hasBooted = true
        if let cached = await projectionCache.load(matching: connectionProfile.baseURL) {
            restoreProjectionCache(cached)
        }
        await notifications.requestAuthorization()
        await startConnection()
    }

    private func startConnection() async {
        let stream = connection.updates
        connectionTask = Task { [weak self] in
            for await update in stream {
                guard let self else { return }
                await self.handle(update)
            }
        }
        await connection.start()
        // Baseline synchronization starts from the connected event. Starting it
        // here races the embedded Host's HTTP listener during a cold launch.
    }

    func shutdown() async {
        stopVoiceConversation()
        syncTask?.cancel()
        connectionTask?.cancel()
        projectionCacheTask?.cancel()
        draftPreparationTask?.cancel()
        await projectionCache.save(projectionCacheSnapshot())
        idleGuard.stop()
        await connection.stop()
    }

    func connect(host: String, pairingCode: String?) async {
        guard let baseURL = NativeConnectionProfile.normalizedURL(host) else {
            errorBanner = "Enter a valid http:// or https:// DSH Host address."
            return
        }
        do {
            let trimmedCode = pairingCode?.trimmingCharacters(in: .whitespacesAndNewlines)
            let token: String?
            if let trimmedCode, !trimmedCode.isEmpty {
                let bootstrap = DshBootstrapClient(baseURL: baseURL)
                let receipt = try await bootstrap.pair(
                    deviceName: Host.current().localizedName ?? "Mac",
                    code: trimmedCode
                )
                token = receipt.token
            } else if baseURL == NativeConnectionProfile.local.baseURL {
                token = nil
            } else {
                token = NativeCredentialStore.token(for: baseURL)
            }
            let profile = NativeConnectionProfile(baseURL: baseURL, bearerToken: token)
            try profile.persist()
            await reconfigure(profile)
            errorBanner = nil
        } catch {
            errorBanner = "Could not pair with this DSH Host: \(error)"
        }
    }

    func useLocalHost() async {
        do {
            try NativeConnectionProfile.local.persist()
            await reconfigure(.local)
        } catch {
            errorBanner = "Could not switch to the local Host: \(error)"
        }
    }

    private func reconfigure(_ profile: NativeConnectionProfile) async {
        stopVoiceConversation()
        syncTask?.cancel()
        connectionTask?.cancel()
        projectionCacheTask?.cancel()
        draftPreparationTask?.cancel()
        await projectionCache.save(projectionCacheSnapshot())
        await connection.stop()
        connectionProfile = profile
        api = DshApiClient(baseURL: profile.baseURL, bearerToken: profile.bearerToken)
        connection = DshLiveConnection(baseURL: profile.baseURL, bearerToken: profile.bearerToken)
        connectionState = .connecting
        hasBaseline = false
        isSynchronizingBaseline = true
        bufferedEnvelopes.removeAll(keepingCapacity: false)
        pendingApprovals.removeAll(keepingCapacity: false)
        pendingQuestions.removeAll(keepingCapacity: false)
        queuedItems.removeAll(keepingCapacity: false)
        backgroundJobs.removeAll(keepingCapacity: false)
        workspaces = []
        sessions = []
        recordsBySession = [:]
        historyHasMoreBySession = [:]
        projectionsBySession = [:]
        nativeCapabilities = nil
        sessionModels = nil
        isLoadingSessionModels = false
        sessionModelsError = nil
        draftSessionId = nil
        draftHarnessId = nil
        selectedSessionId = nil
        activeSubagent = nil
        if let cached = await projectionCache.load(matching: profile.baseURL) {
            restoreProjectionCache(cached)
        }
        await startConnection()
    }

    func beginNewTask(in workspaceId: String? = nil) {
        draftPreparationTask?.cancel()
        draftPreparationGeneration += 1
        let generation = draftPreparationGeneration
        let abandonedDraft = draftSessionId
        draftSessionId = nil
        draftHarnessId = nil
        selectedSessionId = nil
        activeSubagent = nil
        selectedWorkspaceId = workspaceId
        sessionModels = nil
        sessionModelsError = nil
        draft = ""
        pendingImages = []
        UserDefaults.standard.removeObject(forKey: "OpenCodex.lastSessionId")
        if let abandonedDraft {
            Task { [weak self] in
                guard let self else { return }
                _ = try? await self.api.archiveSession(abandonedDraft)
            }
        }
        let harnessId = selectedHarnessId
        guard !harnessId.isEmpty else {
            isLoadingSessionModels = false
            needsHarnessOnboarding = true
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
        beginNewTask(in: workspaceId)
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
                _ = try? await api.archiveSession(sessionId)
                return
            }
            draftSessionId = sessionId
            await refreshSessions()
            async let history: Void = loadHistory(sessionId: sessionId)
            async let models: Void = loadModels(sessionId: sessionId)
            async let capabilities: Void = loadSessionCapabilities(sessionId: sessionId)
            _ = await (history, models, capabilities)
        } catch {
            guard !Task.isCancelled,
                  !isOpenFishCancellation(error),
                  generation == draftPreparationGeneration else { return }
            isLoadingSessionModels = false
            sessionModelsError = String(describing: error)
            errorBanner = "Could not prepare a new task: \(error)"
        }
    }

    func selectSession(_ sessionId: String) async {
        guard sessions.contains(where: { $0.sessionId == sessionId }) else { return }
        if let abandonedDraft = draftSessionId, abandonedDraft != sessionId {
            draftSessionId = nil
            _ = try? await api.archiveSession(abandonedDraft)
        }
        selectedSessionId = sessionId
        activeSubagent = nil
        // Never show the previous task's model catalog while this Harness is
        // resuming or when its own catalog fails to load.
        sessionModels = nil
        sessionModelsError = nil
        isLoadingSessionModels = true
        if let workspace = workspaces.first(where: { $0.sessionIds.contains(sessionId) }) {
            selectedWorkspaceId = workspace.workspaceId
        }
        UserDefaults.standard.set(sessionId, forKey: "OpenCodex.lastSessionId")
        async let history: Void = loadHistory(sessionId: sessionId)
        async let models: Void = loadModels(sessionId: sessionId)
        async let capabilities: Void = loadSessionCapabilities(sessionId: sessionId)
        _ = await (history, models, capabilities)
    }

    func loadOlderHistory() async {
        guard let sessionId = conversationSessionId,
              historyHasMoreBySession[sessionId] == true,
              !isLoadingOlder,
              let beforeSeq = recordsBySession[sessionId]?.first?.event.seq else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let page: SessionHistory
            if let activeSubagent {
                page = try await api.subagentHistory(
                    parentSessionId: activeSubagent.parentSessionId,
                    childSessionId: activeSubagent.childSessionId,
                    mode: activeSubagent.mode,
                    beforeSeq: beforeSeq
                )
            } else {
                page = try await api.history(sessionId: sessionId, beforeSeq: beforeSeq)
            }
            applyHistory(page, sessionId: sessionId)
            errorBanner = nil
        } catch {
            errorBanner = "Could not load earlier messages: \(error)"
        }
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !pendingImages.isEmpty), !isSubmitting else { return }
        guard activeSubagent != nil || selectedSessionId != nil || draftSessionId != nil
                || draftHarnessId != nil || !selectedHarnessId.isEmpty else {
            needsHarnessOnboarding = true
            errorBanner = "Choose and configure a default Harness before starting a task."
            return
        }
        isSubmitting = true
        draft = ""
        let submittedImages = pendingImages
        pendingImages = []

        do {
            if let activeSubagent {
                guard activeSubagent.mode == "continuable", submittedImages.isEmpty else {
                    throw DshApiError.host(
                        "subagent-input-unsupported",
                        "Continuable subagents currently accept text follow-ups only."
                    )
                }
                try await api.promptSubagent(
                    parentSessionId: activeSubagent.parentSessionId,
                    childSessionId: activeSubagent.childSessionId,
                    text: text
                )
                errorBanner = nil
                isSubmitting = false
                return
            }
            let sessionId: String
            if let selectedSessionId {
                sessionId = selectedSessionId
            } else if let draftSessionId {
                sessionId = draftSessionId
                self.draftSessionId = nil
                self.selectedSessionId = sessionId
                UserDefaults.standard.set(sessionId, forKey: "OpenCodex.lastSessionId")
            } else {
                sessionId = try await api.createSession(workspaceId: selectedWorkspaceId, harnessId: draftHarnessId ?? selectedHarnessId)
                self.selectedSessionId = sessionId
                UserDefaults.standard.set(sessionId, forKey: "OpenCodex.lastSessionId")
                await refreshSessions()
            }

            _ = try await api.prompt(
                sessionId: sessionId,
                text: text,
                images: submittedImages.map {
                    PromptImage(mediaType: $0.mediaType, data: $0.data, name: $0.name)
                },
                mode: composerMode
            )
            errorBanner = nil
            if recordsBySession[sessionId] == nil {
                await loadHistory(sessionId: sessionId)
            }
            await loadModels(sessionId: sessionId)
        } catch {
            draft = text
            pendingImages = submittedImages
            errorBanner = "Could not send this task: \(error)"
        }
        isSubmitting = false
    }

    func cancelCurrentTask() async {
        guard let selectedSessionId else { return }
        do {
            try await api.cancel(sessionId: selectedSessionId)
            errorBanner = nil
        } catch {
            errorBanner = "Could not stop this task: \(error)"
        }
    }

    func answer(_ approval: PendingApproval, allow: Bool) async {
        do {
            let receipt = try await api.respond(to: approval, outcome: allow ? "allowed-once" : "rejected")
            guard receipt.accepted else {
                throw DshApiError.host("approval-\(receipt.reason ?? "rejected")", "This approval is no longer pending.")
            }
            errorBanner = nil
        } catch {
            errorBanner = "Could not answer the approval: \(error)"
        }
    }

    func chooseModel(provider: String, model: CatalogModel, effort: String? = nil) async {
        guard let selectedSessionId = controlSessionId else { return }
        do {
            let selected = try await api.selectModel(
                sessionId: selectedSessionId,
                selection: ModelSelection(provider: provider, model: model.id, reasoningEffort: effort)
            )
            if let catalog = sessionModels {
                sessionModels = SessionModels(
                    current: selected,
                    routable: catalog.routable,
                    groups: catalog.groups,
                    failures: catalog.failures,
                    harnessOptions: catalog.harnessOptions
                )
            }
            // A Harness can change the supported thought levels when its
            // active model changes. Refresh the authoritative ACP projection
            // instead of retaining the pre-selection directory.
            await loadModels(sessionId: selectedSessionId)
            errorBanner = nil
        } catch {
            errorBanner = "Could not switch models: \(error)"
        }
    }

    func chooseHarnessConfig(_ option: HarnessConfigOption, value: JSONValue) async {
        guard let sessionId = controlSessionId else { return }
        do {
            let options = try await api.setHarnessConfig(sessionId: sessionId, configId: option.id, value: value)
            if let catalog = sessionModels {
                sessionModels = SessionModels(
                    current: catalog.current,
                    routable: catalog.routable,
                    groups: catalog.groups,
                    failures: catalog.failures,
                    harnessOptions: options
                )
            }
            // ACP configuration is interdependent: changing mode or a custom
            // toggle may replace model/reasoning choices as well.
            await loadModels(sessionId: sessionId)
            errorBanner = nil
        } catch {
            errorBanner = "Could not change \(option.name): \(error)"
        }
    }

    func retryCurrentModels() async {
        guard let sessionId = controlSessionId else {
            if selectedSessionId == nil { beginNewTask(in: selectedWorkspaceId) }
            return
        }
        await loadModels(sessionId: sessionId)
    }

    func choosePermission(_ option: PermissionOption) async {
        guard let selectedSessionId = controlSessionId, option.value != "custom", !isChangingPermission else { return }
        isChangingPermission = true
        defer { isChangingPermission = false }
        do {
            let execution = try await api.executeCommand(
                sessionId: selectedSessionId,
                line: "/permission \(option.value)"
            )
            guard execution.result.kind == "success" else {
                throw DshApiError.host(
                    "command-error",
                    execution.result.text ?? "The permission command was rejected."
                )
            }
            // Unlike model selection, the command response has no projection value or
            // watermark. Pull the authoritative tail after admission so the control settles
            // immediately even if its mux push raced a reconnect.
            applyHistory(try await api.history(sessionId: selectedSessionId), sessionId: selectedSessionId)
            errorBanner = nil
        } catch {
            errorBanner = "Could not change access mode: \(error)"
        }
    }

    func chooseAgentPreset(_ preset: AgentPresetEntry) async {
        guard let selectedSessionId = controlSessionId, controlSession?.blank == true, preset.broken == nil else { return }
        do {
            let selected = try await api.selectAgentPreset(
                sessionId: selectedSessionId,
                agentPreset: preset.id
            )
            if let index = sessions.firstIndex(where: { $0.sessionId == selectedSessionId }) {
                let current = sessions[index]
                sessions[index] = SessionSummary(
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
            await loadSessionCapabilities(sessionId: selectedSessionId)
            errorBanner = nil
        } catch {
            errorBanner = "Could not switch the agent preset: \(error)"
        }
    }

    func chooseHarness(_ harness: HarnessCatalogEntry) {
        guard canChooseHarness, harness.id != currentHarnessId else { return }
        Task { await chooseHarnessForDraft(harness) }
    }

    private func chooseHarnessForDraft(_ harness: HarnessCatalogEntry) async {
        guard harnessOperationId == nil, harness.available else {
            errorBanner = harness.unavailableReason ?? "This Harness is not available on this Mac."
            return
        }
        harnessOperationId = harness.id
        defer { harnessOperationId = nil }
        do {
            let current = harnesses.first(where: { $0.id == harness.id }) ?? harness
            if current.installation.status != "builtin" && current.installation.status != "installed" {
                harnesses = try await api.mutateHarness(action: "install", id: harness.id)
            }
            let configured = harnesses.first(where: { $0.id == harness.id }) ?? harness
            guard configured.auth.status == "not-required" || configured.auth.status == "configured" else {
                errorBanner = "Choose and complete a sign-in method for \(harness.name), then select it again."
                return
            }
            draftPreparationTask?.cancel()
            draftPreparationGeneration += 1
            if let abandonedDraft = draftSessionId { _ = try? await api.archiveSession(abandonedDraft) }
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
            errorBanner = nil
        } catch {
            errorBanner = "Could not use \(harness.name) for this task: \(error)"
        }
    }

    func selectDefaultHarness(_ harness: HarnessCatalogEntry, completesOnboarding: Bool = false) async {
        guard harnessOperationId == nil else { return }
        guard harness.available else {
            errorBanner = harness.unavailableReason ?? "This Harness is not available on this Mac."
            return
        }
        harnessOperationId = harness.id
        defer { harnessOperationId = nil }
        do {
            if harness.installation.status != "builtin" && harness.installation.status != "installed" {
                harnesses = try await api.mutateHarness(action: "install", id: harness.id)
            }
            let configured = harnesses.first(where: { $0.id == harness.id }) ?? harness
            guard configured.auth.status == "not-required" || configured.auth.status == "configured" else {
                // Installation may have discovered authentication methods that
                // were absent from the Registry summary. Let the refreshed
                // onboarding card present them without treating discovery as
                // an installation failure.
                errorBanner = nil
                return
            }
            harnesses = try await api.mutateHarness(action: "default", id: harness.id)
            selectedHarnessId = harness.id
            UserDefaults.standard.set(harness.id, forKey: "OpenFish.defaultHarnessId")
            if completesOnboarding {
                needsHarnessOnboarding = false
            }
            if selectedSessionId == nil { beginNewTask(in: selectedWorkspaceId) }
            errorBanner = nil
        } catch {
            errorBanner = "Could not make \(harness.name) the default Harness: \(error)"
        }
    }

    func refreshHarnessCatalog() async {
        do {
            harnesses = try await api.refreshHarnesses()
            harnessCatalogError = nil
            if let sharedDefault = harnesses.first(where: { $0.isDefault }) {
                selectedHarnessId = sharedDefault.id
                UserDefaults.standard.set(sharedDefault.id, forKey: "OpenFish.defaultHarnessId")
            }
            if !harnesses.contains(where: { $0.id == selectedHarnessId && $0.isDefault }) {
                selectedHarnessId = ""
                UserDefaults.standard.removeObject(forKey: "OpenFish.defaultHarnessId")
                needsHarnessOnboarding = true
            }
        } catch {
            harnessCatalogError = String(describing: error)
            errorBanner = "Could not refresh the Harness catalog: \(error)"
        }
    }

    /// Loads the chooser's source of truth independently from general Settings.
    /// Onboarding must never depend on the timing of the initial baseline sync:
    /// a transient decode or connection failure otherwise leaves a modal with an
    /// empty grid and no way for the user to recover.
    func loadHarnessCatalogForOnboarding(forceRefresh: Bool = false) async {
        guard !isLoadingHarnessCatalog else { return }
        isLoadingHarnessCatalog = true
        defer { isLoadingHarnessCatalog = false }
        do {
            var rows = forceRefresh ? try await api.refreshHarnesses() : try await api.harnesses()
            if rows.isEmpty {
                rows = try await api.refreshHarnesses()
            }
            guard !rows.isEmpty else {
                throw DshApiError.host(
                    "harness-catalog-empty",
                    "The Host returned no Harnesses. Refresh the catalog or restart the embedded Host."
                )
            }
            harnesses = rows
            harnessCatalogError = nil
            errorBanner = nil
        } catch {
            harnessCatalogError = String(describing: error)
        }
    }

    func mutateHarness(_ action: String, harness: HarnessCatalogEntry, authMethod: String? = nil) async {
        guard harnessOperationId == nil else { return }
        harnessOperationId = harness.id
        defer { harnessOperationId = nil }
        do {
            harnesses = try await api.mutateHarness(action: action, id: harness.id, authMethod: authMethod)
            errorBanner = nil
        } catch {
            errorBanner = "Could not \(action) \(harness.name): \(error)"
            harnesses = (try? await api.harnesses()) ?? harnesses
        }
    }

    @discardableResult
    func configureHarness(
        _ harness: HarnessCatalogEntry,
        method: HarnessCatalogEntry.Authentication.Method,
        credentials: [String: String] = [:],
        makeDefault: Bool = false,
        completesOnboarding: Bool = false
    ) async -> Bool {
        guard harnessOperationId == nil else { return false }
        harnessOperationId = harness.id
        defer { harnessOperationId = nil }
        do {
            if harness.installation.status != "builtin" && harness.installation.status != "installed" {
                harnesses = try await api.mutateHarness(action: "install", id: harness.id)
            }
            for field in method.fields {
                if let value = credentials[field.ref], !value.isEmpty {
                    try await api.setCredential(ref: field.ref, value: value)
                } else if field.required {
                    throw DshApiError.host("credential-required", "\(field.name) is required.")
                }
            }
            harnesses = try await api.mutateHarness(
                action: method.kind == "terminal" ? "login" : "auth",
                id: harness.id,
                authMethod: method.id
            )
            guard let configured = harnesses.first(where: { $0.id == harness.id }), configured.auth.status == "configured" else {
                throw DshApiError.host("credential-unavailable", "The Host could not resolve all required credentials for \(harness.name).")
            }
            if makeDefault {
                harnesses = try await api.mutateHarness(action: "default", id: harness.id)
                selectedHarnessId = harness.id
                UserDefaults.standard.set(harness.id, forKey: "OpenFish.defaultHarnessId")
                if completesOnboarding { needsHarnessOnboarding = false }
                if selectedSessionId == nil { beginNewTask(in: selectedWorkspaceId) }
            }
            errorBanner = nil
            return true
        } catch {
            errorBanner = "Could not configure \(harness.name): \(error)"
            harnesses = (try? await api.harnesses()) ?? harnesses
            return false
        }
    }

    func saveCustomHarness(
        id: String, name: String, version: String, description: String, publisher: String,
        license: String, repository: String, protocolName: String,
        distributionKind: String, packageOrCommand: String, arguments: [String],
        distributionEnvironment: String,
        binaryCommand: String, sha256: String, graphLevel: String,
        authMethodId: String, authMethodName: String, authKind: String,
        authFieldRef: String, authFieldName: String, authFieldEnv: String,
        terminalAuthArguments: String, terminalAuthEnvironment: String,
        nodes: [HarnessGraphNode], edges: [HarnessGraphEdge], positions: [String: CGPoint]
    ) async -> Bool {
        func environment(_ source: String) -> [String: JSONValue] {
            source.split(whereSeparator: \.isNewline).reduce(into: [:]) { result, line in
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, !parts[0].isEmpty else { return }
                result[parts[0]] = .string(parts[1])
            }
        }
        let launchEnvironment = JSONValue.object(environment(distributionEnvironment))
        let distribution: JSONValue
        if distributionKind == "executable" {
            distribution = .object(["kind": .string("executable"), "command": .string(packageOrCommand), "args": .array(arguments.map(JSONValue.string)), "env": launchEnvironment])
        } else if distributionKind == "binary" {
            var binary: [String: JSONValue] = [
                "kind": .string("binary"), "archive": .string(packageOrCommand), "command": .string(binaryCommand),
                "args": .array(arguments.map(JSONValue.string)), "env": launchEnvironment,
            ]
            if !sha256.isEmpty { binary["sha256"] = .string(sha256) }
            distribution = .object(binary)
        } else {
            distribution = .object(["kind": .string(distributionKind), "package": .string(packageOrCommand), "args": .array(arguments.map(JSONValue.string)), "env": launchEnvironment])
        }
        let graphNodes: [JSONValue] = nodes.map { node in
            let position = positions[node.id] ?? .zero
            var config = node.config ?? [:]
            config["x"] = .number(position.x)
            config["y"] = .number(position.y)
            return .object([
                "id": .string(node.id), "kind": .string(node.kind), "title": .string(node.title), "editable": .bool(node.editable),
                "config": .object(config),
            ])
        }
        let graphEdges: [JSONValue] = edges.map { .object(["from": .string($0.from), "to": .string($0.to)]) }
        var packObject: [String: JSONValue] = [
            "schemaVersion": .number(0), "id": .string(id), "name": .string(name), "version": .string(version),
            "publisher": .string(publisher.isEmpty ? "OpenFish user" : publisher), "protocol": .string(protocolName), "distribution": distribution,
            "graph": .object(["level": .string(graphLevel), "nodes": .array(graphNodes), "edges": .array(graphEdges)]),
        ]
        if !description.isEmpty { packObject["description"] = .string(description) }
        if !license.isEmpty { packObject["license"] = .string(license) }
        if !repository.isEmpty { packObject["repository"] = .string(repository) }
        if !authMethodId.isEmpty {
            var fields: [JSONValue] = []
            if authKind == "environment", !authFieldRef.isEmpty {
                fields = [.object([
                    "ref": .string(authFieldRef), "name": .string(authFieldName.isEmpty ? authFieldRef : authFieldName),
                    "env": .string(authFieldEnv.isEmpty ? authFieldRef : authFieldEnv), "required": .bool(true), "secret": .bool(true),
                ])]
            }
            var auth: [String: JSONValue] = [
                "id": .string(authMethodId), "name": .string(authMethodName.isEmpty ? authMethodId : authMethodName),
                "kind": .string(authKind), "fields": .array(fields),
            ]
            if authKind == "terminal" {
                let loginArgs = terminalAuthArguments.split(whereSeparator: \.isNewline).map { JSONValue.string(String($0)) }
                auth["terminal"] = .object([
                    "args": .array(loginArgs), "env": .object(environment(terminalAuthEnvironment)),
                ])
            }
            packObject["authMethods"] = .array([.object(auth)])
        }
        let pack: JSONValue = .object(packObject)
        do {
            harnesses = try await api.mutateHarness(action: "upsert", pack: pack)
            errorBanner = nil
            return true
        } catch {
            errorBanner = "Could not save the custom Harness: \(error)"
            return false
        }
    }

    func importCustomHarness(from url: URL) async -> Bool {
        do {
            let data = try Data(contentsOf: url)
            let pack = try JSONDecoder().decode(JSONValue.self, from: data)
            guard case .object = pack else { throw CocoaError(.fileReadCorruptFile) }
            harnesses = try await api.mutateHarness(action: "upsert", pack: pack)
            errorBanner = nil
            return true
        } catch {
            errorBanner = "Could not import the Harness Pack: \(error.localizedDescription)"
            return false
        }
    }

    func exportHarness(_ harness: HarnessCatalogEntry, to url: URL, forPublication: Bool = false) -> Bool {
        guard let distribution = harness.distribution else {
            errorBanner = "\(harness.name) does not expose a portable distribution to export."
            return false
        }
        if forPublication && distribution.kind == "executable" {
            errorBanner = "Community publication requires a portable package or checksummed binary, not a path on this Mac."
            return false
        }
        if forPublication && distribution.kind == "binary" && (distribution.sha256?.isEmpty != false) {
            errorBanner = "Community binary publication requires a SHA-256 checksum."
            return false
        }
        let secretName = try? NSRegularExpression(pattern: "(?i)(?:key|token|secret|password|credential)$")
        let unsafeNames = distribution.env.keys.filter { name in
            secretName?.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
                && !(distribution.env[name] ?? "").isEmpty
        }
        guard unsafeNames.isEmpty else {
            errorBanner = "Move potential secrets out of launch environment before export: \(unsafeNames.sorted().joined(separator: ", ")). Use Authentication fields instead."
            return false
        }

        let environment = JSONValue.object(distribution.env.mapValues(JSONValue.string))
        var distributionObject: [String: JSONValue] = [
            "kind": .string(distribution.kind), "args": .array(distribution.args.map(JSONValue.string)), "env": environment,
        ]
        if let package = distribution.package { distributionObject["package"] = .string(package) }
        if let archive = distribution.archive { distributionObject["archive"] = .string(archive) }
        if let sha256 = distribution.sha256 { distributionObject["sha256"] = .string(sha256) }
        if let command = distribution.command { distributionObject["command"] = .string(command) }

        var pack: [String: JSONValue] = [
            "$schema": .string("https://openfish.dev/schemas/harness-pack-v0.json"),
            "schemaVersion": .number(0), "id": .string(harness.id), "name": .string(harness.name),
            "version": .string(harness.version), "publisher": .string(harness.publisher),
            "verified": .bool(false), "protocol": .string(harness.protocolName), "source": .string("user"),
            "distribution": .object(distributionObject),
            "graph": .object([
                "level": .string(harness.graph.level),
                "nodes": .array(harness.graph.nodes.map { node in
                    var value: [String: JSONValue] = [
                        "id": .string(node.id), "kind": .string(node.kind), "title": .string(node.title), "editable": .bool(node.editable),
                    ]
                    if let config = node.config { value["config"] = .object(config) }
                    return .object(value)
                }),
                "edges": .array(harness.graph.edges.map { .object(["from": .string($0.from), "to": .string($0.to)]) }),
            ]),
        ]
        if let description = harness.description { pack["description"] = .string(description) }
        if let license = harness.license { pack["license"] = .string(license) }
        if let repository = harness.repository { pack["repository"] = .string(repository) }
        if !harness.auth.methods.isEmpty {
            pack["authMethods"] = .array(harness.auth.methods.map { method in
                var value: [String: JSONValue] = [
                    "id": .string(method.id), "name": .string(method.name), "kind": .string(method.kind),
                    "fields": .array(method.fields.map { field in
                        var fieldValue: [String: JSONValue] = [
                            "ref": .string(field.ref), "name": .string(field.name),
                            "required": .bool(field.required), "secret": .bool(field.secret),
                        ]
                        if let env = field.env { fieldValue["env"] = .string(env) }
                        if let placeholder = field.placeholder { fieldValue["placeholder"] = .string(placeholder) }
                        return .object(fieldValue)
                    }),
                ]
                if let terminal = method.terminal {
                    value["terminal"] = .object([
                        "args": .array(terminal.args.map(JSONValue.string)),
                        "env": .object(terminal.env.mapValues(JSONValue.string)),
                    ])
                }
                return .object(value)
            })
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(JSONValue.object(pack)).write(to: url, options: .atomic)
            errorBanner = nil
            return true
        } catch {
            errorBanner = "Could not export the Harness Pack: \(error.localizedDescription)"
            return false
        }
    }

    func addWorkspace() async {
        guard !isAddingWorkspace else { return }
        isAddingWorkspace = true
        defer { isAddingWorkspace = false }
        do {
            if !connectionProfile.isLocal {
                await browseHostDirectory()
                return
            }
            guard let path = await pickLocalDirectory() else { return }
            let workspace = try await api.createWorkspace(path: path)
            upsert(workspace)
            selectedWorkspaceId = workspace.workspaceId
            beginNewTask(in: workspace.workspaceId)
            errorBanner = nil
        } catch {
            errorBanner = "Could not add this project: \(error)"
        }
    }

    private func pickLocalDirectory() async -> String? {
        await withCheckedContinuation { continuation in
            let panel = NSOpenPanel()
            panel.title = "Add project"
            panel.prompt = "Add Project"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url?.path : nil)
            }
        }
    }

    func browseHostDirectory(_ path: String? = nil) async {
        guard !isBrowsingWorkspace else { return }
        isBrowsingWorkspace = true
        defer { isBrowsingWorkspace = false }
        do {
            directoryListing = try await api.listDirectory(path: path)
            isWorkspaceBrowserPresented = true
            errorBanner = nil
        } catch {
            errorBanner = "Could not browse the remote Host: \(error)"
        }
    }

    func createHostDirectory(_ name: String) async {
        guard let parent = directoryListing?.path else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let created = try await api.createDirectory(parent: parent, name: trimmed)
            directoryListing = try await api.listDirectory(path: created)
            errorBanner = nil
        } catch {
            errorBanner = "Could not create the remote folder: \(error)"
        }
    }

    func addBrowsedWorkspace() async {
        guard let path = directoryListing?.path else { return }
        do {
            let workspace = try await api.createWorkspace(path: path)
            upsert(workspace)
            selectedWorkspaceId = workspace.workspaceId
            isWorkspaceBrowserPresented = false
            beginNewTask(in: workspace.workspaceId)
            errorBanner = nil
        } catch {
            errorBanner = "Could not add this remote project: \(error)"
        }
    }

    func archiveCurrentSession() async {
        guard let selectedSessionId else { return }
        do {
            archivedSessionIds = Set(try await api.archiveSession(selectedSessionId))
            beginNewTask(in: selectedWorkspaceId)
            errorBanner = nil
        } catch {
            errorBanner = "Could not archive this task: \(error)"
        }
    }

    func unarchiveSession(_ sessionId: String) async {
        do {
            archivedSessionIds = Set(try await api.unarchiveSession(sessionId))
            await selectSession(sessionId)
            errorBanner = nil
        } catch {
            errorBanner = "Could not restore this task: \(error)"
        }
    }

    func renameCurrentSession(_ title: String) async {
        guard let selectedSessionId else { return }
        do {
            let renamed = try await api.renameSession(selectedSessionId, title: title)
            applyProjection(sessionId: selectedSessionId, key: "title", value: .string(renamed.title), seq: renamed.seq)
            errorBanner = nil
        } catch {
            errorBanner = "Could not rename this task: \(error)"
        }
    }

    func forkCurrentSession(atSeq: Int? = nil) async {
        guard let selectedSessionId else { return }
        do {
            let child = try await api.forkSession(selectedSessionId, atSeq: atSeq)
            await refreshSessions()
            await selectSession(child)
            errorBanner = nil
        } catch {
            errorBanner = "Could not fork this task: \(error)"
        }
    }

    func renameWorkspace(_ workspace: WorkspaceView, title: String) async {
        do {
            upsert(try await api.renameWorkspace(workspace.workspaceId, title: title))
            errorBanner = nil
        } catch {
            errorBanner = "Could not rename this project: \(error)"
        }
    }

    func deleteWorkspace(_ workspace: WorkspaceView) async {
        do {
            try await api.deleteWorkspace(workspace.workspaceId)
            workspaces.removeAll { $0.workspaceId == workspace.workspaceId }
            if selectedWorkspaceId == workspace.workspaceId { selectedWorkspaceId = nil }
            errorBanner = nil
        } catch {
            errorBanner = "Could not remove this project: \(error)"
        }
    }

    func performSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            searchResults = try await api.searchSessions(query).items
            errorBanner = nil
        } catch {
            errorBanner = "Could not search task history: \(error)"
        }
    }

    func addImages(_ urls: [URL]) async {
        let existingBytes = pendingImages.reduce(0) { $0 + $1.byteCount }
        let limits = imageLimits
        if pendingImages.count + urls.count > limits.maxCount {
            errorBanner = "This Host accepts at most \(limits.maxCount) images in one message."
            return
        }
        do {
            var added: [PendingPromptImage] = []
            var aggregate = existingBytes
            for url in urls {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard let mediaType = imageMediaType(url.pathExtension) else {
                    throw DshApiError.host("image-format", "\(url.lastPathComponent) is not PNG, JPEG, WebP, or GIF")
                }
                guard data.count <= limits.maxImageBytes else {
                    throw DshApiError.host("image-too-large", "\(url.lastPathComponent) exceeds the per-image limit")
                }
                aggregate += data.count
                guard aggregate <= limits.maxMessageBytes else {
                    throw DshApiError.host("images-too-large", "The selected images exceed the message limit")
                }
                added.append(PendingPromptImage(
                    name: url.lastPathComponent,
                    mediaType: mediaType,
                    data: data.base64EncodedString(),
                    byteCount: data.count
                ))
            }
            pendingImages.append(contentsOf: added)
            errorBanner = nil
        } catch {
            errorBanner = "Could not attach these images: \(error)"
        }
    }

    func removeImage(_ id: UUID) {
        pendingImages.removeAll { $0.id == id }
    }

    func mutateQueue(_ item: QueuedInboxItem, action: String, replacement: String? = nil) async {
        guard let sessionId = conversationSessionId else { return }
        let value: JSONValue
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
            try await api.updateQueue(sessionId: sessionId, itemId: item.id, action: value)
            errorBanner = nil
        } catch {
            errorBanner = "Could not update queued work: \(error)"
        }
    }

    func answer(_ question: PendingQuestion, selections: [String: [String]], custom: [String: String]) async {
        let answers = question.questions.map { item in
            QuestionAnswerItem(
                id: item.id,
                selected: selections[item.id] ?? [],
                custom: custom[item.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        do {
            let receipt = try await api.respond(to: question, answers: answers)
            guard receipt.accepted else {
                throw DshApiError.host("question-rejected", receipt.reason ?? "This question is no longer pending")
            }
            pendingQuestions[question.rpcId] = nil
            errorBanner = nil
        } catch {
            errorBanner = "Could not answer this question: \(error)"
        }
    }

    func openSubagent(_ entry: SubagentEntry) async {
        guard let parent = selectedSessionId,
              entry.kind == "child",
              let mode = entry.mode else { return }
        let selection = ActiveSubagent(
            parentSessionId: parent,
            childSessionId: entry.id,
            mode: mode,
            label: entry.label ?? "Subagent"
        )
        activeSubagent = selection
        do {
            applyHistory(
                try await api.subagentHistory(
                    parentSessionId: parent,
                    childSessionId: entry.id,
                    mode: mode
                ),
                sessionId: entry.id
            )
            errorBanner = nil
        } catch {
            activeSubagent = nil
            errorBanner = "Could not open this subagent: \(error)"
        }
    }

    func closeSubagent() {
        activeSubagent = nil
    }

    func interruptActiveSubagent() async {
        guard let activeSubagent, activeSubagent.mode == "continuable" else { return }
        do {
            try await api.interruptSubagent(
                parentSessionId: activeSubagent.parentSessionId,
                childSessionId: activeSubagent.childSessionId
            )
            errorBanner = nil
        } catch {
            errorBanner = "Could not stop this subagent: \(error)"
        }
    }

    func createGoal(objective: String, maxRounds: Int?) async {
        guard let selectedSessionId else { return }
        do {
            _ = try await api.createGoal(sessionId: selectedSessionId, objective: objective, maxRounds: maxRounds)
            errorBanner = nil
        } catch {
            errorBanner = "Could not create this goal: \(error)"
        }
    }

    func mutateGoal(_ verb: String) async {
        guard let selectedSessionId, let goal = currentGoal?.goal else { return }
        do {
            _ = try await api.mutateGoal(
                sessionId: selectedSessionId,
                verb: verb,
                ref: GoalRef(id: goal.id, revision: goal.revision)
            )
            errorBanner = nil
        } catch {
            errorBanner = "Could not \(verb) this goal: \(error)"
        }
    }

    func setPlanEnabled(_ enabled: Bool) async {
        guard let selectedSessionId else { return }
        do {
            let result = try await api.executeCommand(
                sessionId: selectedSessionId,
                line: enabled ? "/plan" : "/plan off"
            )
            guard result.result.kind == "success" else {
                throw DshApiError.host("command-error", result.result.text ?? "Plan command failed")
            }
            applyHistory(try await api.history(sessionId: selectedSessionId), sessionId: selectedSessionId)
            errorBanner = nil
        } catch {
            errorBanner = "Could not change plan mode: \(error)"
        }
    }

    func loadSettings() async {
        isLoadingSettings = true
        defer { isLoadingSettings = false }
        do {
            async let settings = api.settings()
            async let providerRows = api.configurableProviders()
            async let modelRows = api.hostModels()
            async let pluginRows = api.pluginInventory()
            let (settingsValue, providersValue, modelsValue, pluginsValue) = try await (settings, providerRows, modelRows, pluginRows)
            settingsCatalog = settingsValue
            providers = providersValue
            hostModels = modelsValue
            plugins = pluginsValue
            let bootstrap = DshBootstrapClient(
                baseURL: connectionProfile.baseURL,
                bearerToken: connectionProfile.bearerToken
            )
            pairedDevices = (try? await bootstrap.devices()) ?? []
            errorBanner = nil
        } catch {
            errorBanner = "Could not load Host settings: \(error)"
        }
    }

    func replaceSettings(_ namespace: SettingsNamespaceView, json: String) async {
        do {
            let data = Data(json.utf8)
            let section = try JSONDecoder().decode(JSONValue.self, from: data)
            guard section.objectValue != nil else {
                throw DshApiError.host("settings-invalid", "A settings section must be a JSON object")
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
                settingsCatalog = SettingsCatalog(
                    writable: catalog.writable,
                    hasDocument: catalog.hasDocument,
                    namespaces: rows
                )
            }
            errorBanner = nil
        } catch {
            errorBanner = "Could not save \(namespace.ns): \(error)"
        }
    }

    func setCredential(ref: String, value: String) async {
        do {
            try await api.setCredential(ref: ref, value: value)
            hostModels = (try? await api.hostModels()) ?? hostModels
            errorBanner = nil
        } catch {
            errorBanner = "Could not store this credential: \(error)"
        }
    }

    func credentialRef(for provider: ConfigurableProvider) -> String? {
        guard let namespace = settingsCatalog?.namespaces.first(where: { $0.ns == provider.settingsNs }) else { return nil }
        var value = namespace.value
        for segment in provider.settingsPath {
            guard let next = value[segment] else { return nil }
            value = next
        }
        return value["apiKeyEnv"]?.stringValue
    }

    func createPairingCode() async {
        do {
            let bootstrap = DshBootstrapClient(
                baseURL: connectionProfile.baseURL,
                bearerToken: connectionProfile.bearerToken
            )
            pairingCode = try await bootstrap.createPairingCode()
            errorBanner = nil
        } catch {
            errorBanner = "Could not create a pairing code: \(error)"
        }
    }

    func revoke(_ device: NativeDevice) async {
        do {
            let bootstrap = DshBootstrapClient(
                baseURL: connectionProfile.baseURL,
                bearerToken: connectionProfile.bearerToken
            )
            _ = try await bootstrap.revoke(deviceId: device.deviceId)
            pairedDevices.removeAll { $0.deviceId == device.deviceId }
            errorBanner = nil
        } catch {
            errorBanner = "Could not revoke this device: \(error)"
        }
    }

    func exportCurrentSession(to url: URL) async {
        guard let selectedSessionId else { return }
        do {
            let data = try await api.sessionExport(sessionId: selectedSessionId)
            try data.write(to: url, options: .atomic)
            errorBanner = nil
        } catch {
            errorBanner = "Could not export this task: \(error)"
        }
    }

    func importArchives(_ urls: [URL], format: String) async {
        guard !urls.isEmpty, !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            let files = try await Task.detached(priority: .userInitiated) {
                var candidates: [URL] = []
                for root in urls {
                    let scoped = root.startAccessingSecurityScopedResource()
                    defer { if scoped { root.stopAccessingSecurityScopedResource() } }
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    if isDirectory.boolValue {
                        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
                        guard let enumerator = FileManager.default.enumerator(
                            at: root,
                            includingPropertiesForKeys: keys,
                            options: [.skipsHiddenFiles, .skipsPackageDescendants]
                        ) else { continue }
                        while let child = enumerator.nextObject() as? URL {
                            let ext = child.pathExtension.lowercased()
                            if ext == "jsonl" || ext == "zip" { candidates.append(child) }
                            if candidates.count > 256 {
                                throw DshApiError.host("import-too-many-files", "Select at most 256 rollout or archive files.")
                            }
                        }
                    } else {
                        candidates.append(root)
                    }
                }
                guard !candidates.isEmpty else {
                    throw DshApiError.host("import-empty", "No .jsonl or .zip files were selected.")
                }
                return try candidates.map { url in
                    (name: url.lastPathComponent, data: try Data(contentsOf: url, options: .mappedIfSafe))
                }
            }.value
            let imported = try await api.importSessions(
                files: files,
                workspaceId: selectedWorkspaceId,
                format: format
            )
            async let workspaceSnapshot = api.workspaces()
            async let sessionSnapshot = api.sessions()
            let (updatedWorkspaces, updatedSessions) = try await (workspaceSnapshot, sessionSnapshot)
            workspaces = updatedWorkspaces.items
            archivedSessionIds = Set(updatedWorkspaces.archivedSessionIds)
            mergeSessionBaseline(updatedSessions)
            let root = imported.first(where: \.root) ?? imported.first
            if let root { await selectSession(root.sessionId) }
            let dshCount = imported.filter { $0.source == "dsh" }.count
            let codexCount = imported.count - dshCount
            lastImportSummary = "Imported \(imported.count) task\(imported.count == 1 ? "" : "s") (\(dshCount) DSH, \(codexCount) Codex)."
            errorBanner = nil
        } catch {
            errorBanner = "Could not import these tasks: \(error)"
        }
    }

    func sessions(in workspace: WorkspaceView?) -> [SessionSummary] {
        let visible = sessions.filter {
            $0.origin != "subagent" && !$0.blank && !archivedSessionIds.contains($0.sessionId)
        }
        let members: [SessionSummary]
        if let workspace {
            let byId = Dictionary(uniqueKeysWithValues: visible.map { ($0.sessionId, $0) })
            members = workspace.sessionIds.compactMap { byId[$0] }.sorted(by: sessionRecency)
        } else {
            let accounted = Set(workspaces.flatMap(\.sessionIds))
            members = visible.filter { !accounted.contains($0.sessionId) }
                .sorted(by: sessionRecency)
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return members }
        let remoteMatches = Set(searchResults.map(\.sessionId))
        return members.filter { session in
            !session.blank && (
                displayTitle(for: session).lowercased().contains(query)
                    || (session.cwd?.lowercased().contains(query) ?? false)
                    || remoteMatches.contains(session.sessionId)
            )
        }
    }

    var archivedSessions: [SessionSummary] {
        sessions
            .filter { archivedSessionIds.contains($0.sessionId) && $0.origin != "subagent" && !$0.blank }
            .sorted(by: sessionRecency)
    }

    var orderedWorkspaces: [WorkspaceView] {
        workspaces.sorted { left, right in
            let leftUpdated = sessions(in: left).first?.updatedAt ?? 0
            let rightUpdated = sessions(in: right).first?.updatedAt ?? 0
            if leftUpdated != rightUpdated { return leftUpdated > rightUpdated }
            return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
        }
    }

    var visibleSessionsByRecency: [SessionSummary] {
        (orderedWorkspaces.flatMap { sessions(in: $0) } + sessions(in: nil))
            .reduce(into: [String: SessionSummary]()) { $0[$1.sessionId] = $1 }
            .values.sorted(by: sessionRecency)
    }

    func hasAttention(_ sessionId: String) -> Bool {
        sessions.first(where: { $0.sessionId == sessionId })?.running == true
            || pendingApprovals.values.contains { $0.sessionId == sessionId }
            || pendingQuestions.values.contains { $0.sessionId == sessionId }
    }

    func isUnread(_ session: SessionSummary) -> Bool {
        session.updatedAt > (readTimestamps[session.sessionId] ?? 0)
    }

    func markRead(_ session: SessionSummary) {
        readTimestamps[session.sessionId] = session.updatedAt
        UserDefaults.standard.set(readTimestamps, forKey: "OpenFish.readTimestamps.mac")
        objectWillChange.send()
    }

    func workspaceTitle(for session: SessionSummary) -> String {
        workspaces.first(where: { $0.sessionIds.contains(session.sessionId) })?.title ?? "No Project"
    }

    func displayTitle(for session: SessionSummary) -> String {
        if session.blank { return "New task" }
        if let projected = projectionsBySession[session.sessionId]?["title"]?.value.stringValue,
           !projected.isEmpty {
            return projected
        }
        if let cached = session.projections?.values["title"]?.stringValue, !cached.isEmpty {
            return cached
        }
        if let cwd = session.cwd {
            let base = cwd.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)
            if let base, !base.isEmpty { return base }
        }
        return String(session.sessionId.prefix(12))
    }

    func hasPendingApproval(_ sessionId: String) -> Bool {
        pendingApprovals.values.contains { $0.sessionId == sessionId }
    }

    func dismissError() {
        errorBanner = nil
    }

    func toggleDictation() async {
        let prefix = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        await voice.toggleListening { [weak self] transcript, _ in
            guard let self else { return }
            self.draft = prefix.isEmpty ? transcript : "\(prefix) \(transcript)"
        }
        if let error = voice.errorMessage {
            errorBanner = error
        } else {
            errorBanner = nil
        }
    }

    func startVoiceConversation() async {
        guard activeSubagent == nil else {
            errorBanner = "Voice conversation is available on the parent DSH task."
            return
        }
        isVoiceConversationPresented = true
        voiceConversationStatus = "Listening"
        voiceConversationTranscript = ""
        await listenForVoiceConversation()
    }

    func stopVoiceConversation() {
        isVoiceConversationPresented = false
        voiceConversationStatus = "Ready"
        voiceConversationTranscript = ""
        voiceConversationSessionId = nil
        voice.stopListening()
        voice.stopSpeaking()
    }

    func interruptVoiceConversation() async {
        guard isVoiceConversationPresented else { return }
        voice.stopSpeaking()
        voiceConversationStatus = "Listening"
        voiceConversationTranscript = ""
        await listenForVoiceConversation()
    }

    private func listenForVoiceConversation() async {
        guard isVoiceConversationPresented, !voice.isListening else { return }
        await voice.startListening { [weak self] transcript, isFinal in
            guard let self, self.isVoiceConversationPresented else { return }
            self.voiceConversationTranscript = transcript
            self.voiceConversationStatus = isFinal ? "Sending to DSH" : "Listening"
            if isFinal {
                Task { @MainActor [weak self] in
                    await self?.submitVoiceTranscript(transcript)
                }
            }
        }
        if let error = voice.errorMessage, isVoiceConversationPresented {
            voiceConversationStatus = error
        }
    }

    private func submitVoiceTranscript(_ transcript: String) async {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isVoiceConversationPresented, !text.isEmpty else {
            if isVoiceConversationPresented { await listenForVoiceConversation() }
            return
        }
        guard selectedSessionId != nil || draftHarnessId != nil || !selectedHarnessId.isEmpty else {
            needsHarnessOnboarding = true
            voiceConversationStatus = "Choose a default Harness first"
            return
        }
        do {
            let sessionId: String
            if let selectedSessionId {
                sessionId = selectedSessionId
            } else {
                sessionId = try await api.createSession(workspaceId: selectedWorkspaceId, harnessId: draftHarnessId ?? selectedHarnessId)
                self.selectedSessionId = sessionId
                UserDefaults.standard.set(sessionId, forKey: "OpenCodex.lastSessionId")
                await refreshSessions()
            }
            voiceConversationSessionId = sessionId
            lastVoiceTurnEndSeq = recordsBySession[sessionId]?.last(where: { $0.event.type == "turn/end" })?.event.seq ?? -1
            let isRunning = sessions.first(where: { $0.sessionId == sessionId })?.running == true
            voiceConversationStatus = isRunning ? "Steering current task" : "OpenFish is working"
            _ = try await api.prompt(
                sessionId: sessionId,
                text: text,
                images: [],
                mode: isRunning ? "steer" : "queue"
            )
            errorBanner = nil
        } catch {
            voiceConversationStatus = "Could not send"
            errorBanner = "Could not send the voice transcript: \(error)"
            try? await Task.sleep(for: .milliseconds(800))
            if isVoiceConversationPresented {
                voiceConversationStatus = "Listening"
                voiceConversationTranscript = ""
                await listenForVoiceConversation()
            }
        }
    }

    private func finishVoiceTurn(sessionId: String, endSeq: Int) {
        guard isVoiceConversationPresented,
              voiceConversationSessionId == sessionId,
              endSeq > lastVoiceTurnEndSeq else { return }
        lastVoiceTurnEndSeq = endSeq
        let response = ConversationProjector.project(recordsBySession[sessionId] ?? [])
            .last(where: { $0.kind == .assistant && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .text
        guard let response else {
            voiceConversationStatus = "Listening"
            Task { await listenForVoiceConversation() }
            return
        }
        voiceConversationStatus = "Speaking"
        voice.speak(response) { [weak self] in
            guard let self, self.isVoiceConversationPresented else { return }
            self.voiceConversationStatus = "Listening"
            self.voiceConversationTranscript = ""
            Task { @MainActor [weak self] in await self?.listenForVoiceConversation() }
        }
    }

    // MARK: - Baselines and stream folding

    private func synchronizeBaseline(selectInitialSession: Bool) async {
        do {
            let bootstrap = DshBootstrapClient(
                baseURL: connectionProfile.baseURL,
                bearerToken: connectionProfile.bearerToken
            )
            async let handshake = bootstrap.handshake()
            async let capabilities = bootstrap.capabilities()
            async let description = api.hostDescription()
            async let workspaceList = api.workspaces()
            async let sessionList = api.sessions()
            let (native, composition, host, workspaceSnapshot, sessionSnapshot) = try await (
                handshake, capabilities, description, workspaceList, sessionList
            )
            guard native.ok,
                  native.product == "opencodex",
                  native.host == "dsh",
                  native.protocolVersion == "v2",
                  native.minimumClientProtocol == "v2" else {
                throw DshApiError.host(
                    "native-protocol-incompatible",
                    "This app requires the OpenFish native bootstrap protocol v2."
                )
            }
            guard composition.product == "opencodex",
                  composition.host == "dsh",
                  composition.surface == "native",
                  composition.protocolVersion == "v2",
                  composition.features.apiProxy,
                  composition.features.typert,
                  composition.contracts.sessions,
                  composition.contracts.workspaces,
                  composition.contracts.interactions,
                  composition.features.localVoice,
                  composition.voice?.contract == "dsh.voice.v1",
                  composition.voice?.transcriptAuthority == "session.prompt",
                  composition.voice?.providers.contains(where: {
                      $0.id == voice.providerID
                          && $0.platforms.contains("macos")
                          && $0.operations.contains("speech-to-text")
                          && $0.operations.contains("text-to-speech")
                          && $0.locality == "device"
                  }) == true else {
                throw DshApiError.host(
                    "native-capability-incompatible",
                    "This DSH Host is missing the OpenFish macOS or local-voice composition."
                )
            }
            guard !Task.isCancelled else { return }

            nativeCapabilities = composition
            hostDescription = host
            workspaces = workspaceSnapshot.items
            archivedSessionIds = Set(workspaceSnapshot.archivedSessionIds)
            mergeSessionBaseline(sessionSnapshot)
            hasBaseline = true
            finishBaselineSynchronization()
            errorBanner = nil
            agentPresets = try? await api.agentPresets()
            harnesses = (try? await api.harnesses()) ?? harnesses
            if let sharedDefault = harnesses.first(where: { $0.isDefault }) {
                selectedHarnessId = sharedDefault.id
                UserDefaults.standard.set(sharedDefault.id, forKey: "OpenFish.defaultHarnessId")
                needsHarnessOnboarding = false
            } else {
                selectedHarnessId = ""
                UserDefaults.standard.removeObject(forKey: "OpenFish.defaultHarnessId")
                needsHarnessOnboarding = !harnesses.isEmpty
            }

            if selectInitialSession {
                let remembered = UserDefaults.standard.string(forKey: "OpenCodex.lastSessionId")
                let candidate = remembered.flatMap { id in
                    sessions.first { $0.sessionId == id && !archivedSessionIds.contains(id) }
                } ?? sessions
                    .filter { !$0.blank && $0.origin != "subagent" && !archivedSessionIds.contains($0.sessionId) }
                    .sorted(by: sessionRecency)
                    .first
                if let candidate {
                    await selectSession(candidate.sessionId)
                } else {
                    beginNewTask(in: selectedWorkspaceId)
                }
            } else if let selectedSessionId {
                async let history: Void = loadHistory(sessionId: selectedSessionId)
                async let models: Void = loadModels(sessionId: selectedSessionId)
                _ = await (history, models)
            } else if draftSessionId == nil {
                beginNewTask(in: selectedWorkspaceId)
            }
        } catch {
            guard !Task.isCancelled else { return }
            nativeCapabilities = nil
            finishBaselineSynchronization()
            errorBanner = "OpenFish could not reach the DSH Host at \(connectionProfile.baseURL.absoluteString). \(error)"
        }
    }

    private func refreshSessions() async {
        do {
            mergeSessionBaseline(try await api.sessions())
        } catch {
            errorBanner = "Could not refresh tasks: \(error)"
        }
    }

    private func loadHistory(sessionId: String) async {
        do {
            applyHistory(try await api.history(sessionId: sessionId), sessionId: sessionId)
            errorBanner = nil
        } catch {
            guard !Task.isCancelled, !isOpenFishCancellation(error) else { return }
            errorBanner = "Could not load this task: \(error)"
        }
    }

    private func applyHistory(_ history: SessionHistory, sessionId: String) {
        recordsBySession[sessionId] = mergeRecords(
            history.events,
            recordsBySession[sessionId] ?? []
        )
        historyHasMoreBySession[sessionId] = history.hasMore
        if let projections = history.projections {
            seedProjections(sessionId: sessionId, block: projections)
        }
        objectWillChange.send()
        scheduleProjectionCache()
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
                sessionModelsError = String(describing: error)
            }
        }
    }

    private func loadSessionCapabilities(sessionId: String) async {
        async let skillRows = try? api.skills(sessionId: sessionId)
        async let commandRows = try? api.commandDirectory(sessionId: sessionId)
        async let childCatalog = try? api.subagents(parentSessionId: sessionId)
        async let presets = try? api.agentPresets()
        let (loadedSkills, loadedCommands, loadedChildren, loadedPresets) = await (
            skillRows,
            commandRows,
            childCatalog,
            presets
        )
        guard controlSessionId == sessionId else { return }
        skills = loadedSkills ?? []
        commands = loadedCommands ?? []
        subagents = loadedChildren?.entries ?? []
        agentPresets = loadedPresets
    }

    private func handle(_ update: DshLiveUpdate) async {
        switch update {
        case let .state(state):
            connectionState = state
            if case .reconnecting = state, hasBaseline {
                isSynchronizingBaseline = true
            }
            // Every connected state denotes a fresh two-socket generation. Rebuild from
            // DSH even if an earlier reconnecting state was displaced under backpressure.
            if state == .connected {
                let selectInitialSession = !hasBaseline
                syncTask?.cancel()
                isSynchronizingBaseline = true
                if hasBaseline {
                    // Answerable frames are a live control-plane baseline. The fresh mux
                    // generation replays only requests that are still pending.
                    pendingApprovals.removeAll(keepingCapacity: true)
                    pendingQuestions.removeAll(keepingCapacity: true)
                    queuedItems.removeAll(keepingCapacity: true)
                    backgroundJobs.removeAll(keepingCapacity: true)
                }
                syncTask = Task { [weak self] in
                    await self?.synchronizeBaseline(selectInitialSession: selectInitialSession)
                }
            }
        case let .envelope(channel, envelope):
            guard !isSynchronizingBaseline else {
                bufferedEnvelopes.append((channel, envelope))
                return
            }
            applyEnvelope(channel, envelope)
        }
        scheduleProjectionCache()
    }

    private func finishBaselineSynchronization() {
        isSynchronizingBaseline = false
        let pending = bufferedEnvelopes
        bufferedEnvelopes.removeAll(keepingCapacity: true)
        for (channel, envelope) in pending {
            applyEnvelope(channel, envelope)
        }
        scheduleProjectionCache()
    }

    private func applyEnvelope(_ channel: DshDownlinkChannel, _ envelope: DshServerRequest) {
        switch channel {
        case .host: handleHost(envelope)
        case .mux: handleMux(envelope)
        }
    }

    private func handleHost(_ envelope: DshServerRequest) {
        let frame = envelope.payload
        let type = frame["type"]?.stringValue ?? envelope.method
        switch type {
        case "host/session-added":
            guard let id = frame["sessionId"]?.stringValue else { return }
            if !sessions.contains(where: { $0.sessionId == id }) {
                sessions.append(SessionSummary(
                    sessionId: id,
                    harnessId: frame["harnessId"]?.stringValue ?? "dsh",
                    updatedAt: Date().timeIntervalSince1970 * 1_000,
                    running: false,
                    blank: frame["blank"]?.boolValue ?? true,
                    parentSessionId: frame["parentSessionId"]?.stringValue,
                    origin: frame["origin"]?.stringValue,
                    cwd: frame["cwd"]?.stringValue,
                    agentPreset: frame["agentPreset"]?.stringValue,
                    projections: nil
                ))
            }
        case "host/session-removed":
            guard let id = frame["sessionId"]?.stringValue else { return }
            sessions.removeAll { $0.sessionId == id }
            recordsBySession[id] = nil
            historyHasMoreBySession[id] = nil
            projectionsBySession[id] = nil
            pendingApprovals = pendingApprovals.filter { $0.value.sessionId != id }
            pendingQuestions = pendingQuestions.filter { $0.value.sessionId != id }
            queuedItems[id] = nil
            backgroundJobs[id] = nil
            if selectedSessionId == id { beginNewTask(in: selectedWorkspaceId) }
        case "host/session-status":
            guard let id = frame["sessionId"]?.stringValue,
                  let running = frame["running"]?.boolValue,
                  let index = sessions.firstIndex(where: { $0.sessionId == id }) else { return }
            let wasRunning = sessions[index].running
            sessions[index].running = running
            if running { sessions[index].blank = false }
            sessions[index].updatedAt = Date().timeIntervalSince1970 * 1_000
            updateIdleGuard()
            if wasRunning && !running && !NSApplication.shared.isActive {
                let title = displayTitle(for: sessions[index])
                Task { await notifications.post(title: title, body: "Task finished", sessionId: id) }
            }
        case "host/agent-error":
            if frame["sessionId"]?.stringValue == selectedSessionId {
                errorBanner = frame["message"]?.stringValue ?? "The DSH agent reported an error."
            }
            if frame["sessionId"]?.stringValue == voiceConversationSessionId {
                voiceConversationStatus = "Task failed"
            }
        case "host/workspace-changed":
            guard let value = frame["workspace"], let workspace = try? value.decode(WorkspaceView.self) else { return }
            upsert(workspace)
        case "host/workspace-removed":
            guard let id = frame["workspaceId"]?.stringValue else { return }
            workspaces.removeAll { $0.workspaceId == id }
            if selectedWorkspaceId == id { selectedWorkspaceId = nil }
        case "host/workspace-order-changed":
            guard let ids = frame["workspaceIds"]?.arrayValue?.compactMap(\.stringValue) else { return }
            let byId = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.workspaceId, $0) })
            workspaces = ids.compactMap { byId[$0] }
        case "host/archived-sessions-changed":
            archivedSessionIds = Set(frame["archivedSessionIds"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        default:
            break
        }
    }

    private func handleMux(_ envelope: DshServerRequest) {
        let frame = envelope.payload
        let type = frame["type"]?.stringValue ?? envelope.method
        switch type {
        case "session/event":
            guard let sessionId = frame["sessionId"]?.stringValue,
                  let eventValue = frame["event"],
                  let event = try? eventValue.decode(SessionEvent.self) else { return }
            let record = SessionEventRecord(event: event, view: frame["view"])
            recordsBySession[sessionId] = mergeRecords(recordsBySession[sessionId] ?? [], [record])
            if let index = sessions.firstIndex(where: { $0.sessionId == sessionId }) {
                sessions[index].updatedAt = event.time
                if event.type == "turn/start" || event.type == "user/message" { sessions[index].blank = false }
            }
            if event.type == "turn/end" {
                finishVoiceTurn(sessionId: sessionId, endSeq: event.seq)
            }
            objectWillChange.send()
        case "session/projection":
            guard let sessionId = frame["sessionId"]?.stringValue,
                  let key = frame["key"]?.stringValue,
                  let value = frame["value"],
                  let seq = frame["seq"]?.intValue else { return }
            applyProjection(sessionId: sessionId, key: key, value: value, seq: seq)
        case "approval/requested":
            guard let sessionId = frame["sessionId"]?.stringValue,
                  let approvalId = frame["approvalId"]?.stringValue,
                  let toolName = frame["toolName"]?.stringValue else { return }
            pendingApprovals[approvalId] = PendingApproval(
                rpcId: envelope.rpcId,
                sessionId: sessionId,
                approvalId: approvalId,
                toolName: toolName,
                callId: frame["callId"]?.stringValue,
                reason: frame["reason"]?.stringValue
            )
            if sessionId == voiceConversationSessionId {
                voiceConversationStatus = "Approval required"
                voice.stopSpeaking()
            }
            if !NSApplication.shared.isActive {
                Task {
                    await notifications.post(
                        title: "OpenFish needs approval",
                        body: toolName,
                        sessionId: sessionId
                    )
                }
            }
        case "approval/resolved":
            guard let approvalId = frame["approvalId"]?.stringValue else { return }
            pendingApprovals[approvalId] = nil
        case "question/requested":
            guard let sessionId = frame["sessionId"]?.stringValue,
                  let values = frame["questions"] else { return }
            let questions = (try? values.decode([QuestionItem].self)) ?? []
            pendingQuestions[envelope.rpcId] = PendingQuestion(
                rpcId: envelope.rpcId,
                sessionId: sessionId,
                questions: questions
            )
            if sessionId == voiceConversationSessionId {
                voiceConversationStatus = "Answer required"
                voice.stopSpeaking()
            }
            if !NSApplication.shared.isActive {
                Task {
                    await notifications.post(
                        title: "OpenFish has a question",
                        body: questions.first?.question ?? "Input is required to continue.",
                        sessionId: sessionId
                    )
                }
            }
        case "question/resolved":
            guard let rpcId = frame["questionRpcId"]?.stringValue else { return }
            pendingQuestions[rpcId] = nil
        case "session/queue":
            guard let sessionId = frame["sessionId"]?.stringValue else { return }
            queuedItems[sessionId] = frame["items"]?.arrayValue?.compactMap(QueuedInboxItem.init(json:)) ?? []
        case "session/jobs":
            guard let sessionId = frame["sessionId"]?.stringValue else { return }
            backgroundJobs[sessionId] = frame["jobs"]?.arrayValue?.compactMap(BackgroundJob.init(json:)) ?? []
        default:
            break
        }
    }

    private func mergeSessionBaseline(_ incoming: [SessionSummary]) {
        for session in incoming {
            if let block = session.projections { seedProjections(sessionId: session.sessionId, block: block) }
        }
        sessions = incoming
        updateIdleGuard()
        scheduleProjectionCache()
    }

    private func mergeRecords(
        _ lhs: [SessionEventRecord],
        _ rhs: [SessionEventRecord]
    ) -> [SessionEventRecord] {
        var bySeq = Dictionary(uniqueKeysWithValues: lhs.map { ($0.event.seq, $0) })
        for record in rhs {
            if let existing = bySeq[record.event.seq], record.view == nil, existing.view != nil {
                continue
            }
            bySeq[record.event.seq] = record
        }
        return bySeq.values.sorted { $0.event.seq < $1.event.seq }
    }

    private func seedProjections(sessionId: String, block: SessionProjectionsBlock) {
        for (key, value) in block.values {
            applyProjection(sessionId: sessionId, key: key, value: value, seq: block.asOfSeq)
        }
    }

    private func applyProjection(sessionId: String, key: String, value: JSONValue, seq: Int) {
        let previous = projectionsBySession[sessionId]?[key]
        guard previous == nil || seq >= previous!.seq else { return }
        projectionsBySession[sessionId, default: [:]][key] = ProjectionCell(seq: seq, value: value)
        objectWillChange.send()
        scheduleProjectionCache()
    }

    private func upsert(_ workspace: WorkspaceView) {
        if let index = workspaces.firstIndex(where: { $0.workspaceId == workspace.workspaceId }) {
            workspaces[index] = workspace
        } else {
            workspaces.append(workspace)
        }
        scheduleProjectionCache()
    }

    private func restoreProjectionCache(_ snapshot: MacProjectionSnapshot) {
        workspaces = snapshot.workspaces
        sessions = snapshot.sessions.map { cached in
            var session = cached
            session.running = false
            return session
        }
        archivedSessionIds = snapshot.archivedSessionIds
        recordsBySession = snapshot.recordsBySession
        historyHasMoreBySession = snapshot.historyHasMoreBySession
        projectionsBySession = snapshot.projectionsBySession
        selectedWorkspaceId = snapshot.selectedWorkspaceId.flatMap { id in
            workspaces.contains(where: { $0.workspaceId == id }) ? id : nil
        }
        selectedSessionId = snapshot.selectedSessionId.flatMap { id in
            sessions.contains(where: { $0.sessionId == id }) ? id : nil
        }
        objectWillChange.send()
    }

    private func scheduleProjectionCache() {
        guard hasBooted else { return }
        projectionCacheTask?.cancel()
        let snapshot = projectionCacheSnapshot()
        projectionCacheTask = Task { [projectionCache] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await projectionCache.save(snapshot)
        }
    }

    private func projectionCacheSnapshot() -> MacProjectionSnapshot {
        var retained = Array(sessions.sorted(by: sessionRecency).prefix(24))
        let requiredIds = Set([selectedSessionId, conversationSessionId].compactMap { $0 })
        for id in requiredIds where !retained.contains(where: { $0.sessionId == id }) {
            if let session = sessions.first(where: { $0.sessionId == id }) {
                if retained.count == 24 { retained.removeLast() }
                retained.append(session)
            }
        }
        let retainedIds = Set(retained.map(\.sessionId))
        var records: [String: [SessionEventRecord]] = [:]
        for id in retainedIds {
            guard let values = recordsBySession[id] else { continue }
            records[id] = Array(values.suffix(1_200))
        }
        let history = historyHasMoreBySession.filter { retainedIds.contains($0.key) }
        let projections = projectionsBySession.filter { retainedIds.contains($0.key) }
        return MacProjectionSnapshot(
            version: 1,
            host: connectionProfile.baseURL.absoluteString,
            savedAt: Date(),
            workspaces: workspaces,
            sessions: retained,
            archivedSessionIds: archivedSessionIds,
            recordsBySession: records,
            historyHasMoreBySession: history,
            projectionsBySession: projections,
            selectedWorkspaceId: selectedWorkspaceId,
            selectedSessionId: selectedSessionId
        )
    }

    private func updateIdleGuard() {
        if sessions.contains(where: \SessionSummary.running) {
            idleGuard.start()
        } else {
            idleGuard.stop()
        }
    }
}

private func visualFixtureRecords(now: Double) -> [SessionEventRecord] {
    func event(_ seq: Int, _ type: String, _ data: [String: JSONValue], view: JSONValue? = nil) -> SessionEventRecord {
        SessionEventRecord(
            event: SessionEvent(
                type: type,
                seq: seq,
                time: now - Double(20 - seq) * 1_000,
                data: .object(data),
                sourceEventSeqs: nil,
                surfaceOp: nil,
                ignorable: nil
            ),
            view: view
        )
    }

    return [
        event(1, "user/message", [
            "content": .array([.object([
                "type": .string("text"),
                "text": .string("Design an offline-first sync flow for notes. Keep conflicts understandable and make every recovery action reversible."),
            ])]),
            "source": .object(["kind": .string("user")]),
        ]),
        event(5, "assistant/message", [
            "turn": .number(1), "step": .number(1),
            "message": .object([
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string("I mapped the current persistence boundary and split the flow into local commit, background sync, and conflict review. The local note stays immediately editable while sync state remains visible."),
                ])]),
            ]),
        ]),
        event(7, "tool/call", [
            "turn": .number(1), "step": .number(2), "callId": .string("call-tests"),
            "name": .string("bash"), "arguments": .string("{\"cmd\":\"./Tests/api-smoke.sh\"}"),
        ], view: .object([
            "for": .string("call"),
            "view": .object([
                "card": .string("terminal"), "title": .string("Run the sync contract checks"),
                "description": .string("Offline writes, reconnect replay, and conflict recovery"),
            ]),
        ])),
        event(9, "tool/result", [
            "turn": .number(1), "step": .number(2),
            "message": .object([
                "source": .object(["kind": .string("tool"), "callId": .string("call-tests")]),
                "content": .array([.object([
                    "type": .string("tool-result"), "toolCallId": .string("call-tests"), "isError": .bool(false),
                    "content": .array([.object([
                        "type": .string("text"),
                        "text": .string("Offline write passed\nReconnect replay passed\nConflict recovery passed"),
                    ])]),
                ])]),
            ]),
        ], view: .object([
            "for": .string("result"),
            "view": .object([
                "card": .string("terminal"),
                "output": .string("Offline write passed\nReconnect replay passed\nConflict recovery passed"),
            ]),
        ])),
        event(12, "assistant/message", [
            "turn": .number(1), "step": .number(3),
            "message": .object([
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string("The sync contract now passes in all three states. I also added a conflict summary that explains what changed before the user chooses which version to keep."),
                ])]),
            ]),
        ]),
    ]
}

private func sessionRecency(_ lhs: SessionSummary, _ rhs: SessionSummary) -> Bool {
    if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
    return lhs.sessionId < rhs.sessionId
}

private func imageMediaType(_ pathExtension: String) -> String? {
    switch pathExtension.lowercased() {
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "webp": return "image/webp"
    case "gif": return "image/gif"
    default: return nil
    }
}
