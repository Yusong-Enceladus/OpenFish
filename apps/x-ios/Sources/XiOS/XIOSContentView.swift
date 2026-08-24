import MarkdownUI
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private enum MobileOpenFishDemoMode {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains { $0 == "--openfish-demo" || $0.hasPrefix("--openfish-demo-") }
    static let showsLoading = ProcessInfo.processInfo.arguments.contains("--openfish-demo-loading")
    static let showsOffline = ProcessInfo.processInfo.arguments.contains("--openfish-demo-offline")
    static let showsRecoverable = ProcessInfo.processInfo.arguments.contains("--openfish-demo-recoverable")
    static let showsFatal = ProcessInfo.processInfo.arguments.contains("--openfish-demo-fatal")
    static let showsEmpty = ProcessInfo.processInfo.arguments.contains("--openfish-demo-empty")
    static let showsHarnessSetup = ProcessInfo.processInfo.arguments.contains("--openfish-demo-harness-catalog")
    static let showsInteractions = ProcessInfo.processInfo.arguments.contains("--openfish-demo-interactions")

    @MainActor
    static func store() -> MobileOpenCodexStore {
        if showsLoading { return .visualLoadingFixture() }
        if showsOffline { return .visualOfflineFixture() }
        if showsRecoverable { return .visualRecoverableFixture() }
        if showsFatal { return .visualFatalFixture() }
        if showsEmpty { return .visualEmptyFixture() }
        if showsHarnessSetup { return .visualHarnessSetupFixture() }
        if showsInteractions { return .visualInteractionFixture() }
        return .visualFixture()
    }
}

public struct OpenCodexIOSView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store: MobileOpenCodexStore
    private let shouldBoot: Bool
    private let runsVoiceHardwareSelfTest: Bool
    private let runsLifecycleHardwareSelfTest: Bool
    @State private var importsPresented = false
    @State private var searchText = ""
    @State private var expandedWorkspaceIDs: Set<String> = []
    @State private var otherTasksExpanded = false
    @State private var archivedTasksExpanded = false
    @State private var choseInitialWorkspace = false
    @State private var showsActivity = false
    @State private var inspectedHomeHarness: MobileHarness?

    public init() {
        let demo = MobileOpenFishDemoMode.isEnabled
        let arguments = ProcessInfo.processInfo.arguments
        let runsVoiceHardwareSelfTest = arguments.contains("--openfish-voice-autotest")
        let runsLifecycleHardwareSelfTest = arguments.contains("--openfish-lifecycle-autotest")
        let isolatedVoiceSmoke = arguments.contains("--openfish-voice-smoke") || runsVoiceHardwareSelfTest
        _store = StateObject(wrappedValue: demo ? MobileOpenFishDemoMode.store() : isolatedVoiceSmoke ? .visualFixture() : MobileOpenCodexStore())
        shouldBoot = !demo && !isolatedVoiceSmoke
        self.runsVoiceHardwareSelfTest = runsVoiceHardwareSelfTest
        self.runsLifecycleHardwareSelfTest = runsLifecycleHardwareSelfTest
    }

    init(store: MobileOpenCodexStore, shouldBoot: Bool) {
        _store = StateObject(wrappedValue: store)
        self.shouldBoot = shouldBoot
        runsVoiceHardwareSelfTest = false
        runsLifecycleHardwareSelfTest = false
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MobileRemoteHeader(
                    store: store,
                    importsPresented: $importsPresented,
                    showsActivity: $showsActivity
                )
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                    if store.hostPresentationState.blocksTaskList {
                        MobileHostAvailabilityView(store: store, state: store.hostPresentationState)
                    } else {
                    MobileHostStatusRow(store: store)

                    if case let .cached(issue) = store.hostPresentationState {
                        MobileCachedHostBanner(store: store, issue: issue)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                    }

                    if let harness = homeHarness, !showsActivity {
                        MobileCurrentHarnessCard(
                            harness: harness,
                            displayName: mobileHarnessDisplayName(harness, among: store.harnesses)
                        ) { inspectedHomeHarness = harness }
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                    }

                    if store.workspaces.isEmpty && store.sessions.isEmpty {
                        ContentUnavailableView(
                            "No tasks yet",
                            systemImage: "square.and.pencil",
                            description: Text("Start with a project or choose No Project. The selected Harness will run on your Mac Host.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 90)
                    }

                    if showsActivity {
                        MobileActivityList(store: store, query: searchText)
                    } else {
                    ForEach(store.orderedWorkspaces) { workspace in
                    let workspaceSessions = filtered(store.sessions(in: workspace))
                    VStack(alignment: .leading, spacing: 0) {
                        Button { toggleWorkspace(workspace.workspaceId) } label: {
                            MobileWorkspaceHeader(
                                title: workspace.title,
                                taskCount: store.sessions(in: workspace).count,
                                expanded: workspaceIsExpanded(workspace.workspaceId)
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 8)

                        if workspaceIsExpanded(workspace.workspaceId) {
                            ForEach(workspaceSessions) { session in
                                NavigationLink {
                                    MobileConversationView(store: store, sessionId: session.sessionId)
                                        .onAppear { store.markRead(session) }
                                } label: {
                                    MobileSessionRow(store: store, session: session)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Archive", systemImage: "archivebox") {
                                        Task { await store.setArchived(session.sessionId, archived: true) }
                                    }
                                }
                            }

                            if workspaceSessions.isEmpty {
                                Text(searchIsActive ? "No matching tasks" : "No tasks yet")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                            }
                        }
                    }
                }

                let unfiled = filtered(store.sessions(in: nil))
                if !unfiled.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Button { otherTasksExpanded.toggle() } label: {
                            MobileWorkspaceHeader(
                                title: "No Project",
                                taskCount: unfiled.count,
                                expanded: otherTasksExpanded || searchIsActive,
                                systemImage: "tray"
                            )
                        }
                        .buttonStyle(.plain)
                        if otherTasksExpanded || searchIsActive {
                            ForEach(unfiled) { session in
                                NavigationLink {
                                    MobileConversationView(store: store, sessionId: session.sessionId)
                                        .onAppear { store.markRead(session) }
                                } label: {
                                    MobileSessionRow(store: store, session: session)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Archive", systemImage: "archivebox") {
                                        Task { await store.setArchived(session.sessionId, archived: true) }
                                    }
                                }
                            }
                        }
                    }
                }

                if !store.archivedSessions.isEmpty {
                    let archived = filtered(store.archivedSessions)
                    if !archived.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Button { archivedTasksExpanded.toggle() } label: {
                                MobileWorkspaceHeader(
                                    title: "Archived",
                                    taskCount: archived.count,
                                    expanded: archivedTasksExpanded || searchIsActive,
                                    systemImage: "archivebox"
                                )
                            }
                            .buttonStyle(.plain)
                            if archivedTasksExpanded || searchIsActive {
                                ForEach(archived) { session in
                                    HStack(spacing: 8) {
                                        MobileSessionRow(store: store, session: session)
                                        Button {
                                            Task { await store.setArchived(session.sessionId, archived: false) }
                                        } label: {
                                            Image(systemName: "arrow.uturn.backward")
                                        }
                                        .buttonStyle(.borderless)
                                        .accessibilityLabel("Restore task")
                                        .padding(.trailing, 16)
                                    }
                                }
                            }
                        }
                    }
                }
                }
                    }
                    }
                    .padding(.bottom, 8)
                }
            }
            .background(Color(uiColor: .systemBackground))
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                MobileRemoteBottomBar(
                    store: store,
                    searchText: $searchText,
                    workspaceID: preferredWorkspaceID
                )
            }
            .refreshable { await store.refresh() }
            .fileImporter(
                isPresented: $importsPresented,
                allowedContentTypes: [UTType(filenameExtension: "jsonl")!, .zip],
                allowsMultipleSelection: true
            ) { result in
                if case let .success(urls) = result { Task { await store.importURLs(urls) } }
            }
            .sheet(isPresented: $store.showsConnection) {
                MobileConnectionView(store: store)
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $inspectedHomeHarness) { harness in
                MobileHarnessDetailView(store: store, harness: harness, initialLens: "Architecture") {
                    Task { await store.selectDefaultHarness(harness) }
                    inspectedHomeHarness = nil
                }
            }
            .sheet(isPresented: $store.showsWorkspaceBrowser) {
                MobileHostDirectoryBrowser(store: store)
            }
            .fullScreenCover(isPresented: $store.showsVoiceConversation) {
                MobileVoiceConversationView(store: store)
            }
            .fullScreenCover(isPresented: Binding(
                get: { store.hasLiveBaseline && store.selectedHarnessId.isEmpty },
                set: { _ in }
            )) {
                MobileHarnessOnboardingView(store: store)
            }
            .alert("OpenFish", isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { store.errorMessage = nil }
            } message: {
                Text(store.errorMessage ?? "")
            }
            .task {
                if shouldBoot { await store.boot() }
#if DEBUG
                if runsVoiceHardwareSelfTest {
                    await store.voice.runPhysicalHardwareSmokeTest()
                }
                if runsLifecycleHardwareSelfTest {
                    await store.runPhysicalLifecycleSmokeTest()
                }
#endif
                chooseInitialWorkspaceIfNeeded()
            }
            .onChange(of: store.workspaces) { _, _ in chooseInitialWorkspaceIfNeeded() }
            .onChange(of: store.sessions) { _, _ in chooseInitialWorkspaceIfNeeded() }
            .onChange(of: scenePhase) { _, phase in
                guard shouldBoot else { return }
                switch phase {
                case .active:
                    Task { await store.becameActive() }
                case .background:
                    Task { await store.enteredBackground() }
                case .inactive:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    private func filtered(_ sessions: [MobileSession]) -> [MobileSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return sessions }
        return sessions.filter { session in
            store.title(for: session).lowercased().contains(query)
                || (session.cwd?.lowercased().contains(query) ?? false)
        }
    }

    private var searchIsActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var homeHarness: MobileHarness? {
        store.harnesses.first(where: { $0.id == store.selectedHarnessId })
            ?? store.harnesses.first(where: \.isDefault)
    }

    private var preferredWorkspaceID: String? {
        if let selectedWorkspaceId = store.selectedWorkspaceId { return selectedWorkspaceId }
        if let expanded = store.orderedWorkspaces.first(where: { expandedWorkspaceIDs.contains($0.workspaceId) }) {
            return expanded.workspaceId
        }
        return store.orderedWorkspaces.first?.workspaceId
    }

    private func workspaceIsExpanded(_ workspaceID: String) -> Bool {
        searchIsActive || expandedWorkspaceIDs.contains(workspaceID)
    }

    private func toggleWorkspace(_ workspaceID: String) {
        if expandedWorkspaceIDs.contains(workspaceID) {
            expandedWorkspaceIDs.remove(workspaceID)
        } else {
            expandedWorkspaceIDs.insert(workspaceID)
            store.selectedWorkspaceId = workspaceID
        }
    }

    private func chooseInitialWorkspaceIfNeeded() {
        guard !choseInitialWorkspace, !store.workspaces.isEmpty else { return }
        guard !store.sessions.isEmpty || store.workspaces.allSatisfy(\.sessionIds.isEmpty) else { return }
        let workspace = store.workspaces.max { left, right in
            let leftUpdate = store.sessions(in: left).map(\.updatedAt).max() ?? 0
            let rightUpdate = store.sessions(in: right).map(\.updatedAt).max() ?? 0
            return leftUpdate < rightUpdate
        }
        if let workspace { expandedWorkspaceIDs.insert(workspace.workspaceId) }
        choseInitialWorkspace = true
    }
}

private struct MobileHostDirectoryBrowser: View {
    @ObservedObject var store: MobileOpenCodexStore
    @Environment(\.dismiss) private var dismiss
    @State private var showsHidden = false
    @State private var creatingFolder = false
    @State private var folderName = ""

