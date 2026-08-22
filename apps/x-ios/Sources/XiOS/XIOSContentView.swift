import MarkdownUI
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

public struct OpenCodexIOSView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = MobileOpenCodexStore()
    @State private var importsPresented = false
    @State private var searchText = ""
    @State private var expandedWorkspaceIDs: Set<String> = []
    @State private var otherTasksExpanded = false
    @State private var archivedTasksExpanded = false
    @State private var choseInitialWorkspace = false
    @State private var selectedComputer = "all"
    @State private var showsActivity = false

    public init() {}

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
                    MobileComputerFilterBar(
                        store: store,
                        selection: $selectedComputer
                    )

                    if store.workspaces.isEmpty && store.sessions.isEmpty {
                        ContentUnavailableView(
                            "No remote tasks",
                            systemImage: "desktopcomputer",
                            description: Text("Connect a computer or add a project to get started.")
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
            .sheet(isPresented: $store.showsWorkspaceBrowser) {
                MobileHostDirectoryBrowser(store: store)
            }
            .fullScreenCover(isPresented: $store.showsVoiceConversation) {
                MobileVoiceConversationView(store: store)
            }
            .fullScreenCover(isPresented: Binding(
                get: { store.nativeCapabilities != nil && store.selectedHarnessId.isEmpty && !store.harnesses.isEmpty },
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
                await store.boot()
                chooseInitialWorkspaceIfNeeded()
            }
            .onChange(of: store.workspaces) { _, _ in chooseInitialWorkspaceIfNeeded() }
            .onChange(of: store.sessions) { _, _ in chooseInitialWorkspaceIfNeeded() }
            .onChange(of: scenePhase) { _, phase in
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

private struct MobileHarnessOnboardingView: View {
    @ObservedObject var store: MobileOpenCodexStore
    @State private var query = ""

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
                    Text("Choose your default Harness").font(.largeTitle.bold())
                    Text("OpenFish will ask the connected Mac to install it. New tasks use this Harness unless you choose another before starting; existing tasks never change.")
                        .foregroundStyle(.secondary)
                    ForEach(filtered) { harness in
                        Button {
                            Task { await store.selectDefaultHarness(harness) }
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(harness.name).font(.headline)
                                    Text(harness.description ?? "No description provided.")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                    Text("\(harness.source) · \(harness.compatibility.status)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if harness.available { Image(systemName: "arrow.down.circle") }
                                else { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                        .disabled(!harness.available)
                    }
                    Text("Harness sign-in and API credentials are stored on the Mac Host. If a Harness needs authentication, OpenFish will tell you to finish it on the Mac before selecting it here.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .interactiveDismissDisabled()
            .searchable(text: $query, prompt: "Find a Harness")
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
                Button { importsPresented = true } label: {
                    Label("Import tasks", systemImage: "square.and.arrow.down")
                }
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
                            Text("OpenFish will work in \(store.selectedWorkspace?.title ?? "the selected project") on your connected computer.")
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
                MobileComposer(store: store)
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
        MobileHarnessConfigMenu(store: store)
        if store.selectedSession == nil {
            Menu("Project") {
                Button("No project") { store.newTask(in: nil) }
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
                ForEach(store.harnesses) { harness in
                    Button {
                        Task { await store.chooseHarness(harness) }
                    } label: {
                        if harness.id == store.currentHarnessId { Label(harness.name, systemImage: "checkmark") }
                        else { Text(harness.name) }
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

    var body: some View {
        if let models = store.sessionModels, !models.groups.isEmpty {
            Menu(store.currentModelLabel) {
                ForEach(models.groups) { group in
                    Section(group.name) {
                        ForEach(group.models) { model in
                            MobileModelSelectionRow(store: store, groupID: group.id, model: model)
                        }
                    }
                }
            }
        }
    }
}

private struct MobileModelSelectionRow: View {
    @ObservedObject var store: MobileOpenCodexStore
    let groupID: String
    let model: MobileCatalogModel

    var body: some View {
        if let reasoning = model.reasoning, reasoning.efforts.count > 1 {
            Menu(model.name) {
                ForEach(reasoning.efforts) { effort in
                    Button {
                        Task { await store.chooseModel(provider: groupID, model: model, effort: effort.id) }
                    } label: {
                        if store.sessionModels?.current.provider == groupID,
                           store.sessionModels?.current.model == model.id,
                           store.sessionModels?.current.reasoningEffort == effort.id {
                            Label(effort.name, systemImage: "checkmark")
                        } else {
                            Text(effort.name)
                        }
                    }
                }
            }
        } else {
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
        }
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
                        })?.name ?? "DSH default"
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
                        Text("No persistent goal is attached to this DSH task.")
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
                        Label("DSH is applying the change", systemImage: "clock")
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
                        LabeledContent("Commands", value: "\(store.commands.count)")
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
                        Text("DSH session").font(.caption).foregroundStyle(.secondary)
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
        List(Array(store.commands.enumerated()), id: \.offset) { _, command in
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
            if store.commands.isEmpty {
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
    @State private var photoItems: [PhotosPickerItem] = []

    init(store: MobileOpenCodexStore) {
        self.store = store
        voice = store.voice
    }

    var body: some View {
        VStack(spacing: 8) {
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
            }
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $photoItems, maxSelectionCount: 8, matching: .images) {
                    Image(systemName: "plus")
                        .frame(width: 32, height: 36)
                }
                TextField("Tell OpenFish what to do", text: $store.draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(.vertical, 8)
                Button { Task { await store.toggleDictation() } } label: {
                    Image(systemName: voice.isListening ? "waveform.circle.fill" : "mic")
                        .foregroundStyle(voice.isListening ? Color.red : Color.primary)
                        .frame(width: 30, height: 36)
                }
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
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
            }
            MobileComposerControls(store: store)
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
    @State private var dangerousPermission: MobilePermissionOption?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if store.selectedSession == nil {
                    Menu {
                        Button("No project") { store.newTask(in: nil) }
                        ForEach(store.orderedWorkspaces) { workspace in
                            Button(workspace.title) { store.newTask(in: workspace.workspaceId) }
                        }
                    } label: {
                        Label(store.selectedWorkspace?.title ?? "Project", systemImage: "folder")
                    }
                }
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
                    }
                }
                MobileModelSelectionMenu(store: store)
                MobileHarnessConfigMenu(store: store)
                if store.canChooseHarness {
                    Menu {
                        ForEach(store.harnesses) { harness in
                            Button(harness.name) { Task { await store.chooseHarness(harness) } }
                        }
                    } label: {
                        Label(store.harnesses.first(where: { $0.id == store.currentHarnessId })?.name ?? store.currentHarnessId, systemImage: "cpu")
                    }
                }
                if store.canChooseAgentPreset, let catalog = store.agentPresets {
                    Menu {
                        ForEach(catalog.presets) { preset in
                            Button(preset.name ?? preset.id) { Task { await store.chooseAgentPreset(preset) } }
                                .disabled(preset.broken != nil)
                        }
                    } label: {
                        Label(store.currentAgentPreset ?? "Agent", systemImage: "person.crop.circle.badge.gearshape")
                    }
                }
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
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
                        Text("Local audio · DSH task").font(.caption).foregroundStyle(.secondary)
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

                Text(store.voiceConversationStatus)
                    .font(.title2.bold())
                    .padding(.top, 24)

                Text(store.voiceConversationTranscript.isEmpty
                    ? "Speak naturally. OpenFish sends only finalized text to the authoritative DSH task."
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
    @State private var credentialRef = "DEEPSEEK_API_KEY"
    @State private var credentialValue = ""
    @Environment(\.dismiss) private var dismiss

    init(store: MobileOpenCodexStore) {
        self.store = store
        voice = store.voice
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("DSH Host") {
                    TextField("http://mac-or-tailscale-ip:3080", text: $host)
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
                    TextField("Credential reference", text: $credentialRef)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    SecureField("Credential value", text: $credentialValue)
                    HStack {
                        Button("Save") {
                            let ref = credentialRef
                            let value = credentialValue
                            credentialValue = ""
                            Task { await store.setCredential(ref: ref, value: value) }
                        }
                        .disabled(
                            credentialRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || credentialValue.isEmpty
                        )
                        Button("Remove", role: .destructive) {
                            Task { await store.unsetCredential(ref: credentialRef) }
                        }
                        .disabled(credentialRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text("Credentials are write-only in DSH and are never returned to this iPhone.")
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
                        Button {
                            Task { await store.selectDefaultHarness(harness) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(harness.name)
                                    if let description = harness.description {
                                        Text(description).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if harness.isDefault { Image(systemName: "checkmark") }
                                else if !harness.available { Text("Install").font(.caption) }
                            }
                        }
                        .disabled(harness.isDefault)
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
                    Text("The apple-local Provider keeps microphone audio on this iPhone. Only finalized text crosses the authenticated DSH session API.")
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
                    Text("This is the live DSH Loader inventory; the iPhone does not own a second plugin registry.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Host configuration") {
                    ForEach(store.settingsCatalog?.namespaces ?? []) { namespace in
                        NavigationLink(namespace.ns) {
                            MobileSettingsNamespaceEditor(store: store, namespace: namespace)
                        }
                    }
                    if store.settingsCatalog?.namespaces.isEmpty != false {
                        Text("No writable namespaces are exposed by this Host.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Paired devices") {
                    if store.pairedDevices.isEmpty {
                        Text("No paired devices are visible to this credential.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.pairedDevices) { device in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                Text("\(device.surface) · last seen \(relativeDate(device.lastSeenAt))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Revoke", role: .destructive) {
                                Task { await store.revoke(device) }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                Section("Architecture") {
                    Text("LAN and Tailscale connect directly to the same DSH Host. The device token lives only in this iPhone's Keychain; sessions, settings, plugins, providers, and logs remain authoritative in DSH.")
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
            .task { await store.loadSettings() }
        }
    }
}

private struct MobileSettingsNamespaceEditor: View {
    @ObservedObject var store: MobileOpenCodexStore
    let namespace: MobileSettingsNamespace
    @State private var text = "{}"

    private var current: MobileSettingsNamespace {
        store.settingsCatalog?.namespaces.first(where: { $0.ns == namespace.ns }) ?? namespace
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .font(.caption.monospaced())
                    .frame(minHeight: 260)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("User override JSON")
            } footer: {
                Text("Applies \(current.applies) · revision \(current.revision). DSH validates and atomically replaces this namespace.")
            }

            if !current.secrets.isEmpty {
                Section("Secret references") {
                    ForEach(Array(current.secrets.enumerated()), id: \.offset) { _, secret in
                        LabeledContent(secret.path.joined(separator: "."), value: secret.set ? "Set" : "Not set")
                    }
                }
            }

            Section {
                Button("Save configuration") {
                    Task { await store.replaceSettings(current, json: text) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .navigationTitle(namespace.ns)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { text = (current.user ?? .object([:])).prettyJSON }
        .onChange(of: store.settingsCatalog) { _, catalog in
            guard let updated = catalog?.namespaces.first(where: { $0.ns == namespace.ns }) else { return }
            text = (updated.user ?? .object([:])).prettyJSON
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
