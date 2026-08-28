import Foundation
import SwiftUI
import AppKit

private struct OpenFishDemoHarnessCatalog: Decodable {
    let version: Int
    let items: [HarnessCatalogEntry]
}

private func isOpenFishCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let apiError = error as? DshApiError {
        switch apiError {
        case let .host(code, _): if code == "cancelled" { return true }
        case let .transport(message): if message.localizedCaseInsensitiveContains("cancelled") { return true }
        case .rpcIdMismatch: break
        }
    }
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

enum OpenFishHostIssueKind: String, Equatable, Sendable {
    case recoverable
    case incompatible
}

struct OpenFishHostIssue: Equatable, Sendable {
    let kind: OpenFishHostIssueKind
    let title: String
    let message: String
}

enum OpenFishHostPresentationState: Equatable, Sendable {
    case loading
    case ready
    case cached(OpenFishHostIssue?)
    case recoverable(OpenFishHostIssue?)
    case fatal(OpenFishHostIssue)
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
    @Published private(set) var hostIssue: OpenFishHostIssue?
    @Published private(set) var hostDescription: HostDescription?
    @Published private(set) var sessionModels: SessionModels?
    @Published private(set) var isLoadingSessionModels = false
    @Published private(set) var isChangingModel = false
    @Published private(set) var isChangingHarnessConfig = false
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
    @Published private(set) var harnessOperationPhase: String?
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
    @Published private(set) var attachmentData: [String: Data] = [:]
    @Published private(set) var failedAttachmentKeys: Set<String> = []
    @Published private(set) var lastImportSummary: String?
    @Published private(set) var isSubmitting = false
    @Published private(set) var isChangingPermission = false
    @Published private(set) var isAddingWorkspace = false
    @Published private(set) var isBrowsingWorkspace = false
    @Published private(set) var directoryListing: HostDirectoryListing?
    @Published var pendingImages: [PendingPromptImage] = []
    @Published var composerMode = "queue"
    @Published var activeSubagent: ActiveSubagent? {
        didSet {
            guard hasBooted else { return }
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
    @Published var selectedSessionId: String? {
        didSet {
            guard hasBooted else { return }
            scheduleProjectionCache()
            guard activeSubagent == nil else { return }
            let selected = selectedSessionId
            let liveConnection = connection
            Task { await liveConnection.selectSession(selected) }
        }
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
    @Published var isModelBrowserPresented = false
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
    private var loadingAttachmentKeys: Set<String> = []
    private var projectionsBySession: [String: [String: ProjectionCell]] = [:]
    private var harnessesBySession: [String: HarnessCatalogEntry] = [:]
    private var connectionTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var projectionCacheTask: Task<Void, Never>?
    private var draftPreparationTask: Task<Void, Never>?
    private var harnessOperationCancellation: (() -> Void)?
    private var draftPreparationGeneration = 0
    private var bufferedFeeds: [JSONValue] = []
    private var remoteEventClientId: String?
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
        api = DshApiClient(
            baseURL: profile.baseURL,
            bearerToken: profile.bearerToken,
            tlsFingerprint: profile.tlsFingerprint
        )
        connection = DshLiveConnection(
            baseURL: profile.baseURL,
            bearerToken: profile.bearerToken,
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

    private func livePreflightIfNeeded(_ harness: HarnessCatalogEntry) async throws -> HarnessCatalogEntry {
        if harness.compatibility.status == "compatible" { return harness }
        let rows = try await runHarnessOperationStep(
            "Checking \(harness.name) against its live protocol…"
        ) {
            try await self.api.mutateHarness(action: "probe", id: harness.id)
        }
        harnesses = rows
        guard let verified = rows.first(where: { $0.id == harness.id }) else {
            throw DshApiError.host("harness-missing-after-preflight", "The checked Harness disappeared from the Host catalog.")
        }
        return verified
    }

    /// Deterministic, network-isolated state for screenshots and product demos.
    static func visualFixture() -> OpenCodexStore {
        // Use a non-network URL scheme so an accidentally reachable code path
        // still cannot contact the resident Host or a model provider.
        let store = OpenCodexStore(baseURL: URL(string: "openfish-demo://fixture")!)
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
            clientId: "demo",
            rpcId: "approval-rpc-visual",
            sessionId: "session-live",
            approvalId: "approval-visual",
            toolName: "bash",
            callId: "call-next",
            reason: "Allow OpenFish to update the local sync contract fixture?"
        )
        store.hostDescription = HostDescription(
            version: "demo", cwd: workspace.path, provider: "openai",
            model: "gpt-5.6-sol", attachedSessions: 1, canOpenPath: true
        )
        store.sessionModels = SessionModels(
            current: ModelSelection(provider: "openai", model: "gpt-5.6-sol", reasoningEffort: "medium"),
            routable: true,
            groups: [
                ModelProviderGroup(
                    id: "openai",
                    name: "OpenAI",
                    models: [
                        CatalogModel(
                            id: "gpt-5.6-sol", name: "GPT-5.6-Sol", description: "Demo model",
                            providerId: "openai", providerName: "OpenAI",
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
            failures: [],
            account: HarnessCatalogEntry.AccountDescriptor(
                label: "ChatGPT · Pro",
                billing: "subscription",
                detail: "Demo data: the official Codex app-server reported a ChatGPT Pro route. OpenFish retained neither email nor credentials."
            )
        )
        store.harnesses = Self.generatedVisualHarnesses().filter { $0.id == "codex" }
        store.sessions = store.sessions.map { session in
            SessionSummary(
                sessionId: session.sessionId, harnessId: "codex", updatedAt: session.updatedAt,
                running: session.running, blank: session.blank, parentSessionId: session.parentSessionId,
                origin: session.origin, cwd: session.cwd, agentPreset: nil, projections: session.projections
            )
        }
        store.selectedHarnessId = "codex"
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
            harnessId: "codex",
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
        store.harnesses = Self.generatedVisualHarnesses()
        store.selectedSessionId = nil
        store.selectedHarnessId = ""
        store.needsHarnessOnboarding = true
        store.isLoadingHarnessCatalog = false
        return store
    }

    static func visualLoadingFixture() -> OpenCodexStore {
        let store = OpenCodexStore(baseURL: URL(string: "openfish-demo://fixture")!)
        store.connectionState = .connecting
        store.hasBooted = true
        store.isSynchronizingBaseline = true
        store.isDemoMode = true
        return store
    }

    static func visualRecoverableFixture() -> OpenCodexStore {
        let store = visualLoadingFixture()
        store.connectionState = .reconnecting(attempt: 3)
        store.isSynchronizingBaseline = false
        store.hostIssue = .init(
            kind: .recoverable,
            title: "OpenFish could not finish connecting",
            message: "The demo Host is temporarily unavailable. Retry the connection or choose another Host."
        )
        return store
    }

    static func visualFatalFixture() -> OpenCodexStore {
        let store = visualLoadingFixture()
        store.connectionState = .connected
        store.isSynchronizingBaseline = false
        store.hostIssue = .init(
            kind: .incompatible,
            title: "This Host is not compatible",
            message: "The demo Host does not implement the OpenFish native bootstrap protocol required by this app."
        )
        return store
    }

    static func visualOfflineFixture() -> OpenCodexStore {
        let store = visualFixture()
        store.connectionState = .reconnecting(attempt: 2)
        store.nativeCapabilities = nil
        store.hostIssue = .init(
            kind: .recoverable,
            title: "Reconnecting to the Host",
            message: "Cached tasks remain readable while sending and approvals wait for the Host."
        )
        return store
    }

    static func visualEmptyFixture() -> OpenCodexStore {
        let store = visualFixture()
        store.workspaces = []
        store.sessions = []
        store.archivedSessionIds = []
        store.recordsBySession = [:]
        store.projectionsBySession = [:]
        store.selectedWorkspaceId = nil
        store.selectedSessionId = nil
        store.draftSessionId = nil
        return store
    }

    private static func generatedVisualHarnesses() -> [HarnessCatalogEntry] {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "openfish-demo-harnesses", withExtension: "json") else {
            preconditionFailure("The generated OpenFish Demo Harness catalog is missing from the app bundle")
        }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return try JSONDecoder().decode(OpenFishDemoHarnessCatalog.self, from: data).items
        } catch {
            preconditionFailure("The generated OpenFish Demo Harness catalog is invalid: \(error)")
        }
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
    var currentHarnessAuthMethod: String? { controlSession?.harnessAuthMethod }
    var controlHarnessVersionLabel: String {
        controlSession?.harnessVersion
            ?? currentHarness?.installation.installedVersion
            ?? currentHarness?.version
            ?? "version pending"
    }
    var currentHarness: HarnessCatalogEntry? {
        if let controlSessionId, let pinned = harnessesBySession[controlSessionId] { return pinned }
        return harnesses.first { $0.id == currentHarnessId }
    }
    func harnessCapability(_ id: String) -> String? {
        if let snapshot = controlSession?.harnessCapabilities {
            return snapshot.contains(id) ? "supported" : "unsupported"
        }
        return currentHarness?.capabilities.first(where: { $0.id == id })?.status
    }
    func harnessCan(_ id: String) -> Bool { harnessCapability(id) != "unsupported" && harnessCapability(id) != nil }
    func canFork(_ session: SessionSummary) -> Bool {
        if let snapshot = session.harnessCapabilities { return snapshot.contains("session.fork") }
        let harnessId = session.harnessId ?? "dsh"
        let harness = harnessesBySession[session.sessionId] ?? harnesses.first(where: { $0.id == harnessId })
        return harness?.capabilities.first(where: { $0.id == "session.fork" })?.status != "unsupported"
            && harness?.capabilities.contains(where: { $0.id == "session.fork" }) == true
    }
    var defaultHarness: HarnessCatalogEntry? { harnesses.first(where: \.isDefault) }
    var canChooseHarness: Bool { selectedSessionId == nil && (controlSession?.blank ?? true) }
    var canChooseAgentPreset: Bool { controlSession?.blank == true && harnessCan("configuration.agent-presets") }

    private func isRunnableDefault(_ harness: HarnessCatalogEntry) -> Bool {
        let installed = harness.installation.status == "builtin" || harness.installation.status == "installed"
        let authenticated = harness.auth.status == "not-required" || harness.auth.status == "configured"
        return harness.available && installed && authenticated
    }

    var currentWorkspace: WorkspaceView? {
        if let sessionId = selectedSessionId {
            return workspaces.first { $0.sessionIds.contains(sessionId) }
        }
        if let selectedWorkspaceId,
           let workspace = workspaces.first(where: { $0.workspaceId == selectedWorkspaceId }) {
            return workspace
        }
        return nil
    }

    var conversation: [ConversationItem] {
        guard let conversationSessionId else { return [] }
        return ConversationProjector.project(recordsBySession[conversationSessionId] ?? [])
    }

    var visibleCommands: [JSONValue] {
        var native: [JSONValue] = []
        if let id = conversationSessionId {
            for record in (recordsBySession[id] ?? []).sorted(by: { $0.event.seq < $1.event.seq }) {
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

    var conversationSessionId: String? {
        activeSubagent?.childSessionId ?? selectedSessionId
    }

    var canLoadOlder: Bool {
        guard let id = conversationSessionId else { return false }
        return historyHasMoreBySession[id] == true && !isLoadingOlder
    }

    func cachedAttachment(sessionId: String, attachmentId: String) -> Data? {
        attachmentData[attachmentCacheKey(sessionId: sessionId, attachmentId: attachmentId)]
    }

    func attachmentFailed(sessionId: String, attachmentId: String) -> Bool {
        failedAttachmentKeys.contains(attachmentCacheKey(sessionId: sessionId, attachmentId: attachmentId))
    }

    func loadAttachment(sessionId: String, attachmentId: String, retry: Bool = false) async {
        let key = attachmentCacheKey(sessionId: sessionId, attachmentId: attachmentId)
        guard attachmentData[key] == nil, loadingAttachmentKeys.insert(key).inserted else { return }
        if retry { failedAttachmentKeys.remove(key) }
        defer { loadingAttachmentKeys.remove(key) }
        do {
            attachmentData[key] = try await api.attachmentData(sessionId: sessionId, attachmentId: attachmentId)
            failedAttachmentKeys.remove(key)
        } catch {
            failedAttachmentKeys.insert(key)
        }
    }

    private func attachmentCacheKey(sessionId: String, attachmentId: String) -> String {
        "\(sessionId):\(attachmentId)"
    }

    var selectedApprovals: [PendingApproval] {
        guard let selectedSessionId = conversationSessionId else { return [] }
        return pendingApprovals.values
            .filter { $0.sessionId == selectedSessionId }
            .sorted { $0.approvalId < $1.approvalId }
    }

    var currentModelName: String {
        guard let models = sessionModels else {
            if isLoadingSessionModels { return "Discovering models…" }
            if sessionModelsError != nil { return "Models unavailable" }
            return "Model not discovered"
        }
        for group in models.groups {
            if group.id == models.current.provider,
               let model = group.models.first(where: { $0.id == models.current.model }) {
                return model.name
            }
        }
        if models.current.provider == "harness", models.groups.isEmpty {
            return "Harness-managed model"
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

    var currentModel: CatalogModel? {
        guard let models = sessionModels else { return nil }
        return models.groups
            .first(where: { $0.id == models.current.provider })?
            .models.first(where: { $0.id == models.current.model })
    }

    var currentReasoningOptions: [ModelReasoningEffort] {
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

    var canAttachImages: Bool { harnessCan("interaction.files") }

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

    var currentHarnessRuntime: HarnessRuntimeProjection? {
        guard let id = conversationSessionId,
              let value = projectionsBySession[id]?["harnessRuntime"]?.value else { return nil }
        return try? value.decode(HarnessRuntimeProjection.self)
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
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty)
            && (pendingImages.isEmpty || canAttachImages)
            && (activeSubagent != nil || sessionModels?.routable == true)
            && canStartNewTask
            && !isSubmitting
    }

    var hostPresentationState: OpenFishHostPresentationState {
        let hasCachedProjection = !workspaces.isEmpty || !sessions.isEmpty
        let liveBaseline = connectionState == .connected
            && hasBaseline
            && !isSynchronizingBaseline
            && (nativeCapabilities != nil || isDemoMode)
        if liveBaseline { return .ready }
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
        guard !connectionProfile.requiresPairing else {
            connectionState = .reconnecting(attempt: 0)
            hasBaseline = false
            isSynchronizingBaseline = false
            hostIssue = OpenFishHostIssue(
                kind: .recoverable,
                title: "Pair this Mac",
                message: "Enter a fresh one-time code from the OpenFish Host. The resulting device credential stays in this Mac's Keychain."
            )
            return
        }
        let stream = connection.updates
        connectionTask = Task { [weak self] in
            for await update in stream {
                guard let self else { return }
                await self.handle(update)
            }
        }
        await connection.selectSession(selectedSessionId)
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
            errorBanner = "Enter the Host's https:// address. Plain HTTP is allowed only for this Mac's loopback Host."
            return
        }
        do {
            let trimmedCode = pairingCode?.trimmingCharacters(in: .whitespacesAndNewlines)
            let token: String?
            let tlsFingerprint: String?
            var persistentURL = baseURL
            if let trimmedCode, !trimmedCode.isEmpty {
                let bootstrap = DshBootstrapClient(baseURL: baseURL, permitsBootstrapTrust: true)
                let result = try await bootstrap.pair(
                    deviceName: Host.current().localizedName ?? "Mac",
                    code: trimmedCode
                )
                token = result.receipt.token
                tlsFingerprint = result.tlsFingerprint
                if let advertised = result.receipt.hostURL {
                    guard let canonical = NativeConnectionProfile.normalizedURL(advertised),
                          canonical.scheme == "https" else {
                        throw NativeCredentialError.incompleteRemoteAuthorization
                    }
                    persistentURL = canonical
                }
            } else if baseURL == NativeConnectionProfile.local.baseURL {
                token = nil
                tlsFingerprint = nil
            } else {
                token = NativeCredentialStore.token(for: baseURL)
                tlsFingerprint = NativeCredentialStore.fingerprint(for: baseURL)
            }
            let profile = NativeConnectionProfile(
                baseURL: persistentURL,
                bearerToken: token,
                tlsFingerprint: tlsFingerprint
            )
            try profile.persist()
            if persistentURL != baseURL {
                NativeCredentialStore.removeAuthorization(for: baseURL)
            }
            await reconfigure(profile)
            errorBanner = nil
        } catch {
            errorBanner = "Could not pair with this OpenFish Host: \(error)"
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

    func retryHostConnection() async {
        guard !isDemoMode else { return }
        guard !connectionProfile.requiresPairing else {
            isSettingsPresented = true
            return
        }
        hostIssue = nil
        syncTask?.cancel()
        connectionTask?.cancel()
        await connection.stop()
        connectionState = .connecting
        isSynchronizingBaseline = true
        await startConnection()
    }

    private func reconfigure(_ profile: NativeConnectionProfile) async {
        stopVoiceConversation()
        syncTask?.cancel()
        connectionTask?.cancel()
        projectionCacheTask?.cancel()
        draftPreparationTask?.cancel()
        // An explicit Host switch is the ownership boundary for a prepared
        // draft. Delete it while the old authenticated client is still live.
        // If that fails, keep its host-keyed snapshot so returning to the Host
        // can retry the exact id instead of leaking an invisible provider task.
        if let abandonedDraft = draftSessionId {
            do {
                try await api.discardSession(abandonedDraft)
                draftSessionId = nil
                draftHarnessId = nil
            } catch {
                // The old Host cache retains the exact pending identity.
            }
        }
        await projectionCache.save(projectionCacheSnapshot())
        await connection.stop()
        connectionProfile = profile
        api = DshApiClient(
            baseURL: profile.baseURL,
            bearerToken: profile.bearerToken,
            tlsFingerprint: profile.tlsFingerprint
        )
        connection = DshLiveConnection(
            baseURL: profile.baseURL,
            bearerToken: profile.bearerToken,
            tlsFingerprint: profile.tlsFingerprint
        )
        connectionState = .connecting
        hostIssue = nil
        hasBaseline = false
        isSynchronizingBaseline = true
        bufferedFeeds.removeAll(keepingCapacity: false)
        remoteEventClientId = nil
        purgeHostProjection()
        isLoadingSessionModels = false
        if let cached = await projectionCache.load(matching: profile.baseURL) {
            restoreProjectionCache(cached)
        }
        await startConnection()
    }

    func beginNewTask(in workspaceId: String? = nil, harnessId requestedHarnessId: String? = nil) {
        guard canStartNewTask else { return }
        if isDemoMode {
            selectedWorkspaceId = workspaceId
            selectedSessionId = nil
            draftHarnessId = requestedHarnessId ?? selectedHarnessId
            draftSessionId = "demo-draft"
            activeSubagent = nil
            draft = ""
            pendingImages = []
            errorBanner = nil
            return
        }
        draftPreparationTask?.cancel()
        draftPreparationGeneration += 1
        let generation = draftPreparationGeneration
        let abandonedDraft = draftSessionId
        let harnessId = requestedHarnessId ?? selectedHarnessId
        draftSessionId = nil
        // A draft is an immutable Harness choice, even when it currently
        // matches the shared default. Persist the exact id so a later default
        // change cannot silently retarget a crash-recovered task.
        draftHarnessId = harnessId
        selectedSessionId = nil
        activeSubagent = nil
        selectedWorkspaceId = workspaceId
        sessionModels = nil
        sessionModelsError = nil
        draft = ""
        pendingImages = []
        UserDefaults.standard.removeObject(forKey: "OpenCodex.lastSessionId")
        scheduleProjectionCache()
        if let abandonedDraft {
            Task { [weak self] in
                guard let self else { return }
                try? await self.api.discardSession(abandonedDraft)
            }
        }
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
        let harnessId = currentHarnessId
        beginNewTask(in: workspaceId, harnessId: harnessId)
    }

    private func prepareNewTaskControls(generation: Int, workspaceId: String?, harnessId: String) async {
        guard !Task.isCancelled,
              generation == draftPreparationGeneration,
              selectedSessionId == nil,
              draftSessionId == nil else { return }
        // The client chooses the durable id before crossing the network. Host
        // retries are idempotent, so cancellation or a lost HTTP response can
        // never create an unaddressable blank provider task.
        let requestedSessionId = UUID().uuidString.lowercased()
        draftSessionId = requestedSessionId
        scheduleProjectionCache()
        do {
            let sessionId = try await api.createSession(
                workspaceId: workspaceId,
                harnessId: harnessId,
                sessionId: requestedSessionId
            )
            guard sessionId == requestedSessionId else {
                throw DshApiError.host(
                    "session-identity-mismatch",
                    "The Host returned a different id for the prepared task."
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
            scheduleProjectionCache()
        }
    }

    func selectSession(_ sessionId: String) async {
        if isDemoMode {
            guard sessions.contains(where: { $0.sessionId == sessionId }) else { return }
            selectedSessionId = sessionId
            activeSubagent = nil
            selectedWorkspaceId = workspaces.first(where: { $0.sessionIds.contains(sessionId) })?.workspaceId
            return
        }
        // A task can be opened immediately after creation (or from a deep link)
        // before the live baseline has announced it. Refresh once instead of
        // silently ignoring the selection and leaving all session controls empty.
        if !sessions.contains(where: { $0.sessionId == sessionId }) {
            do {
                mergeSessionBaseline(try await api.sessions())
            } catch {
                guard !Task.isCancelled, !isOpenFishCancellation(error) else { return }
                errorBanner = "Could not open this task: \(error)"
                return
            }
        }
        guard sessions.contains(where: { $0.sessionId == sessionId }) else {
            errorBanner = "Could not open this task because the Host has not published it yet."
            return
        }
        if let abandonedDraft = draftSessionId, abandonedDraft != sessionId {
            draftSessionId = nil
            draftHarnessId = nil
            try? await api.discardSession(abandonedDraft)
        }
        selectedSessionId = sessionId
        activeSubagent = nil
        // Never show the previous task's model catalog while this Harness is
        // resuming or when its own catalog fails to load.
        sessionModels = nil
        sessionModelsError = nil
        isLoadingSessionModels = true
        selectedWorkspaceId = workspaces.first(where: { $0.sessionIds.contains(sessionId) })?.workspaceId
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
        if isDemoMode {
            draft = ""
            pendingImages = []
            errorBanner = "Demo State is read-only and never sends prompts to a Host or provider."
            return
        }
        guard pendingImages.isEmpty || canAttachImages else {
            errorBanner = "\(currentHarness?.name ?? "This Harness") does not accept image input through its current Driver. Remove the images or choose a Harness that advertises file input."
            return
        }
        guard activeSubagent != nil || sessionModels?.routable == true else {
            errorBanner = sessionModels == nil
                ? "OpenFish is still checking this Harness's model and account. Wait or retry model discovery."
                : "The selected model cannot run. Choose a configured model before sending."
            isModelBrowserPresented = true
            return
        }
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
        let firstTurnHarnessId = draftHarnessId ?? selectedHarnessId
        var firstTurnSessionId: String?

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
                firstTurnSessionId = sessionId
                self.draftSessionId = nil
                self.draftHarnessId = nil
                self.selectedSessionId = sessionId
                UserDefaults.standard.set(sessionId, forKey: "OpenCodex.lastSessionId")
            } else {
                let requestedSessionId = UUID().uuidString.lowercased()
                sessionId = try await api.createSession(
                    workspaceId: selectedWorkspaceId,
                    harnessId: draftHarnessId ?? selectedHarnessId,
                    sessionId: requestedSessionId
                )
                guard sessionId == requestedSessionId else {
                    throw DshApiError.host(
                        "session-identity-mismatch",
                        "The Host returned a different id for the task."
                    )
                }
                firstTurnSessionId = sessionId
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
            if let firstTurnSessionId {
                await reconcileFailedFirstTurn(
                    sessionId: firstTurnSessionId,
                    harnessId: firstTurnHarnessId
                )
            }
            draft = text
            pendingImages = submittedImages
            errorBanner = "Could not send this task: \(error)"
        }
        isSubmitting = false
    }

    private func reconcileFailedFirstTurn(sessionId: String, harnessId: String) async {
        do {
            let authoritative = try await api.sessions()
            mergeSessionBaseline(authoritative)
            guard let summary = authoritative.first(where: { $0.sessionId == sessionId }),
                  summary.blank,
                  summary.origin != "subagent",
                  !archivedSessionIds.contains(sessionId) else { return }
            selectedSessionId = nil
            draftSessionId = sessionId
            draftHarnessId = summary.harnessId ?? harnessId
            UserDefaults.standard.removeObject(forKey: "OpenCodex.lastSessionId")
            scheduleProjectionCache()
        } catch {
            // Unknown admission state is deliberately kept as a selected task;
            // recovery will classify it from the next authoritative baseline.
        }
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
        if isDemoMode {
            pendingApprovals[approval.approvalId] = nil
            return
        }
        do {
            let receipt = try await api.respond(to: approval, outcome: allow ? "allowed-once" : "rejected")
            guard receipt.accepted else {
                throw DshApiError.host("approval-\(receipt.reason ?? "rejected")", "This approval is no longer pending.")
            }
            // The successful RPC receipt is authoritative for this client.
            // A later cancellation/resolution feed is useful for other
            // clients, but it is not guaranteed to race back to the answering
            // connection before the tool and turn complete.
            pendingApprovals[approval.approvalId] = nil
            errorBanner = nil
        } catch {
            errorBanner = "Could not answer the approval: \(error)"
        }
    }

    @discardableResult
    func chooseModel(provider: String, model: CatalogModel, effort: String? = nil) async -> Bool {
        guard let selectedSessionId = controlSessionId, !isChangingModel else { return false }
        isChangingModel = true
        defer { isChangingModel = false }
        if isDemoMode {
            if let catalog = sessionModels {
                sessionModels = SessionModels(
                    current: ModelSelection(
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
                selection: ModelSelection(provider: provider, model: model.id, reasoningEffort: effort)
            )
            if let catalog = sessionModels {
                sessionModels = SessionModels(
                    current: selected,
                    routable: catalog.routable,
                    groups: catalog.groups,
                    failures: catalog.failures,
                    account: catalog.account,
                    harnessOptions: catalog.harnessOptions
                )
            }
            // A Harness can change the supported thought levels when its
            // active model changes. Refresh the authoritative ACP projection
            // instead of retaining the pre-selection directory.
            await loadModels(sessionId: selectedSessionId)
            errorBanner = nil
            return true
        } catch {
            // A protocol may switch the model before rejecting a newly
            // discovered reasoning value. Pull the live catalog even on
            // failure so the picker never keeps showing stale state.
            await loadModels(sessionId: selectedSessionId)
            errorBanner = "Could not switch models: \(error)"
            return false
        }
    }

    func chooseReasoningEffort(_ effort: String) async {
        guard let models = sessionModels,
              let model = currentModel else { return }
        await chooseModel(provider: models.current.provider, model: model, effort: effort)
    }

    func chooseHarnessConfig(_ option: HarnessConfigOption, value: JSONValue) async {
        guard let sessionId = controlSessionId, !isChangingHarnessConfig else { return }
        isChangingHarnessConfig = true
        defer { isChangingHarnessConfig = false }
        do {
            let options = try await api.setHarnessConfig(sessionId: sessionId, configId: option.id, value: value)
            if let catalog = sessionModels {
                sessionModels = SessionModels(
                    current: catalog.current,
                    routable: catalog.routable,
                    groups: catalog.groups,
                    failures: catalog.failures,
                    account: catalog.account,
                    harnessOptions: options
                )
            }
            // ACP configuration is interdependent: changing mode or a custom
            // toggle may replace model/reasoning choices as well.
            await loadModels(sessionId: sessionId)
            errorBanner = nil
        } catch {
            await loadModels(sessionId: sessionId)
            errorBanner = "Could not change \(option.name): \(error)"
        }
    }

    func retryCurrentModels() async {
        guard let sessionId = controlSessionId else {
            if selectedSessionId == nil { beginNewTask(in: selectedWorkspaceId) }
            return
        }
        if selectedSessionId == nil,
           draftSessionId == sessionId,
           !sessions.contains(where: { $0.sessionId == sessionId }) {
            _ = await resumePreparedDraftIfPossible()
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

    func chooseHarness(
        _ harness: HarnessCatalogEntry,
        acceptUnverified: Bool = false,
        acceptDriverBundle: Bool = false,
        force: Bool = false
    ) {
        let samePinnedIdentity = harness.id == currentHarnessId
            && harness.auth.selectedMethod == currentHarnessAuthMethod
        guard canChooseHarness, force || !samePinnedIdentity else { return }
        Task {
            await chooseHarnessForDraft(
                harness,
                acceptUnverified: acceptUnverified,
                acceptDriverBundle: acceptDriverBundle
            )
        }
    }

    private func chooseHarnessForDraft(
        _ harness: HarnessCatalogEntry,
        acceptUnverified: Bool,
        acceptDriverBundle: Bool
    ) async {
        guard harnessOperationId == nil else { return }
        harnessOperationId = harness.id
        harnessOperationPhase = "Checking \(harness.name) and its Driver…"
        defer {
            harnessOperationId = nil
            harnessOperationPhase = nil
            harnessOperationCancellation = nil
        }
        do {
            let current = try await prepareHarnessDriverIfNeeded(
                harness,
                acceptCodeExecution: acceptDriverBundle
            )
            guard current.available else {
                throw DshApiError.host(
                    "harness-unavailable",
                    current.unavailableReason ?? "This Harness is not available on this Mac."
                )
            }
            if current.installation.status != "builtin" && current.installation.status != "installed" {
                harnesses = try await runHarnessOperationStep(
                    "Installing exact \(harness.name) \(harness.version)…",
                    pollInstallationFor: harness.id
                ) {
                    try await self.api.mutateHarness(
                        action: "install", id: harness.id,
                        acceptUnverified: acceptUnverified ? true : nil
                    )
                }
            }
            var configured = harnesses.first(where: { $0.id == harness.id }) ?? current
            guard configured.auth.status == "not-required" || configured.auth.status == "configured" else {
                errorBanner = "Choose and complete a sign-in method for \(harness.name), then select it again."
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
            errorBanner = nil
        } catch {
            errorBanner = isOpenFishCancellation(error)
                ? nil : "Could not use \(harness.name) for this task: \(error)"
            harnesses = (try? await api.harnesses()) ?? harnesses
        }
    }

    func selectDefaultHarness(
        _ harness: HarnessCatalogEntry,
        completesOnboarding: Bool = false,
        acceptUnverified: Bool = false,
        acceptDriverBundle: Bool = false
    ) async {
        guard harnessOperationId == nil else { return }
        harnessOperationId = harness.id
        harnessOperationPhase = "Checking \(harness.name) and its Driver…"
        defer {
            harnessOperationId = nil
            harnessOperationPhase = nil
            harnessOperationCancellation = nil
        }
        do {
            let current = try await prepareHarnessDriverIfNeeded(
                harness,
                acceptCodeExecution: acceptDriverBundle
            )
            guard current.available else {
                throw DshApiError.host(
                    "harness-unavailable",
                    current.unavailableReason ?? "This Harness is not available on this Mac."
                )
            }
            if current.installation.status != "builtin" && current.installation.status != "installed" {
                harnesses = try await runHarnessOperationStep(
                    "Installing exact \(harness.name) \(harness.version)…",
                    pollInstallationFor: harness.id
                ) {
                    try await self.api.mutateHarness(
                        action: "install", id: harness.id,
                        acceptUnverified: acceptUnverified ? true : nil
                    )
                }
            }
            var configured = harnesses.first(where: { $0.id == harness.id }) ?? current
            guard configured.auth.status == "not-required" || configured.auth.status == "configured" else {
                // Installation may have discovered authentication methods that
                // were absent from the Registry summary. Let the refreshed
                // onboarding card present them without treating discovery as
                // an installation failure.
                errorBanner = nil
                return
            }
            configured = try await livePreflightIfNeeded(configured)
            harnesses = try await runHarnessOperationStep(
                "Saving \(configured.name) as the default Harness…",
                cancellable: false
            ) {
                try await self.api.mutateHarness(action: "default", id: configured.id)
            }
            selectedHarnessId = harness.id
            UserDefaults.standard.set(harness.id, forKey: "OpenFish.defaultHarnessId")
            if completesOnboarding {
                needsHarnessOnboarding = false
            }
            if selectedSessionId == nil { beginNewTask(in: selectedWorkspaceId) }
            errorBanner = nil
        } catch {
            errorBanner = isOpenFishCancellation(error)
                ? nil : "Could not make \(harness.name) the default Harness: \(error)"
            harnesses = (try? await api.harnesses()) ?? harnesses
        }
    }

    func refreshHarnessCatalog() async {
        do {
            harnesses = try await api.refreshHarnesses()
            harnessCatalogError = nil
            if let sharedDefault = harnesses.first(where: { $0.isDefault && isRunnableDefault($0) }) {
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

    @discardableResult
    func mutateHarness(
        _ action: String,
        harness: HarnessCatalogEntry,
        authMethod: String? = nil,
        acceptUnverified: Bool = false,
        acceptDriverBundle: Bool = false
    ) async -> Bool {
        guard harnessOperationId == nil else { return false }
        harnessOperationId = harness.id
        harnessOperationPhase = "Checking \(harness.name) and its Driver…"
        defer {
            harnessOperationId = nil
            harnessOperationPhase = nil
            harnessOperationCancellation = nil
        }
        do {
            let operationHarness: HarnessCatalogEntry
            if action == "rollback", let previousVersion = harness.installation.previousVersions.first {
                operationHarness = try await api.resolveHarness(
                    id: harness.id,
                    version: previousVersion,
                    authMethod: harness.auth.selectedMethod
                )
            } else {
                operationHarness = harness
            }
            if ["install", "update", "rollback", "probe", "default", "auth"].contains(action) {
                let prepared = try await prepareHarnessDriverIfNeeded(
                    operationHarness,
                    acceptCodeExecution: acceptDriverBundle
                )
                let repairsAuthenticationDiscovery = action == "install"
                    && prepared.installation.status == "installed"
                    && prepared.auth.status == "unknown"
                    && prepared.driver.loaded
                    && prepared.driver.authorization != "required"
                    && prepared.unavailableReason == prepared.auth.detail
                guard prepared.available || repairsAuthenticationDiscovery else {
                    throw DshApiError.host(
                        "harness-unavailable",
                        prepared.unavailableReason ?? "This Harness is not available on this Mac."
                    )
                }
            }
            let phase: String
            switch action {
            case "install": phase = "Installing exact \(operationHarness.name) \(operationHarness.version)…"
            case "update": phase = "Updating \(operationHarness.name) to \(operationHarness.version)…"
            case "rollback": phase = "Restoring \(operationHarness.name) \(operationHarness.version)…"
            case "probe": phase = "Checking \(operationHarness.name) against its live protocol…"
            case "default": phase = "Saving \(operationHarness.name) as the default Harness…"
            case "auth", "login": phase = "Confirming \(operationHarness.name) authentication…"
            case "uninstall": phase = "Removing the installed \(operationHarness.name) runtime…"
            case "remove": phase = "Removing the local \(operationHarness.name) Pack…"
            default: phase = "Applying \(action) to \(operationHarness.name)…"
            }
            harnesses = try await runHarnessOperationStep(
                phase,
                pollInstallationFor: ["install", "update"].contains(action) ? harness.id : nil,
                cancellable: ["install", "update", "probe"].contains(action)
            ) {
                try await self.api.mutateHarness(
                    action: action, id: harness.id, authMethod: authMethod,
                    acceptUnverified: acceptUnverified ? true : nil
                )
            }
            errorBanner = nil
            return true
        } catch {
            errorBanner = isOpenFishCancellation(error)
                ? nil : "Could not \(action) \(harness.name): \(error)"
            harnesses = (try? await api.harnesses()) ?? harnesses
            return false
        }
    }

    /// Resolve the exact retained Pack that a rollback would activate so the
    /// consent sheet can name its real Driver source instead of the newer
    /// catalog row.
    func rollbackHarnessCandidate(_ harness: HarnessCatalogEntry) async -> HarnessCatalogEntry? {
        guard let version = harness.installation.previousVersions.first else { return nil }
        do {
            return try await api.resolveHarness(
                id: harness.id,
                version: version,
                authMethod: harness.auth.selectedMethod
            )
        } catch {
            errorBanner = "Could not inspect the rollback target for \(harness.name): \(error)"
            return nil
        }
    }

    /// Reactivate the exact Driver source pinned by an existing task. This is
    /// deliberately explicit because one protocol Driver is active per Host;
    /// restoring an older task may replace the source used by newer tasks.
    @discardableResult
    func activatePinnedHarness(
        _ harness: HarnessCatalogEntry,
        acceptDriverBundle: Bool
    ) async -> Bool {
        guard harnessOperationId == nil else { return false }
        harnessOperationId = harness.id
        harnessOperationPhase = "Checking \(harness.name) and its Driver…"
        defer {
            harnessOperationId = nil
            harnessOperationPhase = nil
            harnessOperationCancellation = nil
        }
        do {
            let prepared = try await prepareHarnessDriverIfNeeded(
                harness,
                acceptCodeExecution: acceptDriverBundle
            )
            guard prepared.available else {
                throw DshApiError.host(
                    "harness-unavailable",
                    prepared.unavailableReason ?? "This exact Harness setup is unavailable."
                )
            }
            if let sessionId = controlSessionId {
                harnessesBySession[sessionId] = prepared
            }
            objectWillChange.send()
            errorBanner = nil
            return true
        } catch {
            errorBanner = "Could not restore \(harness.name) \(harness.version): \(error)"
            return false
        }
    }

    @discardableResult
    func submitHarnessPublication(_ harness: HarnessCatalogEntry, githubToken: String?) async -> Bool {
        guard harnessOperationId == nil else { return false }
        harnessOperationId = harness.id
        defer { harnessOperationId = nil }
        do {
            if let githubToken, !githubToken.isEmpty {
                try await api.setCredential(ref: "OPENFISH_GITHUB_TOKEN", value: githubToken)
            }
            harnesses = try await api.mutateHarness(action: "submit-publication", id: harness.id)
            errorBanner = nil
            return true
        } catch {
            errorBanner = "Could not submit \(harness.name) for community review: \(error)"
            harnesses = (try? await api.harnesses()) ?? harnesses
            return false
        }
    }

    @discardableResult
    func submitHarnessRevocation(_ harness: HarnessCatalogEntry, reason: String, githubToken: String?) async -> Bool {
        guard harnessOperationId == nil else { return false }
        harnessOperationId = harness.id
        defer { harnessOperationId = nil }
        do {
            if let githubToken, !githubToken.isEmpty {
                try await api.setCredential(ref: "OPENFISH_GITHUB_TOKEN", value: githubToken)
            }
            harnesses = try await api.mutateHarness(action: "submit-revocation", id: harness.id, reason: reason)
            errorBanner = nil
            return true
        } catch {
            errorBanner = "Could not request revocation of \(harness.name) \(harness.version): \(error)"
            harnesses = (try? await api.harnesses()) ?? harnesses
            return false
        }
    }

    func forgetHarnessPublicationAuthorization() async {
        do {
            try await api.unsetCredential(ref: "OPENFISH_GITHUB_TOKEN")
            errorBanner = nil
        } catch {
            errorBanner = "Could not forget the saved GitHub authorization: \(error)"
        }
    }

    @discardableResult
    func configureHarness(
        _ harness: HarnessCatalogEntry,
        method: HarnessCatalogEntry.Authentication.Method,
        credentials: [String: String] = [:],
        makeDefault: Bool = false,
        completesOnboarding: Bool = false,
        acceptUnverified: Bool = false,
        acceptDriverBundle: Bool = false
    ) async -> Bool {
        guard harnessOperationId == nil else { return false }
        harnessOperationId = harness.id
        harnessOperationPhase = "Checking \(harness.name) and its Driver…"
        defer {
            harnessOperationId = nil
            harnessOperationPhase = nil
            harnessOperationCancellation = nil
        }
        do {
            let current = try await prepareHarnessDriverIfNeeded(
                harness,
                acceptCodeExecution: acceptDriverBundle
            )
            let repairsAuthenticationDiscovery = current.installation.status == "installed"
                && current.auth.status == "unknown"
                && current.driver.loaded
                && current.driver.authorization != "required"
                && current.unavailableReason == current.auth.detail
            guard current.available || repairsAuthenticationDiscovery else {
                throw DshApiError.host(
                    "harness-unavailable",
                    current.unavailableReason ?? "This Harness is not available on this Mac."
                )
            }
            if current.installation.status != "builtin"
                && (current.installation.status != "installed" || repairsAuthenticationDiscovery) {
                harnesses = try await runHarnessOperationStep(
                    "Installing exact \(harness.name) \(harness.version)…",
                    pollInstallationFor: harness.id
                ) {
                    try await self.api.mutateHarness(
                        action: "install", id: harness.id,
                        acceptUnverified: acceptUnverified ? true : nil
                    )
                }
            }
            harnessOperationPhase = "Saving \(method.name) credentials in the Host credential store…"
            for field in method.fields {
                if let value = credentials[field.ref], !value.isEmpty {
                    try await api.setCredential(ref: field.ref, value: value)
                } else if field.required {
                    throw DshApiError.host("credential-required", "\(field.name) is required.")
                }
            }
            let authAction = method.kind == "terminal" ? "login" : "auth"
            harnessOperationPhase = method.kind == "terminal"
                ? "Complete \(method.name) in the OpenFish-managed Terminal window…"
                : "Confirming \(method.name)…"
            if method.kind == "terminal" {
                // The Host owns the managed Terminal process. The client must
                // not advertise cancellation after that external UI has been
                // handed off because killing the request would not prove the
                // login process itself stopped.
                harnesses = try await api.mutateHarness(
                    action: authAction, id: harness.id, authMethod: method.id
                )
            } else {
                harnesses = try await runHarnessOperationStep(
                    "Confirming \(method.name)…",
                    cancellable: false
                ) {
                    try await self.api.mutateHarness(
                        action: authAction, id: harness.id, authMethod: method.id
                    )
                }
            }
            guard var configured = harnesses.first(where: { $0.id == harness.id }), configured.auth.status == "configured" else {
                throw DshApiError.host("credential-unavailable", "The Host could not resolve all required credentials for \(harness.name).")
            }
            configured = try await livePreflightIfNeeded(configured)
            if makeDefault {
                harnesses = try await runHarnessOperationStep(
                    "Saving \(configured.name) as the default Harness…",
                    cancellable: false
                ) {
                    try await self.api.mutateHarness(action: "default", id: configured.id)
                }
                selectedHarnessId = harness.id
                UserDefaults.standard.set(harness.id, forKey: "OpenFish.defaultHarnessId")
                if completesOnboarding { needsHarnessOnboarding = false }
                if selectedSessionId == nil { beginNewTask(in: selectedWorkspaceId) }
            }
            errorBanner = nil
            return true
        } catch {
            errorBanner = isOpenFishCancellation(error)
                ? nil : "Could not configure \(harness.name): \(error)"
            harnesses = (try? await api.harnesses()) ?? harnesses
            return false
        }
    }

    /// Materialize a Pack-declared protocol Driver before asking the Host to
    /// install or run the Harness. The exact source is admitted by the bundled
    /// Driver manager; OpenFish never guesses a package from a protocol name.
    private func prepareHarnessDriverIfNeeded(
        _ harness: HarnessCatalogEntry,
        acceptCodeExecution: Bool
    ) async throws -> HarnessCatalogEntry {
        let current = harnesses.first(where: { $0.id == harness.id && $0.version == harness.version }) ?? harness
        guard let bundle = current.driverBundle else { return current }
        guard OpenFishDriverManager.isAvailable else {
            throw DshApiError.host(
                "driver-manager-unavailable",
                "The packaged OpenFish Driver manager is missing. Reinstall the Mac app."
            )
        }

        let inventory = try await OpenFishDriverManager.list()
        let previous = inventory.bundles.first { $0.packageName == bundle.package && $0.active }
        let exactBundleIsActive = previous?.requested == bundle.spec
        if exactBundleIsActive && current.driver.loaded {
            let rows = try await api.authorizeHarnessDriver(
                id: current.id,
                version: current.version,
                package: bundle.package,
                spec: bundle.spec
            )
            harnesses = rows
            return try await api.resolveHarness(
                id: current.id,
                version: current.version,
                authMethod: current.auth.selectedMethod
            )
        }

        var changedBundle = false
        if !exactBundleIsActive {
            guard acceptCodeExecution else {
                throw DshApiError.host(
                    "driver-consent-required",
                    "Confirm the exact Driver Bundle \(bundle.spec) before OpenFish runs its code."
                )
            }
            _ = try await OpenFishDriverManager.install(
                spec: bundle.spec,
                expectedPackageName: bundle.package,
                allowScripts: bundle.requiresInstallScripts
            )
            changedBundle = true
        }

        if !OpenFishHostRuntime.restartManagedHost() {
            let recovery = changedBundle
                ? await restoreDriverBundle(packageName: bundle.package, previous: previous)
                : nil
            throw DshApiError.host(
                "driver-restart-required",
                "The Driver was admitted, but the active Host is not owned by this OpenFish app. Restart that Host, then retry."
                    + (recovery.map { " Automatic profile recovery also failed: \($0)" } ?? "")
            )
        }

        var lastError: Error?
        for _ in 0..<80 {
            if Task.isCancelled { throw CancellationError() }
            do {
                let rows = try await api.harnesses()
                harnesses = rows
                if let prepared = rows.first(where: { $0.id == harness.id }), prepared.driver.loaded {
                    let authorized = try await api.authorizeHarnessDriver(
                        id: current.id,
                        version: current.version,
                        package: bundle.package,
                        spec: bundle.spec
                    )
                    harnesses = authorized
                    return try await api.resolveHarness(
                        id: current.id,
                        version: current.version,
                        authMethod: current.auth.selectedMethod
                    )
                }
            } catch {
                lastError = error
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        let detail = lastError.map { String(describing: $0) }
            ?? "The restarted Host did not register protocol \(bundle.package)."
        let recovery = changedBundle
            ? await restoreDriverBundle(packageName: bundle.package, previous: previous)
            : nil
        throw DshApiError.host(
            "driver-not-loaded",
            detail + (recovery.map { " Automatic profile recovery also failed: \($0)" }
                ?? (changedBundle ? " The previous Driver profile was restored." : ""))
        )
    }

    /// Undo a failed Driver activation before returning control to the user.
    /// Reinstalling the previous exact source or removing a first install keeps
    /// the Profile from pointing at code that never registered successfully.
    private func restoreDriverBundle(
        packageName: String,
        previous: OpenFishDriverBundle?
    ) async -> String? {
        do {
            if let previous {
                guard let installScriptsAllowed = previous.installScriptsAllowed else {
                    return "the older Driver predates script-consent tracking; reinstall its exact source manually"
                }
                _ = try await OpenFishDriverManager.install(
                    spec: previous.requested,
                    expectedPackageName: packageName,
                    allowScripts: installScriptsAllowed
                )
            } else {
                _ = try await OpenFishDriverManager.remove(packageName: packageName)
            }
            guard OpenFishHostRuntime.restartManagedHost() else {
                return "the verified embedded Host could not be restarted"
            }
            return nil
        } catch {
            return String(describing: error)
        }
    }

    func saveCustomHarness(
        id: String, name: String, version: String, description: String, publisher: String,
        license: String, repository: String, protocolName: String,
        driverPackage: String, driverSpec: String, driverRequiresInstallScripts: Bool,
        distributionKind: String, packageOrCommand: String, arguments: [String],
        distributionEnvironment: String,
        binaryCommand: String, sha256: String, graphLevel: String,
        graphBoundary: String, graphEvidenceSource: String,
        authMethodId: String, authMethodName: String, authKind: String,
        authFieldRef: String, authFieldName: String, authFieldEnv: String,
        authAccountLabel: String, authBilling: String, authAccountDetail: String,
        discoverAuthenticationAtRuntime: Bool,
        agentAuthMetaKey: String, agentAuthFieldProperty: String,
        modelOwner: String, modelConfigurationRequired: Bool, modelConfigurationDetail: String,
        terminalAuthArguments: String, terminalAuthEnvironment: String,
        nodes: [HarnessGraphNode], edges: [HarnessGraphEdge], positions: [String: CGPoint],
        existingPack: HarnessCatalogEntry? = nil
    ) async -> Bool {
        func environment(_ source: String) -> [String: JSONValue] {
            source.split(whereSeparator: \.isNewline).reduce(into: [:]) { result, line in
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, !parts[0].isEmpty else { return }
                result[parts[0]] = .string(parts[1])
            }
        }
        func encodedAuthMethod(_ method: HarnessCatalogEntry.Authentication.Method) -> JSONValue {
            var value: [String: JSONValue] = [
                "id": .string(method.id), "name": .string(method.name), "kind": .string(method.kind),
                "fields": .array(method.fields.map { field in
                    var item: [String: JSONValue] = [
                        "ref": .string(field.ref), "name": .string(field.name),
                        "required": .bool(field.required), "secret": .bool(field.secret),
                    ]
                    if let env = field.env { item["env"] = .string(env) }
                    if let placeholder = field.placeholder { item["placeholder"] = .string(placeholder) }
                    return .object(item)
                }),
            ]
            if let account = method.account {
                value["account"] = .object([
                    "label": .string(account.label), "billing": .string(account.billing),
                    "detail": .string(account.detail),
                ])
            }
            if let agent = method.agent {
                value["agent"] = .object([
                    "metaKey": .string(agent.metaKey),
                    "fieldMap": .object(agent.fieldMap.mapValues(JSONValue.string)),
                ])
            }
            if let terminal = method.terminal {
                value["terminal"] = .object([
                    "args": .array(terminal.args.map(JSONValue.string)),
                    "env": .object(terminal.env.mapValues(JSONValue.string)),
                ])
            }
            return .object(value)
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
            // v0 pre-alpha Packs stored editor layout in executable config.
            // Migrate it out so Drivers see only fields they own.
            config.removeValue(forKey: "x")
            config.removeValue(forKey: "y")
            var value: [String: JSONValue] = [
                "id": .string(node.id), "kind": .string(node.kind), "title": .string(node.title), "editable": .bool(node.editable),
                "position": .object(["x": .number(position.x), "y": .number(position.y)]),
            ]
            if !config.isEmpty { value["config"] = .object(config) }
            if let responsibility = node.responsibility, !responsibility.isEmpty { value["responsibility"] = .string(responsibility) }
            if let inputs = node.inputs { value["inputs"] = .array(inputs.map(JSONValue.string)) }
            if let outputs = node.outputs { value["outputs"] = .array(outputs.map(JSONValue.string)) }
            if let ports = node.ports {
                value["ports"] = .array(ports.map { port in
                    var item: [String: JSONValue] = [
                        "id": .string(port.id), "name": .string(port.name),
                        "direction": .string(port.direction), "dataType": .string(port.dataType),
                    ]
                    if let required = port.required { item["required"] = .bool(required) }
                    return .object(item)
                })
            }
            if let observes = node.observes { value["observes"] = .array(observes.map(JSONValue.string)) }
            if let schema = node.configSchema {
                value["configSchema"] = .object([
                    "version": .number(Double(schema.version)),
                    "fields": .array(schema.fields.map { field in
                        var item: [String: JSONValue] = [
                            "id": .string(field.id), "name": .string(field.name), "type": .string(field.type),
                            "required": .bool(field.required),
                            "binding": .object(["kind": .string(field.binding.kind), "target": .string(field.binding.target)]),
                        ]
                        if let description = field.description { item["description"] = .string(description) }
                        if let choices = field.choices {
                            item["choices"] = .array(choices.map { choice in
                                var choiceValue: [String: JSONValue] = ["id": .string(choice.id), "name": .string(choice.name)]
                                if let description = choice.description { choiceValue["description"] = .string(description) }
                                return .object(choiceValue)
                            })
                        }
                        return .object(item)
                    }),
                ])
            }
            let evidence = graphLevel == "opaque"
                ? (node.evidence ?? [])
                : [HarnessGraphEvidence(kind: "declared", source: graphEvidenceSource, version: version)]
            if !evidence.isEmpty {
                value["evidence"] = .array(evidence.map { item in
                    var evidenceValue: [String: JSONValue] = ["kind": .string(item.kind), "source": .string(item.source)]
                    if let version = item.version { evidenceValue["version"] = .string(version) }
                    return .object(evidenceValue)
                })
            }
            return .object(value)
        }
        let graphEdges: [JSONValue] = edges.map { edge in
            var value: [String: JSONValue] = ["from": .string(edge.from), "to": .string(edge.to)]
            if let fromPort = edge.fromPort { value["fromPort"] = .string(fromPort) }
            if let toPort = edge.toPort { value["toPort"] = .string(toPort) }
            if let label = edge.label, !label.isEmpty { value["label"] = .string(label) }
            if let observes = edge.observes { value["observes"] = .array(observes.map(JSONValue.string)) }
            return .object(value)
        }
        var graphObject: [String: JSONValue] = [
            "level": .string(graphLevel), "manifestVersion": .number(1), "nodes": .array(graphNodes), "edges": .array(graphEdges),
        ]
        if graphLevel != "opaque" {
            graphObject["boundary"] = .string(graphBoundary)
            graphObject["evidence"] = .array([.object([
                "kind": .string("declared"), "source": .string(graphEvidenceSource), "version": .string(version),
            ])])
        }
        var packObject: [String: JSONValue] = [
            "schemaVersion": .number(0), "id": .string(id), "name": .string(name), "version": .string(version),
            "publisher": .string(publisher.isEmpty ? "OpenFish user" : publisher), "protocol": .string(protocolName), "distribution": distribution,
            "graph": .object(graphObject),
        ]
        if !description.isEmpty { packObject["description"] = .string(description) }
        if !license.isEmpty { packObject["license"] = .string(license) }
        if !repository.isEmpty { packObject["repository"] = .string(repository) }
        if let icon = existingPack?.icon { packObject["icon"] = .string(icon) }
        packObject["authenticationDiscovery"] = .object([
            "source": .string(discoverAuthenticationAtRuntime ? "runtime" : "pack"),
            "detail": .string(discoverAuthenticationAtRuntime
                ? "The installed Driver discovers the actual sign-in methods before this Harness can be selected."
                : "This Pack declares the complete sign-in contract; an empty method list means no sign-in is required."),
        ])
        if !driverPackage.isEmpty || !driverSpec.isEmpty {
            packObject["driverBundle"] = .object([
                "apiVersion": .number(1), "package": .string(driverPackage), "spec": .string(driverSpec),
                "requiresInstallScripts": .bool(driverRequiresInstallScripts),
            ])
        }
        if !authAccountLabel.isEmpty, !authAccountDetail.isEmpty {
            packObject["account"] = .object([
                "label": .string(authAccountLabel), "billing": .string(authBilling),
                "detail": .string(authAccountDetail),
            ])
        }
        if !modelConfigurationDetail.isEmpty {
            packObject["modelConfiguration"] = .object([
                "owner": .string(modelOwner), "required": .bool(modelConfigurationRequired),
                "detail": .string(modelConfigurationDetail),
            ])
        }
        if !authMethodId.isEmpty {
            let existingPrimary = existingPack?.auth.methods.first
            let editsExistingPrimary = existingPrimary?.id == authMethodId && existingPrimary?.kind == authKind
            var fields: [JSONValue] = editsExistingPrimary
                ? (existingPrimary?.fields.map { field in
                    var item: [String: JSONValue] = [
                        "ref": .string(field.ref), "name": .string(field.name),
                        "required": .bool(field.required), "secret": .bool(field.secret),
                    ]
                    if let env = field.env { item["env"] = .string(env) }
                    if let placeholder = field.placeholder { item["placeholder"] = .string(placeholder) }
                    return .object(item)
                } ?? [])
                : []
            if ["environment", "agent"].contains(authKind) {
                // The visual form edits the first credential while preserving
                // every additional credential declared by an imported Pack.
                // Remove the old first field before inserting its edited form;
                // otherwise changing a reference silently creates a second
                // credential and leaves stale ACP field-map entries behind.
                if editsExistingPrimary, let priorRef = existingPrimary?.fields.first?.ref {
                    fields.removeAll { $0["ref"]?.stringValue == priorRef }
                }
                fields.removeAll { $0["ref"]?.stringValue == authFieldRef }
            }
            if ["environment", "agent"].contains(authKind), !authFieldRef.isEmpty {
                var field: [String: JSONValue] = [
                    "ref": .string(authFieldRef), "name": .string(authFieldName.isEmpty ? authFieldRef : authFieldName),
                    "required": .bool(true), "secret": .bool(true),
                ]
                if authKind == "environment" {
                    field["env"] = .string(authFieldEnv.isEmpty ? authFieldRef : authFieldEnv)
                }
                fields.insert(.object(field), at: 0)
            }
            var auth: [String: JSONValue] = [
                "id": .string(authMethodId), "name": .string(authMethodName.isEmpty ? authMethodId : authMethodName),
                "kind": .string(authKind), "fields": .array(fields),
            ]
            if !authAccountLabel.isEmpty, !authAccountDetail.isEmpty {
                auth["account"] = .object([
                    "label": .string(authAccountLabel), "billing": .string(authBilling),
                    "detail": .string(authAccountDetail),
                ])
            }
            if authKind == "agent", !agentAuthMetaKey.isEmpty, !agentAuthFieldProperty.isEmpty, !authFieldRef.isEmpty {
                var fieldMap = editsExistingPrimary
                    ? (existingPrimary?.agent?.fieldMap ?? [:]) : [:]
                if let priorRef = existingPrimary?.fields.first?.ref, priorRef != authFieldRef {
                    fieldMap.removeValue(forKey: priorRef)
                }
                fieldMap[authFieldRef] = agentAuthFieldProperty
                auth["agent"] = .object([
                    "metaKey": .string(agentAuthMetaKey),
                    "fieldMap": .object(fieldMap.mapValues(JSONValue.string)),
                ])
            }
            if authKind == "terminal" {
                let loginArgs = terminalAuthArguments.split(whereSeparator: \.isNewline).map { JSONValue.string(String($0)) }
                auth["terminal"] = .object([
                    "args": .array(loginArgs), "env": .object(environment(terminalAuthEnvironment)),
                ])
            }
            let additionalMethods = existingPack?.auth.methods.dropFirst().map(encodedAuthMethod) ?? []
            packObject["authMethods"] = .array([.object(auth)] + additionalMethods)
        } else if let existingMethods = existingPack?.auth.methods, !existingMethods.isEmpty {
            // An empty optional form must never erase authentication methods
            // that the compact editor cannot display. Imported advanced Packs
            // round-trip losslessly; deletion requires an explicit manifest
            // import instead of an accidental empty text field.
            packObject["authMethods"] = .array(existingMethods.map(encodedAuthMethod))
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

    func exportHarness(_ harness: HarnessCatalogEntry, to url: URL, forPublication: Bool = false) async -> Bool {
        guard let distribution = harness.distribution else {
            errorBanner = "\(harness.name) does not expose a portable distribution to export."
            return false
        }
        if forPublication && harness.source != "user" {
            errorBanner = "Only a local user-authored Pack can be submitted for community publication."
            return false
        }
        if forPublication && !harness.driver.loaded {
            errorBanner = "Load a \(harness.protocolName) Driver before preparing this Pack for publication."
            return false
        }
        if forPublication && (harness.installation.status != "installed"
            || harness.installation.installedVersion != harness.version) {
            errorBanner = "Install this exact Pack version before preparing a community submission."
            return false
        }
        if forPublication && harness.compatibility.status != "ready"
            && harness.compatibility.status != "compatible" {
            errorBanner = "Run the prompt-free live preflight successfully before preparing a community submission. The provider may still create session state or charge a setup cost."
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

        var graphObject: [String: JSONValue] = [
            "level": .string(harness.graph.level),
            "nodes": .array(harness.graph.nodes.map { node in
                var value: [String: JSONValue] = [
                    "id": .string(node.id), "kind": .string(node.kind), "title": .string(node.title), "editable": .bool(node.editable),
                ]
                if let position = node.position {
                    value["position"] = .object(["x": .number(position.x), "y": .number(position.y)])
                }
                if let responsibility = node.responsibility { value["responsibility"] = .string(responsibility) }
                if let inputs = node.inputs { value["inputs"] = .array(inputs.map(JSONValue.string)) }
                if let outputs = node.outputs { value["outputs"] = .array(outputs.map(JSONValue.string)) }
                if let ports = node.ports {
                    value["ports"] = .array(ports.map { port in
                        var item: [String: JSONValue] = [
                            "id": .string(port.id), "name": .string(port.name),
                            "direction": .string(port.direction), "dataType": .string(port.dataType),
                        ]
                        if let required = port.required { item["required"] = .bool(required) }
                        return .object(item)
                    })
                }
                if let observes = node.observes { value["observes"] = .array(observes.map(JSONValue.string)) }
                if let schema = node.configSchema {
                    value["configSchema"] = .object([
                        "version": .number(Double(schema.version)),
                        "fields": .array(schema.fields.map { field in
                            var item: [String: JSONValue] = [
                                "id": .string(field.id), "name": .string(field.name), "type": .string(field.type),
                                "required": .bool(field.required),
                                "binding": .object(["kind": .string(field.binding.kind), "target": .string(field.binding.target)]),
                            ]
                            if let description = field.description { item["description"] = .string(description) }
                            if let choices = field.choices {
                                item["choices"] = .array(choices.map { choice in
                                    var choiceValue: [String: JSONValue] = ["id": .string(choice.id), "name": .string(choice.name)]
                                    if let description = choice.description { choiceValue["description"] = .string(description) }
                                    return .object(choiceValue)
                                })
                            }
                            return .object(item)
                        }),
                    ])
                }
                if let evidence = node.evidence {
                    value["evidence"] = .array(evidence.map { item in
                        var evidenceValue: [String: JSONValue] = ["kind": .string(item.kind), "source": .string(item.source)]
                        if let version = item.version { evidenceValue["version"] = .string(version) }
                        return .object(evidenceValue)
                    })
                }
                if let config = node.config { value["config"] = .object(config) }
                return .object(value)
            }),
            "edges": .array(harness.graph.edges.map { edge in
                var value: [String: JSONValue] = ["from": .string(edge.from), "to": .string(edge.to)]
                if let fromPort = edge.fromPort { value["fromPort"] = .string(fromPort) }
                if let toPort = edge.toPort { value["toPort"] = .string(toPort) }
                if let label = edge.label { value["label"] = .string(label) }
                if let observes = edge.observes { value["observes"] = .array(observes.map(JSONValue.string)) }
                return .object(value)
            }),
        ]
        if let manifestVersion = harness.graph.manifestVersion { graphObject["manifestVersion"] = .number(Double(manifestVersion)) }
        if let boundary = harness.graph.boundary { graphObject["boundary"] = .string(boundary) }
        if let evidence = harness.graph.evidence {
            graphObject["evidence"] = .array(evidence.map { item in
                var evidenceValue: [String: JSONValue] = ["kind": .string(item.kind), "source": .string(item.source)]
                if let version = item.version { evidenceValue["version"] = .string(version) }
                return .object(evidenceValue)
            })
        }

        var pack: [String: JSONValue] = [
            "$schema": .string("https://raw.githubusercontent.com/Yusong-Enceladus/OpenFish/main/packages/harness/harness/schema/harness-pack-v0.schema.json"),
            "schemaVersion": .number(0), "id": .string(harness.id), "name": .string(harness.name),
            "version": .string(harness.version), "publisher": .string(harness.publisher),
            "verified": .bool(false), "protocol": .string(harness.protocolName),
            "source": .string(forPublication ? "openfish-community" : "user"),
            "distribution": .object(distributionObject),
            "graph": .object(graphObject),
        ]
        if let description = harness.description { pack["description"] = .string(description) }
        if let license = harness.license { pack["license"] = .string(license) }
        if let repository = harness.repository { pack["repository"] = .string(repository) }
        if let account = harness.account {
            pack["account"] = .object([
                "label": .string(account.label), "billing": .string(account.billing),
                "detail": .string(account.detail),
            ])
        }
        if let modelConfiguration = harness.modelConfiguration {
            pack["modelConfiguration"] = .object([
                "owner": .string(modelConfiguration.owner), "required": .bool(modelConfiguration.required),
                "detail": .string(modelConfiguration.detail),
            ])
        }
        if let driverBundle = harness.driverBundle {
            pack["driverBundle"] = .object([
                "apiVersion": .number(Double(driverBundle.apiVersion)),
                "package": .string(driverBundle.package), "spec": .string(driverBundle.spec),
                "requiresInstallScripts": .bool(driverBundle.requiresInstallScripts),
            ])
        }
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
                if let agent = method.agent {
                    value["agent"] = .object([
                        "metaKey": .string(agent.metaKey),
                        "fieldMap": .object(agent.fieldMap.mapValues(JSONValue.string)),
                    ])
                }
                if let account = method.account {
                    value["account"] = .object([
                        "label": .string(account.label), "billing": .string(account.billing),
                        "detail": .string(account.detail),
                    ])
                }
                return .object(value)
            })
        }
        do {
            if forPublication {
                _ = try await api.mutateHarness(action: "validate-publication", pack: .object(pack))
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(JSONValue.object(pack)).write(to: url, options: .atomic)
            if forPublication {
                #if arch(arm64)
                let architecture = "arm64"
                #elseif arch(x86_64)
                let architecture = "x86_64"
                #else
                let architecture = "unknown"
                #endif
                let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
                let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
                let capabilityRows = harness.capabilities.map { capability in
                    JSONValue.object([
                        "id": .string(capability.id), "status": .string(capability.status),
                        "source": .string(capability.source),
                        "detail": capability.detail.map(JSONValue.string) ?? .null,
                    ])
                }
                let report: JSONValue = .object([
                    "schemaVersion": .number(0),
                    "generatedAt": .string(ISO8601DateFormatter().string(from: Date())),
                    "openFish": .object(["version": .string(appVersion), "build": .string(appBuild)]),
                    "platform": .object([
                        "os": .string("macOS"),
                        "version": .string(ProcessInfo.processInfo.operatingSystemVersionString),
                        "architecture": .string(architecture),
                    ]),
                    "harness": .object([
                        "id": .string(harness.id), "version": .string(harness.version),
                        "protocol": .string(harness.protocolName), "publisher": .string(harness.publisher),
                    ]),
                    "driver": .object([
                        "apiVersion": .number(Double(harness.driver.apiVersion)),
                        "protocol": .string(harness.driver.`protocol`), "loaded": .bool(harness.driver.loaded),
                    ]),
                    "installationIntegrity": .object([
                        "status": .string(harness.installation.integrity.status),
                        "source": .string(harness.installation.integrity.source),
                        "detail": .string(harness.installation.integrity.detail),
                    ]),
                    "authenticationMethod": harness.auth.selectedMethod.map(JSONValue.string) ?? .null,
                    "workspaceModes": .array(harness.capabilities.compactMap { capability in
                        guard capability.status != "unsupported", ["workspace.project", "workspace.no-project"].contains(capability.id) else { return nil }
                        return JSONValue.string(capability.id)
                    }),
                    "compatibility": .object([
                        "status": .string(harness.compatibility.status),
                        "checkedAt": harness.compatibility.checkedAt.map(JSONValue.string) ?? .null,
                        "message": harness.compatibility.message.map(JSONValue.string) ?? .null,
                    ]),
                    "capabilities": .array(capabilityRows),
                    "privacy": .object([
                        "credentialValuesIncluded": .bool(false),
                        "hostIdentityIncluded": .bool(false),
                        "conversationContentIncluded": .bool(false),
                    ]),
                ])
                let reportURL = url.deletingLastPathComponent().appendingPathComponent("\(harness.id).compatibility.json")
                try encoder.encode(report).write(to: reportURL, options: .atomic)
                let instructions = """
                # OpenFish Harness submission: \(harness.id) \(harness.version)

                Generated locally by OpenFish after public-manifest and Driver conformance validation.

                1. Upload `\(url.lastPathComponent)` to `community/harnesses/packs/` in a fork of OpenFish.
                2. Include `\(reportURL.lastPathComponent)` in the pull request description or as an attachment after reviewing it.
                3. Run `pnpm run gen-openfish-community-catalog` and `pnpm run test:harness-contract`.
                4. Open a pull request. Catalog discovery begins only after repository review and merge.

                Community inclusion proves discoverability, not publisher trust or code safety.
                """
                let instructionsURL = url.deletingLastPathComponent().appendingPathComponent("\(harness.id).submission.md")
                try Data(instructions.utf8).write(to: instructionsURL, options: .atomic)
            }
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
        guard harnessCan("session.fork") else {
            errorBanner = "\(currentHarness?.name ?? "This Harness") does not expose a real session fork. Start a new task so its remote history is not misrepresented."
            return
        }
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
        guard canAttachImages else {
            errorBanner = "\(currentHarness?.name ?? "This Harness") does not advertise image input through its current Driver."
            return
        }
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
        if isDemoMode {
            pendingQuestions[question.rpcId] = nil
            return
        }
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
                bearerToken: connectionProfile.bearerToken,
                tlsFingerprint: connectionProfile.tlsFingerprint
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
                bearerToken: connectionProfile.bearerToken,
                tlsFingerprint: connectionProfile.tlsFingerprint
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
                bearerToken: connectionProfile.bearerToken,
                tlsFingerprint: connectionProfile.tlsFingerprint
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
            let byId = visible.reduce(into: [String: SessionSummary]()) { result, session in
                if let current = result[session.sessionId], current.updatedAt > session.updatedAt { return }
                result[session.sessionId] = session
            }
            members = workspace.sessionIds.compactMap { byId[$0] }.sorted(by: sessionRecency)
        } else {
            let accounted = Set(workspaces.flatMap(\.sessionIds))
            members = visible.filter {
                !accounted.contains($0.sessionId) && $0.workspaceMode == "no-project"
            }
                .sorted(by: sessionRecency)
        }

        return filterVisibleSessions(members)
    }

    var otherLocationSessions: [SessionSummary] {
        let accounted = Set(workspaces.flatMap(\.sessionIds))
        let members = sessions.filter {
            $0.origin != "subagent"
                && !$0.blank
                && !archivedSessionIds.contains($0.sessionId)
                && !accounted.contains($0.sessionId)
                && $0.workspaceMode != "no-project"
        }.sorted(by: sessionRecency)
        return filterVisibleSessions(members)
    }

    private func filterVisibleSessions(_ members: [SessionSummary]) -> [SessionSummary] {
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
        (orderedWorkspaces.flatMap { sessions(in: $0) } + sessions(in: nil) + otherLocationSessions)
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
        guard !isDemoMode else {
            errorBanner = "Microphone access is disabled in the network-isolated Demo State."
            return
        }
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
        guard canStartNewTask else { return }
        guard !isDemoMode else {
            errorBanner = "Microphone access is disabled in the network-isolated Demo State."
            return
        }
        guard activeSubagent == nil else {
            errorBanner = "Voice conversation is available on the parent task."
            return
        }
        guard sessionModels?.routable == true else {
            errorBanner = sessionModels == nil
                ? "OpenFish is still checking this Harness's model and account."
                : "Choose a configured model before starting voice conversation."
            isModelBrowserPresented = true
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
            self.voiceConversationStatus = isFinal ? "Sending to the selected Harness" : "Listening"
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
        let firstTurnHarnessId = draftHarnessId ?? selectedHarnessId
        var firstTurnSessionId: String?
        do {
            let sessionId: String
            if let selectedSessionId {
                sessionId = selectedSessionId
            } else if let draftSessionId {
                sessionId = draftSessionId
                firstTurnSessionId = sessionId
                self.draftSessionId = nil
                self.draftHarnessId = nil
                self.selectedSessionId = sessionId
                UserDefaults.standard.set(sessionId, forKey: "OpenCodex.lastSessionId")
            } else {
                let requestedSessionId = UUID().uuidString.lowercased()
                sessionId = try await api.createSession(
                    workspaceId: selectedWorkspaceId,
                    harnessId: draftHarnessId ?? selectedHarnessId,
                    sessionId: requestedSessionId
                )
                guard sessionId == requestedSessionId else {
                    throw DshApiError.host(
                        "session-identity-mismatch",
                        "The Host returned a different id for the voice task."
                    )
                }
                firstTurnSessionId = sessionId
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
            if let firstTurnSessionId {
                await reconcileFailedFirstTurn(
                    sessionId: firstTurnSessionId,
                    harnessId: firstTurnHarnessId
                )
            }
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
                bearerToken: connectionProfile.bearerToken,
                tlsFingerprint: connectionProfile.tlsFingerprint
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
                  composition.features.gateway,
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
                    "This OpenFish Host is missing the macOS or local-voice composition."
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
            hostIssue = nil
            errorBanner = nil
            agentPresets = try? await api.agentPresets()
            harnesses = (try? await api.harnesses()) ?? harnesses
            if let sharedDefault = harnesses.first(where: { $0.isDefault && isRunnableDefault($0) }) {
                selectedHarnessId = sharedDefault.id
                UserDefaults.standard.set(sharedDefault.id, forKey: "OpenFish.defaultHarnessId")
                needsHarnessOnboarding = false
            } else {
                selectedHarnessId = ""
                UserDefaults.standard.removeObject(forKey: "OpenFish.defaultHarnessId")
                // An empty catalog may be a recoverable discovery failure. The
                // onboarding surface owns refresh/retry and must stay visible.
                needsHarnessOnboarding = true
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
                } else if await resumePreparedDraftIfPossible() {
                    // The exact blank provider task survived the app restart.
                } else {
                    beginNewTask(in: selectedWorkspaceId)
                }
            } else if let selectedSessionId {
                async let history: Void = loadHistory(sessionId: selectedSessionId)
                async let models: Void = loadModels(sessionId: selectedSessionId)
                _ = await (history, models)
            } else if !(await resumePreparedDraftIfPossible()) {
                beginNewTask(in: selectedWorkspaceId)
            }
        } catch {
            guard !Task.isCancelled else { return }
            nativeCapabilities = nil
            finishBaselineSynchronization()
            let incompatible: Bool
            let detail: String
            if case let DshApiError.host(code, message) = error {
                incompatible = code == "native-protocol-incompatible" || code == "native-capability-incompatible"
                detail = message
            } else {
                incompatible = false
                detail = String(describing: error)
            }
            hostIssue = OpenFishHostIssue(
                kind: incompatible ? .incompatible : .recoverable,
                title: incompatible ? "This Host is not compatible" : "OpenFish could not finish connecting",
                message: incompatible
                    ? detail
                    : "The Host at \(connectionProfile.baseURL.absoluteString) did not complete its baseline check. \(detail)"
            )
        }
    }

    private func refreshSessions() async {
        do {
            mergeSessionBaseline(try await api.sessions())
        } catch {
            errorBanner = "Could not refresh tasks: \(error)"
        }
    }

    /// Reconcile a cached, client-owned draft against the authoritative Host.
    /// If the create response was lost, retrying the preallocated id is
    /// idempotent. If the first prompt committed before the cache did, promote
    /// it to a normal selected task instead of hiding active work.
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
                    throw DshApiError.host(
                        "session-identity-mismatch",
                        "The Host returned a different id while recovering the prepared task."
                    )
                }
                mergeSessionBaseline(try await api.sessions())
                summary = sessions.first(where: { $0.sessionId == draftSessionId })
            } catch {
                sessionModels = nil
                isLoadingSessionModels = false
                sessionModelsError = String(describing: error)
                errorBanner = "Could not recover the prepared task: \(error)"
                scheduleProjectionCache()
                // Keep the exact identity for an explicit retry or a later
                // reconnect; replacing it would recreate the orphan risk.
                return true
            }
        }

        guard let summary,
              summary.origin != "subagent",
              !archivedSessionIds.contains(summary.sessionId) else {
            self.draftSessionId = nil
            draftHarnessId = nil
            scheduleProjectionCache()
            return false
        }
        if !summary.blank {
            self.draftSessionId = nil
            draftHarnessId = nil
            await selectSession(summary.sessionId)
            return true
        }

        selectedWorkspaceId = workspaces.first(where: { $0.sessionIds.contains(summary.sessionId) })?.workspaceId
        draftHarnessId = summary.harnessId ?? harnessId
        sessionModels = nil
        sessionModelsError = nil
        isLoadingSessionModels = true
        async let history: Void = loadHistory(sessionId: summary.sessionId)
        async let models: Void = loadModels(sessionId: summary.sessionId)
        async let capabilities: Void = loadSessionCapabilities(sessionId: summary.sessionId)
        _ = await (history, models, capabilities)
        scheduleProjectionCache()
        return true
    }

    private func loadHistory(sessionId: String) async {
        do {
            let history = try await api.history(sessionId: sessionId)
            applyHistory(history, sessionId: sessionId)
            if await resolveHarnessSnapshot(sessionId: sessionId, history: history) {
                errorBanner = nil
            }
        } catch {
            guard !Task.isCancelled, !isOpenFishCancellation(error) else { return }
            errorBanner = "Could not load this task: \(error)"
        }
    }

    private func resolveHarnessSnapshot(sessionId: String, history: SessionHistory) async -> Bool {
        let selected = history.events.last(where: { $0.event.type == "harness/selected" })?.event.data
        let summary = sessions.first(where: { $0.sessionId == sessionId })
        let harnessId = selected?["harnessId"]?.stringValue ?? summary?.harnessId ?? "dsh"
        let version = selected?["version"]?.stringValue ?? summary?.harnessVersion
        let authMethod = selected?["authMethod"]?.stringValue ?? summary?.harnessAuthMethod
        do {
            let resolved = try await api.resolveHarness(id: harnessId, version: version, authMethod: authMethod)
            harnessesBySession[sessionId] = resolved
            objectWillChange.send()
            return true
        } catch {
            harnessesBySession[sessionId] = nil
            errorBanner = "This task is pinned to a Harness setup that is not available: \(error)"
            return false
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
        case .authorizationRevoked:
            let revokedHost = connectionProfile.baseURL
            connectionProfile = connectionProfile.forgetAuthorization()
            purgeHostProjection()
            projectionCacheTask?.cancel()
            await projectionCache.clear(matching: revokedHost)
            connectionState = .reconnecting(attempt: 0)
            hasBaseline = false
            isSynchronizingBaseline = false
            hostIssue = OpenFishHostIssue(
                kind: .recoverable,
                title: "This Mac was unpaired",
                message: "The Host rejected the saved device authorization. Create a new one-time code on the Host and pair this Mac again."
            )
            syncTask?.cancel()
            await connection.stop()
            connectionTask?.cancel()
            connectionTask = nil
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
        case let .feed(frame):
            guard !isSynchronizingBaseline else {
                bufferedFeeds.append(frame)
                return
            }
            handleFeed(frame)
        }
        scheduleProjectionCache()
    }

    private func finishBaselineSynchronization() {
        isSynchronizingBaseline = false
        let pending = bufferedFeeds
        bufferedFeeds.removeAll(keepingCapacity: true)
        for frame in pending { handleFeed(frame) }
        scheduleProjectionCache()
    }

    private func handleFeed(_ frame: JSONValue) {
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

    private func handleRemoteEvents(_ frame: JSONValue) {
        switch frame["type"]?.stringValue {
        case "ready":
            remoteEventClientId = frame["clientId"]?.stringValue
            pendingApprovals.removeAll(keepingCapacity: true)
            pendingQuestions.removeAll(keepingCapacity: true)
        case "emit":
            guard let event = frame["event"]?.stringValue else { return }
            let args = frame["args"]?.arrayValue ?? []
            switch event {
            case "api-session/added":
                guard let summaryValue = args.first,
                      let summary = try? summaryValue.decode(SessionSummary.self) else { return }
                if let index = sessions.firstIndex(where: { $0.sessionId == summary.sessionId }) {
                    sessions[index] = summary
                } else {
                    sessions.append(summary)
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
                updateIdleGuard()
                if wasRunning && !running && !NSApplication.shared.isActive {
                    let title = displayTitle(for: sessions[index])
                    Task { await notifications.post(title: title, body: "Task finished", sessionId: id) }
                }
            case "api-session/activity":
                guard args.count >= 2,
                      let id = args[0].stringValue,
                      let updatedAt = args[1].doubleValue,
                      let index = sessions.firstIndex(where: { $0.sessionId == id }) else { return }
                sessions[index].updatedAt = updatedAt
                sessions[index].blank = false
            case "api-session/error":
                guard args.count >= 2,
                      let id = args[0].stringValue,
                      let message = args[1].stringValue else { return }
                if id == selectedSessionId { errorBanner = message }
                if id == voiceConversationSessionId { voiceConversationStatus = "Task failed" }
            case "agent-preset/selected", "commands/change", "credentials/reference-updated",
                 "llm/adapters-updated", "settings/document-updated":
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
                pendingApprovals[eventId] = PendingApproval(
                    clientId: clientId,
                    rpcId: eventId,
                    sessionId: sessionId,
                    approvalId: eventId,
                    toolName: toolName,
                    callId: request["callId"]?.stringValue,
                    reason: request["reason"]?.stringValue
                )
                if sessionId == voiceConversationSessionId {
                    voiceConversationStatus = "Approval required"
                    voice.stopSpeaking()
                }
                if !NSApplication.shared.isActive {
                    Task { await notifications.post(title: "OpenFish needs approval", body: toolName, sessionId: sessionId) }
                }
            case "user-questions/request":
                let questions = (try? request["questions"]?.decode([QuestionItem].self)) ?? []
                pendingQuestions[eventId] = PendingQuestion(
                    clientId: clientId,
                    rpcId: eventId,
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
            default: break
            }
        case "cancel":
            guard let eventId = frame["eventId"]?.stringValue else { return }
            pendingApprovals[eventId] = nil
            pendingQuestions[eventId] = nil
        default: break
        }
    }

    private func refreshLiveCatalogs(after event: String) async {
        switch event {
        case "agent-preset/selected": agentPresets = try? await api.agentPresets()
        case "commands/change":
            if let sessionId = controlSessionId { commands = (try? await api.commandDirectory(sessionId: sessionId)) ?? [] }
        case "llm/adapters-updated": hostModels = (try? await api.hostModels()) ?? hostModels
        case "settings/document-updated": settingsCatalog = try? await api.settings()
        case "credentials/reference-updated": providers = (try? await api.configurableProviders()) ?? providers
        default: break
        }
    }

    private func handleWorkspaceFeed(_ frame: JSONValue) {
        switch frame["type"]?.stringValue {
        case "baseline":
            guard let value = frame["value"], let baseline = try? value.decode(WorkspaceList.self) else { return }
            workspaces = baseline.items
            archivedSessionIds = Set(baseline.archivedSessionIds)
        case "upsert":
            guard let value = frame["workspace"], let workspace = try? value.decode(WorkspaceView.self) else { return }
            upsert(workspace)
        case "remove":
            guard let id = frame["workspaceId"]?.stringValue else { return }
            workspaces.removeAll { $0.workspaceId == id }
            if selectedWorkspaceId == id { selectedWorkspaceId = nil }
        case "order":
            guard let ids = frame["workspaceIds"]?.arrayValue?.compactMap(\.stringValue) else { return }
            let byId = workspaces.reduce(into: [String: WorkspaceView]()) { $0[$1.workspaceId] = $1 }
            workspaces = ids.compactMap { byId[$0] }
        case "archived":
            archivedSessionIds = Set(frame["archivedSessionIds"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        default: break
        }
    }

    private func handleControlFeed(_ frame: JSONValue) {
        switch frame["type"]?.stringValue {
        case "baseline":
            guard let value = frame["value"] else { return }
            queuedItems = (value["queues"]?.objectValue ?? [:]).mapValues {
                $0.arrayValue?.compactMap(QueuedInboxItem.init(json:)) ?? []
            }
            backgroundJobs = (value["jobs"]?.objectValue ?? [:]).mapValues {
                $0.arrayValue?.compactMap(BackgroundJob.init(json:)) ?? []
            }
            for (sessionId, blockValue) in value["projections"]?.objectValue ?? [:] {
                if let block = try? blockValue.decode(SessionProjectionsBlock.self) {
                    seedProjections(sessionId: sessionId, block: block)
                }
            }
        case "queue":
            guard let sessionId = frame["sessionId"]?.stringValue else { return }
            queuedItems[sessionId] = frame["items"]?.arrayValue?.compactMap(QueuedInboxItem.init(json:)) ?? []
        case "jobs":
            guard let sessionId = frame["sessionId"]?.stringValue else { return }
            backgroundJobs[sessionId] = frame["jobs"]?.arrayValue?.compactMap(BackgroundJob.init(json:)) ?? []
        case "projection":
            guard let sessionId = frame["sessionId"]?.stringValue,
                  let key = frame["key"]?.stringValue,
                  let value = frame["value"],
                  let seq = frame["seq"]?.intValue else { return }
            applyProjection(sessionId: sessionId, key: key, value: value, seq: seq)
        default: break
        }
    }

    private func handleSessionFeed(_ frame: JSONValue, sessionId: String) {
        switch frame["type"]?.stringValue {
        case "snapshot":
            let incoming = frame["events"]?.arrayValue?.compactMap { entry -> SessionEventRecord? in
                guard let value = entry["event"], let event = try? value.decode(SessionEvent.self) else { return nil }
                return SessionEventRecord(event: event, view: nil)
            } ?? []
            recordsBySession[sessionId] = mergeRecords(incoming, recordsBySession[sessionId] ?? [])
            historyHasMoreBySession[sessionId] = frame["hasMore"]?.boolValue ?? false
            if let projections = frame["projections"],
               let block = try? projections.decode(SessionProjectionsBlock.self) {
                seedProjections(sessionId: sessionId, block: block)
            }
        case "event":
            guard let value = frame["event"], let event = try? value.decode(SessionEvent.self) else { return }
            recordsBySession[sessionId] = mergeRecords(
                recordsBySession[sessionId] ?? [],
                [SessionEventRecord(event: event, view: nil)]
            )
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
        recordsBySession[id] = nil
        historyHasMoreBySession[id] = nil
        projectionsBySession[id] = nil
        pendingApprovals = pendingApprovals.filter { $0.value.sessionId != id }
        pendingQuestions = pendingQuestions.filter { $0.value.sessionId != id }
        queuedItems[id] = nil
        backgroundJobs[id] = nil
        if selectedSessionId == id { beginNewTask(in: selectedWorkspaceId) }
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
            let byId = workspaces.reduce(into: [String: WorkspaceView]()) { result, workspace in
                result[workspace.workspaceId] = workspace
            }
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
                clientId: remoteEventClientId ?? "",
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
                clientId: remoteEventClientId ?? "",
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
        if let selectedSessionId {
            selectedWorkspaceId = workspaces.first(where: { $0.sessionIds.contains(selectedSessionId) })?.workspaceId
        }
        updateIdleGuard()
        scheduleProjectionCache()
    }

    private func mergeRecords(
        _ lhs: [SessionEventRecord],
        _ rhs: [SessionEventRecord]
    ) -> [SessionEventRecord] {
        var bySeq = lhs.reduce(into: [Int: SessionEventRecord]()) { result, record in
            if let existing = result[record.event.seq], record.view == nil, existing.view != nil { return }
            result[record.event.seq] = record
        }
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

    /// Remote revocation is also a local privacy boundary. Cached Host data is
    /// useful during an ordinary outage, but it must not remain readable after
    /// that Host explicitly removes this device's authorization.
    private func purgeHostProjection() {
        remoteEventClientId = nil
        bufferedFeeds.removeAll(keepingCapacity: false)
        workspaces = []
        sessions = []
        archivedSessionIds = []
        recordsBySession = [:]
        historyHasMoreBySession = [:]
        projectionsBySession = [:]
        harnessesBySession = [:]
        pendingApprovals = [:]
        pendingQuestions = [:]
        queuedItems = [:]
        backgroundJobs = [:]
        searchResults = []
        skills = []
        commands = []
        subagents = []
        harnesses = []
        providers = []
        plugins = []
        pairedDevices = []
        pairingCode = nil
        nativeCapabilities = nil
        hostDescription = nil
        settingsCatalog = nil
        agentPresets = nil
        hostModels = HostModelCatalog(groups: [], failures: [])
        directoryListing = nil
        sessionModels = nil
        sessionModelsError = nil
        attachmentData = [:]
        failedAttachmentKeys = []
        pendingImages = []
        draft = ""
        draftSessionId = nil
        draftHarnessId = nil
        selectedSessionId = nil
        selectedWorkspaceId = nil
        activeSubagent = nil
        UserDefaults.standard.removeObject(forKey: "OpenCodex.lastSessionId")
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
        let requiredIds = Set([selectedSessionId, conversationSessionId, draftSessionId].compactMap { $0 })
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
            version: 2,
            host: connectionProfile.baseURL.absoluteString,
            savedAt: Date(),
            workspaces: workspaces,
            sessions: retained,
            archivedSessionIds: archivedSessionIds,
            recordsBySession: records,
            historyHasMoreBySession: history,
            projectionsBySession: projections,
            selectedWorkspaceId: selectedWorkspaceId,
            selectedSessionId: selectedSessionId,
            draftSessionId: draftSessionId,
            draftHarnessId: draftHarnessId
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