    var body: some View {
        NavigationStack {
            List {
                if let listing = store.directoryListing {
                    Section("Selected folder") {
                        Text(listing.path)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Button("Use this folder as a project") {
                            Task { await store.addCurrentHostDirectory() }
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if listing.crumbs.count > 1 {
                        Section("Location") {
                            ForEach(listing.crumbs.reversed()) { crumb in
                                Button {
                                    Task { await store.browseHostDirectory(crumb.path) }
                                } label: {
                                    Label(crumb.name, systemImage: "arrow.up.left")
                                }
                            }
                        }
                    }

                    Section("Folders") {
                        let entries = listing.entries.filter { showsHidden || !$0.hidden }
                        if entries.isEmpty {
                            ContentUnavailableView(
                                "No subfolders",
                                systemImage: "folder",
                                description: Text("Choose this folder or go to a parent folder.")
                            )
                        }
                        ForEach(entries) { entry in
                            Button {
                                Task { await store.browseHostDirectory(entry.path) }
                            } label: {
                                HStack {
                                    Label(entry.name, systemImage: "folder")
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                        if listing.truncated {
                            Text("This folder has more entries. Refine it from the Host or choose a narrower parent.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if store.isBrowsingDirectories {
                    ProgressView("Loading Host folders…")
                }
            }
            .navigationTitle("Add project")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        store.showsWorkspaceBrowser = false
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showsHidden.toggle() } label: {
                        Image(systemName: showsHidden ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(showsHidden ? "Hide hidden folders" : "Show hidden folders")
                    Button {
                        folderName = ""
                        creatingFolder = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .accessibilityLabel("New folder")
                }
            }
            .alert("New folder", isPresented: $creatingFolder) {
                TextField("Folder name", text: $folderName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { Task { await store.createHostFolder(folderName) } }
            }
        }
    }
}

/// Compatibility spelling retained for existing library embedders.
public struct XIOSContentView: View {
    public init() {}
    public var body: some View { OpenCodexIOSView() }
}

private func mobileHarnessDisplayName(_ harness: MobileHarness, among catalog: [MobileHarness]) -> String {
    let hasCollision = catalog.contains {
        $0.id != harness.id
            && $0.name.localizedCaseInsensitiveCompare(harness.name) == .orderedSame
    }
    return hasCollision ? "\(harness.name) · \(harness.protocolName.uppercased())" : harness.name
}

private func mobileHarnessRequiresMacDriver(_ harness: MobileHarness) -> Bool {
    harness.driverBundle != nil
        && (harness.driver.authorization == "required"
            || !harness.driver.loaded
            || harness.installation.status != "installed"
            || harness.installation.installedVersion != harness.installation.availableVersion)
}

private func mobileHarnessRequiresMacCodeConsent(_ harness: MobileHarness) -> Bool {
    !harness.verified
        && harness.source != "user"
        && (harness.installation.status != "installed"
            || harness.installation.installedVersion != harness.installation.availableVersion)
}

private func mobileHarnessRequiresMacSetup(_ harness: MobileHarness) -> Bool {
    mobileHarnessRequiresMacDriver(harness) || mobileHarnessRequiresMacCodeConsent(harness)
}

private struct MobileCurrentHarnessCard: View {
    let harness: MobileHarness
    let displayName: String
    let inspect: () -> Void

    var body: some View {
        Button(action: inspect) {
            HStack(spacing: 12) {
                Image(systemName: "square.3.layers.3d")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Current Harness")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(displayName).font(.subheadline.weight(.semibold))
                        if harness.verified { Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(.blue) }
                    }
                    Text("\(harness.graph.nodes.count) components · \(harness.graph.level.capitalized)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Label("How it works", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.caption.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(14)
            .frame(minHeight: 84)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Current Harness \(displayName), see how this Harness works")
        .accessibilityIdentifier("OpenFish.iOS.CurrentHarness")
    }
}

private struct MobileHostStatusRow: View {
    @ObservedObject var store: MobileOpenCodexStore

    private var host: String {
        store.isDemoMode ? "Demo Mac" : store.profile.baseURL.host ?? "Mac Host"
    }

    private var statusLabel: String {
        switch store.hostPresentationState {
        case .ready: "Connected"
        case .cached: "Offline"
        case .loading: "Connecting"
        case .recoverable: "Reconnect"
        case .fatal: "Incompatible"
        }
    }

    var body: some View {
        Button { store.showsConnection = true } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(store.hasLiveBaseline ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Image(systemName: "desktopcomputer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(host)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if let problem = store.connectionProblem, store.connectionState != .connected {
                        Text(problem)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Host \(host), \(statusLabel)")
    }
}

private struct MobileHostAvailabilityView: View {
    @ObservedObject var store: MobileOpenCodexStore
    let state: MobileHostPresentationState

    private var copy: (title: String, message: String, icon: String, loading: Bool) {
        switch state {
        case .loading:
            ("Connecting to your Mac", "OpenFish is checking the Host protocol and restoring your tasks.", "desktopcomputer", true)
        case let .recoverable(issue):
            (issue?.title ?? "Could not reach this Mac", issue?.message ?? "OpenFish will keep retrying. Check the Mac Host or pair with another Mac.", "wifi.exclamationmark", false)
        case let .fatal(issue):
            (issue.title, issue.message, "exclamationmark.octagon", false)
        case .ready, .cached:
            ("Connected", "Your tasks are available.", "checkmark.circle", false)
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            if copy.loading {
                ProgressView()
                    .controlSize(.large)
                    .accessibilityLabel("Connecting to Mac Host")
            } else {
                Image(systemName: copy.icon)
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(copy.title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(copy.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if !copy.loading {
                Button("Retry now") { Task { await store.retryHostConnection() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            Button("Connection settings") { store.showsConnection = true }
                .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.top, 96)
        .accessibilityIdentifier("OpenFish.Mobile.Host.Availability")
    }
}

private struct MobileCachedHostBanner: View {
    @ObservedObject var store: MobileOpenCodexStore
    let issue: MobileHostIssue?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                issue?.kind == .incompatible ? "Cached tasks · incompatible Host" : "Cached tasks · reconnecting",
                systemImage: issue?.kind == .incompatible ? "exclamationmark.octagon.fill" : "wifi.slash"
            )
            .font(.subheadline.weight(.semibold))
            Text(issue?.message ?? "Read cached tasks now. Sending, approvals, and new tasks resume after the Host reconnects.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Retry") { Task { await store.retryHostConnection() } }
                    .buttonStyle(.bordered)
                Button("Connection") { store.showsConnection = true }
                    .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("OpenFish.Mobile.Host.Cached")
    }
}

private struct MobileHarnessOnboardingView: View {
    @ObservedObject var store: MobileOpenCodexStore
    @State private var query = ""
    @State private var inspectedHarness: MobileHarness?
    @State private var inspectedHarnessLens = "Simple"
    @State private var authSetup: MobileHarnessAuthSetup?

    private var filtered: [MobileHarness] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return store.harnesses }
        return store.harnesses.filter {
            $0.id.lowercased().contains(needle) || $0.name.lowercased().contains(needle)
                || ($0.description?.lowercased().contains(needle) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "shippingbox.and.arrow.backward")
                        .font(.system(size: 42, weight: .medium))
                        .foregroundStyle(.tint)
                    Text("Choose how OpenFish works").font(.largeTitle.bold())
                    Text("Pick the execution system that owns models, tools, guardrails, and resumable sessions. The connected Mac installs it; existing tasks never change Harnesses.")
                        .foregroundStyle(.secondary)
                    if store.harnesses.isEmpty {
                        ContentUnavailableView(
                            "Harness catalog unavailable",
                            systemImage: "exclamationmark.triangle",
                            description: Text("Reconnect to the Mac Host and retry. Pack installation and credentials remain owned by that Host.")
                        )
                        Button("Retry from Mac Host") { Task { await store.refresh() } }
                            .buttonStyle(.borderedProminent)
                        Button("Connection settings") { store.showsConnection = true }
                    } else if filtered.isEmpty {
                        ContentUnavailableView.search(text: query)
                        Button("Clear search") { query = "" }
                    }
                    ForEach(filtered) { harness in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(mobileHarnessDisplayName(harness, among: store.harnesses)).font(.headline)
                                Text(harness.description ?? "No description provided.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Text("v\(harness.version) · \(harness.installation.status.replacingOccurrences(of: "-", with: " ")) · \(harness.compatibility.classification.replacingOccurrences(of: "-", with: " "))")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let publication = harness.publication {
                                    Text("Community · \(publication.status.replacingOccurrences(of: "-", with: " "))")
                                        .font(.caption.weight(publication.status == "revoked" ? .semibold : .regular))
                                        .foregroundStyle(publication.status == "revoked" ? Color.red : Color.secondary)
                                }
                            }
                            Spacer()
                            Button("How it works") {
                                inspectedHarnessLens = "Architecture"
                                inspectedHarness = harness
                            }
                                .buttonStyle(.bordered)
                            if store.harnessOperationId == harness.id {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityLabel("Installing \(harness.name)")
                            } else if mobileHarnessRequiresMacSetup(harness) {
                                Button("Set up on Mac") {
                                    inspectedHarnessLens = "Simple"
                                    inspectedHarness = harness
                                }
                                    .buttonStyle(.bordered)
                            } else {
                                Button(harness.auth.status == "not-required" || harness.auth.status == "configured" ? "Use" : "Set up") {
                                    requestUse(harness)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(store.harnessOperationId != nil || !harness.available)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                    }
                    Text("Harness sign-in and API credentials are stored on the Mac Host. If a Harness needs authentication, OpenFish will tell you to finish it on the Mac before selecting it here.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .interactiveDismissDisabled()
            .searchable(text: $query, prompt: "Find a Harness")
        }
        .sheet(item: $inspectedHarness) { harness in
            MobileHarnessDetailView(store: store, harness: harness, initialLens: inspectedHarnessLens) {
                requestUse(harness)
                inspectedHarness = nil
            }
        }
        .sheet(item: $authSetup) { setup in
            MobileHarnessCredentialsView(
                store: store,
                harness: setup.harness,
                makeDefault: true
            )
        }
    }

    private func requestUse(_ harness: MobileHarness) {
        if mobileHarnessRequiresMacSetup(harness) {
            inspectedHarnessLens = "Simple"
            inspectedHarness = harness
        } else if harness.auth.status != "not-required" && harness.auth.status != "configured" {
            authSetup = MobileHarnessAuthSetup(harness: harness)
        } else {
            Task { await store.selectDefaultHarness(harness) }
        }
    }
}

private struct MobileHarnessAuthSetup: Identifiable {
    let harness: MobileHarness
    var id: String { harness.id }
}

private struct MobileHarnessCredentialsView: View {
    @ObservedObject var store: MobileOpenCodexStore
    let harness: MobileHarness
    let makeDefault: Bool
    let selectForDraft: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var selectedMethodId: String
    @State private var saving = false

    init(
        store: MobileOpenCodexStore,
        harness: MobileHarness,
        makeDefault: Bool,
        selectForDraft: Bool = false
    ) {
        self.store = store
        self.harness = harness
        self.makeDefault = makeDefault
        self.selectForDraft = selectForDraft
        _selectedMethodId = State(initialValue: harness.auth.selectedMethod ?? harness.auth.methods.first?.id ?? "")
    }

    private var currentHarness: MobileHarness {
        store.harnesses.first(where: { $0.id == harness.id }) ?? harness
    }

    private var method: MobileHarness.Authentication.Method? {
        currentHarness.auth.methods.first(where: { $0.id == selectedMethodId })
            ?? currentHarness.auth.methods.first
    }

    private var canConfirmOnPhone: Bool {
        guard let method else { return false }
        return method.kind != "terminal" && method.fields.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Choose how \(currentHarness.name) authenticates. API keys and terminal sign-in never enter this iPhone; methods that need either one must be completed on the connected Mac.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Sign-in method") {
                    if currentHarness.auth.methods.isEmpty {
                        ContentUnavailableView(
                            "No sign-in method advertised",
                            systemImage: "key.slash",
                            description: Text("Install or refresh this Harness on the connected Mac so its Driver can discover authentication.")
                        )
                    } else {
                        Picker("Method", selection: $selectedMethodId) {
                            ForEach(currentHarness.auth.methods) { method in
                                Text(method.name).tag(method.id)
                            }
                        }
                    }
                }

                if let method {
                    if currentHarness.id == store.currentHarnessId,
                       let runtimeAccount = store.sessionModels?.account {
                        Section("Live task route") {
                            LabeledContent("Account", value: runtimeAccount.label)
                            LabeledContent(
                                "Billing",
                                value: runtimeAccount.billing.replacingOccurrences(of: "-", with: " ").capitalized
                            )
                            Text(runtimeAccount.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Account and billing") {
                        LabeledContent("Account", value: method.account?.label ?? method.name)
                        LabeledContent(
                            "Billing",
                            value: method.account?.billing.replacingOccurrences(of: "-", with: " ").capitalized ?? "Not declared"
                        )
                        Text(method.account?.detail ?? "This Harness Pack has not declared who owns billing for this method.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if method.kind == "terminal" || !method.fields.isEmpty {
                        Section {
                            Label("Finish this sign-in in OpenFish on the connected Mac.", systemImage: "macbook.and.iphone")
                                .font(.subheadline)
                            if method.kind == "terminal" {
                                Text("This method opens an interactive terminal owned by the Mac. Terminal input and authentication tokens are never proxied through the iPhone.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Required on Mac: \(method.fields.map(\.name).joined(separator: ", ")). OpenFish deliberately does not provide a mobile API-key form because the paired Host connection may use a trusted LAN transport.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Button("Check Host status") { Task { await store.refresh() } }
                        }
                    } else {
                        Section {
                            Label("This method has no fields to enter on this iPhone.", systemImage: "checkmark.shield")
                                .font(.subheadline)
                            Text(method.kind == "agent"
                                ? "Selecting it asks the connected Mac to verify the Harness-owned local account state. It does not sign you in on this iPhone or grant model quota."
                                : "The connected Mac still verifies that the Harness can use this method before a task starts.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Configure Harness")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm") {
                        guard let method else { return }
                        saving = true
                        Task {
                            let saved = await store.configureHarness(
                                currentHarness,
                                method: method,
                                makeDefault: makeDefault
                            )
                            saving = false
                            if saved {
                                if selectForDraft {
                                    await store.chooseHarness(
                                        currentHarness,
                                        force: true
                                    )
                                }
                                dismiss()
                            }
                        }
                    }
                    .disabled(!canConfirmOnPhone || saving || store.harnessOperationId != nil)
                }
            }
        }
        .interactiveDismissDisabled(saving)
    }
}

private struct MobileHarnessDetailView: View {
    @ObservedObject var store: MobileOpenCodexStore
    let harness: MobileHarness
    let use: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var lens: String
    @State private var selectedNodeId: String?
    @State private var architecturePresentation = "Flow"
    @State private var handoffCopied = false

    init(
        store: MobileOpenCodexStore,
        harness: MobileHarness,
        initialLens: String = "Simple",
        use: @escaping () -> Void
    ) {
        self.store = store
        self.harness = harness
        self.use = use
        _lens = State(initialValue: initialLens)
    }

    private var currentHarness: MobileHarness {
        store.harnesses.first(where: { $0.id == harness.id }) ?? harness
    }

    private var matchingRuntime: MobileHarnessRuntimeProjection? {
        guard store.currentHarness?.id == harness.id,
              store.currentHarness?.version == harness.version,
              let runtime = store.currentHarnessRuntime,
              runtime.harnessId == nil || runtime.harnessId == harness.id,
              runtime.version == nil || runtime.version == harness.version else { return nil }
        return runtime
    }

    private var truthExplanation: String {
        switch harness.graph.level {
        case "composable": return "This Pack declares editable nodes. Use the Manifest Editor on the Mac to change them."
        case "observable": return "Read-only structure declared by the Pack. OpenFish does not invent private internals."
        default: return "Only the runtime boundary is public. The Harness keeps its private internals opaque."
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(harness.name).font(.largeTitle.bold())
                            Text("\(harness.publisher) · \(harness.protocolName.uppercased()) · \(harness.version)")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if harness.verified { Image(systemName: "checkmark.seal.fill").foregroundStyle(.blue).font(.title2) }
                    }
                    if let description = harness.description { Text(description).foregroundStyle(.secondary) }
                    Picker("Harness lens", selection: $lens) {
                        Text("Simple").tag("Simple")
                        Text("How it works").tag("Architecture")
                        Text("Live").tag("Runtime")
                        Text("Manifest").tag("Manifest")
                    }
                    .pickerStyle(.segmented)

                    if lens == "Simple" {
                        VStack(spacing: 10) {
                            MobileLensFact(
                                title: "What changes",
                                value: "\(currentHarness.description ?? "This Pack does not declare a usage summary.") New tasks can use it; existing tasks stay pinned to their original Harness and version.",
                                icon: "arrow.triangle.branch"
                            )
                            MobileLensFact(title: "Models & sign-in", value: modelAndSignInSummary, icon: "cpu")
                            MobileLensFact(title: "Install & updates", value: lifecycleSummary, icon: "shippingbox")
                            MobileLensFact(
                                title: "Trust & compatibility",
                                value: "\(currentHarness.compatibility.classification.replacingOccurrences(of: "-", with: " ")) · \(currentHarness.installation.integrity.status.replacingOccurrences(of: "-", with: " ")) · \(driverAuthorizationSummary)",
                                icon: "checkmark.shield"
                            )
                            if let publication = currentHarness.publication {
                                MobileLensFact(
                                    title: "Community publication",
                                    value: "\(publication.status.replacingOccurrences(of: "-", with: " ")) · \(publication.detail)\(publication.revokedReason.map { " Reason: \($0)" } ?? "")",
                                    icon: publication.status == "revoked" ? "exclamationmark.shield.fill" : publication.status == "published" ? "checkmark.seal.fill" : "doc.badge.clock"
                                )
                                if let review = publication.reviewUrl, let url = URL(string: review) {
                                    Link("Open community review", destination: url)
                                        .font(.footnote.weight(.semibold))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            MobileLensFact(title: "Permission boundary", value: permissionSummary, icon: "hand.raised")
                            if currentHarness.installation.status != "builtin" {
                                Label(
                                    "Update, rollback, uninstall, and removal are managed on the connected Mac so a phone cannot silently replace task runtimes.",
                                    systemImage: "macbook.and.iphone"
                                )
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if let bundle = currentHarness.driverBundle, mobileHarnessRequiresMacDriver(currentHarness) {
                                Label(
                                    "This Harness needs \(bundle.package) from \(bundle.spec). OpenFish on the Mac must show the code-execution warning, install the exact Driver, and restart its verified Host before the iPhone can use it.",
                                    systemImage: "macbook.and.iphone"
                                )
                                .font(.footnote)
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if mobileHarnessRequiresMacCodeConsent(currentHarness) {
                                Label(
                                    "This exact third-party Harness version has not been verified. Review and admit its code in OpenFish on the Host Mac; a paired iPhone cannot grant Host code execution.",
                                    systemImage: "lock.desktopcomputer"
                                )
                                .font(.footnote)
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    } else if lens == "Manifest" {
                        ContentUnavailableView(
                            "Manifest Editor is on your Mac",
                            systemImage: "point.3.connected.trianglepath.dotted",
                            description: Text("Create, validate, import, preflight, and submit credential-free Harness Packs to the reviewed community catalog on the connected Mac. This iPhone remains a safe read-only architecture and approval controller.")
                        )
                        .frame(minHeight: 250)
                    } else if lens == "Runtime" {
                        VStack(alignment: .leading, spacing: 12) {
                            MobileHarnessArchitectureFlow(
                                graph: harness.graph, runtime: matchingRuntime,
                                selectedNodeId: selectedNodeId, onSelect: { selectedNodeId = $0 }
                            )
                            if let runtime = matchingRuntime, !runtime.nodes.isEmpty {
                                ForEach(runtime.nodes.keys.sorted(), id: \.self) { nodeID in
                                    if let activity = runtime.nodes[nodeID] {
                                        MobileLensFact(
                                            title: harness.graph.nodes.first(where: { $0.id == nodeID })?.title ?? nodeID,
                                            value: "\(activity.status) · \(activity.activity)",
                                            icon: activity.status == "failed" ? "exclamationmark.triangle" : "waveform.path.ecg"
                                        )
                                    }
                                }
                                if let edges = runtime.edges, !edges.isEmpty {
                                    Text("Observed flows").font(.headline).padding(.top, 4)
                                    ForEach(edges.keys.sorted(), id: \.self) { edgeID in
                                        if let edge = edges[edgeID] {
                                            MobileLensFact(
                                                title: "\(edge.from) → \(edge.to)",
                                                value: "\(edge.status) · \(edge.activity)",
                                                icon: edge.status == "failed" ? "exclamationmark.triangle" : "arrow.right"
                                            )
                                        }
                                    }
                                }
                            } else {
                                ContentUnavailableView("No runtime evidence yet", systemImage: "waveform.path.ecg", description: Text("Start a task with this Harness. Only observed declared components will appear."))
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label(harness.graph.boundary ?? "Harness process", systemImage: "square.dashed")
                                Spacer()
                                Text(harness.graph.level.capitalized).font(.caption.weight(.semibold))
                            }
                            .font(.caption.weight(.semibold))
                            Picker("Architecture presentation", selection: $architecturePresentation) {
                                Text("Operational lens").tag("Flow")
                                Text("Full map").tag("Map")
                            }
                            .pickerStyle(.segmented)
                            if architecturePresentation == "Flow" {
                                MobileHarnessArchitectureFlow(
                                    graph: harness.graph, selectedNodeId: selectedNodeId,
                                    onSelect: { selectedNodeId = $0 }
                                )
                            } else {
                                MobileHarnessGraphPreview(graph: harness.graph)
                                    .frame(height: max(240, min(560, CGFloat(harness.graph.nodes.count) * 72 + 20)))
                            }
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(harness.graph.nodes) { node in
                                        Button(node.title) { selectedNodeId = node.id }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                            .tint(selectedNodeId == node.id ? Color.accentColor : nil)
                                    }
                                }
                            }
                            if let node = selectedNode {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack {
                                        Text(node.title).font(.headline)
                                        Spacer()
                                        Text(node.editable ? "Editable" : "Read only").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(node.responsibility ?? "This Pack has not supplied a responsibility statement.")
                                        .font(.footnote).foregroundStyle(.secondary)
                                    if let inputs = node.inputs, !inputs.isEmpty {
                                        MobileArchitectureValues(title: "Receives", values: inputs, icon: "arrow.down.left")
                                    }
                                    if let outputs = node.outputs, !outputs.isEmpty {
                                        MobileArchitectureValues(title: "Produces", values: outputs, icon: "arrow.up.right")
                                    }
                                    if let ports = node.ports, !ports.isEmpty {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text("Typed ports").font(.caption.weight(.semibold))
                                            ForEach(ports) { port in
                                                HStack(spacing: 6) {
                                                    Image(systemName: port.direction == "input" ? "arrow.right.circle" : "arrow.left.circle")
                                                    Text(port.name).font(.caption)
                                                    Spacer()
                                                    Text(port.dataType).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                                }
                                            }
                                        }
                                    }
                                    if let fields = node.configSchema?.fields, !fields.isEmpty {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text("Executable controls").font(.caption.weight(.semibold))
                                            ForEach(fields) { field in
                                                HStack(alignment: .firstTextBaseline) {
                                                    VStack(alignment: .leading, spacing: 1) {
                                                        Text(field.name).font(.caption)
                                                        Text("\(field.binding.kind) · \(field.binding.target)")
                                                            .font(.caption2.monospaced()).foregroundStyle(.secondary)
                                                    }
                                                    Spacer()
                                                    Text(mobileConfigValue(node.config?[field.id]))
                                                        .font(.caption2.weight(.medium)).lineLimit(1)
                                                }
                                            }
                                        }
                                    }
                                    if let evidence = node.evidence {
                                        ForEach(evidence) { item in
                                            Label(item.kind.replacingOccurrences(of: "-", with: " ").capitalized, systemImage: "doc.text.magnifyingglass")
                                                .font(.caption.weight(.semibold))
                                            Text("\(item.source)\(item.version.map { " · \($0)" } ?? "")")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .padding(12)
                                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                            }
                            Text(truthExplanation).font(.footnote).foregroundStyle(.secondary)
                            Text(currentHarness.driver.loaded
                                ? "Driver API v\(currentHarness.driver.apiVersion) negotiated · \(driverAuthorizationSummary) · \(currentHarness.capabilities.filter { $0.status != "unsupported" }.count) advertised capabilities"
                                : "The required Driver is not loaded on the connected Mac.")
                                .font(.caption2).foregroundStyle(.secondary)
                            if harness.source == "user" {
                                Button {
                                    UIPasteboard.general.string = harness.id
                                    handoffCopied = true
                                } label: {
                                    Label(handoffCopied ? "Pack ID copied" : "Continue in Manifest Editor on Mac", systemImage: "macbook.and.iphone")
                                }
                                .buttonStyle(.bordered)
                                Text("This Pack already lives on the connected Host. Open Settings → Harnesses → Manifest on that Mac and choose \(harness.name). No manifest or credential is transferred through the clipboard; only its public Pack ID is copied.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Negotiated capabilities").font(.headline)
                                ForEach(harness.capabilities) { capability in
                                    HStack {
                                        Image(systemName: capability.status == "supported" ? "checkmark.circle.fill" : capability.status == "runtime" ? "waveform.path.ecg" : "minus.circle")
                                            .foregroundStyle(capability.status == "supported" ? Color.green : capability.status == "runtime" ? Color.blue : Color.secondary)
                                        Text(capability.id.replacingOccurrences(of: ".", with: " · "))
                                            .font(.footnote)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.72)
                                        Spacer()
                                        Text(capability.status).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                            }
                            .padding(12)
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                    if store.harnessOperationId == harness.id {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Installing and checking \(harness.name)…")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .accessibilityElement(children: .combine)
                    } else {
                        Button(harnessActionTitle) {
                            use()
                        }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                            .disabled(
                                store.harnessOperationId != nil || !currentHarness.available
                                    || currentHarness.isDefault || (requiresSetup && !canConfigureOnPhone)
                                    || mobileHarnessRequiresMacSetup(currentHarness)
                            )
                    }
                    if requiresSetup {
                        Label(
                            canConfigureOnPhone
                                ? "The connected Mac verifies this sign-in choice. No credential value is returned to this iPhone."
                                : "Finish authentication on the connected Mac. Harness-owned terminal input never moves to this iPhone.",
                            systemImage: canConfigureOnPhone ? "lock.shield" : "macbook.and.iphone"
                        )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                // A Pack may advertise arbitrarily long capability ids, evidence
                // URLs, or component titles. Constrain the content to the phone
                // viewport so one unbroken value cannot widen and clip the whole
                // sheet (including its navigation controls).
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
            }
            .frame(maxWidth: .infinity)
            .navigationTitle("Harness details")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .onAppear { selectedNodeId = harness.graph.nodes.first?.id }
        .accessibilityIdentifier("OpenFish.iOS.HarnessDetail")
    }

    private var selectedNode: MobileHarness.GraphNode? {
        harness.graph.nodes.first(where: { $0.id == selectedNodeId }) ?? harness.graph.nodes.first
    }

    private var driverAuthorizationSummary: String {
        switch currentHarness.driver.authorization {
        case "authorized": return "exact Driver source authorized"
        case "required": return "exact Driver source needs Mac authorization"
        default: return "built-in Driver"
        }
    }

    private var harnessActionTitle: String {
        if currentHarness.isDefault { return "Default for new tasks" }
        if mobileHarnessRequiresMacDriver(currentHarness) { return "Install Driver on Mac first" }
        if mobileHarnessRequiresMacCodeConsent(currentHarness) { return "Review code on Mac first" }
        if requiresSetup { return canConfigureOnPhone ? "Set up sign-in" : "Set up on Mac" }
        if currentHarness.installation.status == "builtin" || currentHarness.installation.status == "installed" {
            return "Use for new tasks"
        }
        return "Install and use for new tasks"
    }

    private var requiresSetup: Bool {
        currentHarness.auth.status != "not-required" && currentHarness.auth.status != "configured"
    }

    private var canConfigureOnPhone: Bool {
        currentHarness.auth.methods.contains { $0.kind != "terminal" && $0.fields.isEmpty }
    }

    private var modelAndSignInSummary: String {
        if let selected = currentHarness.auth.selectedMethod {
            let method = currentHarness.auth.methods.first(where: { $0.id == selected })
            return method?.account?.label ?? method?.name ?? selected
        }
        if currentHarness.auth.status != "not-required" {
            return currentHarness.auth.status.replacingOccurrences(of: "-", with: " ")
        }
        return currentHarness.modelConfiguration?.detail
            ?? currentHarness.account?.label
            ?? "Model and account contract not declared by this Pack"
    }

    private var lifecycleSummary: String {
        if currentHarness.installation.status == "builtin" {
            return "Bundled inside this OpenFish build. Updates and rollback follow the Mac app; it cannot be removed separately."
        }
        if currentHarness.installation.status == "installed" {
            let active = currentHarness.installation.installedVersion ?? currentHarness.version
            var parts = ["Installed exact version \(active)"]
            let available = currentHarness.installation.availableVersion
            if available != active {
                parts.append("\(available) available on the Mac")
            }
            if !currentHarness.installation.previousVersions.isEmpty {
                parts.append("rollback available")
            }
            return parts.joined(separator: " · ")
        }
        return "The connected Mac will install exact version \(currentHarness.installation.availableVersion) into OpenFish's private runtime after confirmation."
    }

    private var permissionSummary: String {
        let tools = currentHarness.capabilities.first(where: { $0.id == "interaction.tools" })?.status
        let approvals = currentHarness.capabilities.first(where: { $0.id == "interaction.approvals" })?.status
        if tools == "unsupported" { return "This Driver does not advertise tool actions." }
        if approvals == "supported" || approvals == "runtime" {
            return "The Harness owns tool behavior; OpenFish mirrors advertised approval requests from the Mac."
        }
        return "The Harness owns tool behavior and does not advertise an approval flow. Review it on the Mac before use."
    }
}

private struct MobileArchitectureValues: View {
    let title: String
    let values: [String]
    let icon: String

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold))
                Text(values.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private func mobileConfigValue(_ value: MobileJSONValue?) -> String {
    guard let value else { return "Not set" }
    if let text = value.stringValue { return text }
    if let flag = value.boolValue { return flag ? "On" : "Off" }
    return "Configured"
}

private struct MobileHarnessArchitecturePhase: Identifiable {
    let id: String
    let title: String
    let summary: String
    let icon: String
    let nodes: [MobileHarness.GraphNode]
}

private struct MobileHarnessArchitectureFlow: View {
    let graph: MobileHarness.Graph
    var runtime: MobileHarnessRuntimeProjection? = nil
    var selectedNodeId: String? = nil
    var onSelect: ((String) -> Void)? = nil

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Operational architecture").font(.subheadline.weight(.semibold))
                Text("Stages come from the Pack's exact connections, including branches and cycles. OpenFish does not infer private categories.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)

            ForEach(phases) { phase in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 9) {
                        Image(systemName: phase.icon)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(phase.title).font(.subheadline.weight(.semibold))
                            Text(phase.summary).font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                    ForEach(phase.nodes) { node in
                        Button { onSelect?(node.id) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Circle()
                                    .fill(runtimeColor(node.id))
                                    .frame(width: 8, height: 8)
                                    .padding(.top, 5)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(node.title).font(.subheadline.weight(.semibold))
                                        Spacer(minLength: 0)
                                        if node.editable {
                                            Image(systemName: "slider.horizontal.3")
                                                .font(.caption2.weight(.medium))
                                                .foregroundStyle(.secondary)
                                        }
                                        if let observed = runtime?.nodes[node.id] {
                                            Text(observed.status.capitalized)
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(runtimeColor(node.id))
                                        }
                                    }
                                    Text(node.responsibility ?? "Responsibility not declared by this Pack.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                    Text(relationshipSummary(node.id))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(2)
                                    if let observed = runtime?.nodes[node.id] {
                                        Text(observed.activity)
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(runtimeColor(node.id))
                                            .lineLimit(2)
                                    }
                                }
                            }
                            .padding(11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                selectedNodeId == node.id ? Color.accentColor.opacity(0.12) : Color(uiColor: .tertiarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 12)
                            )
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(
                                selectedNodeId == node.id ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.12)
                            ))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(node.title), \(phase.title), \(node.responsibility ?? node.kind)")
                    }
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 15))
            }
        }
    }

    private var phases: [MobileHarnessArchitecturePhase] {
        guard !graph.nodes.isEmpty else { return [] }
        let order = Dictionary(uniqueKeysWithValues: graph.nodes.enumerated().map { ($0.element.id, $0.offset) })
        var assigned = Set<String>()
        var groups: [[MobileHarness.GraphNode]] = []
        for node in graph.nodes where !assigned.contains(node.id) {
            let group = graph.nodes.filter { candidate in
                canReach(node.id, candidate.id) && canReach(candidate.id, node.id)
            }
            assigned.formUnion(group.map(\.id))
            groups.append(group.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) })
        }
        let groupByNode = Dictionary(uniqueKeysWithValues: groups.enumerated().flatMap { index, nodes in
            nodes.map { ($0.id, index) }
        })
        var outgoing = Dictionary(uniqueKeysWithValues: groups.indices.map { ($0, Set<Int>()) })
        var indegree = Dictionary(uniqueKeysWithValues: groups.indices.map { ($0, 0) })
        for edge in graph.edges {
            guard let source = groupByNode[edge.from], let target = groupByNode[edge.to], source != target,
                  outgoing[source]?.insert(target).inserted == true else { continue }
            indegree[target, default: 0] += 1
        }
        var remaining = Set(groups.indices)
        var layers: [[Int]] = []
        while !remaining.isEmpty {
            var ready = remaining.filter { indegree[$0, default: 0] == 0 }
                .sorted { firstNodeOrder(groups[$0], order: order) < firstNodeOrder(groups[$1], order: order) }
            if ready.isEmpty, let fallback = remaining.min(by: {
                firstNodeOrder(groups[$0], order: order) < firstNodeOrder(groups[$1], order: order)
            }) { ready = [fallback] }
            layers.append(ready)
            for index in ready {
                remaining.remove(index)
                for target in outgoing[index] ?? [] { indegree[target, default: 0] -= 1 }
            }
        }
        return layers.enumerated().map { index, groupIndices in
            let nodes = groupIndices.flatMap { groups[$0] }.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
            let containsCycle = groupIndices.contains { groups[$0].count > 1 }
            let title = layers.count == 1 ? "Harness boundary"
                : index == 0 ? "Entry stage"
                : index == layers.count - 1 ? "Outcome stage"
                : containsCycle ? "Runtime loop" : "Stage \(index + 1)"
            let summary = containsCycle ? "Pack-declared cycle · \(nodes.count) components"
                : groupIndices.count > 1 ? "Parallel paths · \(nodes.count) components"
                : "\(nodes.count) Pack-declared component\(nodes.count == 1 ? "" : "s")"
            return MobileHarnessArchitecturePhase(
                id: groupIndices.map(String.init).joined(separator: "-"), title: title, summary: summary,
                icon: containsCycle ? "arrow.triangle.2.circlepath"
                    : index == 0 ? "arrow.right"
                    : index == layers.count - 1 ? "arrow.turn.down.right" : "point.3.connected.trianglepath.dotted",
                nodes: nodes
            )
        }
    }

    private func canReach(_ source: String, _ target: String) -> Bool {
        if source == target { return true }
        var visited = Set([source])
        var pending = [source]
        while let current = pending.popLast() {
            for next in graph.edges.lazy.filter({ $0.from == current }).map(\.to) where !visited.contains(next) {
                if next == target { return true }
                visited.insert(next)
                pending.append(next)
            }
        }
        return false
    }

    private func firstNodeOrder(_ nodes: [MobileHarness.GraphNode], order: [String: Int]) -> Int {
        nodes.compactMap { order[$0.id] }.min() ?? .max
    }

    private func relationshipSummary(_ nodeID: String) -> String {
        let names = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0.title) })
        let incoming = graph.edges.filter { $0.to == nodeID }.map { edge in
            let source = names[edge.from] ?? edge.from
            return edge.label.map { "\(source) [\($0)]" } ?? source
        }
        let outgoing = graph.edges.filter { $0.from == nodeID }.map { edge in
            let target = names[edge.to] ?? edge.to
            return edge.label.map { "\(target) [\($0)]" } ?? target
        }
        return "\(incoming.isEmpty ? "entry" : "from \(incoming.joined(separator: ", "))") · \(outgoing.isEmpty ? "outcome" : "to \(outgoing.joined(separator: ", "))")"
    }

    private func runtimeColor(_ nodeId: String) -> Color {
        switch runtime?.nodes[nodeId]?.status {
        case "active": return .blue
        case "completed": return .green
        case "failed": return .red
        case "waiting": return .orange
        default: return .secondary
        }
    }
}

private struct MobileLensFact: View {
    let title: String
    let value: String
    let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
            Text(value).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 13))
    }
}

private struct MobileHarnessGraphPreview: View {
    let graph: MobileHarness.Graph
    var runtime: MobileHarnessRuntimeProjection? = nil
    @State private var scale: CGFloat = 1
    @GestureState private var gestureScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var gestureOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let points = layout(in: proxy.size)
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.secondary.opacity(0.055))
                ForEach(Array(graph.edges.enumerated()), id: \.offset) { _, edge in
                    if let from = points[edge.from], let to = points[edge.to] {
                        let endpoints = edgeEndpoints(from: from, to: to)
                        let liveEdge = runtimeEdge(edge)
                        Path { path in
                            path.move(to: endpoints.start)
                            path.addLine(to: endpoints.end)
                        }
                        .stroke(edgeColor(liveEdge?.status).opacity(liveEdge == nil ? 0.45 : 0.95), style: StrokeStyle(
                            lineWidth: liveEdge == nil ? 1.35 : 2.4, lineCap: .round, lineJoin: .round
                        ))
                        Image(systemName: "arrowtriangle.right.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(edgeColor(liveEdge?.status).opacity(liveEdge == nil ? 0.65 : 0.95))
                            .rotationEffect(.radians(atan2(
                                endpoints.end.y - endpoints.start.y,
                                endpoints.end.x - endpoints.start.x
                            )))
                            .position(endpoints.end)
                        if let label = edge.label {
                            Text(label)
                                .font(.system(size: 8.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .padding(.horizontal, 5)
                                .frame(height: 17)
                                .background(.regularMaterial, in: Capsule())
                                .position(
                                    x: (endpoints.start.x + endpoints.end.x) / 2,
                                    y: (endpoints.start.y + endpoints.end.y) / 2 - 10
                                )
                        }
                    }
                }
                ForEach(graph.nodes) { node in
                    HStack(spacing: 9) {
                        Circle()
                            .fill(runtimeColor(node.id))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(node.title)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Text(node.kind)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .frame(width: min(250, proxy.size.width - 72), height: 56)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(
                        runtimeColor(node.id).opacity(runtime?.nodes[node.id] == nil ? 0.25 : 0.9),
                        lineWidth: runtime?.nodes[node.id] == nil ? 1 : 2
                    ))
                    .position(points[node.id] ?? .zero)
                }
            }
            .scaleEffect(scale * gestureScale)
            .offset(x: offset.width + gestureOffset.width, y: offset.height + gestureOffset.height)
            .gesture(
                SimultaneousGesture(
                    MagnificationGesture()
                        .updating($gestureScale) { value, state, _ in state = value }
                        .onEnded { value in scale = min(2.5, max(0.6, scale * value)) },
                    DragGesture()
                        .updating($gestureOffset) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            offset.width += value.translation.width
                            offset.height += value.translation.height
                        }
                )
            )
            .clipped()
            .overlay(alignment: .topTrailing) {
                if scale != 1 || offset != .zero {
                    Button {
                        withAnimation(.snappy) { scale = 1; offset = .zero }
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .padding(8)
                            .background(.regularMaterial, in: Circle())
                    }
                    .padding(8)
                    .accessibilityLabel("Reset graph view")
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(graph.level) Harness architecture with \(graph.nodes.count) nodes")
    }

    private func layout(in size: CGSize) -> [String: CGPoint] {
        guard !graph.nodes.isEmpty else { return [:] }
        let authored = graph.nodes.compactMap { node -> (String, MobileHarness.GraphNode.Position)? in
            node.position.map { (node.id, $0) }
        }
        if authored.count == graph.nodes.count {
            let xs = authored.map { $0.1.x }
            let ys = authored.map { $0.1.y }
            let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
            let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
            let xInset: CGFloat = min(128, max(58, size.width * 0.20))
            let yInset: CGFloat = 40
            return Dictionary(uniqueKeysWithValues: authored.map { id, point in
                let x = maxX == minX ? size.width / 2
                    : xInset + CGFloat((point.x - minX) / (maxX - minX)) * max(1, size.width - xInset * 2)
                let y = maxY == minY ? size.height / 2
                    : yInset + CGFloat((point.y - minY) / (maxY - minY)) * max(1, size.height - yInset * 2)
                return (id, CGPoint(x: x, y: y))
            })
        }

        var level = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, 0) })
        let order = Dictionary(uniqueKeysWithValues: graph.nodes.enumerated().map { ($0.element.id, $0.offset) })
        for _ in 0..<max(1, graph.nodes.count - 1) {
            var changed = false
            for edge in graph.edges where (order[edge.from] ?? 0) < (order[edge.to] ?? 0) {
                let candidate = min(graph.nodes.count - 1, (level[edge.from] ?? 0) + 1)
                if candidate > (level[edge.to] ?? 0) {
                    level[edge.to] = candidate
                    changed = true
                }
            }
            if !changed { break }
        }
        let levels = Array(Set(level.values)).sorted()
        let normalized = Dictionary(uniqueKeysWithValues: levels.enumerated().map { ($0.element, $0.offset) })
        let rows = Dictionary(grouping: graph.nodes) { normalized[level[$0.id] ?? 0] ?? 0 }
        let maxRow = rows.keys.max() ?? 0
        var result: [String: CGPoint] = [:]
        for row in 0...maxRow {
            let nodes = rows[row] ?? []
            let step = nodes.count <= 1 ? 0 : max(116, (size.width - 136) / CGFloat(nodes.count - 1))
            let width = step * CGFloat(max(0, nodes.count - 1))
            let start = nodes.count <= 1 ? size.width / 2 : (size.width - width) / 2
            for (column, node) in nodes.enumerated() {
                result[node.id] = CGPoint(
                    x: start + CGFloat(column) * step,
                    y: 42 + CGFloat(row) * max(78, (size.height - 84) / CGFloat(max(1, maxRow)))
                )
            }
        }
        return result
    }

    private func edgeEndpoints(from: CGPoint, to: CGPoint) -> (start: CGPoint, end: CGPoint) {
        let dx = to.x - from.x, dy = to.y - from.y
        let distance = max(1, hypot(dx, dy))
        let inset: CGFloat = abs(dx) >= abs(dy) ? 124 : 31
        let ux = dx / distance, uy = dy / distance
        return (
            CGPoint(x: from.x + ux * inset, y: from.y + uy * inset),
            CGPoint(x: to.x - ux * inset, y: to.y - uy * inset)
        )
    }

    private func runtimeColor(_ nodeId: String) -> Color {
        switch runtime?.nodes[nodeId]?.status {
        case "active": return .blue
        case "completed": return .green
        case "failed": return .red
        case "waiting": return .orange
        default: return .secondary
        }
    }

    private func runtimeEdge(_ edge: MobileHarness.GraphEdge) -> MobileHarnessRuntimeProjection.Edge? {
        runtime?.edges?.values.first {
            $0.from == edge.from && $0.to == edge.to && $0.fromPort == edge.fromPort && $0.toPort == edge.toPort
        }
    }

    private func edgeColor(_ status: String?) -> Color {
        switch status {
        case "active": return .blue
        case "completed": return .green
        case "failed": return .red
        case "waiting": return .orange
        default: return .secondary
        }
    }

}

private struct MobileRemoteHeader: View {
    @ObservedObject var store: MobileOpenCodexStore
    @Binding var importsPresented: Bool
    @Binding var showsActivity: Bool

    var body: some View {
        HStack {
            Button { store.showsConnection = true } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(Color.secondary.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Connection")

            Spacer()
            Text("OpenFish")
                .font(.system(size: 17, weight: .semibold))
            if store.isDemoMode {
                Text("DEMO")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Color.secondary.opacity(0.13), in: Capsule())
            }
            Spacer()

            Button { showsActivity.toggle() } label: {
                Image(systemName: showsActivity ? "bell.fill" : "bell")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(showsActivity ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsActivity ? "Show projects" : "Show activity")

            Menu {
                Button {
                    Task { await store.browseHostDirectory() }
                } label: {
                    Label("Add project", systemImage: "folder.badge.plus")
                }
                .disabled(!store.canStartNewTask)
                Button { importsPresented = true } label: {
                    Label("Import tasks", systemImage: "square.and.arrow.down")
                }
                .disabled(!store.canStartNewTask)
                Button { store.showsConnection = true } label: {
                    Label("Connection settings", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(Color.secondary.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More task options")
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .frame(height: 36)
    }
}

private enum MobileActivityPeriod: String, CaseIterable, Identifiable {
    case priority = "Priority"
    case today = "Today"
    case yesterday = "Yesterday"
    case previousSevenDays = "Previous 7 Days"
    case older = "Earlier"
    var id: String { rawValue }
}

private struct MobileActivityList: View {
    @ObservedObject var store: MobileOpenCodexStore
    let query: String

    var body: some View {
        ForEach(MobileActivityPeriod.allCases) { period in
            let rows = sessions(for: period)
            if !rows.isEmpty {
                MobileActivityPeriodSection(store: store, period: period, sessions: rows)
            }
        }
    }

    private func sessions(for period: MobileActivityPeriod) -> [MobileSession] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = store.visibleSessionsByRecency.filter { session in
            normalized.isEmpty
                || store.title(for: session).lowercased().contains(normalized)
                || (session.cwd?.lowercased().contains(normalized) ?? false)
        }
        let priorityIDs = Set(all.filter { store.hasAttention($0.sessionId) }.map(\.sessionId))
        if period == .priority { return all.filter { priorityIDs.contains($0.sessionId) } }
        return all.filter { !priorityIDs.contains($0.sessionId) && mobileActivityPeriod($0.updatedAt) == period }
    }
}

private struct MobileActivityPeriodSection: View {
    @ObservedObject var store: MobileOpenCodexStore
    let period: MobileActivityPeriod
    let sessions: [MobileSession]
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { isExpanded.toggle() } label: {
                HStack {
                    Text(period.rawValue)
                    Spacer()
                    Text("\(sessions.count)").foregroundStyle(.tertiary)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                ForEach(sessions) { session in
                    NavigationLink {
                        MobileConversationView(store: store, sessionId: session.sessionId)
                            .onAppear { store.markRead(session) }
                    } label: {
                        MobileSessionRow(store: store, session: session, showsWorkspace: true)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private func mobileActivityPeriod(_ milliseconds: Double) -> MobileActivityPeriod {
    let calendar = Calendar.autoupdatingCurrent
    let date = Date(timeIntervalSince1970: milliseconds / 1_000)
    if calendar.isDateInToday(date) { return .today }
    if calendar.isDateInYesterday(date) { return .yesterday }
    if let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: Date()), date >= sevenDaysAgo {
        return .previousSevenDays
    }
    return .older
}

private struct MobileComputerFilterBar: View {
    @ObservedObject var store: MobileOpenCodexStore
    @Binding var selection: String

    private var computerName: String {
        store.profile.baseURL.host ?? store.profile.baseURL.absoluteString
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                MobileComputerChip(title: "All", selected: selection == "all") {
                    selection = "all"
                }
                MobileComputerChip(
                    title: computerName,
                    selected: selection == "computer",
                    statusColor: store.connectionState == .connected ? .green : .orange,
                    systemImage: "desktopcomputer"
                ) {
                    selection = "computer"
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}

private struct MobileComputerChip: View {
    let title: String
    let selected: Bool
    var statusColor: Color?
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let statusColor {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                }
                if let systemImage {
                    Image(systemName: systemImage).font(.caption)
                }
                Text(title).lineLimit(1)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(selected ? Color(uiColor: .systemBackground) : .primary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(
                selected ? Color.primary : Color.secondary.opacity(0.13),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }
}

private struct MobileRemoteBottomBar: View {
    @ObservedObject var store: MobileOpenCodexStore
    @Binding var searchText: String
    let workspaceID: String?

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search tasks", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .font(.system(size: 15))
            .padding(.horizontal, 13)
            .frame(height: 40)
            .background(Color.secondary.opacity(0.12), in: Capsule())

            Button {
                Task { await store.startVoiceConversation() }
            } label: {
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(Color(uiColor: .label), in: Circle())
                    .foregroundStyle(Color(uiColor: .systemBackground))
            }
            .accessibilityLabel("Start voice conversation")
            .buttonStyle(.plain)
            .disabled(!store.canStartNewTask)

            NavigationLink {
                MobileConversationView(store: store, sessionId: nil, newWorkspaceId: workspaceID)
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(Color(uiColor: .label), in: Circle())
                    .foregroundStyle(Color(uiColor: .systemBackground))
            }
            .accessibilityLabel("New task")
            .buttonStyle(.plain)
            .disabled(!store.canStartNewTask)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .top) { Divider() }
    }
}

private struct MobileSessionRow: View {
    @ObservedObject var store: MobileOpenCodexStore
    let session: MobileSession
    var showsWorkspace = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text(store.title(for: session))
                    .lineLimit(1)
                    .font(.system(size: 15, weight: store.isUnread(session) ? .medium : .regular))
                if showsWorkspace {
                    Text(store.workspaceTitle(for: session))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if session.running {
                ProgressView().controlSize(.small)
            }
        }
        .foregroundStyle(.primary)
        .padding(.leading, 32)
        .padding(.trailing, 16)
        .frame(height: showsWorkspace ? 50 : 42)
        .contentShape(Rectangle())
    }
}

private struct MobileWorkspaceHeader: View {
    let title: String
    let taskCount: Int
    let expanded: Bool
    var systemImage = "folder"

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(taskCount, format: .number)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .contentShape(Rectangle())
    }
}

private struct MobileConversationView: View {
    @ObservedObject var store: MobileOpenCodexStore
    let sessionId: String?
    var newWorkspaceId: String? = nil
    @State private var renaming = false
    @State private var renameText = ""
    @State private var dangerousPermission: MobilePermissionOption?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if store.canLoadOlder || store.isLoadingOlder {
                        Button {
                            Task { await store.loadOlder() }
                        } label: {
                            HStack {
                                Spacer()
                                if store.isLoadingOlder { ProgressView().controlSize(.small) }
                                else { Text("Load earlier messages").font(.caption) }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(store.isLoadingOlder)
                    }

                    if store.conversation.isEmpty {
                        VStack(spacing: 8) {
                            Text("Start a task")
                                .font(.title3.weight(.semibold))
                            Text(workspaceExplanation)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                        .padding(.top, 120)
                    }

                    MobileConversationTimeline(
                        store: store,
                        sessionId: store.conversationSessionId ?? sessionId ?? ""
                    )
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .onChange(of: store.conversation.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if let goal = store.currentGoal?.goal {
                    MobileGoalBar(store: store, goal: goal)
                }
                MobileComposer(store: store, isNewTask: sessionId == nil)
            }
            .background(.ultraThinMaterial)
        }
        .navigationTitle(store.activeSubagent?.label ?? store.selectedSession.map(store.title) ?? "New task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task { await store.startVoiceConversation() }
                } label: {
                    Image(systemName: "waveform.circle")
                }
                .accessibilityLabel("Start voice conversation")
                if store.conversationRunning {
                    Button { Task { await store.cancel() } } label: { Image(systemName: "stop.fill") }
                }
                if store.activeSubagent != nil {
                    Button { store.closeSubagent() } label: { Image(systemName: "arrow.uturn.backward") }
                        .accessibilityLabel("Return to parent task")
                }
                if store.selectedSession != nil {
                    Button { store.showsTaskInspector = true } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .accessibilityLabel("Task details")
                }
                Menu {
                    MobileConversationOptionsMenu(
                        store: store,
                        dangerousPermission: $dangerousPermission,
                        renameText: $renameText,
                        renaming: $renaming
                    )
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("More task actions")
            }
        }
        .task {
            if let sessionId { await store.select(sessionId) }
            else { store.newTask(in: newWorkspaceId) }
        }
        .sheet(isPresented: $store.showsTaskInspector) {
            MobileTaskInspectorView(store: store)
        }
        .alert("Rename task", isPresented: $renaming) {
            TextField("Task name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { Task { await store.renameCurrent(renameText) } }
        }
        .alert("Enable Full Access?", isPresented: Binding(
            get: { dangerousPermission != nil },
            set: { if !$0 { dangerousPermission = nil } }
        )) {
            Button("Cancel", role: .cancel) { dangerousPermission = nil }
            Button("Enable", role: .destructive) {
                guard let option = dangerousPermission else { return }
                dangerousPermission = nil
                Task { await store.choosePermission(option) }
            }
        } message: {
            Text(dangerousPermission?.description ?? "OpenFish may run commands and change files outside the workspace sandbox.")
        }
    }

    private var workspaceExplanation: String {
        if let workspace = store.selectedWorkspace {
            return "OpenFish will work in \(workspace.title) on your connected computer."
        }
        return "OpenFish will use its managed No Project workspace on your connected computer."
    }
}

private struct MobileGoalBar: View {
    @ObservedObject var store: MobileOpenCodexStore
    let goal: MobileGoalView

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "scope")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(goal.objective)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text("Goal · \(goal.phase.capitalized)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Menu {
                if goal.phase == "active" {
                    Button("Pause") { Task { await store.mutateGoal("pause") } }
                } else if goal.phase == "paused" || goal.phase == "blocked" {
                    Button("Resume") { Task { await store.mutateGoal("resume") } }
                }
                if goal.phase != "complete" {
                    Button("Mark complete") { Task { await store.mutateGoal("complete") } }
                }
                Button("Clear", role: .destructive) { Task { await store.mutateGoal("clear") } }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 30, height: 30)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.accentColor.opacity(0.08))
        .overlay(alignment: .top) { Divider() }
    }
}

private struct MobileConversationTimeline: View {
    @ObservedObject var store: MobileOpenCodexStore
    let sessionId: String

    var body: some View {
        ForEach(store.conversation) { item in
            MobileConversationRow(
                item: item,
                sessionId: sessionId,
                store: store,
                voice: store.voice
            )
            .id(item.id)
        }
        ForEach(store.selectedApprovals) { approval in
            MobileApprovalCard(store: store, approval: approval)
        }
        ForEach(store.selectedQuestions) { question in
            MobileQuestionCard(store: store, pending: question)
        }
        if !store.selectedQueue.isEmpty {
            MobileQueueCard(store: store, items: store.selectedQueue)
        }
        if store.conversationRunning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("OpenFish is working…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct MobileConversationOptionsMenu: View {
    @ObservedObject var store: MobileOpenCodexStore
    @Binding var dangerousPermission: MobilePermissionOption?
    @Binding var renameText: String
    @Binding var renaming: Bool

    var body: some View {
        MobileModelSelectionMenu(store: store)
        MobileReasoningSelectionMenu(store: store)
        MobileHarnessConfigMenu(store: store)
        if store.selectedSession == nil {
            Menu("Project") {
                Button("No Project") { store.newTask(in: nil) }
                ForEach(store.orderedWorkspaces) { workspace in
                    Button {
                        store.newTask(in: workspace.workspaceId)
                    } label: {
                        if store.selectedWorkspaceId == workspace.workspaceId {
                            Label(workspace.title, systemImage: "checkmark")
                        } else {
                            Text(workspace.title)
                        }
                    }
                }
            }
        }
        if let permissions = store.currentPermissions {
            Menu("Access") {
                ForEach(permissions.options.filter { $0.value != "custom" }) { option in
                    MobilePermissionSelectionButton(
                        store: store,
                        option: option,
                        selected: option.value == permissions.currentValue,
                        dangerousPermission: $dangerousPermission
                    )
                }
            }
        }
        if store.canChooseHarness {
            Menu("Harness") {
                ForEach(store.harnesses.filter {
                    $0.installation.status == "builtin" || $0.installation.status == "installed"
                }) { harness in
                    Button {
                        Task { await store.chooseHarness(harness) }
                    } label: {
                        if harness.id == store.currentHarnessId {
                            Label(mobileHarnessDisplayName(harness, among: store.harnesses), systemImage: "checkmark")
                        } else {
                            Text(mobileHarnessDisplayName(harness, among: store.harnesses))
                        }
                    }
                }
            }
        }
        if store.canChooseAgentPreset, let catalog = store.agentPresets {
            Menu("Agent") {
                ForEach(catalog.presets) { preset in
                    Button(preset.name ?? preset.id) { Task { await store.chooseAgentPreset(preset) } }
                        .disabled(preset.broken != nil)
                }
            }
        }
        Divider()
        if let selected = store.selectedSession {
            Button("Rename task") {
                renameText = store.title(for: selected)
                renaming = true
            }
            Button("Fork task") { Task { await store.forkCurrent() } }
                .disabled(!store.harnessCan("session.fork"))
            Button("Archive task") { Task { await store.setArchived(selected.sessionId, archived: true) } }
        }
        Button("Prepare export") { Task { await store.prepareExport() } }
        if let url = store.exportURL {
            ShareLink(item: url) { Label("Share export", systemImage: "square.and.arrow.up") }
        }
        Picker("Prompt behavior", selection: $store.promptMode) {
            Text("Queue").tag("queue")
            Text("Steer").tag("steer")
        }
    }
}

private struct MobilePermissionSelectionButton: View {
    @ObservedObject var store: MobileOpenCodexStore
    let option: MobilePermissionOption
    let selected: Bool
    @Binding var dangerousPermission: MobilePermissionOption?

    var body: some View {
        Button {
            if option.value == "danger-full-access" { dangerousPermission = option }
            else { Task { await store.choosePermission(option) } }
        } label: {
            if selected { Label(option.name, systemImage: "checkmark") }
            else { Text(option.name) }
        }
    }
}

private struct MobileModelSelectionMenu: View {
    @ObservedObject var store: MobileOpenCodexStore

    private func providerName(_ model: MobileCatalogModel) -> String {
        model.providerName ?? "Provider not declared"
    }

    var body: some View {
        if let models = store.sessionModels, !models.groups.isEmpty {
            Menu(store.currentModelName) {
                ForEach(models.groups) { group in
                    Section(group.name) {
                        if group.id == "harness" {
                            let providers = Dictionary(grouping: group.models, by: providerName)
                            ForEach(providers.keys.sorted(), id: \.self) { provider in
                                Menu(provider) {
                                    ForEach(providers[provider] ?? []) { model in
                                        MobileModelSelectionRow(store: store, groupID: group.id, model: model)
                                    }
                                }
                            }
                        } else {
                            ForEach(group.models) { model in
                                MobileModelSelectionRow(store: store, groupID: group.id, model: model)
                            }
                        }
                    }
                }
            }
        } else {
            Menu(store.isLoadingSessionModels ? "Checking models…" : "Models unavailable") {
                if store.isLoadingSessionModels {
                    Text("Waiting for the active Harness to advertise its model catalog.")
                } else if let error = store.sessionModelsError {
                    Text(error)
                } else {
                    Text("This Harness has not advertised model choices yet.")
                }
                Button("Refresh") { Task { await store.refreshCurrentModels() } }
            }
        }
    }
}

private struct MobileModelSelectionRow: View {
    @ObservedObject var store: MobileOpenCodexStore
    let groupID: String
    let model: MobileCatalogModel

    var body: some View {
        Button {
            Task {
                await store.chooseModel(
                    provider: groupID,
                    model: model,
                    effort: model.reasoning?.defaultEffort
                )
            }
        } label: {
            if store.sessionModels?.current.provider == groupID,
               store.sessionModels?.current.model == model.id {
                Label(model.name, systemImage: "checkmark")
            } else {
                Text(model.name)
            }
        }
        .disabled(store.isChangingModel || store.isChangingHarnessConfig)
    }
}

private struct MobileModelChoice: Identifiable {
    let groupID: String
    let providerName: String
    let model: MobileCatalogModel
    var id: String { "\(groupID):\(model.id)" }
}

private struct MobileModelSelectionSheet: View {
    @ObservedObject var store: MobileOpenCodexStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var attemptedLoad = false

    private var choices: [MobileModelChoice] {
        (store.sessionModels?.groups ?? []).flatMap { group in
            group.models.map { model in
                let provider = group.id == "harness"
                    ? (model.providerName ?? "Provider not declared")
                    : group.name
                return MobileModelChoice(groupID: group.id, providerName: provider, model: model)
            }
        }
    }

    private var filtered: [MobileModelChoice] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return choices }
        return choices.filter {
            $0.model.name.localizedCaseInsensitiveContains(needle)
                || $0.model.id.localizedCaseInsensitiveContains(needle)
                || $0.providerName.localizedCaseInsensitiveContains(needle)
        }
    }

    private var grouped: [(provider: String, choices: [MobileModelChoice])] {
        Dictionary(grouping: filtered, by: \.providerName)
            .map { (provider: $0.key, choices: $0.value) }
            .sorted { $0.provider.localizedStandardCompare($1.provider) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                if (!attemptedLoad || store.isLoadingSessionModels), choices.isEmpty {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Loading model choices…")
                                Text("Waiting for the active Harness to advertise its catalog.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else if let error = store.sessionModelsError, choices.isEmpty {
                    ContentUnavailableView {
                        Label("Could not load models", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try again") {
                            attemptedLoad = false
                            Task {
                                await store.refreshCurrentModels()
                                attemptedLoad = true
                            }
                        }
                    }
                } else if choices.isEmpty {
                    ContentUnavailableView {
                        Label("No models advertised", systemImage: "shippingbox")
                    } description: {
                        Text("This Harness has not provided model choices for the current task yet.")
                    } actions: {
                        Button("Refresh") {
                            attemptedLoad = false
                            Task {
                                await store.refreshCurrentModels()
                                attemptedLoad = true
                            }
                        }
                    }
                } else if grouped.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ForEach(grouped, id: \.provider) { group in
                        Section(group.provider) {
                            ForEach(group.choices) { choice in
                                Button {
                                    Task {
                                        let selected = await store.chooseModel(
                                            provider: choice.groupID,
                                            model: choice.model,
                                            effort: choice.model.reasoning?.defaultEffort
                                        )
                                        if selected { dismiss() }
                                    }
                                } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: isSelected(choice) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(isSelected(choice) ? Color.accentColor : Color.secondary.opacity(0.45))
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(choice.model.name).foregroundStyle(.primary)
                                            Text(choice.model.id).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                    }
                                }
                                .disabled(store.isChangingModel || store.isChangingHarnessConfig)
                            }
                        }
                    }
                    Section {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(store.currentHarness?.modelConfiguration?.owner == "harness"
                                ? "This list is advertised by the Harness. A listed model can still require provider credentials configured inside that Harness."
                                : "This list comes from the connected Mac Host and reflects its current model routes.")
                            if let account = store.sessionModels?.account {
                                Text("Account · \(account.label) · \(account.billing.replacingOccurrences(of: "-", with: " ").capitalized)")
                                    .fontWeight(.medium)
                                Text(account.detail)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Choose a model")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Model or provider")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .task {
            if store.sessionModels == nil {
                await store.refreshCurrentModels()
            }
            attemptedLoad = true
        }
    }

    private func isSelected(_ choice: MobileModelChoice) -> Bool {
        store.sessionModels?.current.provider == choice.groupID
            && store.sessionModels?.current.model == choice.model.id
    }
}

private struct MobileReasoningSelectionMenu: View {
    @ObservedObject var store: MobileOpenCodexStore

    var body: some View {
        Menu(store.currentReasoningName ?? "Reasoning · Auto") {
            if store.currentReasoningOptions.isEmpty {
                Text("This Harness and model did not advertise a reasoning control.")
                Button("Refresh") { Task { await store.refreshCurrentModels() } }
            } else {
                ForEach(store.currentReasoningOptions) { effort in
                    Button {
                        Task { await store.chooseReasoningEffort(effort.id) }
                    } label: {
                        if store.sessionModels?.current.reasoningEffort == effort.id {
                            Label(effort.name, systemImage: "checkmark")
                        } else {
                            Text(effort.name)
                        }
                    }
                }
            }
        }
        .disabled(store.isChangingModel || store.isChangingHarnessConfig)
    }
}

private struct MobileHarnessConfigMenu: View {
    @ObservedObject var store: MobileOpenCodexStore

    private var options: [MobileHarnessConfigOption] {
        (store.sessionModels?.harnessOptions ?? []).filter {
            $0.category != "model" && $0.category != "thought_level"
        }
    }

    var body: some View {
        if !options.isEmpty {
            Menu {
                ForEach(options) { option in
                    if option.type == "boolean" {
                        let enabled = option.currentValue == .bool(true)
                        Button {
                            Task { await store.chooseHarnessConfig(option, value: .bool(!enabled)) }
                        } label: {
                            if enabled { Label(option.name, systemImage: "checkmark") }
                            else { Text(option.name) }
                        }
                    } else {
                        Menu(option.name) {
                            ForEach(option.values) { value in
                                Button {
                                    Task { await store.chooseHarnessConfig(option, value: .string(value.id)) }
                                } label: {
                                    if option.currentValue == .string(value.id) {
                                        Label(value.name, systemImage: "checkmark")
                                    } else {
                                        Text(value.name)
                                    }
                                }
                            }
                        }
                    }
                }
            } label: {
                Label("Harness options", systemImage: "slider.horizontal.3")
            }
            .disabled(store.isChangingHarnessConfig || store.isChangingModel)
        }
    }
}

private struct MobileTaskInspectorView: View {
    @ObservedObject var store: MobileOpenCodexStore
    @Environment(\.dismiss) private var dismiss
    @State private var creatingGoal = false
    @State private var goalObjective = ""
    @State private var goalRounds = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Run") {
                    LabeledContent("Status", value: store.conversationRunning ? "Working" : "Ready")
                    LabeledContent(
                        "Harness",
                        value: store.harnesses.first(where: { $0.id == store.currentHarnessId })?.name
                            ?? store.currentHarnessId
                    )
                    LabeledContent("Model", value: store.currentModelName)
                    LabeledContent(
                        "Access",
                        value: store.currentPermissions?.options.first(where: {
                            $0.value == store.currentPermissions?.currentValue
                        })?.name ?? "Harness default"
                    )
                    LabeledContent("Agent", value: store.selectedSession?.agentPreset ?? "Composition default")
                }

                Section("Goal") {
                    if let goal = store.currentGoal?.goal {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(goal.objective).font(.body.weight(.medium))
                            HStack {
                                Text(goal.phase.capitalized)
                                if let rounds = store.currentGoal?.roundsStarted {
                                    Text("· \(rounds) round\(rounds == 1 ? "" : "s")")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        if goal.phase == "active" {
                            Button("Pause goal") { Task { await store.mutateGoal("pause") } }
                        } else if goal.phase == "paused" || goal.phase == "blocked" {
                            Button("Resume goal") { Task { await store.mutateGoal("resume") } }
                        }
                        if goal.phase != "complete" {
                            Button("Mark complete") { Task { await store.mutateGoal("complete") } }
                        }
                        Button("Clear goal", role: .destructive) {
                            Task { await store.mutateGoal("clear") }
                        }
                    } else {
                        Text("No persistent goal is attached to this task.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Create goal") {
                            goalObjective = ""
                            goalRounds = ""
                            creatingGoal = true
                        }
                    }
                }

                Section("Plan") {
                    Toggle("Plan mode", isOn: Binding(
                        get: { store.currentPlan?.active == true },
                        set: { enabled in Task { await store.setPlanEnabled(enabled) } }
                    ))
                    if store.currentPlan?.pending == true {
                        Label("The Host is applying the change", systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let todos = store.currentTodos, todos != .null {
                    Section("Checklist") {
                        Text(todos.prettyJSON)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }

                if !store.subagents.isEmpty {
                    Section("Subagents") {
                        ForEach(store.subagents) { child in
                            Button {
                                Task {
                                    await store.openSubagent(child)
                                    if store.activeSubagent != nil { dismiss() }
                                }
                            } label: {
                                HStack(spacing: 10) {
                                Circle()
                                    .fill(child.activity == "running" ? Color.green : Color.secondary.opacity(0.35))
                                    .frame(width: 7, height: 7)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(child.label ?? child.id).lineLimit(1)
                                    Text(child.reason ?? child.mode ?? child.kind)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                    if child.hasChildren { Image(systemName: "point.3.connected.trianglepath.dotted") }
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(child.kind != "child" || child.mode == nil)
                        }
                    }
                }

                Section("Capabilities") {
                    NavigationLink {
                        MobileSkillsView(store: store, dismissInspector: { dismiss() })
                    } label: {
                        LabeledContent("Skills", value: "\(store.skills.count)")
                    }
                    NavigationLink {
                        MobileCommandsView(store: store, dismissInspector: { dismiss() })
                    } label: {
                        LabeledContent("Commands", value: "\(store.visibleCommands.count)")
                    }
                }

                Section("Project") {
                    LabeledContent("Name", value: store.selectedWorkspace?.title ?? "No Project")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Path").font(.caption).foregroundStyle(.secondary)
                        Text(store.selectedSession?.cwd ?? store.selectedWorkspace?.path ?? "—")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("OpenFish task ID").font(.caption).foregroundStyle(.secondary)
                        Text(store.selectedSessionId ?? "—")
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Task details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("Create goal", isPresented: $creatingGoal) {
                TextField("Objective", text: $goalObjective, axis: .vertical)
                TextField("Maximum rounds (optional)", text: $goalRounds)
                    .keyboardType(.numberPad)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    let rounds = Int(goalRounds).flatMap { $0 > 0 ? $0 : nil }
                    Task { await store.createGoal(objective: goalObjective, maxRounds: rounds) }
                }
                .disabled(goalObjective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct MobileSkillsView: View {
    @ObservedObject var store: MobileOpenCodexStore
    let dismissInspector: () -> Void

    var body: some View {
        List(store.skills) { skill in
            Button {
                store.draft = "/\(skill.name) "
                dismissInspector()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(skill.name).font(.body.weight(.medium))
                        if skill.modelInvocable {
                            Text("MODEL")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text(skill.description).font(.caption).foregroundStyle(.secondary)
                    if let whenToUse = skill.whenToUse {
                        Text(whenToUse).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("Skills")
        .overlay {
            if store.skills.isEmpty {
                ContentUnavailableView("No skills", systemImage: "wand.and.stars")
            }
        }
    }
}

private struct MobileCommandsView: View {
    @ObservedObject var store: MobileOpenCodexStore
    let dismissInspector: () -> Void

    var body: some View {
        List(Array(store.visibleCommands.enumerated()), id: \.offset) { _, command in
            if let name = command["name"]?.stringValue {
                Button {
                    store.draft = "/\(name) "
                    dismissInspector()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("/\(name)").font(.body.monospaced().weight(.medium))
                        if let description = command["description"]?.stringValue {
                            Text(description).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Commands")
        .overlay {
            if store.visibleCommands.isEmpty {
                ContentUnavailableView("No commands", systemImage: "command")
            }
        }
    }
}

private struct MobileConversationRow: View {
    let item: MobileConversationItem
    let sessionId: String
    @ObservedObject var store: MobileOpenCodexStore
    @ObservedObject var voice: MobileLocalVoice
    @State private var expanded = false

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 52)
                VStack(alignment: .leading, spacing: 8) {
                    MobileConversationAttachments(item: item, sessionId: sessionId, store: store)
                    if !item.text.isEmpty { MobileMarkdownText(item.text) }
                }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.16), in: RoundedRectangle(cornerRadius: 18))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                MobileConversationAttachments(item: item, sessionId: sessionId, store: store)
                if let detail = item.detail {
                    DisclosureGroup("Reasoning") {
                        MobileMarkdownText(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                    }
                }
                if !item.text.isEmpty { MobileMarkdownText(item.text) }
                if !item.text.isEmpty || item.isRunning {
                    HStack(spacing: 16) {
                        if !item.text.isEmpty {
                            Button {
                                voice.isSpeaking ? voice.stopSpeaking() : voice.speak(item.text)
                            } label: {
                                Image(systemName: voice.isSpeaking ? "speaker.slash" : "speaker.wave.2")
                            }
                            .disabled(item.isRunning)
                        }
                        if item.isRunning {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        case .activity:
            DisclosureGroup(isExpanded: $expanded) {
                if item.sections.isEmpty, !item.isRunning {
                    Text(item.failed ? "No error details were returned." : "No additional output.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(item.sections) { section in
                            MobileConversationSectionView(section: section)
                        }
                    }
                    .padding(.top, 10)
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: item.failed ? "xmark.circle" : item.isRunning ? "gearshape.2" : "checkmark")
                        .foregroundStyle(item.failed ? Color.red : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title ?? "Tool").font(.subheadline)
                        if let detail = item.detail { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer()
                    if item.isRunning { ProgressView().controlSize(.mini) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        case .notice:
            Label {
                VStack(alignment: .leading) {
                    if let title = item.title { Text(title).font(.caption.weight(.semibold)) }
                    MobileMarkdownText(item.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: item.failed ? "exclamationmark.triangle" : "info.circle")
            }
        }
    }
}

private struct MobileMarkdownText: View {
    let source: String

    init(_ source: String) {
        self.source = source
    }

    var body: some View {
        Markdown(source)
        .markdownTheme(.gitHub)
        .font(.system(size: 16))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MobileConversationSectionView: View {
    let section: MobileConversationSection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = section.title {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            switch section.style {
            case .markdown:
                MobileMarkdownText(section.text)
            case .code(let language):
                MobileCodeBlock(text: section.text, language: language, isDiff: false)
            case .diff:
                MobileCodeBlock(text: section.text, language: "diff", isDiff: true)
            }
        }
    }
}

private struct MobileCodeBlock: View {
    let text: String
    let language: String?
    let isDiff: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.uppercased() ?? "TEXT")
                Spacer()
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy content")
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 30)

            Divider()

            ScrollView(.horizontal) {
                if isDiff {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                            Text(String(line))
                                .foregroundStyle(diffColor(for: line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                } else {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                }
            }
        }
        .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 0.5)
        }
    }

    private func diffColor(for line: Substring) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red }
        return .primary
    }
}

private struct MobileConversationAttachments: View {
    let item: MobileConversationItem
    let sessionId: String
    @ObservedObject var store: MobileOpenCodexStore

    var body: some View {
        ForEach(item.attachments) { attachment in
            Group {
                if let data = store.cachedAttachment(sessionId: sessionId, attachmentId: attachment.attachmentId),
                   let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(attachment.name ?? "Loading image…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 80)
                }
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .task(id: attachment.attachmentId) {
                await store.loadAttachment(sessionId: sessionId, attachmentId: attachment.attachmentId)
            }
        }
    }
}

private struct MobileApprovalCard: View {
    @ObservedObject var store: MobileOpenCodexStore
    let approval: MobileApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permission requested")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Do you want to allow OpenFish to run this action?")
                .font(.subheadline.weight(.medium))
            Text(approval.toolName)
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            if let reason = approval.reason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            Button("Approve") { Task { await store.answer(approval, allow: true) } }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            Divider()
            HStack {
                Spacer()
                Button("Deny", role: .destructive) { Task { await store.answer(approval, allow: false) } }
                    .buttonStyle(.borderless)
            }
        }
        .padding(16)
        .background(Color.secondary.opacity(0.11), in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        }
    }
}

private struct MobileQueueCard: View {
    @ObservedObject var store: MobileOpenCodexStore
    let items: [MobileQueuedItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Queued work", systemImage: "text.line.first.and.arrowtriangle.forward")
                .font(.subheadline.weight(.semibold))
            ForEach(items) { item in
                MobileQueueRow(store: store, item: item)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct MobileQueueRow: View {
    @ObservedObject var store: MobileOpenCodexStore
    let item: MobileQueuedItem
    @State private var editing = false
    @State private var replacement = ""

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.placement == "steering" ? "Steering" : "Next")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(item.text.isEmpty ? "Pending message" : item.text)
                    .font(.caption)
                    .lineLimit(3)
            }
            Spacer()
            if item.placement == "queued" {
                Button("Steer") { Task { await store.mutateQueue(item, action: "steer") } }
                    .buttonStyle(.borderless)
            }
            Button {
                replacement = item.text
                editing = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Edit queued message")
            Button(role: .destructive) {
                Task { await store.mutateQueue(item, action: "remove") }
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove queued message")
        }
        .alert("Edit queued message", isPresented: $editing) {
            TextField("Message", text: $replacement)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                Task { await store.mutateQueue(item, action: "edit", replacement: replacement) }
            }
            .disabled(replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

private struct MobileQuestionCard: View {
    @ObservedObject var store: MobileOpenCodexStore
    let pending: MobilePendingQuestion
    @State private var selections: [String: Set<String>] = [:]
    @State private var custom: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("OpenFish asks", systemImage: "questionmark.bubble")
                .font(.subheadline.weight(.semibold))
            ForEach(pending.questions) { question in
                VStack(alignment: .leading, spacing: 8) {
                Text(question.question)
                if let detail = question.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                ForEach(question.options ?? []) { option in
                    Button {
                        var selected = selections[question.id] ?? []
                        if question.multiSelect == true {
                            if selected.contains(option.label) { selected.remove(option.label) }
                            else { selected.insert(option.label) }
                        } else {
                            selected = [option.label]
                        }
                        selections[question.id] = selected
                    } label: {
                        HStack {
                            Image(systemName: selections[question.id]?.contains(option.label) == true
                                ? (question.multiSelect == true ? "checkmark.square.fill" : "checkmark.circle.fill")
                                : (question.multiSelect == true ? "square" : "circle"))
                            VStack(alignment: .leading) {
                                Text(option.label)
                                if let detail = option.description { Text(detail).font(.caption2).foregroundStyle(.secondary) }
                            }
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(option.label)
                }
                TextField("Type another answer", text: Binding(
                    get: { custom[question.id] ?? "" },
                    set: { custom[question.id] = $0 }
                ), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                }
            }
            Button("Submit answers") {
                let answers = pending.questions.map { question in
                    let value = custom[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return MobileQuestionAnswer(
                        id: question.id,
                        selected: Array(selections[question.id] ?? []).sorted(),
                        custom: value?.isEmpty == false ? value : nil
                    )
                }
                Task { await store.answer(pending, answers: answers) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSubmit)
        }
        .padding(14)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private var canSubmit: Bool {
        pending.questions.allSatisfy { question in
            selections[question.id]?.isEmpty == false
                || custom[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }
}

private struct MobileComposer: View {
    @ObservedObject var store: MobileOpenCodexStore
    @ObservedObject private var voice: MobileLocalVoice
    let isNewTask: Bool
    @Environment(\.openURL) private var openURL
    @State private var photoItems: [PhotosPickerItem] = []

    init(store: MobileOpenCodexStore, isNewTask: Bool) {
        self.store = store
        self.isNewTask = isNewTask
        voice = store.voice
    }

    var body: some View {
        VStack(spacing: 8) {
            if let error = voice.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .font(.caption.weight(.semibold))
                }
                .padding(10)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
            if !store.pendingImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(store.pendingImages) { image in
                            HStack {
                                Image(systemName: "photo")
                                Text(image.name).lineLimit(1)
                                Button { store.removeImage(image.id) } label: { Image(systemName: "xmark.circle.fill") }
                            }
                            .font(.caption)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                    }
                }
                if !store.canAttachImages {
                    Label("The active Harness cannot receive images. Remove them or switch Harness before sending.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $photoItems, maxSelectionCount: 8, matching: .images) {
                    Image(systemName: "plus")
                        .frame(width: 32, height: 36)
                }
                .disabled(!store.canAttachImages)
                .opacity(store.canAttachImages ? 1 : 0.35)
                TextField("Tell OpenFish what to do", text: $store.draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(.vertical, 8)
                Button { Task { await store.toggleDictation() } } label: {
                    Group {
                        if voice.isStarting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: voice.isListening ? "waveform.circle.fill" : "mic")
                                .foregroundStyle(voice.isListening ? Color.red : Color.primary)
                        }
                    }
                    .frame(width: 30, height: 36)
                }
                .disabled(voice.isStarting)
                if store.canSend || store.isSending {
                    Button { Task { await store.send() } } label: {
                        Group {
                            if store.isSending { ProgressView().tint(Color(uiColor: .systemBackground)) }
                            else { Image(systemName: "arrow.up").fontWeight(.bold) }
                        }
                        .frame(width: 32, height: 32)
                        .background(Color.primary, in: Circle())
                        .foregroundStyle(Color(uiColor: .systemBackground))
                    }
                    .disabled(!store.canSend)
                    .accessibilityLabel(store.isSending ? "Sending" : "Send message")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
            }
            MobileComposerControls(store: store, isNewTask: isNewTask)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .onChange(of: photoItems) { _, items in
            Task {
                for (index, item) in items.enumerated() {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                    let mediaType = imageMediaType(data) ?? "image/jpeg"
                    store.addImage(data: data, name: "Photo \(index + 1)", mediaType: mediaType)
                }
                photoItems = []
            }
        }
    }
}

private struct MobileComposerControls: View {
    @ObservedObject var store: MobileOpenCodexStore
    let isNewTask: Bool
    @State private var dangerousPermission: MobilePermissionOption?
    @State private var showingModelPicker = false
    @State private var showingWorkspacePicker = false
    @State private var authSetup: MobileHarnessAuthSetup?

    private var installedHarnesses: [MobileHarness] {
        store.harnesses.filter {
            $0.installation.status == "builtin" || $0.installation.status == "installed"
        }
    }

    private var catalogHarnesses: [MobileHarness] {
        store.harnesses.filter {
            $0.installation.status != "builtin" && $0.installation.status != "installed"
        }
    }

    private var accountLabel: String {
        if let runtime = store.sessionModels?.account { return runtime.label }
        guard let harness = store.currentHarness else { return "Account unavailable" }
        if let selected = harness.auth.selectedMethod,
           let method = harness.auth.methods.first(where: { $0.id == selected }) {
            return method.account?.label ?? method.name
        }
        return harness.account?.label
            ?? (harness.auth.status == "not-required" ? "Billing not declared" : "Sign-in required")
    }

    @ViewBuilder
    private func harnessButton(_ harness: MobileHarness) -> some View {
        Button {
            if mobileHarnessRequiresMacSetup(harness) {
                store.explainRequiredMacSetup(for: harness)
            } else if harness.auth.status != "not-required" && harness.auth.status != "configured" {
                authSetup = MobileHarnessAuthSetup(harness: harness)
            } else {
                Task { await store.chooseHarness(harness) }
            }
        } label: {
            if harness.id == store.currentHarnessId {
                Label(mobileHarnessDisplayName(harness, among: store.harnesses), systemImage: "checkmark")
            } else if mobileHarnessRequiresMacSetup(harness) {
                Label("\(mobileHarnessDisplayName(harness, among: store.harnesses)) · Set up on Mac", systemImage: "macbook")
            } else {
                Text(mobileHarnessDisplayName(harness, among: store.harnesses))
            }
        }
        .disabled((!harness.available && !mobileHarnessRequiresMacSetup(harness)) || store.harnessOperationId != nil)
    }

    var body: some View {
        HStack(spacing: 10) {
            if isNewTask || store.canChooseWorkspace {
                Button { showingWorkspacePicker = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                        Text(store.selectedWorkspace?.title ?? "No Project")
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                    .frame(width: 96, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(3)
                .accessibilityIdentifier("OpenFish.iOS.WorkspacePicker")
                .buttonStyle(.plain)
            }

            Menu {
                if store.canChooseHarness {
                    Menu("Harness · \(store.currentHarness.map { mobileHarnessDisplayName($0, among: store.harnesses) } ?? store.currentHarnessId)") {
                        Menu("Installed") {
                            ForEach(installedHarnesses) { harness in
                                harnessButton(harness)
                            }
                        }
                        if !catalogHarnesses.isEmpty {
                            Menu("Catalog") {
                                ForEach(catalogHarnesses) { harness in
                                    harnessButton(harness)
                                }
                            }
                        }
                    }
                }
                if store.canChooseHarness,
                   let harness = store.currentHarness,
                   !harness.auth.methods.isEmpty {
                    Button("Account · \(accountLabel)") {
                        authSetup = MobileHarnessAuthSetup(harness: harness)
                    }
                }
                // Keep the entry stable while an ACP process is starting or refreshing
                // capabilities; the picker itself explains loading and unsupported states.
                Button(
                    store.isLoadingSessionModels
                        ? "Choose model · Checking…"
                        : store.sessionModelsError == nil
                            ? "Choose model · \(store.currentModelName)"
                            : "Choose model · Needs attention"
                ) { showingModelPicker = true }
                Menu("Reasoning · \(store.currentReasoningName ?? "Auto")") {
                    if store.currentReasoningOptions.isEmpty {
                        Text("This Harness and model did not advertise a reasoning control.")
                        Button("Refresh") { Task { await store.refreshCurrentModels() } }
                    } else {
                        ForEach(store.currentReasoningOptions) { effort in
                            Button {
                                Task { await store.chooseReasoningEffort(effort.id) }
                            } label: {
                                if store.sessionModels?.current.reasoningEffort == effort.id {
                                    Label(effort.name, systemImage: "checkmark")
                                } else {
                                    Text(effort.name)
                                }
                            }
                        }
                    }
                }
                MobileHarnessConfigMenu(store: store)
                if store.canChooseAgentPreset, let catalog = store.agentPresets {
                    Menu("Agent preset") {
                        ForEach(catalog.presets) { preset in
                            Button(preset.name ?? preset.id) { Task { await store.chooseAgentPreset(preset) } }
                                .disabled(preset.broken != nil)
                        }
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "square.3.layers.3d")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(store.currentHarness.map { mobileHarnessDisplayName($0, among: store.harnesses) } ?? store.currentHarnessId) · \(store.currentModelLabel)")
                            .lineLimit(1)
                        Text("\(store.currentReasoningName ?? "Reasoning Auto") · \(accountLabel)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .layoutPriority(1)
            .accessibilityIdentifier("OpenFish.iOS.HarnessModelPicker")

            Spacer(minLength: 0)

            if let permissions = store.currentPermissions {
                Menu {
                    ForEach(permissions.options.filter { $0.value != "custom" }) { option in
                        MobilePermissionSelectionButton(
                            store: store,
                            option: option,
                            selected: option.value == permissions.currentValue,
                            dangerousPermission: $dangerousPermission
                        )
                    }
                } label: {
                    Label(
                        permissions.options.first(where: { $0.value == permissions.currentValue })?.name ?? "Access",
                        systemImage: "shield"
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                }
                .accessibilityLabel("Permission \(permissions.options.first(where: { $0.value == permissions.currentValue })?.name ?? "Access")")
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .sheet(isPresented: $showingModelPicker) {
            MobileModelSelectionSheet(store: store)
        }
        .sheet(isPresented: $showingWorkspacePicker) {
            MobileWorkspaceSelectionSheet(store: store)
        }
        .alert("Enable Full Access?", isPresented: Binding(
            get: { dangerousPermission != nil },
            set: { if !$0 { dangerousPermission = nil } }
        )) {
            Button("Cancel", role: .cancel) { dangerousPermission = nil }
            Button("Enable", role: .destructive) {
                guard let option = dangerousPermission else { return }
                dangerousPermission = nil
                Task { await store.choosePermission(option) }
            }
        } message: {
            Text(dangerousPermission?.description ?? "OpenFish may run commands and change files outside the workspace sandbox.")
        }
        .sheet(item: $authSetup) { setup in
            MobileHarnessCredentialsView(
                store: store,
                harness: setup.harness,
                makeDefault: false,
                selectForDraft: true
            )
        }
    }
}

private struct MobileWorkspaceSelectionSheet: View {
    @ObservedObject var store: MobileOpenCodexStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    workspaceButton(title: "No Project", workspaceID: nil)
                } footer: {
                    Text("OpenFish uses a managed working directory instead of Desktop or the Host launch folder.")
                }
                Section("Projects") {
                    ForEach(store.orderedWorkspaces) { workspace in
                        workspaceButton(title: workspace.title, workspaceID: workspace.workspaceId)
                    }
                }
            }
            .navigationTitle("Choose workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func workspaceButton(title: String, workspaceID: String?) -> some View {
        Button {
            store.changeNewTaskWorkspace(to: workspaceID)
            dismiss()
        } label: {
            HStack {
                Label(title, systemImage: workspaceID == nil ? "tray" : "folder")
                Spacer()
                if store.selectedWorkspaceId == workspaceID {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                }
            }
        }
        .foregroundStyle(.primary)
    }
}

private struct MobileVoiceConversationView: View {
    @ObservedObject var store: MobileOpenCodexStore
    @ObservedObject private var voice: MobileLocalVoice
    @Environment(\.dismiss) private var dismiss

    init(store: MobileOpenCodexStore) {
        self.store = store
        voice = store.voice
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.16), Color(uiColor: .systemBackground)],
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Voice with OpenFish").font(.headline)
                        Text("Apple on-device mode · final text only").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        store.stopVoiceConversation()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 36, height: 36)
                            .background(.thinMaterial, in: Circle())
                    }
                    .accessibilityLabel("End voice conversation")
                }
                .padding(20)

                Spacer()

                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.10))
                        .frame(width: 250, height: 250)
                    Circle()
                        .fill(Color.accentColor.opacity(voice.isListening || voice.isSpeaking ? 0.22 : 0.11))
                        .frame(width: voice.isListening || voice.isSpeaking ? 192 : 170, height: voice.isListening || voice.isSpeaking ? 192 : 170)
                        .animation(.easeInOut(duration: 0.7), value: voice.isListening || voice.isSpeaking)
                    Image(systemName: voice.isSpeaking ? "speaker.wave.3.fill" : voice.isListening ? "waveform" : "sparkles")
                        .font(.system(size: 56, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.variableColor.iterative, isActive: voice.isListening || voice.isSpeaking)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(store.voiceConversationStatus)
                .accessibilityIdentifier("voice-status")
                .accessibilityValue(voice.isListening ? "microphone active" : "microphone inactive")

                Text(store.voiceConversationStatus)
                    .font(.title2.bold())
                    .padding(.top, 24)

                Text(store.voiceConversationTranscript.isEmpty
                    ? "Speak naturally. OpenFish sends only finalized text to the current Harness task."
                    : store.voiceConversationTranscript)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(5)
                    .frame(maxWidth: 330, minHeight: 90, alignment: .top)
                    .padding(.horizontal, 24)
                    .padding(.top, 10)

                Spacer()

                HStack(spacing: 14) {
                    Button {
                        Task { await store.interruptVoiceConversation() }
                    } label: {
                        Label(voice.isSpeaking ? "Interrupt" : "Listen", systemImage: "mic.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button("End") {
                        store.stopVoiceConversation()
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 30)
            }
        }
        .onDisappear { store.stopVoiceConversation() }
    }
}

private struct MobileConnectionView: View {
    @ObservedObject var store: MobileOpenCodexStore
    @ObservedObject private var voice: MobileLocalVoice
    @State private var host = ""
    @State private var code = ""
    @State private var inspectedHarness: MobileHarness?
    @State private var authSetup: MobileHarnessAuthSetup?
    @Environment(\.dismiss) private var dismiss

    init(store: MobileOpenCodexStore) {
        self.store = store
        voice = store.voice
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("OpenFish Host") {
                    TextField("https://mac-name.local:3081", text: $host)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField("One-time pairing code", text: $code)
                        .textInputAutocapitalization(.characters)
                    Button("Pair and connect") { Task { await store.connect(host: host, pairingCode: code) } }
                        .buttonStyle(.borderedProminent)
                    LabeledContent("Current", value: store.profile.baseURL.absoluteString)
                    LabeledContent("State", value: store.connectionState.label)
                }

                Section("Models") {
                    Label("Configure provider API keys on the connected Mac.", systemImage: "macbook.and.iphone")
                    Text("The iPhone receives only the provider/model catalog needed to choose a task identity. It cannot read, write, or remove Host credentials.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(store.providers) { provider in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(provider.active ? Color.green : Color.secondary.opacity(0.35))
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.displayName)
                                Text(provider.provider)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(provider.active ? "Active" : "Dormant")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Default Harness") {
                    ForEach(store.harnesses) { harness in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mobileHarnessDisplayName(harness, among: store.harnesses))
                                if let description = harness.description {
                                    Text(description).font(.caption).foregroundStyle(.secondary)
                                }
                                if let bundle = harness.driverBundle, mobileHarnessRequiresMacDriver(harness) {
                                    Text("Mac setup required · \(bundle.package) · \(bundle.spec)")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                        .lineLimit(2)
                                }
                                if mobileHarnessRequiresMacCodeConsent(harness) {
                                    Text("Mac review required · unverified exact code version")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            Button("Details") { inspectedHarness = harness }
                            if store.harnessOperationId == harness.id {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityLabel("Installing \(harness.name)")
                            } else if harness.isDefault {
                                Image(systemName: "checkmark")
                            } else if mobileHarnessRequiresMacSetup(harness) {
                                Button("Set up on Mac") { inspectedHarness = harness }
                            } else {
                                Button(harness.auth.status == "not-required" || harness.auth.status == "configured" ? "Use" : "Set up") {
                                    requestUse(harness)
                                }
                                .disabled(store.harnessOperationId != nil || !harness.available)
                            }
                        }
                    }
                    Text("This changes the Host default for new tasks on every connected Open Fish device. Existing tasks keep their original Harness.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Voice") {
                    LabeledContent("Contract", value: store.nativeCapabilities?.voice?.contract ?? "Unavailable")
                    LabeledContent("Provider", value: voice.providerName)
                    LabeledContent("Transcript owner", value: store.nativeCapabilities?.voice?.transcriptAuthority ?? "Unavailable")
                    Picker("Playback voice", selection: $voice.preferredVoiceIdentifier) {
                        Text("Automatic (best installed)").tag("")
                        ForEach(voice.availableVoices) { option in
                            Text("\(option.name) · \(option.quality)").tag(option.id)
                        }
                    }
                    VStack(alignment: .leading) {
                        Text("Playback rate")
                        Slider(value: $voice.speechRate, in: 0.35...0.62)
                    }
                    Button(voice.isSpeaking ? "Stop preview" : "Preview voice") {
                        if voice.isSpeaking { voice.stopSpeaking() }
                        else { voice.speak("OpenFish voice is running locally on this iPhone.") }
                    }
                    Text("The apple-local Provider keeps microphone audio on this iPhone. Only finalized text is submitted to the current Harness task.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Notifications") {
                    Button("Enable task notifications") {
                        Task { await store.enableNotifications() }
                    }
                    Text("OpenFish asks only when you choose to enable notifications. You can change the result later in iPhone Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Cordis plugins") {
                    if store.plugins.isEmpty {
                        Text("No plugin inventory is available.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.plugins) { plugin in
                        HStack(spacing: 10) {
                            Image(systemName: plugin.enabled ? "puzzlepiece.extension.fill" : "puzzlepiece.extension")
                                .foregroundStyle(plugin.enabled ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(plugin.moduleName ?? plugin.entryId).lineLimit(1)
                                Text(plugin.entryId)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(plugin.fiberPhase ?? (plugin.enabled ? "enabled" : "disabled"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("This is the live DSH Loader inventory from the OpenFish Host; the iPhone does not own a second plugin registry.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Host configuration") {
                    Label("Edit Harness, provider, plugin, and secret configuration on the connected Mac.", systemImage: "lock.desktopcomputer")
                    Text("Remote devices intentionally cannot inspect or mutate the Host configuration plane. Task controls and their pinned identities remain available here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("This iPhone") {
                    Label(
                        store.profile.isLocal ? "Local development connection" : "Paired with this OpenFish Host",
                        systemImage: store.profile.isLocal ? "iphone.and.arrow.forward" : "checkmark.shield.fill"
                    )
                    Text("For privacy, a remote device cannot enumerate or revoke other paired devices. Manage the full device list on the Host Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !store.profile.isLocal {
                        Button("Unpair this iPhone", role: .destructive) {
                            Task { await store.unpairThisDevice() }
                        }
                    }
                }

                Section("Architecture") {
                    Text("LAN and Tailscale connect directly to the same OpenFish Host. The device token lives only in this iPhone's Keychain; sessions, settings, plugins, providers, and logs remain authoritative on that Host.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if store.isLoadingSettings {
                    ToolbarItem(placement: .topBarLeading) { ProgressView().controlSize(.small) }
                }
            }
            .onAppear { host = store.profile.baseURL.absoluteString }
            .task { await store.loadHostInventory() }
        }
        .sheet(item: $inspectedHarness) { harness in
            MobileHarnessDetailView(store: store, harness: harness) {
                requestUse(harness)
                inspectedHarness = nil
            }
        }
        .sheet(item: $authSetup) { setup in
            MobileHarnessCredentialsView(
                store: store,
                harness: setup.harness,
                makeDefault: true
            )
        }
    }

    private func requestUse(_ harness: MobileHarness) {
        if mobileHarnessRequiresMacSetup(harness) {
            inspectedHarness = harness
        } else if harness.auth.status != "not-required" && harness.auth.status != "configured" {
            authSetup = MobileHarnessAuthSetup(harness: harness)
        } else {
            Task { await store.selectDefaultHarness(harness) }
        }
    }
}

private func relativeDate(_ milliseconds: Double) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(
        for: Date(timeIntervalSince1970: milliseconds / 1_000),
        relativeTo: Date()
    )
}

private func imageMediaType(_ data: Data) -> String? {
    guard let first = data.first else { return nil }
    if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
    if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
    if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
    if first == 0x52, data.count > 12, String(data: data[8..<12], encoding: .ascii) == "WEBP" { return "image/webp" }
    return nil
}

private extension MobileJSONValue {
    var prettyJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }
}
