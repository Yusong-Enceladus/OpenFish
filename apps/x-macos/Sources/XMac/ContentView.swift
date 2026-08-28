import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum OpenCodexPalette {
    static let sidebar = adaptive(
        light: NSColor(srgbRed: 0.965, green: 0.965, blue: 0.958, alpha: 1),
        dark: NSColor(srgbRed: 0.125, green: 0.125, blue: 0.125, alpha: 1)
    )
    static let canvas = adaptive(
        light: NSColor(srgbRed: 0.995, green: 0.995, blue: 0.992, alpha: 1),
        dark: NSColor(srgbRed: 0.095, green: 0.095, blue: 0.095, alpha: 1)
    )
    static let elevated = adaptive(
        light: NSColor(srgbRed: 1, green: 1, blue: 0.997, alpha: 1),
        dark: NSColor(srgbRed: 0.125, green: 0.125, blue: 0.125, alpha: 1)
    )
    static let selected = Color.accentColor.opacity(0.13)
    static let hover = Color.primary.opacity(0.055)
    static let border = Color.primary.opacity(0.10)
    static let softBorder = Color.primary.opacity(0.065)
    static let secondaryText = Color.secondary.opacity(0.88)

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

@MainActor
struct ContentView: View {
    @StateObject private var store: OpenCodexStore
    private let shouldBoot: Bool

    init(store: OpenCodexStore? = nil, shouldBoot: Bool = true) {
        _store = StateObject(wrappedValue: store ?? OpenCodexStore())
        self.shouldBoot = shouldBoot
    }

    var body: some View {
        HStack(spacing: 0) {
            OpenCodexSidebar(store: store)
                .frame(width: 268)

            Rectangle()
                .fill(OpenCodexPalette.border)
                .frame(width: 1)

            OpenCodexMainSurface(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if store.isInspectorPresented, store.selectedSessionId != nil {
                Rectangle()
                    .fill(OpenCodexPalette.border)
                    .frame(width: 1)
                TaskInspector(store: store)
                    .frame(width: 310)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(OpenCodexPalette.canvas)
        .overlay {
            if store.isModelBrowserPresented {
                ZStack {
                    Color.black.opacity(0.34)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { store.isModelBrowserPresented = false }
                    ModelSelectionSheet(store: store) {
                        store.isModelBrowserPresented = false
                    }
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(OpenCodexPalette.border))
                    .shadow(color: .black.opacity(0.22), radius: 32, y: 14)
                }
                .transition(.opacity)
                .zIndex(100)
            }
        }
        .task {
            if shouldBoot { await store.boot() }
        }
        .onDisappear {
            if shouldBoot { Task { await store.shutdown() } }
        }
        .animation(.snappy(duration: 0.22), value: store.isInspectorPresented)
        .sheet(isPresented: $store.isSettingsPresented) {
            OpenCodexSettingsView(store: store)
                .frame(minWidth: 760, minHeight: 560)
        }
        .sheet(isPresented: $store.isWorkspaceBrowserPresented) {
            HostDirectoryBrowser(store: store)
                .frame(minWidth: 620, minHeight: 500)
        }
        .sheet(isPresented: $store.isVoiceConversationPresented) {
            VoiceConversationView(store: store)
                .frame(width: 460, height: 520)
        }
        .sheet(isPresented: Binding(
            get: { store.needsHarnessOnboarding },
            set: { _ in }
        )) {
            HarnessOnboardingView(store: store)
                .frame(minWidth: 720, minHeight: 540)
                .interactiveDismissDisabled()
        }
    }
}

private struct HostDirectoryBrowser: View {
    @ObservedObject var store: OpenCodexStore
    @State private var showsHidden = false
    @State private var creatingFolder = false
    @State private var folderName = ""

    private var visibleEntries: [HostDirectoryEntry] {
        (store.directoryListing?.entries ?? []).filter { showsHidden || !$0.hidden }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add project from OpenFish Host")
                        .font(.system(size: 15, weight: .semibold))
                    Text(store.connectionProfile.baseURL.host ?? store.connectionProfile.baseURL.absoluteString)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)

            Divider()

            if let listing = store.directoryListing {
                VStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(Array(listing.crumbs.enumerated()), id: \.element.id) { index, crumb in
                                if index > 0 {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                Button(crumb.name) {
                                    Task { await store.browseHostDirectory(crumb.path) }
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 12.5, weight: index == listing.crumbs.count - 1 ? .semibold : .regular))
                            }
                        }
                        .padding(.horizontal, 18)
                        .frame(height: 42)
                    }

                    Divider()

                    if visibleEntries.isEmpty {
                        ContentUnavailableView(
                            "No subfolders",
                            systemImage: "folder",
                            description: Text("Use this folder as the project, or choose a parent above.")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(visibleEntries) { entry in
                            Button {
                                Task { await store.browseHostDirectory(entry.path) }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: entry.hidden ? "folder.fill.badge.minus" : "folder.fill")
                                        .foregroundStyle(Color.accentColor)
                                    Text(entry.name)
                                        .lineLimit(1)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .listStyle(.inset)
                    }

                    if listing.truncated {
                        Label("This directory contains additional folders that are not shown.", systemImage: "info.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Divider()

                    HStack(spacing: 10) {
                        Toggle("Show hidden folders", isOn: $showsHidden)
                            .toggleStyle(.checkbox)
                        Button("New Folder") {
                            folderName = ""
                            creatingFolder = true
                        }
                        .disabled(store.isBrowsingWorkspace)
                        Spacer()
                        Button("Cancel") { store.isWorkspaceBrowserPresented = false }
                        Button("Add Project") { Task { await store.addBrowsedWorkspace() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(store.isBrowsingWorkspace)
                    }
                    .padding(14)
                }
            } else {
                ProgressView("Loading folders from the Host…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay {
            if store.isBrowsingWorkspace {
                ProgressView()
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .alert("New folder", isPresented: $creatingFolder) {
            TextField("Folder name", text: $folderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { Task { await store.createHostDirectory(folderName) } }
                .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

// MARK: - Sidebar

private struct OpenCodexSidebar: View {
    @ObservedObject var store: OpenCodexStore
    @State private var showsActivity = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                OpenCodexMark(size: 28)
                Text("OpenFish")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Button {
                    showsActivity.toggle()
                } label: {
                    Image(systemName: showsActivity ? "bell.fill" : "bell")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 30, height: 30)
                        .background(showsActivity ? OpenCodexPalette.selected : Color.clear, in: Circle())
                }
                .buttonStyle(.plain)
                .help(showsActivity ? "Show projects" : "Show activity")
                Button {
                    store.beginNewTask(in: store.selectedWorkspaceId)
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .help("New task")
                .accessibilityIdentifier("OpenFish.NewTask")
                .disabled(!store.canStartNewTask)
            }
            .padding(.horizontal, 14)
            .padding(.top, 30)
            .padding(.bottom, 12)

            Button {
                store.beginNewTask(in: store.selectedWorkspaceId)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                    Text("New task")
                        .font(.system(size: 14, weight: .medium))
                    Spacer()
                    Text("⌘N")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 9)
                .frame(height: 34)
                .background(OpenCodexPalette.hover, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)
            .padding(.horizontal, 10)
            .disabled(!store.canStartNewTask)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                TextField("Search tasks", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit { Task { await store.performSearch() } }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 10)
            .padding(.top, 9)
            .padding(.bottom, 8)

            if showsActivity {
                ActivitySidebar(store: store)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(store.orderedWorkspaces) { workspace in
                            WorkspaceSection(store: store, workspace: workspace)
                        }

                        if !store.sessions(in: nil).isEmpty {
                            WorkspaceSection(store: store, workspace: nil)
                        }

                        if !store.otherLocationSessions.isEmpty {
                            WorkspaceSection(store: store, workspace: nil, looseKind: .external)
                        }

                        if !store.archivedSessions.isEmpty {
                            ArchivedTasksSection(store: store)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }

            Spacer(minLength: 8)

            Button {
                Task { await store.addWorkspace() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .frame(width: 18)
                    Text(store.isAddingWorkspace ? "Adding project…" : "Add project")
                    Spacer()
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OpenCodexPalette.secondaryText)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.isAddingWorkspace)
            .disabled(!store.canStartNewTask)

            Button {
                store.isSettingsPresented = true
                Task { await store.loadSettings() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                        .frame(width: 18)
                    Text("Settings")
                    Spacer()
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OpenCodexPalette.secondaryText)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ConnectionFooter(state: store.connectionState, isDemoMode: store.isDemoMode)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
        .background(OpenCodexPalette.sidebar)
    }
}

private enum ActivityPeriod: String, CaseIterable, Identifiable {
    case priority = "Priority"
    case today = "Today"
    case yesterday = "Yesterday"
    case previousSevenDays = "Previous 7 Days"
    case older = "Earlier"
    var id: String { rawValue }
}

private struct ActivitySidebar: View {
    @ObservedObject var store: OpenCodexStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 15) {
                ForEach(ActivityPeriod.allCases) { period in
                    let rows = sessions(for: period)
                    if !rows.isEmpty {
                        ActivityPeriodSection(store: store, period: period, sessions: rows)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private func sessions(for period: ActivityPeriod) -> [SessionSummary] {
        let all = store.visibleSessionsByRecency
        let priorityIDs = Set(all.filter { store.hasAttention($0.sessionId) }.map(\.sessionId))
        if period == .priority { return all.filter { priorityIDs.contains($0.sessionId) } }
        return all.filter { !priorityIDs.contains($0.sessionId) && activityPeriod($0.updatedAt) == period }
    }
}

private struct ActivityPeriodSection: View {
    @ObservedObject var store: OpenCodexStore
    let period: ActivityPeriod
    let sessions: [SessionSummary]
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Text(period.rawValue)
                    Spacer()
                    Text("\(sessions.count)").foregroundStyle(.tertiary)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .frame(height: 25)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                ForEach(sessions) { session in
                    SessionRow(store: store, session: session, showsWorkspace: true)
                }
            }
        }
    }
}

private func activityPeriod(_ milliseconds: Double) -> ActivityPeriod {
    let calendar = Calendar.autoupdatingCurrent
    let date = Date(timeIntervalSince1970: milliseconds / 1_000)
    if calendar.isDateInToday(date) { return .today }
    if calendar.isDateInYesterday(date) { return .yesterday }
    if let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: Date()), date >= sevenDaysAgo {
        return .previousSevenDays
    }
    return .older
}

private struct ArchivedTasksSection: View {
    @ObservedObject var store: OpenCodexStore
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 10)
                    Image(systemName: "archivebox")
                        .font(.system(size: 12.5, weight: .medium))
                    Text("Archived")
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Text("\(store.archivedSessions.count)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .frame(height: 25)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(store.archivedSessions) { session in
                    HStack(spacing: 8) {
                        Image(systemName: "archivebox")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                        Text(store.displayTitle(for: session))
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer()
                        Button("Restore") {
                            Task { await store.unarchiveSession(session.sessionId) }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 29)
                }
            }
        }
    }
}

private enum LooseSessionSectionKind: Equatable {
    case noProject
    case external
}

private struct WorkspaceSection: View {
    @ObservedObject var store: OpenCodexStore
    let workspace: WorkspaceView?
    var looseKind: LooseSessionSectionKind = .noProject
    @State private var isExpanded = true
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var confirmDelete = false

    init(
        store: OpenCodexStore,
        workspace: WorkspaceView?,
        looseKind: LooseSessionSectionKind = .noProject
    ) {
        _store = ObservedObject(wrappedValue: store)
        self.workspace = workspace
        self.looseKind = looseKind
    }

    private var sessions: [SessionSummary] {
        if workspace != nil { return store.sessions(in: workspace) }
        return looseKind == .noProject ? store.sessions(in: nil) : store.otherLocationSessions
    }

    private var sectionTitle: String {
        workspace?.title ?? (looseKind == .noProject ? "No Project" : "Other locations")
    }

    private var sectionIcon: String {
        if workspace != nil { return "folder" }
        return looseKind == .noProject ? "tray" : "externaldrive"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 10)
                        .foregroundStyle(.tertiary)
                    Image(systemName: sectionIcon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(sectionTitle)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    if let workspace {
                        Button {
                            store.beginNewTask(in: workspace.workspaceId)
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11.5, weight: .bold))
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .help("New task in \(workspace.title)")
                        .disabled(!store.canStartNewTask)
                    } else if looseKind == .noProject {
                        Button {
                            store.beginNewTask(in: nil)
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11.5, weight: .bold))
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .help("New No Project task")
                        .disabled(!store.canStartNewTask)
                    }
                }
                .padding(.horizontal, 7)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                if let workspace {
                    Button("Rename project…") {
                        renameText = workspace.title
                        isRenaming = true
                    }
                    Button("Remove project", role: .destructive) { confirmDelete = true }
                }
            }

            if isExpanded {
                if sessions.isEmpty {
                    Text("No tasks yet")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 30)
                        .padding(.vertical, 3)
                } else {
                    ForEach(sessions) { session in
                        SessionRow(store: store, session: session)
                    }
                }
            }
        }
        .alert("Rename project", isPresented: $isRenaming) {
            TextField("Project name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let workspace { Task { await store.renameWorkspace(workspace, title: renameText) } }
            }
        }
        .confirmationDialog(
            "Remove this project from OpenFish? Files and task history stay on disk.",
            isPresented: $confirmDelete
        ) {
            Button("Remove project", role: .destructive) {
                if let workspace { Task { await store.deleteWorkspace(workspace) } }
            }
        }
    }
}

private struct SessionRow: View {
    @ObservedObject var store: OpenCodexStore
    let session: SessionSummary
    var showsWorkspace = false
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var isHoverCardPresented = false
    @State private var hoverTask: Task<Void, Never>?

    private var selected: Bool { store.selectedSessionId == session.sessionId }

    var body: some View {
        Button {
            store.markRead(session)
            Task { await store.selectSession(session.sessionId) }
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(session.running || store.hasPendingApproval(session.sessionId) ? 1 : 0))
                        .frame(width: 6, height: 6)
                    if !session.running && !store.hasPendingApproval(session.sessionId) {
                        Circle()
                            .stroke(Color.secondary.opacity(0.30), lineWidth: 1)
                            .frame(width: 6, height: 6)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.displayTitle(for: session))
                        .font(.system(size: 14, weight: selected || store.isUnread(session) ? .medium : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if showsWorkspace {
                        Text(store.workspaceTitle(for: session))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if store.hasPendingApproval(session.sessionId) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                } else if session.running {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: showsWorkspace ? 43 : 36)
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .background(selected ? OpenCodexPalette.selected : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoverTask?.cancel()
            if hovering {
                hoverTask = Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !Task.isCancelled else { return }
                    await MainActor.run { isHoverCardPresented = true }
                }
            } else {
                isHoverCardPresented = false
            }
        }
        .popover(isPresented: $isHoverCardPresented, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(store.displayTitle(for: session))
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)
                    Spacer(minLength: 12)
                    Text(relativeTime(session.updatedAt))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(workspaceTitle)
                        .font(.system(size: 13))
                        .lineLimit(1)
                }
            }
            .padding(14)
            .frame(width: 320, alignment: .leading)
        }
        .contextMenu {
            Button("Rename task…") {
                renameText = store.displayTitle(for: session)
                isRenaming = true
            }
            Button("Fork task") {
                Task {
                    await store.selectSession(session.sessionId)
                    await store.forkCurrentSession()
                }
            }
            .disabled(!store.canFork(session))
            Divider()
            Button("Archive task") {
                Task {
                    await store.selectSession(session.sessionId)
                    await store.archiveCurrentSession()
                }
            }
        }
        .alert("Rename task", isPresented: $isRenaming) {
            TextField("Task name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                Task {
                    await store.selectSession(session.sessionId)
                    await store.renameCurrentSession(renameText)
                }
            }
        }
    }

    private var statusColor: Color {
        if store.hasPendingApproval(session.sessionId) { return .orange }
        if session.running { return .accentColor }
        return .clear
    }

    private var workspaceTitle: String {
        store.workspaceTitle(for: session)
    }
}

private struct ConnectionFooter: View {
    let state: DshConnectionState
    let isDemoMode: Bool

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(state == .connected ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(isDemoMode ? "Demo data · offline" : state == .connected ? "OpenFish Host connected" : state.label)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(height: 24)
    }
}

// MARK: - Main surface

private struct OpenCodexMainSurface: View {
    @ObservedObject var store: OpenCodexStore

    var body: some View {
        Group {
            switch store.hostPresentationState {
            case .loading:
                HostAvailabilitySurface(
                    title: "Starting OpenFish Host",
                    message: "OpenFish is starting the local control plane and checking its native protocol.",
                    systemImage: "desktopcomputer.and.arrow.down",
                    showsProgress: true,
                    primaryTitle: nil,
                    primaryAction: nil,
                    store: store
                )
            case let .recoverable(issue):
                HostAvailabilitySurface(
                    title: issue?.title ?? "OpenFish has not reached this Host",
                    message: issue?.message ?? "The connection will keep retrying. You can retry now or choose another Host.",
                    systemImage: "wifi.exclamationmark",
                    showsProgress: false,
                    primaryTitle: "Retry now",
                    primaryAction: { Task { await store.retryHostConnection() } },
                    store: store
                )
            case let .fatal(issue):
                HostAvailabilitySurface(
                    title: issue.title,
                    message: issue.message,
                    systemImage: "exclamationmark.octagon",
                    showsProgress: false,
                    primaryTitle: "Open connection settings",
                    primaryAction: { store.isSettingsPresented = true },
                    store: store
                )
            case let .cached(issue):
                VStack(spacing: 0) {
                    CachedHostBanner(store: store, issue: issue)
                    taskSurface
                }
            case .ready:
                taskSurface
            }
        }
        .background(OpenCodexPalette.canvas)
    }

    @ViewBuilder
    private var taskSurface: some View {
        VStack(spacing: 0) {
            if let session = store.currentSession {
                TaskHeader(store: store, session: session)
                if let error = store.errorBanner {
                    ErrorBanner(text: error, dismiss: store.dismissError)
                }
                if let harness = store.currentHarness,
                   !harness.available,
                   harness.driverBundle != nil {
                    PinnedHarnessSetupBanner(store: store, harness: harness)
                }
                ConversationSurface(store: store, session: session)
            } else {
                NewTaskHeader(store: store)
                if let error = store.errorBanner {
                    ErrorBanner(text: error, dismiss: store.dismissError)
                }
                NewTaskSurface(store: store)
            }
        }
    }
}

private struct CachedHostBanner: View {
    @ObservedObject var store: OpenCodexStore
    let issue: OpenFishHostIssue?

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: issue?.kind == .incompatible ? "exclamationmark.octagon.fill" : "wifi.slash")
                .foregroundStyle(issue?.kind == .incompatible ? Color.red : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(issue?.kind == .incompatible ? "Cached tasks · incompatible Host" : "Cached tasks · reconnecting")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(issue?.message ?? "You can read cached tasks. Sending, approvals, and new tasks resume after the Host reconnects.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Retry") { Task { await store.retryHostConnection() } }
                .buttonStyle(.bordered)
            Button("Connection") { store.isSettingsPresented = true }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.orange.opacity(0.14)).frame(height: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("OpenFish.Host.Cached")
    }
}

private struct HostAvailabilitySurface: View {
    let title: String
    let message: String
    let systemImage: String
    let showsProgress: Bool
    let primaryTitle: String?
    let primaryAction: (() -> Void)?
    @ObservedObject var store: OpenCodexStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("OpenFish Host")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(store.connectionProfile.isLocal ? "This Mac" : store.connectionProfile.baseURL.host ?? "Remote Host")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 26)
            .padding(.bottom, 10)
            .frame(height: 68)
            .overlay(alignment: .bottom) { Rectangle().fill(OpenCodexPalette.softBorder).frame(height: 1) }

            VStack(spacing: 14) {
                if showsProgress {
                    ProgressView()
                        .controlSize(.large)
                        .accessibilityLabel("Connecting to OpenFish Host")
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                Text(message)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                HStack(spacing: 10) {
                    if let primaryTitle, let primaryAction {
                        Button(primaryTitle, action: primaryAction)
                            .buttonStyle(.borderedProminent)
                    }
                    if !store.connectionProfile.isLocal {
                        Button("Use this Mac") { Task { await store.useLocalHost() } }
                            .buttonStyle(.bordered)
                    }
                    if primaryTitle != "Open connection settings" {
                        Button("Connection settings") { store.isSettingsPresented = true }
                            .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(36)
        }
        .accessibilityIdentifier("OpenFish.Host.Availability")
    }
}

private struct TaskHeader: View {
    @ObservedObject var store: OpenCodexStore
    let session: SessionSummary
    @State private var isRenaming = false
    @State private var renameText = ""

    var body: some View {
        HStack(spacing: 11) {
            if store.activeSubagent != nil {
                Button { store.closeSubagent() } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help("Back to parent task")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(store.activeSubagent?.label ?? store.displayTitle(for: session))
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                        .font(.system(size: 12.5))
                    Text(store.currentWorkspace?.title ?? "No Project")
                        .lineLimit(1)
                    Text("·")
                    Text(
                        store.isDemoMode
                            ? "Demo"
                            : store.connectionProfile.isLocal ? "Local" : store.connectionProfile.baseURL.host ?? "Remote"
                    )
                    Text("·")
                    Label(
                        store.currentHarness.map { harnessDisplayName($0, among: store.harnesses) }
                            ?? store.currentHarnessId,
                        systemImage: "shippingbox"
                    )
                }
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            }
            Spacer()

            if session.running || store.activeSubagent?.mode == "continuable" {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Working")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            }

            Button {
                Task { await store.startVoiceConversation() }
            } label: {
                Image(systemName: "waveform.circle")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Start local voice conversation")
            .accessibilityLabel("Start voice conversation")
            .disabled(!store.canStartNewTask)

            Button {
                store.isInspectorPresented.toggle()
            } label: {
                Image(systemName: "sidebar.right")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Task details")

            Menu {
                Button("Rename task…") {
                    renameText = store.displayTitle(for: session)
                    isRenaming = true
                }
                Button("Fork task") { Task { await store.forkCurrentSession() } }
                    .disabled(!store.harnessCan("session.fork"))
                Button("Export task…") { exportTask(store: store) }
                Divider()
                Button("Archive task") {
                    Task { await store.archiveCurrentSession() }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 18)
        .padding(.top, 26)
        .padding(.bottom, 10)
        .frame(height: 68)
        .background(OpenCodexPalette.canvas)
        .overlay(alignment: .bottom) {
            Rectangle().fill(OpenCodexPalette.softBorder).frame(height: 1)
        }
        .alert("Rename task", isPresented: $isRenaming) {
            TextField("Task name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { Task { await store.renameCurrentSession(renameText) } }
        }
    }
}

private struct NewTaskHeader: View {
    @ObservedObject var store: OpenCodexStore

    var body: some View {
        HStack {
            Text("New task")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Button {
                Task { await store.startVoiceConversation() }
            } label: {
                Image(systemName: "waveform.circle")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Start local voice conversation")
            .disabled(!store.canStartNewTask)
            HStack(spacing: 6) {
                Circle()
                    .fill(store.connectionState == .connected ? Color.green : Color.secondary)
                    .frame(width: 6, height: 6)
                Text(store.connectionState == .connected ? "Mac Host connected" : store.connectionState.label)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.top, 26)
        .padding(.bottom, 10)
        .frame(height: 68)
        .overlay(alignment: .bottom) {
            Rectangle().fill(OpenCodexPalette.softBorder).frame(height: 1)
        }
    }
}

private struct ErrorBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 13))
                .lineLimit(2)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.09))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.orange.opacity(0.14)).frame(height: 1)
        }
    }
}

private struct PinnedHarnessSetupBanner: View {
    @ObservedObject var store: OpenCodexStore
    let harness: HarnessCatalogEntry
    @State private var isConfirming = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("This task needs its exact Harness setup")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(harness.unavailableReason ?? "Activate \(harness.name) \(harness.version) before continuing.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            Button("Activate exact Driver") { isConfirming = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(store.harnessOperationId != nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.08))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.orange.opacity(0.14)).frame(height: 1)
        }
        .confirmationDialog(
            "Activate the exact Driver for this task?",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Activate \(harness.driverBundle?.spec ?? harness.version)") {
                Task { await store.activatePinnedHarness(harness, acceptDriverBundle: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "OpenFish will admit the pinned source, restart only its verified embedded Host, and authorize it for \(harness.name) \(harness.version). Because one \(harness.protocolName) Driver is active per Host, newer tasks using a different source may ask you to switch back."
            )
        }
        .accessibilityIdentifier("OpenFish.Harness.RestorePinned")
    }
}

// MARK: - New task

private struct NewTaskSurface: View {
    @ObservedObject var store: OpenCodexStore

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Spacer(minLength: max(44, geometry.size.height * 0.19))

                VStack(spacing: 6) {
                    Text("Start with a task")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Describe the outcome. You can review the runtime before anything sensitive happens.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.bottom, 18)

                Composer(store: store, prominent: true)
                    .frame(width: min(840, max(360, geometry.size.width - 96)))

                Spacer(minLength: max(72, geometry.size.height * 0.22))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 36)
        }
    }
}

// MARK: - Conversation

private struct ConversationSurface: View {
    @ObservedObject var store: OpenCodexStore
    let session: SessionSummary

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if store.canLoadOlder || store.isLoadingOlder {
                        HStack {
                            Spacer()
                            Button {
                                Task { await store.loadOlderHistory() }
                            } label: {
                                if store.isLoadingOlder {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("Load earlier messages")
                                }
                            }
                            .buttonStyle(.borderless)
                            .disabled(store.isLoadingOlder)
                            Spacer()
                        }
                    }

                    if store.conversation.isEmpty && store.selectedApprovals.isEmpty && store.selectedQuestions.isEmpty {
                        EmptyConversation(workspace: store.currentWorkspace?.title ?? workspaceName(session.cwd))
                            .padding(.top, 86)
                    }

                    ForEach(store.conversation) { item in
                        ConversationItemView(
                            item: item,
                            sessionId: store.conversationSessionId ?? session.sessionId,
                            store: store,
                            voice: store.voice
                        )
                            .id(item.id)
                    }

                    ForEach(store.selectedApprovals) { approval in
                        ApprovalCard(store: store, approval: approval)
                            .id("approval:\(approval.id)")
                    }

                    ForEach(store.selectedQuestions) { question in
                        QuestionCard(store: store, pending: question)
                            .id("question:\(question.id)")
                    }

                    if !store.selectedQueue.isEmpty {
                        QueueDock(store: store, items: store.selectedQueue)
                    }

                    if !store.selectedJobs.isEmpty {
                        BackgroundJobsCard(jobs: store.selectedJobs)
                    }

                    if session.running && store.selectedApprovals.isEmpty {
                        WorkingIndicator()
                            .id("working")
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("conversation-end")
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 34)
                .padding(.top, 34)
                .padding(.bottom, 178)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [OpenCodexPalette.canvas.opacity(0), OpenCodexPalette.canvas],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 26)
                    if let goal = store.currentGoal?.goal {
                        GoalBar(store: store, goal: goal)
                            .frame(maxWidth: 760)
                            .padding(.horizontal, 34)
                            .padding(.bottom, 8)
                    }
                    Composer(store: store, prominent: false)
                        .frame(maxWidth: 760)
                        .padding(.horizontal, 34)
                        .padding(.bottom, 18)
                        .frame(maxWidth: .infinity)
                        .background(OpenCodexPalette.canvas)
                }
            }
            .onChange(of: store.conversation.count) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("conversation-end", anchor: .bottom) }
            }
            .onChange(of: store.selectedApprovals.count) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("conversation-end", anchor: .bottom) }
            }
            .onChange(of: store.selectedQuestions.count) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("conversation-end", anchor: .bottom) }
            }
        }
    }
}

private struct EmptyConversation: View {
    let workspace: String

    var body: some View {
        VStack(spacing: 10) {
            OpenCodexMark(size: 30)
            Text("Start this task")
                .font(.system(size: 18, weight: .semibold))
            Text("OpenFish is ready in \(workspace).")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ConversationItemView: View {
    let item: ConversationItem
    let sessionId: String
    @ObservedObject var store: OpenCodexStore
    @ObservedObject var voice: LocalVoiceService

    @ViewBuilder
    var body: some View {
        switch item.kind {
        case .user:
            UserMessage(item: item, sessionId: sessionId, store: store)
        case .assistant:
            AssistantMessage(item: item, sessionId: sessionId, store: store, voice: voice)
        case .activity:
            ActivityCard(item: item)
        case .notice:
            NoticeCard(item: item)
        }
    }
}

private struct UserMessage: View {
    let item: ConversationItem
    let sessionId: String
    @ObservedObject var store: OpenCodexStore

    var body: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 88)
            VStack(alignment: .leading, spacing: 8) {
                ConversationAttachments(item: item, sessionId: sessionId, store: store)
                if !item.text.isEmpty {
                    Text(markdown(item.text))
                        .font(.system(size: 15))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
            }
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .background(Color.accentColor.opacity(0.105), in: RoundedRectangle(cornerRadius: 15))
        }
    }
}

private struct AssistantMessage: View {
    let item: ConversationItem
    let sessionId: String
    @ObservedObject var store: OpenCodexStore
    @ObservedObject var voice: LocalVoiceService

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            OpenCodexMark(size: 26)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 10) {
                ConversationAttachments(item: item, sessionId: sessionId, store: store)
                if let reasoning = item.detail, !reasoning.isEmpty {
                    DisclosureGroup("Reasoning") {
                        Text(reasoning)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.top, 6)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                }

                if !item.text.isEmpty {
                    Text(markdown(item.text))
                        .font(.system(size: 15))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if item.isStreaming {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Working")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                }
                if !item.text.isEmpty && !item.isStreaming {
                    Button {
                        voice.isSpeaking ? voice.stopSpeaking() : voice.speak(item.text)
                    } label: {
                        Label(voice.isSpeaking ? "Stop reading" : "Read aloud", systemImage: voice.isSpeaking ? "stop.fill" : "speaker.wave.2")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ConversationAttachments: View {
    let item: ConversationItem
    let sessionId: String
    @ObservedObject var store: OpenCodexStore

    var body: some View {
        ForEach(item.attachments) { attachment in
            Group {
                if let data = store.cachedAttachment(sessionId: sessionId, attachmentId: attachment.attachmentId),
                   let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel(attachment.name ?? "Image attachment")
                } else if store.attachmentFailed(sessionId: sessionId, attachmentId: attachment.attachmentId) {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                        Text("Could not load \(attachment.name ?? "image")")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Button("Retry") {
                            Task {
                                await store.loadAttachment(
                                    sessionId: sessionId,
                                    attachmentId: attachment.attachmentId,
                                    retry: true
                                )
                            }
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, minHeight: 96)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(attachment.name ?? "Loading image…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 96)
                }
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(OpenCodexPalette.softBorder))
            .task(id: attachment.attachmentId) {
                await store.loadAttachment(sessionId: sessionId, attachmentId: attachment.attachmentId)
            }
        }
    }
}

private struct ActivityCard: View {
    let item: ConversationItem
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard !item.text.isEmpty else { return }
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: activityIcon(item.card))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title ?? "Tool")
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        if let detail = item.detail {
                            Text(detail)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    ActivityStatus(state: item.activityState)
                    if !item.text.isEmpty {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded, !item.text.isEmpty {
                Rectangle().fill(OpenCodexPalette.softBorder).frame(height: 1)
                ScrollView(.horizontal) {
                    Text(item.text)
                        .font(.system(size: 12.5, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                }
                .frame(maxHeight: 240)
            }
        }
        .background(OpenCodexPalette.elevated.opacity(0.62), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(OpenCodexPalette.softBorder))
        .padding(.leading, 33)
    }
}

private struct ActivityStatus: View {
    let state: ActivityState?

    var body: some View {
        switch state {
        case .running:
            ProgressView().controlSize(.mini)
        case .completed:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.red)
        case nil:
            EmptyView()
        }
    }
}

private struct NoticeCard: View {
    let item: ConversationItem

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: item.activityState == .failed ? "exclamationmark.triangle" : "info.circle")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(item.activityState == .failed ? Color.orange : Color.secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                if let title = item.title {
                    Text(title).font(.system(size: 13, weight: .semibold))
                }
                Text(item.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(OpenCodexPalette.hover, in: RoundedRectangle(cornerRadius: 10))
        .padding(.leading, 33)
    }
}

private struct ApprovalCard: View {
    @ObservedObject var store: OpenCodexStore
    let approval: PendingApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.orange)
                    .frame(width: 24, height: 24)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Approval needed")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(approval.reason ?? "Allow \(approval.toolName) to continue this task?")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Reject") {
                    Task { await store.answer(approval, allow: false) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("Allow once") {
                    Task { await store.answer(approval, allow: true) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.22)))
        .padding(.leading, 33)
    }
}

private struct QuestionCard: View {
    @ObservedObject var store: OpenCodexStore
    let pending: PendingQuestion
    @State private var selections: [String: [String]] = [:]
    @State private var custom: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("OpenFish needs your input", systemImage: "questionmark.bubble")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            ForEach(pending.questions) { item in
                VStack(alignment: .leading, spacing: 8) {
                    if let header = item.header {
                        Text(header.uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    Text(item.question)
                        .font(.system(size: 12.5, weight: .medium))
                    if let detail = item.detail {
                        Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                    ForEach(item.options ?? []) { option in
                        Toggle(isOn: optionBinding(question: item, label: option.label)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label).font(.system(size: 13, weight: .medium))
                                if let description = option.description {
                                    Text(description).font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                    TextField("Or type an answer", text: Binding(
                        get: { custom[item.id] ?? "" },
                        set: { custom[item.id] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                }
            }
            HStack {
                Spacer()
                Button("Submit") {
                    Task { await store.answer(pending, selections: selections, custom: custom) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor.opacity(0.20)))
        .padding(.leading, 33)
    }

    private func optionBinding(question: QuestionItem, label: String) -> Binding<Bool> {
        Binding(
            get: { selections[question.id]?.contains(label) == true },
            set: { selected in
                var values = selections[question.id] ?? []
                if selected {
                    if question.multiSelect == true {
                        if !values.contains(label) { values.append(label) }
                    } else {
                        values = [label]
                    }
                } else {
                    values.removeAll { $0 == label }
                }
                selections[question.id] = values
            }
        )
    }
}

private struct GoalBar: View {
    @ObservedObject var store: OpenCodexStore
    let goal: GoalView

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "scope")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(goal.objective).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Text("Goal · \(goal.phase)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if goal.phase == "active" {
                Button("Pause") { Task { await store.mutateGoal("pause") } }
            } else if goal.phase == "paused" || goal.phase == "blocked" {
                Button("Resume") { Task { await store.mutateGoal("resume") } }
            }
            if goal.phase != "complete" {
                Button("Complete") { Task { await store.mutateGoal("complete") } }
            }
            Button {
                Task { await store.mutateGoal("clear") }
            } label: { Image(systemName: "xmark") }
                .help("Clear goal")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(12)
        .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.15)))
    }
}

private struct QueueDock: View {
    @ObservedObject var store: OpenCodexStore
    let items: [QueuedInboxItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Queued work", systemImage: "text.line.first.and.arrowtriangle.forward")
                .font(.system(size: 13, weight: .semibold))
            ForEach(items) { item in
                QueueRow(store: store, item: item)
            }
        }
        .padding(12)
        .background(OpenCodexPalette.hover, in: RoundedRectangle(cornerRadius: 11))
        .padding(.leading, 33)
    }
}

private struct QueueRow: View {
    @ObservedObject var store: OpenCodexStore
    let item: QueuedInboxItem
    @State private var editing = false
    @State private var replacement = ""

    var body: some View {
        HStack(spacing: 8) {
            Text(item.text.isEmpty ? "Pending \(item.placement) message" : item.text)
                .font(.system(size: 12))
                .lineLimit(2)
            Spacer()
            if item.placement == "queued" {
                Button("Steer") { Task { await store.mutateQueue(item, action: "steer") } }
            }
            Button("Edit") {
                replacement = item.text
                editing = true
            }
            Button(role: .destructive) {
                Task { await store.mutateQueue(item, action: "remove") }
            } label: { Image(systemName: "trash") }
        }
        .buttonStyle(.borderless)
        .controlSize(.mini)
        .alert("Edit queued message", isPresented: $editing) {
            TextField("Message", text: $replacement)
            Button("Cancel", role: .cancel) {}
            Button("Save") { Task { await store.mutateQueue(item, action: "edit", replacement: replacement) } }
        }
    }
}

private struct BackgroundJobsCard: View {
    let jobs: [BackgroundJob]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Background jobs", systemImage: "clock.arrow.2.circlepath")
                .font(.system(size: 13, weight: .semibold))
            ForEach(jobs) { job in
                HStack(spacing: 8) {
                    Circle()
                        .fill(job.status == "running" ? Color.green : Color.secondary.opacity(0.35))
                        .frame(width: 6, height: 6)
                    Text(job.label).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Text(job.detail ?? job.status)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(OpenCodexPalette.hover, in: RoundedRectangle(cornerRadius: 11))
        .padding(.leading, 33)
    }
}

private struct WorkingIndicator: View {
    var body: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text("OpenFish is working…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 34)
    }
}

// MARK: - Composer

private struct AlignedComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let canSubmit: Bool
    let submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ComposerScrollView()
        let clipView = LeadingComposerClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.placeholder = placeholder
        textView.onSubmit = { [weak coordinator = context.coordinator] in
            guard coordinator?.parent.canSubmit == true else { return }
            coordinator?.parent.submit()
        }
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let composerScrollView = scrollView as? ComposerScrollView,
              let textView = scrollView.documentView as? ComposerNSTextView else { return }
        if textView.string != text { textView.string = text }
        textView.placeholder = placeholder
        textView.needsDisplay = true
        composerScrollView.pinDocumentToViewport()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AlignedComposerTextView

        init(_ parent: AlignedComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            textView.needsDisplay = true
        }
    }
}

/// AppKit centers a document view that is temporarily narrower than its clip
/// view by returning a negative horizontal bounds origin. The composer changes
/// width when its async controls load, so prevent that centering at the source.
private final class LeadingComposerClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        bounds.origin.x = 0
        return bounds
    }
}

/// Keeps AppKit's document view pinned to the clip view's leading edge.
///
/// A freshly-created `NSTextView` has a narrow default frame. `NSClipView`
/// centers a document view that is narrower than its viewport, which made the
/// insertion point jump roughly 100 points to the right until the editor had
/// enough content to grow. SwiftUI can resize the representable without
/// calling `updateNSView`, so enforce the document width during AppKit layout.
private final class ComposerScrollView: NSScrollView {
    private var isPinningDocument = false

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        pinDocumentToViewport()
    }

    override func layout() {
        super.layout()
        pinDocumentToViewport()
    }

    func pinDocumentToViewport() {
        guard !isPinningDocument, let documentView else { return }
        isPinningDocument = true
        defer { isPinningDocument = false }

        let viewport = contentSize
        guard viewport.width > 0 else { return }
        var documentFrame = documentView.frame
        let targetHeight = max(documentFrame.height, viewport.height)
        if abs(documentFrame.minX) > 0.5
            || abs(documentFrame.width - viewport.width) > 0.5
            || abs(documentFrame.height - targetHeight) > 0.5 {
            documentFrame.origin.x = 0
            documentFrame.size.width = viewport.width
            documentFrame.size.height = targetHeight
            documentView.frame = documentFrame
        }

        // Resizing the document view is not enough. If AppKit laid out the
        // original narrow text view first, NSClipView keeps the negative x
        // origin it used to center that view. Reset the viewport as well so
        // the caret and placeholder remain pinned to the leading inset.
        if abs(contentView.bounds.origin.x) > 0.5 {
            contentView.setBoundsOrigin(NSPoint(x: 0, y: contentView.bounds.origin.y))
            reflectScrolledClipView(contentView)
        }
    }
}

private final class ComposerNSTextView: NSTextView {
    var placeholder = ""
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, !event.modifierFlags.contains(.shift) {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        placeholder.draw(
            at: NSPoint(x: textContainerInset.width, y: textContainerInset.height),
            withAttributes: attributes
        )
    }
}

private struct Composer: View {
    @ObservedObject var store: OpenCodexStore
    let prominent: Bool
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !store.pendingImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(store.pendingImages) { image in
                            HStack(spacing: 6) {
                                Image(systemName: "photo")
                                Text(image.name).lineLimit(1)
                                Button { store.removeImage(image.id) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                            }
                            .font(.system(size: 11.5))
                            .padding(.horizontal, 8)
                            .frame(height: 25)
                            .background(OpenCodexPalette.hover, in: Capsule())
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 9)
                }
                if !store.canAttachImages {
                    Label("The active Harness does not accept images. Remove them or switch Harness before sending.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 13)
                        .padding(.top, 5)
                }
            }
            AlignedComposerTextView(
                text: $store.draft,
                placeholder: store.selectedSessionId == nil ? "Describe a task" : "Ask OpenFish to follow up",
                canSubmit: store.canSend,
                submit: { Task { await store.send() } }
            )
            .focused($focused)
            .frame(
                minWidth: 0,
                maxWidth: .infinity,
                minHeight: prominent ? 78 : 52,
                maxHeight: prominent ? 150 : 96,
                alignment: .topLeading
            )
            .accessibilityIdentifier("OpenFish.Composer")
            .padding(.horizontal, 12)
            .padding(.top, 7)

            RunIdentityLine(store: store)
                .padding(.horizontal, 13)
                .padding(.bottom, 7)

            HStack(spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        ComposerCapabilityMenu(store: store)
                        if store.canChooseHarness {
                            HarnessPicker(store: store)
                        }
                        // Keep the model control mounted while Harness capabilities refresh.
                        // Some ACP processes advertise their catalog asynchronously; removing
                        // this view would also destroy an open selection sheet mid-click.
                        ModelPicker(store: store)
                        // A capability refresh must not make an existing control jump
                        // out of the composer. The menu explains unsupported states.
                        ReasoningPicker(store: store)
                        HarnessAccountBadge(store: store)
                        WorkspacePicker(store: store)
                        PermissionPicker(store: store)
                        ComposerOverflowMenu(store: store)
                        if store.currentSession?.running == true {
                            Menu {
                                Button("Queue after current turn") { store.composerMode = "queue" }
                                Button("Steer current turn") { store.composerMode = "steer" }
                            } label: {
                                Label(store.composerMode == "steer" ? "Steer" : "Queue", systemImage: "arrow.triangle.branch")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .frame(height: 26)
                                    .background(OpenCodexPalette.hover, in: RoundedRectangle(cornerRadius: 7))
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }

                    // Model identity is part of the task contract, so the
                    // compact toolbar must never hide it in a scroll view.
                    // Secondary controls remain available from the overflow
                    // and settings surfaces when the window is narrow.
                    HStack(spacing: 8) {
                        if store.canChooseHarness {
                            HarnessPicker(store: store)
                        }
                        ModelPicker(store: store)
                        ReasoningPicker(store: store)
                        HarnessAccountBadge(store: store, compact: true)
                        ComposerOverflowMenu(store: store)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    Task { await store.toggleDictation() }
                } label: {
                    Group {
                        if store.voice.isStarting {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: store.voice.isListening ? "waveform.circle.fill" : "mic")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(store.voice.isListening ? Color.red : Color.secondary)
                        }
                    }
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(store.voice.isStarting)
                .help(store.voice.isListening ? "Stop local dictation" : "Dictate locally")
                .accessibilityIdentifier("OpenFish.Dictation")

                if store.currentSession?.running == true {
                    Button {
                        Task { await store.cancelCurrentTask() }
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 28, height: 28)
                            .background(Color.primary.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Stop task")
                    .accessibilityIdentifier("OpenFish.Stop")
                }

                Button {
                    Task { await store.send() }
                } label: {
                    ZStack {
                        Circle()
                            .fill(store.canSend ? Color.accentColor : Color.primary.opacity(0.08))
                            .frame(width: 30, height: 30)
                        if store.isSubmitting {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(.white)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 12.5, weight: .bold))
                                .foregroundStyle(store.canSend ? Color.white : Color.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!store.canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("OpenFish.Send")
            }
            .padding(.horizontal, 11)
            .padding(.bottom, 10)
        }
        .background(OpenCodexPalette.elevated, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(OpenCodexPalette.border))
        .shadow(color: .black.opacity(0.07), radius: 16, y: 5)
        .onAppear { if prominent { focused = true } }
    }
}

private struct RunIdentityLine: View {
    @ObservedObject var store: OpenCodexStore

    private var host: String {
        store.connectionProfile.isLocal ? "Local Mac" : (store.connectionProfile.baseURL.host ?? "Remote Host")
    }

    private var account: String {
        if let runtime = store.sessionModels?.account { return runtime.label }
        guard let harness = store.currentHarness else {
            return store.isLoadingSessionModels ? "Checking Harness account…" : "Harness account status unavailable"
        }
        switch harness.auth.selectedMethod {
        case let methodID?:
            let method = harness.auth.methods.first(where: { $0.id == methodID })
            return method?.account?.label ?? method?.name ?? methodID
        default:
            guard harness.auth.status == "not-required" else { return "Account not configured" }
            return harness.account?.label ?? "Account and billing not declared by this Pack"
        }
    }

    private var workspace: String {
        store.currentWorkspace?.title ?? selectedWorkspaceTitle(store)
    }

    private var provider: String {
        guard let models = store.sessionModels else { return "Provider pending" }
        let group = models.groups.first(where: { $0.id == models.current.provider })
        let model = group?.models.first(where: { $0.id == models.current.model })
        return model?.providerName ?? (models.current.provider == "harness" ? "Provider not declared" : (group?.name ?? models.current.provider))
    }

    private var harness: String {
        guard let value = store.currentHarness else { return "Harness pending" }
        return "\(value.name) \(store.controlHarnessVersionLabel)"
    }

    private var model: String {
        store.isLoadingSessionModels ? "Checking model…" : store.currentModelName
    }

    private var reasoning: String {
        store.currentReasoningLabel
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) {
                identity("Host", host, icon: "desktopcomputer")
                separator
                identity("Workspace", workspace, icon: "folder")
                separator
                identity("Access", store.currentPermissionName, icon: "shield")
                Spacer(minLength: 8)
                identity("Harness", harness, icon: "shippingbox")
                separator
                identity("Account", account, icon: "person.crop.circle")
                separator
                identity("Provider", provider, icon: "network")
                separator
                identity("Model", model, icon: "cpu")
                separator
                identity("Reasoning", reasoning, icon: "brain.head.profile")
            }
            HStack(spacing: 7) {
                identity("Workspace", workspace, icon: "folder")
                separator
                identity("Access", store.currentPermissionName, icon: "shield")
                Spacer(minLength: 8)
                identity("Harness", harness, icon: "shippingbox")
                separator
                identity("Model", model, icon: "cpu")
                separator
                identity("Reasoning", reasoning, icon: "brain.head.profile")
            }
            HStack(spacing: 7) {
                identity("Workspace", workspace, icon: "folder")
                Spacer(minLength: 8)
                identity("Harness", harness, icon: "shippingbox")
                separator
                identity("Model", model, icon: "cpu")
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .help("Host: \(host) · Workspace: \(workspace) · Permission: \(store.currentPermissionName) · Harness: \(harness) · Account: \(account) · Provider: \(provider) · Model: \(model) · Reasoning: \(reasoning)")
        .accessibilityLabel("Host \(host), workspace \(workspace), permission \(store.currentPermissionName), Harness \(harness), account \(account), provider \(provider), model \(model), reasoning \(reasoning)")
    }

    private var separator: some View {
        Text("·").foregroundStyle(.quaternary)
    }

    private func identity(_ title: String, _ value: String, icon: String) -> some View {
        Label("\(title) · \(value)", systemImage: icon)
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct ComposerOverflowMenu: View {
    @ObservedObject var store: OpenCodexStore
    @State private var fullAccessOption: PermissionOption?

    private var harnessOptions: [HarnessConfigOption] {
        (store.sessionModels?.harnessOptions ?? []).filter {
            $0.category != "model" && $0.category != "thought_level"
        }
    }

    var body: some View {
        Menu {
            if !harnessOptions.isEmpty {
                Menu("Harness options") {
                    ForEach(harnessOptions) { option in
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
                }
            }

            if store.canChooseAgentPreset {
                Menu("Agent preset") {
                    ForEach(store.agentPresets?.presets ?? []) { preset in
                        Button {
                            Task { await store.chooseAgentPreset(preset) }
                        } label: {
                            if preset.id == store.currentAgentPreset {
                                Label(preset.name ?? preset.id, systemImage: "checkmark")
                            } else {
                                Text(preset.name ?? preset.id)
                            }
                        }
                        .disabled(preset.broken != nil)
                    }
                }
            }

            if !harnessOptions.isEmpty || store.canChooseAgentPreset {
                Divider()
            }
            if store.selectedSessionId == nil {
                Menu("Project") {
                    Button("No Project") { store.changeNewTaskWorkspace(to: nil) }
                    ForEach(store.workspaces) { workspace in
                        Button {
                            store.changeNewTaskWorkspace(to: workspace.workspaceId)
                        } label: {
                            if store.selectedWorkspaceId == workspace.workspaceId {
                                Label(workspace.title, systemImage: "checkmark")
                            } else {
                                Text(workspace.title)
                            }
                        }
                    }
                    Divider()
                    Button("Add project…") { Task { await store.addWorkspace() } }
                }
            }
            if let permissions = store.currentPermissions {
                Menu("Access · \(store.currentPermissionName)") {
                    ForEach(permissions.options.filter { $0.value != "custom" }) { option in
                        Button {
                            if option.value == "danger-full-access" {
                                fullAccessOption = option
                            } else {
                                Task { await store.choosePermission(option) }
                            }
                        } label: {
                            if option.value == permissions.currentValue {
                                Label(option.name, systemImage: "checkmark")
                            } else {
                                Text(option.name)
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Open Harness settings…") {
                store.isSettingsPresented = true
                Task { await store.loadSettings() }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 26, height: 26)
                .background(OpenCodexPalette.hover, in: RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("More runtime options")
        .accessibilityLabel("More runtime options")
        .alert(
            "Enable Full Access?",
            isPresented: Binding(
                get: { fullAccessOption != nil },
                set: { if !$0 { fullAccessOption = nil } }
            ),
            presenting: fullAccessOption
        ) { option in
            Button("Cancel", role: .cancel) { fullAccessOption = nil }
            Button("Enable Full Access", role: .destructive) {
                fullAccessOption = nil
                Task { await store.choosePermission(option) }
            }
        } message: { option in
            Text(option.description ?? "OpenFish will be able to run commands and change files outside the workspace sandbox.")
        }
    }
}

private struct ComposerCapabilityMenu: View {
    @ObservedObject var store: OpenCodexStore
    @State private var creatingGoal = false
    @State private var goalObjective = ""

    var body: some View {
        Menu {
            if store.canAttachImages {
                Button {
                    chooseImages(store: store)
                } label: {
                    Label("Attach images…", systemImage: "photo.badge.plus")
                }
            } else {
                Label("Images unavailable for this Harness", systemImage: "exclamationmark.triangle")
            }
            Divider()
            if !store.skills.isEmpty {
                Menu("Skills") {
                    ForEach(store.skills) { skill in
                        Button(skill.name) { store.draft = "/\(skill.name) " }
                    }
                }
            }
            if !store.visibleCommands.isEmpty {
                Menu("Commands") {
                    ForEach(Array(store.visibleCommands.enumerated()), id: \.offset) { _, command in
                        if let name = command["name"]?.stringValue {
                            Button(name) { store.draft = "/\(name) " }
                        }
                    }
                }
            }
            Divider()
            Button(store.currentPlan?.active == true ? "Turn plan mode off" : "Turn plan mode on") {
                Task { await store.setPlanEnabled(store.currentPlan?.active != true) }
            }
            Button("Create goal…") {
                goalObjective = ""
                creatingGoal = true
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11.5, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(OpenCodexPalette.hover, in: RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .alert("Create goal", isPresented: $creatingGoal) {
            TextField("Objective", text: $goalObjective)
            Button("Cancel", role: .cancel) {}
            Button("Create") { Task { await store.createGoal(objective: goalObjective, maxRounds: nil) } }
        }
    }
}

private struct AgentPresetPicker: View {
    @ObservedObject var store: OpenCodexStore

    var body: some View {
        Menu {
            ForEach(store.agentPresets?.presets ?? []) { preset in
                Button {
                    Task { await store.chooseAgentPreset(preset) }
                } label: {
                    if preset.id == store.currentAgentPreset {
                        Label(preset.name ?? preset.id, systemImage: "checkmark")
                    } else {
                        Text(preset.name ?? preset.id)
                    }
                }
                .disabled(preset.broken != nil)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.crop.circle.badge.gearshape")
                Text(store.currentAgentPreset ?? "Agent")
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(OpenCodexPalette.hover, in: RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(store.agentPresets?.presets.isEmpty != false)
    }
}

private func harnessDisplayName(_ harness: HarnessCatalogEntry, among catalog: [HarnessCatalogEntry]) -> String {
    let hasCollision = catalog.contains {
        $0.id != harness.id
            && $0.name.localizedCaseInsensitiveCompare(harness.name) == .orderedSame
    }
    return hasCollision ? "\(harness.name) · \(harness.protocolName.uppercased())" : harness.name
}

private func harnessNeedsDriverBundleConsent(_ harness: HarnessCatalogEntry) -> Bool {
    harness.driverBundle != nil
        && (harness.driver.authorization == "required"
            || !harness.driver.loaded
            || harness.installation.status != "installed"
            || harness.installation.installedVersion != harness.installation.availableVersion)
}

private func harnessNeedsExecutionConsent(_ harness: HarnessCatalogEntry) -> Bool {
    let addsUnreviewedHarnessCode = !harness.verified
        && harness.source != "user"
        && harness.installation.status != "installed"
    return addsUnreviewedHarnessCode || harnessNeedsDriverBundleConsent(harness)
}

private func harnessCanPrepare(_ harness: HarnessCatalogEntry) -> Bool {
    guard harness.publication?.status != "revoked" else { return false }
    return harness.available
        || (harness.installation.status == "installed"
            && harness.auth.status == "unknown"
            && harness.driver.loaded
            && harness.driver.authorization != "required"
            && harness.unavailableReason == harness.auth.detail)
        || (harness.driverBundle != nil
            && (harness.driver.authorization == "required" || !harness.driver.loaded)
            && OpenFishDriverManager.isAvailable)
}

private func harnessExecutionConsentTitle(_ harness: HarnessCatalogEntry?) -> String {
    guard let harness, harnessNeedsDriverBundleConsent(harness) else {
        return "Install an unverified Harness?"
    }
    return "Install the required Harness Driver?"
}

private func harnessExecutionConsentMessage(_ harness: HarnessCatalogEntry?) -> String {
    guard let harness else { return "Review the exact code source before continuing." }
    var paragraphs: [String] = []
    if let bundle = harness.driverBundle, harnessNeedsDriverBundleConsent(harness) {
        paragraphs.append(
            "\(harness.name) declares \(bundle.package) from the exact source \(bundle.spec) for protocol \(harness.protocolName). OpenFish will stage and validate that Driver Bundle, restart only its verified embedded Host, confirm Driver API v1 registration, and then continue."
        )
        paragraphs.append(
            bundle.requiresInstallScripts
                ? "This exact Bundle declares npm lifecycle scripts. Those scripts run locally before structural Driver admission."
                : "npm lifecycle scripts remain disabled for this Bundle."
        )
    }
    if !harness.verified && harness.source != "user" {
        paragraphs.append(
            "The Harness Pack format and exact version were validated, but OpenFish has not audited its publisher or executable contents."
        )
    }
    return paragraphs.joined(separator: "\n\n")
}

private struct HarnessDestructiveAction: Identifiable {
    let operation: String
    let harness: HarnessCatalogEntry

    var id: String { "\(operation):\(harness.id):\(harness.version)" }
    var confirmationTitle: String { operation == "remove" ? "Remove Pack" : "Uninstall Harness" }
    var title: String {
        operation == "remove"
            ? "Remove \(harness.name) from OpenFish?"
            : "Uninstall \(harness.name)?"
    }
    var message: String {
        if operation == "remove" {
            return "This deletes the local Pack definition, every installed version, and its private Harness runtime data. Tasks pinned to this Harness block removal. Shared provider credentials in Keychain remain, and an already-published catalog version must be revoked separately."
        }
        return "This removes every installed version and its private Harness runtime data, including Harness-owned sign-in and session caches. Tasks pinned to this Harness block removal. Shared provider credentials in Keychain remain."
    }
}

private struct HarnessPicker: View {
    @ObservedObject var store: OpenCodexStore
    @State private var showingCatalog = ProcessInfo.processInfo.arguments.contains("--openfish-demo-harness-catalog")
    @State private var showingEditor = false
    @State private var authSelection: HarnessAuthSelection?
    @State private var query = ""
    @State private var inspectedHarnessId: String?
    @State private var pendingCommunityHarness: HarnessCatalogEntry?
    @State private var pendingCommunityAction: String?
    @State private var pendingCommunityAuthSelection: HarnessAuthSelection?
    @State private var pendingDestructiveAction: HarnessDestructiveAction?
    @State private var lens = "Simple"

    private var filtered: [HarnessCatalogEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return store.harnesses }
        return store.harnesses.filter {
            $0.id.lowercased().contains(needle)
                || $0.name.lowercased().contains(needle)
                || ($0.description?.lowercased().contains(needle) ?? false)
        }
    }

    private func subtitle(_ harness: HarnessCatalogEntry) -> String {
        harness.description ?? "\(harness.publisher) · \(harness.protocolName.uppercased())"
    }

    private var inspectedHarness: HarnessCatalogEntry? {
        store.harnesses.first { $0.id == inspectedHarnessId } ?? store.currentHarness ?? filtered.first
    }

    private var pendingConsentHarness: HarnessCatalogEntry? {
        pendingCommunityAuthSelection?.harness ?? pendingCommunityHarness
    }

    var body: some View {
        Button { showingCatalog = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "cpu")
                Text(store.currentHarness.map { harnessDisplayName($0, among: store.harnesses) } ?? store.currentHarnessId).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .frame(maxWidth: 110, alignment: .leading)
            .background(OpenCodexPalette.hover, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("OpenFish.HarnessPicker")
        .sheet(isPresented: $showingCatalog) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Harnesses")
                            .font(.system(size: 18, weight: .semibold))
                        Text("Choose the execution system for this task. Existing tasks keep their Harness.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { await store.refreshHarnessCatalog() } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    Button { showingEditor = true } label: {
                        Label("New Pack", systemImage: "plus")
                    }
                    Button("Done") { showingCatalog = false }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(16)

                Divider()

                HStack(spacing: 0) {
                    VStack(spacing: 10) {
                        HStack(spacing: 7) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.tertiary)
                            TextField("Find a Harness", text: $query)
                                .textFieldStyle(.plain)
                        }
                        .padding(.horizontal, 9)
                        .frame(height: 32)
                        .background(OpenCodexPalette.hover, in: RoundedRectangle(cornerRadius: 7))

                        ScrollView {
                            LazyVStack(spacing: 3) {
                                ForEach(filtered) { harness in
                                    HStack(alignment: .center, spacing: 6) {
                                        Button {
                                            inspectedHarnessId = harness.id
                                            lens = "Simple"
                                        } label: {
                                            HStack(alignment: .top, spacing: 9) {
                                                Image(systemName: harness.id == store.currentHarnessId ? "checkmark.circle.fill" : "shippingbox")
                                                    .foregroundStyle(harness.id == store.currentHarnessId ? Color.accentColor : Color.secondary)
                                                    .frame(width: 17)
                                                VStack(alignment: .leading, spacing: 3) {
                                                    HStack(spacing: 5) {
                                                        Text(harnessDisplayName(harness, among: store.harnesses))
                                                            .font(.system(size: 12.5, weight: .semibold))
                                                        if harness.verified {
                                                            Image(systemName: "checkmark.seal.fill")
                                                                .foregroundStyle(.blue)
                                                                .font(.caption2)
                                                        }
                                                    }
                                                    Text(subtitle(harness))
                                                        .font(.system(size: 10.5))
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(2)
                                                    Text("v\(harness.version) · \(harness.installation.status.replacingOccurrences(of: "-", with: " ")) · \(harness.compatibility.classification.replacingOccurrences(of: "-", with: " "))")
                                                        .font(.system(size: 9.5, weight: .medium))
                                                        .foregroundStyle(.tertiary)
                                                    if let reason = harness.unavailableReason {
                                                        Text(reason)
                                                            .font(.system(size: 10))
                                                            .foregroundStyle(.red)
                                                            .lineLimit(2)
                                                    }
                                                }
                                                Spacer(minLength: 0)
                                            }
                                            .padding(8)
                                            .contentShape(Rectangle())
                                            .background(
                                                inspectedHarness?.id == harness.id ? OpenCodexPalette.selected : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 7)
                                            )
                                        }
                                        .buttonStyle(.plain)

                                        if harness.installation.status != "builtin" {
                                            Menu {
                                                if harness.installation.status == "installed" {
                                                    if harness.installation.installedVersion != harness.installation.availableVersion {
                                                        Button("Update") { requestMutation("update", harness: harness) }
                                                    }
                                                    if !harness.installation.previousVersions.isEmpty {
                                                        Button("Roll back") { requestMutation("rollback", harness: harness) }
                                                    }
                                                    Button("Uninstall", role: .destructive) {
                                                        pendingDestructiveAction = HarnessDestructiveAction(operation: "uninstall", harness: harness)
                                                    }
                                                } else {
                                                    Button("Install") { requestMutation("install", harness: harness) }
                                                }
                                                if harness.source == "user" {
                                                    Divider()
                                                    Button("Remove Pack", role: .destructive) {
                                                        pendingDestructiveAction = HarnessDestructiveAction(operation: "remove", harness: harness)
                                                    }
                                                }
                                            } label: {
                                                if store.harnessOperationId == harness.id { ProgressView().controlSize(.small) }
                                                else { Image(systemName: "ellipsis") }
                                            }
                                            .menuStyle(.borderlessButton)
                                            .frame(width: 22)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(12)
                    .frame(width: 294)

                    Divider()

                    VStack(spacing: 0) {
                        if let inspectedHarness {
                            ScrollView {
                                HarnessProgressiveLensPanel(
                                    store: store,
                                    harness: inspectedHarness,
                                    lens: $lens,
                                    showingCreateEditor: $showingEditor
                                )
                                    .padding(16)
                            }
                            Divider()
                            HStack {
                                Text(inspectedHarness.available
                                     ? "Ready for this task"
                                     : harnessCanPrepare(inspectedHarness)
                                        ? "Exact Driver install required"
                                        : (inspectedHarness.unavailableReason ?? "Unavailable"))
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(inspectedHarness.available ? Color.secondary : harnessCanPrepare(inspectedHarness) ? Color.orange : Color.red)
                                Spacer()
                                if inspectedHarness.auth.status == "unknown" {
                                    Button(inspectedHarness.installation.status == "installed" ? "Inspect setup again" : "Install to inspect setup") {
                                        requestMutation("install", harness: inspectedHarness)
                                    }
                                    .disabled(!harnessCanPrepare(inspectedHarness) || store.harnessOperationId != nil)
                                } else if !inspectedHarness.auth.methods.isEmpty {
                                    Menu(accountButtonTitle(inspectedHarness)) {
                                        ForEach(inspectedHarness.auth.methods) { method in
                                            Button {
                                                requestAuthentication(HarnessAuthSelection(
                                                    harness: inspectedHarness, method: method,
                                                    makeDefault: false, completesOnboarding: false, selectForDraft: true
                                                ))
                                            } label: {
                                                if inspectedHarness.auth.selectedMethod == method.id {
                                                    Label(method.name, systemImage: "checkmark")
                                                } else {
                                                    Text(method.name)
                                                }
                                            }
                                        }
                                    }
                                    .disabled(!harnessCanPrepare(inspectedHarness) || store.harnessOperationId != nil)
                                }
                                let selectedIdentity = inspectedHarness.id == store.currentHarnessId
                                    && inspectedHarness.auth.selectedMethod == store.currentHarnessAuthMethod
                                Button(selectedIdentity ? "Selected" : "Use for this task") {
                                    use(inspectedHarness)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(
                                    selectedIdentity || !harnessCanPrepare(inspectedHarness)
                                        || store.harnessOperationId != nil
                                        || (inspectedHarness.auth.status != "not-required" && inspectedHarness.auth.status != "configured")
                                )
                            }
                            .padding(14)
                        } else {
                            ContentUnavailableView("No Harnesses", systemImage: "shippingbox", description: Text("Refresh the catalog or create a Harness Pack."))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 840, minHeight: 580)
            // The catalog is already a sheet. Present its editor and
            // credential flow from inside that sheet; sibling sheet
            // modifiers on HarnessPicker are ignored by SwiftUI while the
            // catalog presentation is active.
            .sheet(isPresented: $showingEditor) {
                HarnessPackEditor(store: store, isPresented: $showingEditor)
            }
            .sheet(item: $authSelection) {
                selection in HarnessCredentialsSheet(store: store, selection: selection)
            }
            .alert(harnessExecutionConsentTitle(pendingConsentHarness), isPresented: Binding(
                get: { pendingCommunityHarness != nil || pendingCommunityAuthSelection != nil },
                set: { if !$0 { clearPendingCommunityAction() } }
            )) {
                Button("Cancel", role: .cancel) { clearPendingCommunityAction() }
                Button(communityConfirmationTitle) {
                    if var selection = pendingCommunityAuthSelection {
                        clearPendingCommunityAction()
                        selection.acceptUnverified = true
                        selection.acceptDriverBundle = true
                        authSelection = selection
                    } else if let harness = pendingCommunityHarness {
                        let action = pendingCommunityAction
                        clearPendingCommunityAction()
                        if action == "use" {
                            useConfirmed(harness, acceptUnverified: true, acceptDriverBundle: true)
                        }
                        else if let action {
                            Task {
                                await store.mutateHarness(
                                    action, harness: harness,
                                    acceptUnverified: true, acceptDriverBundle: true
                                )
                            }
                        }
                    }
                }
            } message: {
                Text(harnessExecutionConsentMessage(pendingConsentHarness))
            }
            .confirmationDialog(
                pendingDestructiveAction?.title ?? "Confirm Harness removal",
                isPresented: Binding(
                    get: { pendingDestructiveAction != nil },
                    set: { if !$0 { pendingDestructiveAction = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let action = pendingDestructiveAction {
                    Button(action.confirmationTitle, role: .destructive) {
                        pendingDestructiveAction = nil
                        Task { await store.mutateHarness(action.operation, harness: action.harness) }
                    }
                }
                Button("Cancel", role: .cancel) { pendingDestructiveAction = nil }
            } message: {
                Text(pendingDestructiveAction?.message ?? "")
            }
        }
    }

    private var communityConfirmationTitle: String {
        if pendingCommunityAuthSelection != nil || pendingCommunityAction == "use" { return "Install and use" }
        if pendingCommunityAction == "update" { return "Install update" }
        return "Install"
    }

    private func accountButtonTitle(_ harness: HarnessCatalogEntry) -> String {
        guard let selected = harness.auth.selectedMethod else { return "Choose account" }
        let method = harness.auth.methods.first(where: { $0.id == selected })
        return "Account · \(method?.account?.label ?? method?.name ?? selected)"
    }

    private func use(_ harness: HarnessCatalogEntry) {
        if harnessNeedsExecutionConsent(harness) {
            pendingCommunityHarness = harness
            pendingCommunityAction = "use"
            return
        }
        useConfirmed(harness)
    }

    private func useConfirmed(
        _ harness: HarnessCatalogEntry,
        acceptUnverified: Bool = false,
        acceptDriverBundle: Bool = false
    ) {
        if harness.auth.status == "not-required" || harness.auth.status == "configured" {
            store.chooseHarness(
                harness,
                acceptUnverified: acceptUnverified,
                acceptDriverBundle: acceptDriverBundle
            )
            showingCatalog = false
        } else if let method = harness.auth.methods.first {
            var selection = HarnessAuthSelection(
                harness: harness, method: method, makeDefault: false,
                completesOnboarding: false, selectForDraft: true
            )
            selection.acceptUnverified = acceptUnverified
            selection.acceptDriverBundle = acceptDriverBundle
            authSelection = selection
        }
    }

    private func requestAuthentication(_ selection: HarnessAuthSelection) {
        let harness = selection.harness
        if harnessNeedsExecutionConsent(harness) {
            pendingCommunityAuthSelection = selection
        } else {
            authSelection = selection
        }
    }

    private func requestMutation(_ action: String, harness: HarnessCatalogEntry) {
        if action == "rollback" {
            Task {
                guard let candidate = await store.rollbackHarnessCandidate(harness) else { return }
                if candidate.driverBundle != nil || (!candidate.verified && candidate.source != "user") {
                    pendingCommunityHarness = candidate
                    pendingCommunityAction = action
                } else {
                    await store.mutateHarness(action, harness: candidate)
                }
            }
            return
        }
        let needsUpdateConsent = action == "update" && !harness.verified && harness.source != "user"
        if needsUpdateConsent || harnessNeedsExecutionConsent(harness) {
            pendingCommunityHarness = harness
            pendingCommunityAction = action
        } else {
            Task { await store.mutateHarness(action, harness: harness) }
        }
    }

    private func clearPendingCommunityAction() {
        pendingCommunityHarness = nil
        pendingCommunityAction = nil
        pendingCommunityAuthSelection = nil
    }
}

private struct HarnessAuthSelection: Identifiable {
    let harness: HarnessCatalogEntry
    let method: HarnessCatalogEntry.Authentication.Method
    let makeDefault: Bool
    let completesOnboarding: Bool
    var selectForDraft = false
    var acceptUnverified = false
    var acceptDriverBundle = false
    var id: String { "\(harness.id):\(method.id)" }
}

private struct HarnessCredentialsSheet: View {
    @ObservedObject var store: OpenCodexStore
    let selection: HarnessAuthSelection
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var saving = false

    private var complete: Bool {
        selection.method.fields.allSatisfy { !$0.required || !(values[$0.ref] ?? "").isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Configure \(selection.harness.name)").font(.title2.bold())
            Text(selection.method.kind == "terminal"
                ? "OpenFish will open the installed Harness's official sign-in in Terminal and wait for it to finish. No secret is returned to the app."
                : selection.method.fields.isEmpty
                ? "Confirm this sign-in method before OpenFish asks the installed Harness to use it. No secret is returned to the app."
                : "Configuration values are written to the Host credential service and are never stored in the Harness Pack. Secret fields are never returned to the app.")
                .font(.callout).foregroundStyle(.secondary)
            GroupBox("Account and billing") {
                VStack(alignment: .leading, spacing: 5) {
                    Text(selection.method.account?.label ?? selection.method.name)
                        .font(.callout.weight(.semibold))
                    Text(selection.method.account?.detail ?? "This Harness has not declared who owns billing for this authentication method.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Billing · \(selection.method.account?.billing.replacingOccurrences(of: "-", with: " ").capitalized ?? "Not declared")")
                        .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(selection.method.fields) { field in
                VStack(alignment: .leading, spacing: 5) {
                    Text(field.name).font(.caption.weight(.medium))
                    if field.secret {
                        SecureField(field.placeholder ?? field.ref, text: Binding(
                            get: { values[field.ref] ?? "" }, set: { values[field.ref] = $0 }
                        )).textFieldStyle(.roundedBorder)
                    } else {
                        TextField(field.placeholder ?? field.ref, text: Binding(
                            get: { values[field.ref] ?? "" }, set: { values[field.ref] = $0 }
                        )).textFieldStyle(.roundedBorder)
                    }
                }
            }
            if saving {
                HarnessOperationStatus(store: store)
            }
            HStack {
                Spacer()
                Button(saving && store.canCancelHarnessOperation ? "Cancel operation" : "Cancel") {
                    if saving && store.canCancelHarnessOperation { store.cancelHarnessOperation() }
                    else { dismiss() }
                }
                Button(selection.method.kind == "terminal" ? "Open sign-in" : (selection.method.fields.isEmpty ? "Confirm and use" : "Save and use")) {
                    let submitted = values
                    values = [:]
                    saving = true
                    Task {
                        let saved = await store.configureHarness(
                            selection.harness,
                            method: selection.method,
                            credentials: submitted,
                            makeDefault: selection.makeDefault,
                            completesOnboarding: selection.completesOnboarding,
                            acceptUnverified: selection.acceptUnverified,
                            acceptDriverBundle: selection.acceptDriverBundle
                        )
                        saving = false
                        if saved {
                            if selection.selectForDraft { store.chooseHarness(selection.harness, force: true) }
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!complete || saving)
            }
        }
        .padding(22)
        .frame(width: 440)
        .interactiveDismissDisabled(saving)
    }
}

private struct HarnessPackEditor: View {
    private struct ComponentTemplate: Identifiable {
        let id: String
        let title: String
        let kind: String
        let responsibility: String
        let inputs: [String]
        let outputs: [String]
        let observes: [String]
        let editable: Bool
        let ports: [HarnessGraphPort]?
        let configSchema: HarnessNodeConfigSchema?
        let defaultConfig: [String: JSONValue]?

        init(
            id: String,
            title: String,
            kind: String,
            responsibility: String,
            inputs: [String],
            outputs: [String],
            observes: [String],
            editable: Bool = false,
            ports: [HarnessGraphPort]? = nil,
            configSchema: HarnessNodeConfigSchema? = nil,
            defaultConfig: [String: JSONValue]? = nil
        ) {
            self.id = id
            self.title = title
            self.kind = kind
            self.responsibility = responsibility
            self.inputs = inputs
            self.outputs = outputs
            self.observes = observes
            self.editable = editable
            self.ports = ports
            self.configSchema = configSchema
            self.defaultConfig = defaultConfig
        }
    }
    private struct GraphSnapshot: Equatable {
        let level: String
        let boundary: String
        let evidenceSource: String
        let nodes: [HarnessGraphNode]
        let edges: [HarnessGraphEdge]
        let positions: [String: CGPoint]
    }
    private static let runtimeSignals = [
        "protocol.ready", "session.ready", "turn.started", "turn.completed", "turn.failed",
        "model.completed", "tool.activity", "output.activity", "approval.requested", "approval.resolved",
    ]
    private static let reservedHarnessIDs = Set(["dsh", "codex", "oh-my-pi"])
    private static let descriptiveTemplates: [ComponentTemplate] = [
        .init(id: "protocol", title: "Protocol boundary", kind: "protocol-adapter", responsibility: "Translates Host requests and Harness updates across the declared protocol boundary.", inputs: ["Host request"], outputs: ["Harness update"], observes: ["protocol.ready"]),
        .init(id: "context", title: "Context assembly", kind: "context-runtime", responsibility: "Builds model-visible input from the sources this Harness actually owns.", inputs: ["instructions", "task context"], outputs: ["model input"], observes: []),
        .init(id: "session", title: "Agent session", kind: "agent-session", responsibility: "Owns task lifecycle, turns, cancellation, and resumable session state.", inputs: ["task message", "session controls"], outputs: ["turn updates"], observes: ["session.ready", "turn.started", "turn.completed", "turn.failed"]),
        .init(id: "model", title: "Model client", kind: "model-client", responsibility: "Routes inference through the model and account selected by this Harness.", inputs: ["model input", "model selection"], outputs: ["model stream"], observes: ["model.completed"]),
        .init(id: "tools", title: "Tool runtime", kind: "tool-runtime", responsibility: "Validates and executes the tool operations this Harness exposes.", inputs: ["tool request"], outputs: ["tool result"], observes: ["tool.activity"]),
        .init(id: "permissions", title: "Permission policy", kind: "permission-policy", responsibility: "Stops guarded effects until the declared policy or user resolves them.", inputs: ["guarded effect"], outputs: ["permission decision"], observes: ["approval.requested", "approval.resolved"]),
        .init(id: "execution", title: "Execution boundary", kind: "execution-boundary", responsibility: "Constrains filesystem, process, and network effects according to the active policy.", inputs: ["approved operation"], outputs: ["bounded effect"], observes: []),
        .init(id: "output", title: "Output stream", kind: "output-stream", responsibility: "Publishes the structured progress and final output visible to OpenFish.", inputs: ["Harness events"], outputs: ["visible output"], observes: ["output.activity"]),
        .init(id: "persistence", title: "Persistence", kind: "session-storage", responsibility: "Stores the exact resumable state that this Harness declares it owns.", inputs: ["session events"], outputs: ["resumable state"], observes: []),
        .init(id: "extensions", title: "Extensions", kind: "extension-runtime", responsibility: "Adds declared tools, providers, hooks, or behavior without hiding their ownership boundary.", inputs: ["extension packages"], outputs: ["runtime contributions"], observes: []),
    ]
    @ObservedObject var store: OpenCodexStore
    @Binding var isPresented: Bool
    var existing: HarnessCatalogEntry? = nil
    @State private var id = ""
    @State private var name = ""
    @State private var version = "1.0.0"
    @State private var description = ""
    @State private var publisher = ""
    @State private var license = ""
    @State private var repository = ""
    @State private var protocolName = "acp"
    @State private var driverPackage = ""
    @State private var driverSpec = ""
    @State private var driverRequiresInstallScripts = false
    @State private var acceptsDriverCodeExecution = false
    @State private var distributionKind = "npx"
    @State private var packageOrCommand = ""
    @State private var binaryCommand = ""
    @State private var sha256 = ""
    @State private var arguments = ""
    @State private var distributionEnvironment = ""
    @State private var graphLevel = "opaque"
    @State private var graphBoundary = "Harness process"
    @State private var graphEvidenceSource = "Pack declaration"
    @State private var authMethodId = ""
    @State private var authMethodName = ""
    @State private var authKind = "agent"
    @State private var authFieldRef = ""
    @State private var authFieldName = ""
    @State private var authFieldEnv = ""
    @State private var authAccountLabel = ""
    @State private var authBilling = "unknown"
    @State private var authAccountDetail = ""
    @State private var discoverAuthenticationAtRuntime = true
    @State private var agentAuthMetaKey = ""
    @State private var agentAuthFieldProperty = ""
    @State private var modelOwner = "harness"
    @State private var modelConfigurationRequired = false
    @State private var modelConfigurationDetail = "Models and model-specific controls are discovered from the running Harness."
    @State private var terminalAuthArguments = ""
    @State private var terminalAuthEnvironment = ""
    @State private var nodes: [HarnessGraphNode] = [
        HarnessGraphNode(
            id: "runtime", kind: "harness-runtime", title: "Harness runtime", editable: false,
            responsibility: "Runs this Harness while its private internal architecture remains undisclosed.",
            inputs: ["protocol requests"], outputs: ["protocol updates"],
            evidence: [HarnessGraphEvidence(kind: "declared", source: "Pack boundary", version: nil)],
            observes: Self.runtimeSignals, config: nil
        ),
    ]
    @State private var edges: [HarnessGraphEdge] = []
    @State private var positions: [String: CGPoint] = ["runtime": CGPoint(x: 320, y: 100)]
    @State private var selectedEditorNodeId: String? = "runtime"
    @State private var edgeFrom = "runtime"
    @State private var edgeTo = "runtime"
    @State private var edgeFromPort = ""
    @State private var edgeToPort = ""
    @State private var edgeLabel = ""
    @State private var edgeObserves: [String] = []
    @State private var saving = false
    @State private var loadedExisting = false
    @State private var editorPage = "Setup"
    @State private var graphUndo: [GraphSnapshot] = []
    @State private var graphRedo: [GraphSnapshot] = []
    @State private var suppressGraphHistory = false
    @State private var preflightSummary: String?

    private var graphSnapshot: GraphSnapshot {
        GraphSnapshot(
            level: graphLevel, boundary: graphBoundary, evidenceSource: graphEvidenceSource,
            nodes: nodes, edges: edges, positions: positions
        )
    }

    private var loadedDriverProtocols: [String] {
        Array(Set(store.harnesses.filter { $0.driver.loaded && $0.protocolName != "dsh" }.map(\.protocolName))).sorted()
    }

    private var selectedDriverIsLoaded: Bool {
        protocolName != "dsh" && store.harnesses.contains { $0.protocolName == protocolName && $0.driver.loaded }
    }

    private var driverAuthoring: HarnessAuthoringContract? {
        let candidates = store.harnesses.filter { $0.protocolName == protocolName && $0.driver.loaded }
        if let existing, let exact = candidates.first(where: { $0.id == existing.id }) {
            return exact.authoring
        }
        return candidates.first?.authoring
    }

    private var driverComponentTemplates: [ComponentTemplate] {
        (driverAuthoring?.nodeKinds ?? []).map { definition in
            ComponentTemplate(
                id: definition.kind,
                title: definition.name,
                kind: definition.kind,
                responsibility: definition.responsibility,
                inputs: definition.inputs,
                outputs: definition.outputs,
                observes: definition.observes ?? [],
                editable: definition.editable,
                ports: definition.ports,
                configSchema: definition.configSchema,
                defaultConfig: definition.defaultConfig
            )
        }
    }

    private var componentTemplates: [ComponentTemplate] {
        let driverKinds = Set(driverComponentTemplates.map(\.kind))
        return driverComponentTemplates + Self.descriptiveTemplates.filter { !driverKinds.contains($0.kind) }
    }

    private var driverBindingKinds: [HarnessBindingKindDefinition] {
        driverAuthoring?.bindingKinds ?? []
    }

    private var protocolUsesBundledDriver: Bool {
        ["dsh", "acp", "codex-app-server"].contains(protocolName)
    }

    private var canRunLivePreflight: Bool {
        selectedDriverIsLoaded
            || (!protocolUsesBundledDriver
                && !driverPackage.isEmpty
                && !driverSpec.isEmpty
                && acceptsDriverCodeExecution
                && OpenFishDriverManager.isAvailable)
    }

    private var changeSummary: [String] {
        guard let existing else { return ["New Pack \(version)"] }
        var changes: [String] = []
        if version != existing.version { changes.append("Version · \(existing.version) → \(version)") }
        if name != existing.name { changes.append("Name · \(existing.name) → \(name)") }
        if description != (existing.description ?? "") { changes.append("Description changed") }
        if publisher != existing.publisher { changes.append("Publisher · \(existing.publisher) → \(publisher)") }
        if license != (existing.license ?? "") { changes.append("License changed") }
        if repository != (existing.repository ?? "") { changes.append("Repository changed") }
        if protocolName != existing.protocolName { changes.append("Driver protocol · \(existing.protocolName) → \(protocolName)") }
        let previousDistribution = existing.distribution?.package
            ?? existing.distribution?.archive
            ?? existing.distribution?.command
            ?? "none"
        if distributionKind != existing.distribution?.kind || packageOrCommand != previousDistribution {
            changes.append("Distribution · \(existing.distribution?.kind ?? "none") \(previousDistribution) → \(distributionKind) \(packageOrCommand)")
        }
        let nextArguments = arguments.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        if nextArguments != (existing.distribution?.args ?? []) { changes.append("Launch arguments changed") }
        let nextEnvironmentNames = Set(distributionEnvironment.split(whereSeparator: \.isNewline).compactMap {
            $0.split(separator: "=", maxSplits: 1).first.map(String.init)
        })
        if nextEnvironmentNames != Set(existing.distribution?.env.keys ?? Dictionary<String, String>().keys) {
            changes.append("Launch environment names changed; values remain hidden")
        }
        if binaryCommand != (existing.distribution?.kind == "binary" ? existing.distribution?.command ?? "" : "")
            || sha256 != (existing.distribution?.sha256 ?? "") {
            changes.append("Binary command or integrity declaration changed")
        }
        if driverPackage != (existing.driverBundle?.package ?? "")
            || driverSpec != (existing.driverBundle?.spec ?? "")
            || driverRequiresInstallScripts != (existing.driverBundle?.requiresInstallScripts ?? false) {
            changes.append("Exact Driver Bundle changed")
        }
        let storedPositions = Dictionary(uniqueKeysWithValues: existing.graph.nodes.enumerated().map { index, node in
            let x = node.position?.x ?? node.config?["x"]?.doubleValue ?? Double(110 + (index % 3) * 190)
            let y = node.position?.y ?? node.config?["y"]?.doubleValue ?? Double(70 + (index / 3) * 100)
            return (node.id, CGPoint(x: x, y: y))
        })
        if graphLevel != existing.graph.level { changes.append("Architecture level · \(existing.graph.level) → \(graphLevel)") }
        if graphBoundary != (existing.graph.boundary ?? "Harness process") { changes.append("Harness boundary changed") }
        if graphEvidenceSource != (existing.graph.evidence?.first?.source ?? "Pack declaration") { changes.append("Architecture evidence source changed") }
        let previousByID = Dictionary(existing.graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let currentByID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let added = Set(currentByID.keys).subtracting(previousByID.keys).sorted()
        let removed = Set(previousByID.keys).subtracting(currentByID.keys).sorted()
        if !added.isEmpty { changes.append("Components added · \(added.joined(separator: ", "))") }
        if !removed.isEmpty { changes.append("Components removed · \(removed.joined(separator: ", "))") }
        for nodeID in Set(previousByID.keys).intersection(currentByID.keys).sorted() {
            guard let before = previousByID[nodeID], let after = currentByID[nodeID], before != after else { continue }
            var parts: [String] = []
            if before.title != after.title || before.kind != after.kind || before.responsibility != after.responsibility {
                parts.append("identity/responsibility")
            }
            if before.inputs != after.inputs || before.outputs != after.outputs || before.ports != after.ports {
                parts.append("ports/data flow")
            }
            if before.editable != after.editable || before.configSchema != after.configSchema || before.config != after.config {
                parts.append("executable controls")
            }
            if before.evidence != after.evidence || before.observes != after.observes { parts.append("evidence bindings") }
            changes.append("Component \(nodeID) · \((parts.isEmpty ? ["manifest"] : parts).joined(separator: ", "))")
        }
        if edges != existing.graph.edges { changes.append("Declared connections changed") }
        if positions != storedPositions {
            changes.append("Canvas layout changed (presentation only)")
        }
        let nextTerminalArguments = terminalAuthArguments
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
        if authMethodId != (existing.auth.methods.first?.id ?? "")
            || authMethodName != (existing.auth.methods.first?.name ?? "")
            || authKind != (existing.auth.methods.first?.kind ?? "agent")
            || authFieldRef != (existing.auth.methods.first?.fields.first?.ref ?? "")
            || authFieldName != (existing.auth.methods.first?.fields.first?.name ?? "")
            || authFieldEnv != (existing.auth.methods.first?.fields.first?.env ?? "")
            || authAccountLabel != (existing.auth.methods.first?.account?.label ?? existing.account?.label ?? "")
            || authBilling != (existing.auth.methods.first?.account?.billing ?? existing.account?.billing ?? "unknown")
            || authAccountDetail != (existing.auth.methods.first?.account?.detail ?? existing.account?.detail ?? "")
            || agentAuthMetaKey != (existing.auth.methods.first?.agent?.metaKey ?? "")
            || agentAuthFieldProperty != (authFieldRef.isEmpty
                ? ""
                : existing.auth.methods.first?.agent?.fieldMap[authFieldRef] ?? "")
            || nextTerminalArguments != (existing.auth.methods.first?.terminal?.args ?? []) {
            changes.append("Authentication/account contract changed")
        }
        let nextTerminalEnvironmentNames = Set(terminalAuthEnvironment.split(whereSeparator: \.isNewline).compactMap {
            $0.split(separator: "=", maxSplits: 1).first.map(String.init)
        })
        if nextTerminalEnvironmentNames != Set(existing.auth.methods.first?.terminal?.env.keys ?? Dictionary<String, String>().keys) {
            changes.append("Authentication environment names changed; values remain hidden")
        }
        if discoverAuthenticationAtRuntime != (existing.authenticationDiscovery?.source == "runtime") {
            changes.append("Authentication discovery changed")
        }
        let previousModelDetail = existing.modelConfiguration?.detail
            ?? "Models and model-specific controls are discovered from the running Harness."
        if modelOwner != (existing.modelConfiguration?.owner ?? "harness")
            || modelConfigurationRequired != (existing.modelConfiguration?.required ?? false)
            || modelConfigurationDetail != previousModelDetail {
            changes.append("Model ownership contract changed")
        }
        return changes
    }

    private var validationIssues: [String] {
        var issues: [String] = []
        let sensitiveEnvironmentName = try? NSRegularExpression(
            pattern: "(?i)(?:key|token|secret|password|credential)$"
        )
        func storedSecretNames(in source: String) -> [String] {
            source.split(whereSeparator: \.isNewline).compactMap { line in
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, !parts[1].isEmpty else { return nil }
                let name = parts[0]
                let range = NSRange(name.startIndex..., in: name)
                return sensitiveEnvironmentName?.firstMatch(in: name, range: range) == nil ? nil : name
            }
        }
        if id.range(of: #"^[a-z0-9][a-z0-9._-]*$"#, options: .regularExpression) == nil {
            issues.append("Identifier must use lowercase letters, numbers, dots, underscores, or hyphens.")
        }
        if Self.reservedHarnessIDs.contains(id) {
            issues.append("This identifier belongs to a bundled Harness. Fork it under a new identifier so installed tasks keep a trustworthy identity.")
        }
        if protocolName == "dsh" {
            issues.append("DSH is an internal bundled runtime, not a public Driver id. Choose ACP or another loaded Driver.")
        }
        if protocolUsesBundledDriver && (!driverPackage.isEmpty || !driverSpec.isEmpty) {
            issues.append("The \(protocolName.uppercased()) Driver is bundled with OpenFish and cannot be replaced by a Pack.")
        }
        if !protocolUsesBundledDriver {
            if driverPackage.isEmpty || driverSpec.isEmpty {
                issues.append("A non-bundled protocol needs an exact Driver Bundle so another Mac can use this Pack by name.")
            }
            if !driverPackage.isEmpty,
               driverPackage.range(of: #"^(?:@[a-z0-9][a-z0-9._~-]*/)?[a-z0-9][a-z0-9._~-]*$"#, options: .regularExpression) == nil {
                issues.append("Driver Bundle package must be a valid npm package identity.")
            }
            let exactNpmDriver = driverSpec.range(
                of: #"^(?:@[a-z0-9][a-z0-9._~-]*/)?[a-z0-9][a-z0-9._~-]*@[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"#,
                options: .regularExpression
            ) != nil
            let exactGitHubDriver = driverSpec.range(
                of: #"^github:[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]+#[0-9a-fA-F]{40}$"#,
                options: .regularExpression
            ) != nil
            if exactNpmDriver {
                let expectedPrefix = "\(driverPackage)@"
                if !driverSpec.hasPrefix(expectedPrefix) {
                    issues.append("Driver Bundle source must name the same npm package as its package identity.")
                }
            }
            if !driverSpec.isEmpty && !exactNpmDriver && !exactGitHubDriver {
                issues.append("Driver Bundle source must pin an exact npm version or a full GitHub commit.")
            }
        }
        if version.range(of: #"^[0-9A-Za-z][0-9A-Za-z._+-]*$"#, options: .regularExpression) == nil {
            issues.append("Version must be a portable exact identifier without slashes or spaces.")
        }
        if let existing, existing.installation.status == "installed", version == existing.version, !changeSummary.isEmpty {
            issues.append("This exact version is already installed. Increment the Pack version so existing tasks keep their immutable runtime snapshot.")
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("Name is required.") }
        if publisher.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("Publisher is required.") }
        if packageOrCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("A distribution package, URL, or command is required.") }
        if ["npx", "bunx"].contains(distributionKind),
           packageOrCommand.range(
               of: #"^\S+@[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"#,
               options: .regularExpression
           ) == nil {
            issues.append("npm and Bun packages must pin an exact semantic version.")
        }
        if distributionKind == "uvx",
           packageOrCommand.range(
               of: #"^[^\s<>=!~;]+(?:==|@)[0-9][0-9A-Za-z._+-]*$"#,
               options: .regularExpression
           ) == nil {
            issues.append("Python packages must pin an exact version with == or @.")
        }
        if distributionKind == "binary" && binaryCommand.isEmpty { issues.append("A binary archive needs its command inside the archive.") }
        if authMethodId.isEmpty != authMethodName.isEmpty {
            issues.append("Authentication method id and name must be supplied together.")
        }
        if !authMethodId.isEmpty {
            if existing?.auth.methods.dropFirst().contains(where: { $0.id == authMethodId }) == true {
                issues.append("Authentication method id \(authMethodId) is already used by a preserved additional method.")
            }
            if ["environment", "agent"].contains(authKind), !authFieldRef.isEmpty,
               authFieldRef.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) == nil {
                issues.append("Credential references use environment-style names such as OPENAI_API_KEY.")
            }
            if authKind == "environment", authFieldRef.isEmpty {
                issues.append("Environment authentication needs a credential reference.")
            }
            if authKind == "environment", !authFieldEnv.isEmpty,
               authFieldEnv.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) == nil {
                issues.append("Authentication environment variable names must be portable.")
            }
            if authKind == "agent", (!agentAuthMetaKey.isEmpty || !agentAuthFieldProperty.isEmpty), authFieldRef.isEmpty {
                issues.append("ACP authentication metadata needs a credential reference to map.")
            }
            if authKind == "terminal", terminalAuthArguments.split(whereSeparator: \.isNewline).isEmpty {
                issues.append("Terminal authentication needs at least one login argument.")
            }
        }
        if authAccountLabel.isEmpty != authAccountDetail.isEmpty {
            issues.append("Account label and billing explanation must be supplied together.")
        }
        if agentAuthMetaKey.isEmpty != agentAuthFieldProperty.isEmpty {
            issues.append("ACP agent metadata key and credential property must be supplied together.")
        }
        if modelConfigurationDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("Explain where model configuration comes from.")
        }
        let leakedSecretNames = Set(
            storedSecretNames(in: distributionEnvironment)
                + storedSecretNames(in: terminalAuthEnvironment)
        ).sorted()
        if !leakedSecretNames.isEmpty {
            issues.append("Move potential secrets to Authentication fields: \(leakedSecretNames.joined(separator: ", ")).")
        }
        if nodes.isEmpty { issues.append("The architecture graph needs at least one truthful runtime boundary node.") }
        if graphLevel == "opaque" && nodes.count != 1 { issues.append("Opaque graphs expose exactly one runtime boundary node.") }
        if graphLevel != "opaque" && graphBoundary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("Name the Harness boundary represented by this graph.") }
        if graphLevel != "opaque" && graphEvidenceSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("Architecture evidence needs a source.") }
        if graphLevel != "opaque" && nodes.contains(where: { ($0.responsibility ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { issues.append("Every visible architecture component needs a responsibility.") }
        if Set(nodes.map(\.id)).count != nodes.count { issues.append("Architecture node ids must be unique.") }
        let nodeIDs = Set(nodes.map(\.id))
        if edges.contains(where: { !nodeIDs.contains($0.from) || !nodeIDs.contains($0.to) }) { issues.append("Every architecture edge must connect existing nodes.") }
        if edges.contains(where: { $0.from == $0.to }) { issues.append("Architecture edges cannot connect a component to itself.") }
        let edgeKeys = edges.map { "\($0.from)\u{0}\($0.fromPort ?? "")\u{0}\($0.to)\u{0}\($0.toPort ?? "")" }
        if Set(edgeKeys).count != edgeKeys.count { issues.append("Architecture edges must be unique.") }
        if graphLevel != "opaque", !nodes.isEmpty {
            var adjacent = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, Set<String>()) })
            for edge in edges {
                adjacent[edge.from, default: []].insert(edge.to)
                adjacent[edge.to, default: []].insert(edge.from)
            }
            var pending = [nodes[0].id]
            var visited = Set<String>()
            while let current = pending.popLast() {
                guard visited.insert(current).inserted else { continue }
                pending.append(contentsOf: adjacent[current] ?? [])
            }
            if visited.count != nodes.count { issues.append("Connect every declared architecture component into one truthful Harness boundary.") }
        }
        if graphLevel != "composable" && nodes.contains(where: \.editable) { issues.append("Only composable graphs may expose editable nodes.") }
        for node in nodes where node.editable {
            guard let nodeKind = driverAuthoring?.nodeKinds.first(where: { $0.kind == node.kind }) else {
                issues.append("Editable component \(node.title) needs a node kind published by the loaded \(protocolName) Driver.")
                continue
            }
            if !nodeKind.editable {
                issues.append("The \(protocolName) Driver declares component kind \(node.kind) as explanatory, not executable.")
            }
            for field in node.configSchema?.fields ?? [] {
                guard let binding = driverBindingKinds.first(where: { $0.kind == field.binding.kind }) else {
                    issues.append("Control \(field.name) uses a binding kind the loaded Driver did not publish.")
                    continue
                }
                if !binding.fieldTypes.contains(field.type) {
                    issues.append("Driver binding \(binding.name) cannot execute a \(field.type) control.")
                }
                if let pattern = binding.targetPattern,
                   field.binding.target.range(of: pattern, options: .regularExpression) == nil {
                    issues.append("Control \(field.name) has an invalid \(binding.targetLabel.lowercased()).")
                }
            }
        }
        func isRuntimeSignal(_ signal: String) -> Bool {
            Self.runtimeSignals.contains(signal)
                || (signal.hasPrefix("driver.\(protocolName).")
                    && signal.count > "driver.\(protocolName).".count
                    && signal.range(of: #"^[a-z0-9][a-z0-9._-]*$"#, options: .regularExpression) != nil)
        }
        if nodes.contains(where: { node in
            let observations = node.observes ?? []
            return Set(observations).count != observations.count || observations.contains(where: { !isRuntimeSignal($0) })
        }) { issues.append("Runtime observations must be unique built-in ids or use driver.\(protocolName).<signal>.") }
        for node in nodes {
            let ports = node.ports ?? []
            if Set(ports.map(\.id)).count != ports.count { issues.append("Component \(node.title) has duplicate typed port ids.") }
            if ports.contains(where: {
                $0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || $0.dataType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !["input", "output"].contains($0.direction)
            }) { issues.append("Component \(node.title) has an incomplete typed port.") }
            let fields = node.configSchema?.fields ?? []
            if Set(fields.map(\.id)).count != fields.count { issues.append("Component \(node.title) has duplicate executable control ids.") }
            if fields.contains(where: {
                $0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || $0.binding.kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || $0.binding.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) { issues.append("Component \(node.title) has an incomplete executable control binding.") }
            if !node.editable && !fields.isEmpty { issues.append("Read-only component \(node.title) cannot expose executable controls.") }
            for field in fields {
                let value = node.config?[field.id]
                if field.required && value == nil { issues.append("Control \(field.name) needs a default value.") }
                if field.type == "boolean", value != nil, value?.boolValue == nil { issues.append("Control \(field.name) requires a boolean value.") }
                if ["string", "select", "secret-reference"].contains(field.type), value != nil, value?.stringValue == nil { issues.append("Control \(field.name) requires a text value.") }
                if field.type == "select", !(field.choices ?? []).contains(where: { $0.id == value?.stringValue }) { issues.append("Control \(field.name) must select a declared choice.") }
                if field.type == "secret-reference", let reference = value?.stringValue,
                   reference.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) == nil {
                    issues.append("Control \(field.name) must name a Host credential reference, never contain the credential value.")
                }
            }
        }
        for edge in edges {
            let source = nodes.first(where: { $0.id == edge.from })
            let target = nodes.first(where: { $0.id == edge.to })
            let sourcePort = edge.fromPort.flatMap { id in source?.ports?.first(where: { $0.id == id }) }
            let targetPort = edge.toPort.flatMap { id in target?.ports?.first(where: { $0.id == id }) }
            if edge.fromPort != nil && sourcePort?.direction != "output" { issues.append("A graph connection references an invalid output port.") }
            if edge.toPort != nil && targetPort?.direction != "input" { issues.append("A graph connection references an invalid input port.") }
            if let sourcePort, let targetPort, sourcePort.dataType != targetPort.dataType { issues.append("A graph connection joins incompatible port types.") }
            let observations = edge.observes ?? []
            if Set(observations).count != observations.count || observations.contains(where: { !isRuntimeSignal($0) }) {
                issues.append("Connection observations must be unique built-in ids or use driver.\(protocolName).<signal>.")
            }
        }
        return issues
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(existing == nil ? "Create Harness Pack" : "Edit Harness Pack").font(.title2.bold())
                    Text("Define how OpenFish installs, explains, and safely configures this Harness.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Editor page", selection: $editorPage) {
                    Text("Setup").tag("Setup")
                    Text("Architecture").tag("Architecture")
                    Text("Account & models").tag("Access")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 360)
                if existing != nil {
                    Menu {
                        if changeSummary.isEmpty { Text("No material changes") }
                        else { ForEach(changeSummary, id: \.self) { Text($0) } }
                    } label: {
                        Label(changeSummary.isEmpty ? "No changes" : "\(changeSummary.count) changes", systemImage: "arrow.left.arrow.right")
                    }
                    .menuStyle(.borderlessButton)
                }
            }
            Form {
                if editorPage == "Setup" {
                TextField("Identifier", text: $id)
                    .disabled(existing != nil)
                TextField("Name", text: $name)
                TextField("Version", text: $version)
                TextField("Description", text: $description)
                TextField("Publisher", text: $publisher)
                TextField("License", text: $license)
                TextField("Repository URL", text: $repository)
                HStack {
                    TextField("Protocol / Driver id", text: $protocolName)
                    Menu("Loaded Drivers") {
                        ForEach(loadedDriverProtocols, id: \.self) { item in
                            Button(item) { protocolName = item }
                        }
                    }
                }
                Label(
                    selectedDriverIsLoaded
                        ? "Driver API v1 is loaded. This Pack can proceed to install and live preflight."
                        : protocolUsesBundledDriver
                            ? "This protocol uses the Driver bundled with OpenFish. Refresh or repair the Host if it is not loaded."
                            : "Declare an exact Driver Bundle below. On another Mac, OpenFish will ask before staging it, restart its verified Host, and continue setup automatically.",
                    systemImage: selectedDriverIsLoaded ? "checkmark.circle.fill" : "shippingbox"
                )
                .font(.caption)
                .foregroundStyle(selectedDriverIsLoaded ? Color.green : Color.orange)
                if !protocolUsesBundledDriver {
                    Section("Self-installing Driver Bundle") {
                        TextField("npm package identity", text: $driverPackage)
                        TextField("Exact package@version or github:owner/repo#commit", text: $driverSpec)
                        Toggle("This Driver requires npm install scripts", isOn: $driverRequiresInstallScripts)
                        Toggle(
                            "Allow this exact Driver to run for live preflight on this Mac",
                            isOn: $acceptsDriverCodeExecution
                        )
                        if driverRequiresInstallScripts {
                            Label(
                                "Lifecycle scripts run before Driver admission. OpenFish shows this warning again when another user installs the Pack.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                        Text("The Driver Bundle extends OpenFish with this protocol. The Harness distribution below is the executable that Driver launches for each task.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Picker("Distribution", selection: $distributionKind) {
                    Text("npm").tag("npx"); Text("Bun").tag("bunx"); Text("Python / uvx").tag("uvx")
                    Text("Binary archive").tag("binary"); Text("Existing executable").tag("executable")
                }
                TextField(distributionKind == "executable" ? "Executable path" : (distributionKind == "binary" ? "Archive URL" : "Package@version"), text: $packageOrCommand)
                if distributionKind == "binary" {
                    TextField("Command inside archive", text: $binaryCommand)
                    TextField("SHA-256 (recommended)", text: $sha256)
                }
                TextField("Arguments (one per line)", text: $arguments, axis: .vertical).lineLimit(2...4)
                TextField("Launch environment (NAME=value, one per line)", text: $distributionEnvironment, axis: .vertical).lineLimit(2...4)
                Text("Launch environment is stored in the Pack. Put API keys and tokens in Authentication fields so OpenFish can keep them in Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                }
                if editorPage == "Architecture" {
                Picker("Graph truthfulness", selection: $graphLevel) {
                    Text("Opaque").tag("opaque"); Text("Observable").tag("observable"); Text("Composable").tag("composable")
                }
                Text(graphLevel == "opaque"
                     ? "Start here unless the Harness publishes evidence for its internal responsibilities. OpenFish will show one honest runtime boundary."
                     : graphLevel == "observable"
                        ? "Add only responsibilities supported by an official manifest, versioned source, or runtime observation. This view remains read only."
                        : "Composable means the declared editable nodes have real Driver semantics. A visual node alone does not make a Harness executable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if graphLevel != "opaque" {
                    TextField("Harness boundary", text: $graphBoundary)
                    TextField("Architecture evidence source", text: $graphEvidenceSource)
                    Text("Use an official manifest, versioned source path, or runtime capability. A name alone is not evidence.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                }
                if editorPage == "Access" {
                Section("Authentication (optional)") {
                    Toggle("Discover sign-in methods from the installed Harness", isOn: $discoverAuthenticationAtRuntime)
                    Text(discoverAuthenticationAtRuntime
                         ? "Before installation, OpenFish shows sign-in as unknown. After installation, the Driver must report the actual methods or explicitly confirm that no sign-in is required."
                         : "The methods declared below are the complete sign-in contract. If the list is empty, OpenFish will state that this Harness requires no sign-in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let preservedCount = existing?.auth.methods.dropFirst().count, preservedCount > 0 {
                        Label(
                            "This Pack also declares \(preservedCount) advanced authentication \(preservedCount == 1 ? "method" : "methods"). They are preserved byte-for-field when this primary method is edited or the optional form is left empty.",
                            systemImage: "lock.shield"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    TextField("Method id", text: $authMethodId)
                    TextField("Method name", text: $authMethodName)
                    Picker("Method type", selection: $authKind) {
                        Text("Harness / browser").tag("agent"); Text("Environment credential").tag("environment"); Text("Terminal login").tag("terminal")
                    }
                    if authKind == "environment" {
                        TextField("Credential reference", text: $authFieldRef)
                        TextField("Field label", text: $authFieldName)
                        TextField("Environment variable", text: $authFieldEnv)
                    } else if authKind == "agent" {
                        TextField("Credential reference (optional)", text: $authFieldRef)
                        TextField("Field label", text: $authFieldName)
                        TextField("ACP metadata key", text: $agentAuthMetaKey)
                        TextField("Credential property", text: $agentAuthFieldProperty)
                        Text("This maps a Keychain reference into ACP authenticate metadata without naming a provider in OpenFish code.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if authKind == "terminal" {
                        TextField("Login arguments (one per line)", text: $terminalAuthArguments, axis: .vertical).lineLimit(2...4)
                        TextField("Login environment (NAME=value, one per line)", text: $terminalAuthEnvironment, axis: .vertical).lineLimit(2...4)
                    }
                    TextField("Account label (shown before a task starts)", text: $authAccountLabel)
                    Picker("Billing", selection: $authBilling) {
                        Text("Subscription").tag("subscription")
                        Text("Usage based").tag("usage")
                        Text("Local / no external billing").tag("local")
                        Text("Managed by Harness").tag("harness-managed")
                        Text("Unknown / not declared").tag("unknown")
                    }
                    TextField("Account and billing explanation", text: $authAccountDetail, axis: .vertical)
                        .lineLimit(2...4)
                    Text("OpenFish displays this Pack declaration to the user; it does not infer billing from a model or executable name.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Model ownership") {
                    Picker("Configured by", selection: $modelOwner) {
                        Text("Harness").tag("harness")
                        Text("OpenFish Host").tag("host")
                    }
                    Toggle("Configuration required before first task", isOn: $modelConfigurationRequired)
                    TextField("Model configuration explanation", text: $modelConfigurationDetail, axis: .vertical)
                        .lineLimit(2...4)
                    Text("This declaration drives onboarding and model controls for every Pack; OpenFish does not infer it from a Harness name.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                }
            }
            if editorPage == "Architecture" {
            HStack {
                Text("Architecture graph").font(.headline)
                Menu {
                    Button("Private runtime boundary") { applyStarter("opaque") }
                    Button("Observable coding Harness") { applyStarter("observable") }
                    Button("Composable Harness") { applyStarter("composable") }
                } label: {
                    Label("Start from a draft", systemImage: "wand.and.stars")
                }
                .help("Drafts are author declarations, never evidence of private internals. Confirm every component and evidence source before saving.")
                Spacer()
                Button { undoGraph() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(graphUndo.isEmpty)
                Button { redoGraph() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .disabled(graphRedo.isEmpty)
            }
            Text(driverBindingKinds.isEmpty
                 ? "This Driver exposes no executable authoring vocabulary. You can document evidence-backed structure, but OpenFish will not pretend those nodes change Harness behavior."
                 : "Executable controls use binding kinds published by the loaded Driver. OpenFish validates the manifest first, then live-preflights targets without sending a model prompt.")
                .font(.caption)
                .foregroundStyle(.secondary)
            EditableHarnessGraphCanvas(
                nodes: $nodes, edges: $edges, positions: $positions,
                selectedNodeId: $selectedEditorNodeId
            )
                .frame(minHeight: 210)
            ForEach(Array(nodes.enumerated()).filter { $0.element.id == selectedEditorNodeId }, id: \.element.id) { index, node in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        TextField("Node id", text: Binding(get: { nodes[index].id }, set: {
                        let oldID = nodes[index].id
                        let newID = $0
                        nodes[index] = HarnessGraphNode(id: newID, kind: node.kind, title: node.title, editable: node.editable, responsibility: node.responsibility, inputs: node.inputs, outputs: node.outputs, ports: node.ports, evidence: node.evidence, observes: node.observes, configSchema: node.configSchema, config: node.config)
                        positions[newID] = positions.removeValue(forKey: oldID)
                        selectedEditorNodeId = newID
                        edges = edges.map { edge in
                            HarnessGraphEdge(
                                from: edge.from == oldID ? newID : edge.from,
                                to: edge.to == oldID ? newID : edge.to,
                                fromPort: edge.fromPort, toPort: edge.toPort,
                                label: edge.label, observes: edge.observes
                            )
                        }
                        }))
                        TextField("Title", text: Binding(get: { nodes[index].title }, set: { nodes[index] = HarnessGraphNode(id: node.id, kind: node.kind, title: $0, editable: node.editable, responsibility: node.responsibility, inputs: node.inputs, outputs: node.outputs, ports: node.ports, evidence: node.evidence, observes: node.observes, configSchema: node.configSchema, config: node.config) }))
                        TextField("Kind", text: Binding(get: { nodes[index].kind }, set: { nodes[index] = HarnessGraphNode(id: node.id, kind: $0, title: node.title, editable: node.editable, responsibility: node.responsibility, inputs: node.inputs, outputs: node.outputs, ports: node.ports, evidence: node.evidence, observes: node.observes, configSchema: node.configSchema, config: node.config) }))
                        Toggle("Executable", isOn: Binding(get: { nodes[index].editable }, set: { nodes[index] = HarnessGraphNode(id: node.id, kind: node.kind, title: node.title, editable: $0, responsibility: node.responsibility, inputs: node.inputs, outputs: node.outputs, ports: node.ports, evidence: node.evidence, observes: node.observes, configSchema: node.configSchema, config: node.config) }))
                            .toggleStyle(.checkbox)
                            .disabled(
                                graphLevel != "composable"
                                    || driverAuthoring?.nodeKinds.first(where: { $0.kind == node.kind })?.editable != true
                            )
                        Button(role: .destructive) {
                            nodes.remove(at: index)
                            positions.removeValue(forKey: node.id)
                            edges.removeAll { $0.from == node.id || $0.to == node.id }
                            selectedEditorNodeId = nodes.first?.id
                        } label: { Image(systemName: "trash") }
                    }
                    TextField("Responsibility", text: Binding(
                        get: { nodes[index].responsibility ?? "" },
                        set: { nodes[index] = HarnessGraphNode(id: node.id, kind: node.kind, title: node.title, editable: node.editable, responsibility: $0, inputs: node.inputs, outputs: node.outputs, ports: node.ports, evidence: node.evidence, observes: node.observes, configSchema: node.configSchema, config: node.config) }
                    ))
                    HStack {
                        TextField("Inputs (comma separated)", text: Binding(
                            get: { (nodes[index].inputs ?? []).joined(separator: ", ") },
                            set: { value in
                                let inputs = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                                nodes[index] = HarnessGraphNode(id: node.id, kind: node.kind, title: node.title, editable: node.editable, responsibility: node.responsibility, inputs: inputs, outputs: node.outputs, ports: node.ports, evidence: node.evidence, observes: node.observes, configSchema: node.configSchema, config: node.config)
                            }
                        ))
                        TextField("Outputs (comma separated)", text: Binding(
                            get: { (nodes[index].outputs ?? []).joined(separator: ", ") },
                            set: { value in
                                let outputs = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                                nodes[index] = HarnessGraphNode(id: node.id, kind: node.kind, title: node.title, editable: node.editable, responsibility: node.responsibility, inputs: node.inputs, outputs: outputs, ports: node.ports, evidence: node.evidence, observes: node.observes, configSchema: node.configSchema, config: node.config)
                            }
                        ))
                    }
                    HarnessPortsEditor(
                        node: Binding(get: { nodes[index] }, set: { nodes[index] = $0 }),
                        edges: $edges
                    )
                    HarnessRuntimeSignalPicker(
                        title: "Observed node signals",
                        signals: Binding(
                            get: { nodes[index].observes ?? [] },
                            set: { observes in
                                nodes[index] = HarnessGraphNode(
                                    id: node.id, kind: node.kind, title: node.title, editable: node.editable,
                                    responsibility: node.responsibility, inputs: node.inputs, outputs: node.outputs,
                                    ports: node.ports, evidence: node.evidence,
                                    observes: observes.isEmpty ? nil : observes,
                                    configSchema: node.configSchema, config: node.config
                                )
                            }
                        ),
                        available: Self.runtimeSignals,
                        customPrefix: "driver.\(protocolName)."
                    )
                    Text("A component without an evidence binding never lights up.")
                        .font(.caption2).foregroundStyle(.secondary)
                    HarnessNodeConfigEditor(
                        node: Binding(get: { nodes[index] }, set: { nodes[index] = $0 }),
                        bindingKinds: driverBindingKinds
                    )
                }
            }
            HStack {
                Menu {
                    if !driverComponentTemplates.isEmpty {
                        Section("Driver components") {
                            ForEach(driverComponentTemplates) { template in
                                Button(template.title) { addComponent(template) }
                            }
                        }
                    }
                    Section("Evidence-only components") {
                        ForEach(Self.descriptiveTemplates.filter { template in
                            !Set(driverComponentTemplates.map(\.kind)).contains(template.kind)
                        }) { template in
                            Button(template.title) { addComponent(template) }
                        }
                    }
                } label: {
                    Label("Add component", systemImage: "plus")
                }
                if nodes.count >= 2 {
                    Picker("From", selection: $edgeFrom) { ForEach(nodes) { Text($0.title).tag($0.id) } }.frame(width: 130)
                    Picker("Output", selection: $edgeFromPort) {
                        Text("Component").tag("")
                        ForEach(nodes.first(where: { $0.id == edgeFrom })?.ports?.filter { $0.direction == "output" } ?? []) { port in
                            Text(port.name).tag(port.id)
                        }
                    }.frame(width: 120)
                    Picker("To", selection: $edgeTo) { ForEach(nodes) { Text($0.title).tag($0.id) } }.frame(width: 130)
                    Picker("Input", selection: $edgeToPort) {
                        Text("Component").tag("")
                        ForEach(nodes.first(where: { $0.id == edgeTo })?.ports?.filter { $0.direction == "input" } ?? []) { port in
                            Text(port.name).tag(port.id)
                        }
                    }.frame(width: 120)
                    TextField("Flow label", text: $edgeLabel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    HarnessRuntimeSignalPicker(
                        title: "Observe flow", signals: $edgeObserves,
                        available: Self.runtimeSignals,
                        customPrefix: "driver.\(protocolName).", compact: true
                    )
                    Button("Connect") {
                        let edge = HarnessGraphEdge(
                            from: edgeFrom, to: edgeTo,
                            fromPort: edgeFromPort.isEmpty ? nil : edgeFromPort,
                            toPort: edgeToPort.isEmpty ? nil : edgeToPort,
                            label: edgeLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? nil : edgeLabel.trimmingCharacters(in: .whitespacesAndNewlines),
                            observes: edgeObserves.isEmpty ? nil : edgeObserves
                        )
                        if !edges.contains(edge) { edges.append(edge) }
                    }
                    .disabled(edgeFrom == edgeTo)
                }
                Spacer()
                Text("\(nodes.count) nodes · \(edges.count) edges").foregroundStyle(.secondary)
            }
            if !edges.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Connections").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(edges.enumerated()), id: \.offset) { index, edge in
                        HStack(spacing: 8) {
                            Text("\(nodes.first(where: { $0.id == edge.from })?.title ?? edge.from) → \(nodes.first(where: { $0.id == edge.to })?.title ?? edge.to)")
                                .font(.caption).lineLimit(1)
                            TextField("Value / control flow", text: Binding(
                                get: { edges[index].label ?? "" },
                                set: { edges[index].label = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                            Spacer()
                            HarnessRuntimeSignalPicker(
                                title: "Observed flow",
                                signals: Binding(
                                    get: { edges[index].observes ?? [] },
                                    set: { edges[index].observes = $0.isEmpty ? nil : $0 }
                                ),
                                available: Self.runtimeSignals,
                                customPrefix: "driver.\(protocolName).",
                                compact: true
                            )
                            Button(role: .destructive) { edges.remove(at: index) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                .padding(9)
                .background(OpenCodexPalette.hover, in: RoundedRectangle(cornerRadius: 9))
            }
            }
            if !validationIssues.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Fix before saving", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    ForEach(validationIssues, id: \.self) { Text("• \($0)").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let preflightSummary {
                Label(preflightSummary, systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(.green)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Save Manifest") { save(runPreflight: false) }
                    .disabled(saving || !validationIssues.isEmpty)
                Button("Install & Live Preflight") { save(runPreflight: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || !validationIssues.isEmpty || !canRunLivePreflight)
                    .help("Saves the Pack, installs its exact declared executable in OpenFish's private runtime, initializes the live Driver without sending a prompt, and tears it down.")
            }
        }
        .padding(22)
        .frame(width: 820, height: 780)
        .onChange(of: graphLevel) { _, level in
            if level == "opaque" {
                let existingRuntime = nodes.first ?? HarnessGraphNode(
                    id: "runtime", kind: "harness-runtime", title: name.isEmpty ? "Harness runtime" : name,
                    editable: false, responsibility: "Runs this Harness while its private internals remain undisclosed.", config: nil
                )
                let runtime = HarnessGraphNode(
                    id: "runtime", kind: "harness-runtime", title: existingRuntime.title,
                    editable: false, responsibility: existingRuntime.responsibility,
                    inputs: existingRuntime.inputs, outputs: existingRuntime.outputs, ports: existingRuntime.ports,
                    evidence: existingRuntime.evidence, observes: existingRuntime.observes ?? Self.runtimeSignals,
                    configSchema: nil, config: existingRuntime.config
                )
                nodes = [runtime]
                edges = []
                positions = [runtime.id: CGPoint(x: 320, y: 100)]
                edgeFrom = runtime.id
                edgeTo = runtime.id
                selectedEditorNodeId = runtime.id
                return
            }
            nodes = nodes.map {
                HarnessGraphNode(
                    id: $0.id, kind: $0.kind, title: $0.title,
                    editable: level == "composable" ? $0.editable : false,
                    responsibility: $0.responsibility, inputs: $0.inputs, outputs: $0.outputs, ports: $0.ports,
                    evidence: $0.evidence, observes: $0.observes,
                    configSchema: level == "composable" ? $0.configSchema : nil, config: $0.config
                )
            }
        }
        .onAppear { loadExistingIfNeeded() }
        .onChange(of: graphSnapshot) { oldValue, _ in
            if suppressGraphHistory {
                suppressGraphHistory = false
                return
            }
            if graphUndo.last != oldValue { graphUndo.append(oldValue) }
            if graphUndo.count > 80 { graphUndo.removeFirst(graphUndo.count - 80) }
            graphRedo.removeAll()
        }
    }

    private func restoreGraph(_ snapshot: GraphSnapshot) {
        suppressGraphHistory = true
        graphLevel = snapshot.level
        graphBoundary = snapshot.boundary
        graphEvidenceSource = snapshot.evidenceSource
        nodes = snapshot.nodes
        edges = snapshot.edges
        positions = snapshot.positions
        if !snapshot.nodes.contains(where: { $0.id == selectedEditorNodeId }) {
            selectedEditorNodeId = snapshot.nodes.first?.id
        }
    }

    private func uniqueNodeID(_ preferred: String) -> String {
        let used = Set(nodes.map(\.id))
        if !used.contains(preferred) { return preferred }
        var index = 2
        while used.contains("\(preferred)-\(index)") { index += 1 }
        return "\(preferred)-\(index)"
    }

    private func addComponent(_ template: ComponentTemplate) {
        let nodeID = uniqueNodeID(template.id)
        let node = HarnessGraphNode(
            id: nodeID, kind: template.kind, title: template.title,
            editable: graphLevel == "composable" && template.editable && template.configSchema != nil,
            responsibility: template.responsibility, inputs: template.inputs, outputs: template.outputs,
            ports: template.ports,
            evidence: [HarnessGraphEvidence(kind: "declared", source: graphEvidenceSource, version: version)],
            observes: template.observes.isEmpty ? nil : template.observes,
            configSchema: template.configSchema,
            config: template.defaultConfig
        )
        nodes.append(node)
        positions[nodeID] = CGPoint(x: 140 + (nodes.count % 4) * 155, y: 90 + (nodes.count / 4) * 100)
        if edgeFrom.isEmpty { edgeFrom = nodeID }
        edgeTo = nodeID
        selectedEditorNodeId = nodeID
    }

    private func applyStarter(_ level: String) {
        graphLevel = level
        graphBoundary = name.isEmpty ? "Harness process" : "\(name) process"
        if level == "opaque" {
            let runtime = HarnessGraphNode(
                id: "runtime", kind: "harness-runtime", title: name.isEmpty ? "Harness runtime" : name,
                editable: false, responsibility: "Runs this Harness while its private internals remain undisclosed.",
                inputs: ["protocol requests"], outputs: ["protocol updates"],
                evidence: [HarnessGraphEvidence(kind: "declared", source: graphEvidenceSource, version: version)],
                observes: Self.runtimeSignals, config: nil
            )
            nodes = [runtime]
            edges = []
            positions = [runtime.id: CGPoint(x: 320, y: 105)]
            edgeFrom = runtime.id
            edgeTo = runtime.id
            selectedEditorNodeId = runtime.id
            return
        }
        let modelKind = driverAuthoring?.nodeKinds.contains(where: { $0.kind == "model-router" }) == true
            ? "model-router" : "model-client"
        let selected = ["protocol-adapter", "context-runtime", "agent-session", modelKind, "tool-runtime", "permission-policy", "execution-boundary", "output-stream", "session-storage"]
        nodes = []
        edges = []
        positions = [:]
        for kind in selected {
            if let template = componentTemplates.first(where: { $0.kind == kind }) { addComponent(template) }
        }
        let idsByKind = Dictionary(uniqueKeysWithValues: nodes.map { ($0.kind, $0.id) })
        func nodeID(_ kind: String) -> String { idsByKind[kind] ?? kind }
        edges = [
            HarnessGraphEdge(from: nodeID("protocol-adapter"), to: nodeID("agent-session"), label: "task and lifecycle request", observes: ["session.ready", "turn.started"]),
            HarnessGraphEdge(from: nodeID("agent-session"), to: nodeID("context-runtime"), label: "turn context", observes: ["turn.started"]),
            HarnessGraphEdge(from: nodeID("context-runtime"), to: nodeID(modelKind), label: "model-visible input", observes: ["turn.started"]),
            HarnessGraphEdge(from: nodeID(modelKind), to: nodeID("tool-runtime"), label: "tool request", observes: ["tool.activity"]),
            HarnessGraphEdge(from: nodeID("tool-runtime"), to: nodeID("permission-policy"), label: "guarded effect", observes: ["approval.requested"]),
            HarnessGraphEdge(from: nodeID("permission-policy"), to: nodeID("execution-boundary"), label: "permission decision"),
            HarnessGraphEdge(from: nodeID("execution-boundary"), to: nodeID("agent-session"), label: "tool result", observes: ["tool.activity"]),
            HarnessGraphEdge(from: nodeID(modelKind), to: nodeID("output-stream"), label: "model stream", observes: ["model.completed", "output.activity"]),
            HarnessGraphEdge(from: nodeID("agent-session"), to: nodeID("session-storage"), label: "resumable state", observes: ["turn.completed", "turn.failed"]),
        ]
        edgeFrom = nodeID("protocol-adapter")
        edgeTo = nodeID("agent-session")
        selectedEditorNodeId = edgeFrom
    }

    private func save(runPreflight: Bool) {
        saving = true
        preflightSummary = nil
        Task {
            let args = arguments.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
            let saved = await store.saveCustomHarness(
                id: id, name: name, version: version, description: description, publisher: publisher,
                license: license, repository: repository, protocolName: protocolName,
                driverPackage: driverPackage, driverSpec: driverSpec,
                driverRequiresInstallScripts: driverRequiresInstallScripts,
                distributionKind: distributionKind, packageOrCommand: packageOrCommand, arguments: args,
                distributionEnvironment: distributionEnvironment,
                binaryCommand: binaryCommand, sha256: sha256, graphLevel: graphLevel,
                graphBoundary: graphBoundary, graphEvidenceSource: graphEvidenceSource,
                authMethodId: authMethodId, authMethodName: authMethodName, authKind: authKind,
                authFieldRef: authFieldRef, authFieldName: authFieldName, authFieldEnv: authFieldEnv,
                authAccountLabel: authAccountLabel, authBilling: authBilling, authAccountDetail: authAccountDetail,
                discoverAuthenticationAtRuntime: discoverAuthenticationAtRuntime,
                agentAuthMetaKey: agentAuthMetaKey, agentAuthFieldProperty: agentAuthFieldProperty,
                modelOwner: modelOwner, modelConfigurationRequired: modelConfigurationRequired,
                modelConfigurationDetail: modelConfigurationDetail,
                terminalAuthArguments: terminalAuthArguments, terminalAuthEnvironment: terminalAuthEnvironment,
                nodes: nodes, edges: edges, positions: positions, existingPack: existing
            )
            guard saved else { saving = false; return }
            guard runPreflight, let savedHarness = store.harnesses.first(where: { $0.id == id }) else {
                preflightSummary = "Manifest admitted and saved. No executable was installed or started."
                saving = false
                return
            }
            let installed: Bool
            if savedHarness.installation.status == "installed" || savedHarness.installation.status == "builtin" {
                installed = true
            } else {
                installed = await store.mutateHarness(
                    "install", harness: savedHarness, acceptUnverified: true,
                    acceptDriverBundle: acceptsDriverCodeExecution
                )
            }
            guard installed, let installedHarness = store.harnesses.first(where: { $0.id == id }) else {
                saving = false
                return
            }
            let preflighted = await store.mutateHarness(
                "probe", harness: installedHarness,
                acceptDriverBundle: acceptsDriverCodeExecution
            )
            if preflighted {
                preflightSummary = store.harnesses.first(where: { $0.id == id })?.compatibility.message
                    ?? "Live Driver preflight passed without sending a model prompt."
            }
            saving = false
        }
    }

    private func undoGraph() {
        guard let snapshot = graphUndo.popLast() else { return }
        graphRedo.append(graphSnapshot)
        restoreGraph(snapshot)
    }

    private func redoGraph() {
        guard let snapshot = graphRedo.popLast() else { return }
        graphUndo.append(graphSnapshot)
        restoreGraph(snapshot)
    }

    private func loadExistingIfNeeded() {
        guard !loadedExisting, let existing else { return }
        loadedExisting = true
        suppressGraphHistory = true
        id = existing.id
        name = existing.name
        version = existing.version
        description = existing.description ?? ""
        publisher = existing.publisher
        license = existing.license ?? ""
        repository = existing.repository ?? ""
        protocolName = existing.protocolName
        driverPackage = existing.driverBundle?.package ?? ""
        driverSpec = existing.driverBundle?.spec ?? ""
        driverRequiresInstallScripts = existing.driverBundle?.requiresInstallScripts ?? false
        discoverAuthenticationAtRuntime = existing.authenticationDiscovery?.source == "runtime"
        modelOwner = existing.modelConfiguration?.owner ?? "harness"
        modelConfigurationRequired = existing.modelConfiguration?.required ?? false
        modelConfigurationDetail = existing.modelConfiguration?.detail
            ?? "Models and model-specific controls are discovered from the running Harness."
        graphLevel = existing.graph.level
        graphBoundary = existing.graph.boundary ?? "Harness process"
        graphEvidenceSource = existing.graph.evidence?.first?.source ?? "Pack declaration"
        nodes = existing.graph.nodes
        edges = existing.graph.edges
        positions = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { index, node in
            let x = node.position?.x ?? node.config?["x"]?.doubleValue ?? Double(110 + (index % 3) * 190)
            let y = node.position?.y ?? node.config?["y"]?.doubleValue ?? Double(70 + (index / 3) * 100)
            return (node.id, CGPoint(x: x, y: y))
        })
        edgeFrom = nodes.first?.id ?? ""
        edgeTo = nodes.dropFirst().first?.id ?? nodes.first?.id ?? ""
        selectedEditorNodeId = nodes.first?.id
        if let distribution = existing.distribution {
            distributionKind = distribution.kind
            packageOrCommand = distribution.package ?? distribution.archive ?? distribution.command ?? ""
            binaryCommand = distribution.kind == "binary" ? distribution.command ?? "" : ""
            sha256 = distribution.sha256 ?? ""
            arguments = distribution.args.joined(separator: "\n")
            distributionEnvironment = distribution.env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        }
        if let method = existing.auth.methods.first {
            authMethodId = method.id
            authMethodName = method.name
            authKind = method.kind
            if let field = method.fields.first {
                authFieldRef = field.ref
                authFieldName = field.name
                authFieldEnv = field.env ?? ""
            }
            authAccountLabel = method.account?.label ?? existing.account?.label ?? ""
            authBilling = method.account?.billing ?? existing.account?.billing ?? "unknown"
            authAccountDetail = method.account?.detail ?? existing.account?.detail ?? ""
            agentAuthMetaKey = method.agent?.metaKey ?? ""
            if let ref = method.fields.first?.ref {
                agentAuthFieldProperty = method.agent?.fieldMap[ref] ?? ""
            }
            if let terminal = method.terminal {
                terminalAuthArguments = terminal.args.joined(separator: "\n")
                terminalAuthEnvironment = terminal.env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
            }
        }
        if existing.auth.methods.isEmpty {
            authAccountLabel = existing.account?.label ?? ""
            authBilling = existing.account?.billing ?? "unknown"
            authAccountDetail = existing.account?.detail ?? ""
        }
    }
}

private struct HarnessTypedFieldDraft: Identifiable {
    let id = UUID()
    var fieldID: String
    var name: String
    var kind: String
    var bindingKind: String
    var target: String
    var required: Bool
    var choices: String
    var stringValue: String
    var boolValue: Bool
}

private struct HarnessNodeConfigEditor: View {
    @Binding var node: HarnessGraphNode
    let bindingKinds: [HarnessBindingKindDefinition]
    @State private var text = "{}"
    @State private var error: String?
    @State private var fields: [HarnessTypedFieldDraft] = []
    @State private var showingAdvanced = false

    private var supportedFieldTypes: [String] {
        let supported = Set(bindingKinds.flatMap(\.fieldTypes))
        return ["string", "boolean", "select", "secret-reference"].filter { supported.contains($0) }
    }

    private func bindings(for type: String) -> [HarnessBindingKindDefinition] {
        bindingKinds.filter { $0.fieldTypes.contains(type) }
    }

    private func binding(_ kind: String) -> HarnessBindingKindDefinition? {
        bindingKinds.first { $0.kind == kind }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if node.editable {
                HStack {
                    Label("Executable controls", systemImage: "slider.horizontal.3")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Button("Add control") {
                        guard let binding = bindingKinds.first,
                              let fieldType = binding.fieldTypes.first else { return }
                        let index = fields.count + 1
                        fields.append(.init(
                            fieldID: "option_\(index)", name: "Option \(index)", kind: fieldType,
                            bindingKind: binding.kind,
                            target: "", required: true, choices: "", stringValue: "", boolValue: false
                        ))
                    }
                    .controlSize(.small)
                    .disabled(bindingKinds.isEmpty)
                }
                ForEach($fields) { $field in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 7) {
                            TextField("Field id", text: $field.fieldID).textFieldStyle(.roundedBorder)
                            TextField("Label", text: $field.name).textFieldStyle(.roundedBorder)
                            Picker("Type", selection: $field.kind) {
                                if supportedFieldTypes.contains("string") { Text("Text").tag("string") }
                                if supportedFieldTypes.contains("boolean") { Text("Boolean").tag("boolean") }
                                if supportedFieldTypes.contains("select") { Text("Choice").tag("select") }
                                if supportedFieldTypes.contains("secret-reference") { Text("Credential reference").tag("secret-reference") }
                            }
                            .labelsHidden().frame(width: 148)
                            .onChange(of: field.kind) { _, type in
                                if !bindings(for: type).contains(where: { $0.kind == field.bindingKind }),
                                   let replacement = bindings(for: type).first {
                                    field.bindingKind = replacement.kind
                                }
                            }
                            Toggle("Required", isOn: $field.required).toggleStyle(.checkbox)
                            Button(role: .destructive) {
                                fields.removeAll { $0.id == field.id }
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                        HStack(spacing: 7) {
                            Picker("Driver binding", selection: $field.bindingKind) {
                                ForEach(bindings(for: field.kind)) { binding in
                                    Text(binding.name).tag(binding.kind)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 150)
                            TextField(binding(field.bindingKind)?.targetLabel ?? "Binding target", text: $field.target)
                                .textFieldStyle(.roundedBorder)
                                .help(binding(field.bindingKind)?.targetPlaceholder ?? "Driver-owned executable target")
                            if field.kind == "boolean" {
                                Toggle(field.boolValue ? "On" : "Off", isOn: $field.boolValue)
                                    .toggleStyle(.switch).frame(width: 76)
                            } else if field.kind == "select" {
                                TextField("Choices: id | Label, one per line", text: $field.choices, axis: .vertical)
                                    .textFieldStyle(.roundedBorder).lineLimit(1...3)
                                TextField("Selected id", text: $field.stringValue).textFieldStyle(.roundedBorder)
                                    .frame(width: 120)
                            } else if field.kind == "secret-reference" {
                                TextField("Host reference, e.g. OPENAI_API_KEY", text: $field.stringValue)
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                TextField("Default value", text: $field.stringValue).textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                    .padding(9)
                    .background(OpenCodexPalette.hover, in: RoundedRectangle(cornerRadius: 8))
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(bindingKinds.isEmpty
                         ? "The loaded Driver exposes no executable binding vocabulary, so this node must remain explanatory."
                         : "Each control binds through a Driver-published semantic. Live preflight verifies targets and values, then tears the Harness down without sending a model prompt.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Apply controls") { applyTypedFields() }
                        .controlSize(.small)
                }
                if fields.isEmpty {
                    Text("No executable controls. This component remains explanatory until its Driver owns a typed binding.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("Advanced manifest JSON", isExpanded: $showingAdvanced) {
                HStack(alignment: .top, spacing: 8) {
                    TextEditor(text: $text)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 68)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(error == nil ? OpenCodexPalette.border : Color.red))
                    Button("Apply JSON") { applyJSON() }.disabled(!node.editable)
                }
                Text("Advanced JSON remains subject to the selected protocol Driver's executable-config validation.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onAppear { load() }
        .onChange(of: node.id) { _, _ in load() }
        if let error { Text(error).font(.caption2).foregroundStyle(.red) }
    }

    private func encoded(_ object: [String: JSONValue]) -> String {
        guard let data = try? JSONEncoder().encode(JSONValue.object(object)),
              let value = String(data: data, encoding: .utf8) else { return "{}" }
        return value
    }

    private func choiceLines(_ choices: [HarnessConfigChoice]?) -> String {
        (choices ?? []).map { "\($0.id) | \($0.name)" }.joined(separator: "\n")
    }

    private func load() {
        text = encoded(node.config ?? [:])
        if let schema = node.configSchema {
            fields = schema.fields.map { field in
                let value = node.config?[field.id]
                return HarnessTypedFieldDraft(
                    fieldID: field.id, name: field.name, kind: field.type,
                    bindingKind: field.binding.kind, target: field.binding.target,
                    required: field.required, choices: choiceLines(field.choices),
                    stringValue: value?.stringValue ?? "", boolValue: value?.boolValue ?? false
                )
            }
            return
        }
        fields = []
    }

    private func replacing(schema: HarnessNodeConfigSchema?, config: [String: JSONValue]) {
        node = HarnessGraphNode(
            id: node.id, kind: node.kind, title: node.title, editable: node.editable,
            responsibility: node.responsibility, inputs: node.inputs, outputs: node.outputs, ports: node.ports,
            evidence: node.evidence, observes: node.observes, configSchema: schema, config: config
        )
        text = encoded(config)
    }

    private func parsedChoices(_ source: String) -> [HarnessConfigChoice] {
        source.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let id = parts.first, !id.isEmpty else { return nil }
            return HarnessConfigChoice(id: id, name: parts.count == 2 && !parts[1].isEmpty ? parts[1] : id)
        }
    }

    private func applyTypedFields() {
        let ids = fields.map { $0.fieldID.trimmingCharacters(in: .whitespacesAndNewlines) }
        let targets = fields.map { $0.target.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !ids.contains(""), Set(ids).count == ids.count else {
            error = "Every control needs one unique non-empty field id."
            return
        }
        guard !targets.contains("") else {
            error = "Every control needs a Driver binding target."
            return
        }
        if fields.contains(where: { $0.bindingKind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            error = "Every control needs a Driver binding kind."
            return
        }
        var config: [String: JSONValue] = [:]
        var schemaFields: [HarnessConfigField] = []
        for (index, draft) in fields.enumerated() {
            let choices = parsedChoices(draft.choices)
            if draft.kind == "select" && choices.isEmpty {
                error = "Choice control \(draft.name) needs at least one id | Label row."
                return
            }
            if draft.kind == "select" && !choices.contains(where: { $0.id == draft.stringValue }) {
                error = "Selected value for \(draft.name) must match a declared choice id."
                return
            }
            if draft.kind == "secret-reference",
               draft.stringValue.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) == nil {
                error = "Credential reference for \(draft.name) must look like OPENAI_API_KEY. Secret values never belong in a Pack."
                return
            }
            let fieldID = ids[index]
            guard let binding = binding(draft.bindingKind), binding.fieldTypes.contains(draft.kind) else {
                error = "The loaded Driver does not support \(draft.kind) through binding \(draft.bindingKind)."
                return
            }
            if let pattern = binding.targetPattern,
               targets[index].range(of: pattern, options: .regularExpression) == nil {
                error = "\(draft.name) needs a valid \(binding.targetLabel.lowercased())."
                return
            }
            schemaFields.append(HarnessConfigField(
                id: fieldID, name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fieldID : draft.name,
                type: draft.kind, required: draft.required,
                choices: draft.kind == "select" ? choices : nil,
                binding: HarnessConfigBinding(
                    kind: draft.bindingKind,
                    target: targets[index]
                )
            ))
            config[fieldID] = draft.kind == "boolean" ? JSONValue.bool(draft.boolValue) : JSONValue.string(draft.stringValue)
        }
        replacing(schema: schemaFields.isEmpty ? nil : HarnessNodeConfigSchema(version: 1, fields: schemaFields), config: config)
        error = nil
    }

    private func applyJSON() {
        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            guard case let .object(config) = value else {
                error = "Node config must be a JSON object."
                return
            }
            guard let schema = node.configSchema else {
                guard config.isEmpty else {
                    error = "Define Driver-backed typed controls before adding executable config."
                    return
                }
                replacing(schema: nil, config: [:])
                error = nil
                return
            }
            let fieldsByID = Dictionary(uniqueKeysWithValues: schema.fields.map { ($0.id, $0) })
            let undeclared = config.keys.filter { fieldsByID[$0] == nil }.sorted()
            guard undeclared.isEmpty else {
                error = "Undeclared config field: \(undeclared.joined(separator: ", ")). Add a typed Driver binding first."
                return
            }
            for field in schema.fields {
                guard let configured = config[field.id] else {
                    if field.required {
                        error = "Required config field \(field.name) is missing."
                        return
                    }
                    continue
                }
                switch (field.type, configured) {
                case ("boolean", .bool): break
                case ("string", .string), ("secret-reference", .string): break
                case ("select", .string(let selected)):
                    guard field.choices?.contains(where: { $0.id == selected }) == true else {
                        error = "Value for \(field.name) must match a declared choice id."
                        return
                    }
                default:
                    error = "\(field.name) accepts only its declared \(field.type) scalar value; nested JSON and numbers are not executable Pack config."
                    return
                }
                if field.type == "secret-reference",
                   configured.stringValue?.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) == nil {
                    error = "\(field.name) must contain a Host credential reference such as OPENAI_API_KEY, never a secret value."
                    return
                }
            }
            replacing(schema: node.configSchema, config: config)
            load()
            error = nil
        } catch {
            self.error = "Invalid JSON: \(error.localizedDescription)"
        }
    }
}

private struct HarnessGraphPreview: View {
    let graph: HarnessGraph
    var runtime: HarnessRuntimeProjection? = nil
    var interactive = false
    var selectedNodeId: String? = nil
    var onSelect: ((String) -> Void)? = nil
    @State private var scale: CGFloat = 1
    @GestureState private var gestureScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var gestureOffset: CGSize = .zero
    @State private var query = ""
    @FocusState private var focusedNodeId: String?

    var body: some View {
        GeometryReader { proxy in
            let points = layout(in: proxy.size)
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.045))
                RoundedRectangle(cornerRadius: 10)
                    .stroke(OpenCodexPalette.softBorder)

                ForEach(Array(graph.edges.enumerated()), id: \.offset) { _, edge in
                    if let from = points[edge.from], let to = points[edge.to] {
                        let endpoints = edgeEndpoints(from: from, to: to)
                        let liveEdge = runtimeEdge(edge)
                        Path { path in
                            path.move(to: endpoints.start)
                            path.addLine(to: endpoints.end)
                        }
                        .stroke(edgeColor(liveEdge?.status).opacity(liveEdge == nil ? 0.5 : 0.95), style: StrokeStyle(
                            lineWidth: liveEdge == nil ? 1.35 : 2.4, lineCap: .round
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
                                .background(OpenCodexPalette.elevated.opacity(0.94), in: Capsule())
                                .position(
                                    x: (endpoints.start.x + endpoints.end.x) / 2,
                                    y: (endpoints.start.y + endpoints.end.y) / 2 - 10
                                )
                        }
                    }
                }
                ForEach(graph.nodes) { node in
                    Button {
                        onSelect?(node.id)
                    } label: {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(runtimeColor(node.id))
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(node.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .lineLimit(2)
                                Text(node.kind)
                                    .font(.system(size: 8.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 9)
                        .frame(width: 144, height: 54)
                        .background(OpenCodexPalette.elevated, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                            selectedNodeId == node.id || matches(node) ? Color.accentColor : nodeColor(node).opacity(0.65),
                            lineWidth: selectedNodeId == node.id || matches(node) ? 1.6 : 1
                        ))
                    }
                    .buttonStyle(.plain)
                    .focused($focusedNodeId, equals: node.id)
                    .position(points[node.id] ?? .zero)
                }

                if let boundary = graph.boundary {
                    Text(boundary)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 5))
                        .position(x: 68, y: 16)
                }
            }
            .scaleEffect(scale * gestureScale)
            .offset(x: offset.width + gestureOffset.width, y: offset.height + gestureOffset.height)
            .gesture(
                SimultaneousGesture(
                    MagnificationGesture()
                        .updating($gestureScale) { value, state, _ in if interactive { state = value } }
                        .onEnded { value in if interactive { scale = min(2.5, max(0.55, scale * value)) } },
                    DragGesture()
                        .updating($gestureOffset) { value, state, _ in if interactive { state = value.translation } }
                        .onEnded { value in
                            if interactive {
                                offset.width += value.translation.width
                                offset.height += value.translation.height
                            }
                        }
                )
            )
            .clipped()
            .onMoveCommand { direction in
                guard interactive else { return }
                moveFocus(direction)
            }
            .overlay(alignment: .topTrailing) {
                if interactive {
                    HStack(spacing: 5) {
                        TextField("Find node", text: $query)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 118)
                            .onSubmit { focusFirstMatch() }
                        Button { scale = min(2.5, scale + 0.2) } label: { Image(systemName: "plus.magnifyingglass") }
                        Button { scale = max(0.55, scale - 0.2) } label: { Image(systemName: "minus.magnifyingglass") }
                        Button { scale = 1; offset = .zero; query = "" } label: { Image(systemName: "arrow.counterclockwise") }
                    }
                    .buttonStyle(.borderless)
                    .padding(7)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(7)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(graph.level) Harness architecture with \(graph.nodes.count) components")
    }

    private func layout(in size: CGSize) -> [String: CGPoint] {
        guard !graph.nodes.isEmpty else { return [:] }
        let authored = graph.nodes.compactMap { node -> (String, HarnessGraphPosition)? in
            node.position.map { (node.id, $0) }
        }
        if authored.count == graph.nodes.count {
            let xs = authored.map { $0.1.x }
            let ys = authored.map { $0.1.y }
            let minX = xs.min() ?? 0
            let maxX = xs.max() ?? minX
            let minY = ys.min() ?? 0
            let maxY = ys.max() ?? minY
            let horizontalInset: CGFloat = min(86, max(46, size.width * 0.12))
            let verticalInset: CGFloat = min(48, max(34, size.height * 0.12))
            let usableWidth = max(1, size.width - horizontalInset * 2)
            let usableHeight = max(1, size.height - verticalInset * 2)
            return Dictionary(uniqueKeysWithValues: authored.map { id, position in
                let x = maxX == minX ? size.width / 2
                    : horizontalInset + CGFloat((position.x - minX) / (maxX - minX)) * usableWidth
                let y = maxY == minY ? size.height / 2
                    : verticalInset + CGFloat((position.y - minY) / (maxY - minY)) * usableHeight
                return (id, CGPoint(x: x, y: y))
            })
        }
        var level = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, 0) })
        let nodeIDs = Set(graph.nodes.map(\.id))
        let sourceOrder = Dictionary(uniqueKeysWithValues: graph.nodes.enumerated().map { ($0.element.id, $0.offset) })
        for _ in 0..<max(1, graph.nodes.count - 1) {
            var changed = false
            for edge in graph.edges where nodeIDs.contains(edge.from)
                && nodeIDs.contains(edge.to)
                && (sourceOrder[edge.from] ?? 0) < (sourceOrder[edge.to] ?? 0) {
                let candidate = min(graph.nodes.count - 1, (level[edge.from] ?? 0) + 1)
                if candidate > (level[edge.to] ?? 0) {
                    level[edge.to] = candidate
                    changed = true
                }
            }
            if !changed { break }
        }

        let usedLevels = Array(Set(level.values)).sorted()
        let normalized = Dictionary(uniqueKeysWithValues: usedLevels.enumerated().map { ($0.element, $0.offset) })
        let rows = Dictionary(grouping: graph.nodes) { normalized[level[$0.id] ?? 0] ?? 0 }
        let maxRow = max(0, (rows.keys.max() ?? 0))
        let horizontalInset: CGFloat = 76
        let verticalInset: CGFloat = 48
        let verticalStep = maxRow == 0 ? 0 : max(66, (size.height - verticalInset * 2) / CGFloat(maxRow))

        var points: [String: CGPoint] = [:]
        for row in 0...maxRow {
            let nodes = rows[row] ?? []
            let usableWidth = max(136, size.width - horizontalInset * 2)
            let horizontalStep = nodes.count <= 1 ? 0 : usableWidth / CGFloat(nodes.count - 1)
            let contentWidth = horizontalStep * CGFloat(max(0, nodes.count - 1))
            let startX = nodes.count <= 1 ? size.width / 2 : max(horizontalInset, (size.width - contentWidth) / 2)
            for (column, node) in nodes.enumerated() {
                points[node.id] = CGPoint(
                    x: min(size.width - horizontalInset, startX + CGFloat(column) * horizontalStep),
                    y: min(size.height - verticalInset, verticalInset + CGFloat(row) * verticalStep)
                )
            }
        }
        return points
    }

    private func edgeEndpoints(from: CGPoint, to: CGPoint) -> (start: CGPoint, end: CGPoint) {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let distance = max(1, hypot(dx, dy))
        let ux = dx / distance
        let uy = dy / distance
        let horizontal = abs(dx) >= abs(dy)
        let inset: CGFloat = horizontal ? 76 : 34
        return (
            CGPoint(x: from.x + ux * inset, y: from.y + uy * inset),
            CGPoint(x: to.x - ux * inset, y: to.y - uy * inset)
        )
    }

    private func matches(_ node: HarnessGraphNode) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return !needle.isEmpty && (node.title.localizedCaseInsensitiveContains(needle) || node.kind.localizedCaseInsensitiveContains(needle))
    }

    private func focusFirstMatch() {
        guard let match = graph.nodes.first(where: matches) else { return }
        focusedNodeId = match.id
        onSelect?(match.id)
    }

    private func moveFocus(_ direction: MoveCommandDirection) {
        guard !graph.nodes.isEmpty else { return }
        let current = graph.nodes.firstIndex { $0.id == (focusedNodeId ?? selectedNodeId) } ?? 0
        let delta: Int
        switch direction {
        case .left, .up: delta = -1
        case .right, .down: delta = 1
        @unknown default: delta = 0
        }
        let next = min(graph.nodes.count - 1, max(0, current + delta))
        let id = graph.nodes[next].id
        focusedNodeId = id
        onSelect?(id)
    }

    private func nodeColor(_ node: HarnessGraphNode) -> Color {
        matches(node) ? .purple : runtimeColor(node.id)
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

    private func runtimeEdge(_ edge: HarnessGraphEdge) -> HarnessRuntimeProjection.Edge? {
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

/// A readable architecture projection for narrow inspectors. The full graph
/// remains available in the full relationship map, where there is enough space for
/// topology; this view preserves every component and its live evidence without
/// shrinking nodes into an illegible diagram.
private struct HarnessArchitectureSummary: View {
    let graph: HarnessGraph
    var runtime: HarnessRuntimeProjection? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let boundary = graph.boundary {
                HStack(spacing: 6) {
                    Image(systemName: "shippingbox")
                    Text(boundary).lineLimit(2)
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            }

            ForEach(graph.nodes) { node in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(runtimeColor(node.id))
                        .frame(width: 7, height: 7)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(node.title)
                                .font(.system(size: 11.5, weight: .semibold))
                            Spacer(minLength: 4)
                            Text(runtime?.nodes[node.id]?.status ?? node.kind)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        if let responsibility = node.responsibility {
                            Text(responsibility)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let activity = runtime?.nodes[node.id]?.activity {
                            Text(activity)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(runtimeColor(node.id))
                                .lineLimit(2)
                        }
                    }
                }
                .padding(8)
                .background(OpenCodexPalette.elevated, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(OpenCodexPalette.softBorder))
            }

            Text("\(graph.nodes.count) components · \(graph.edges.count) declared connections")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(graph.level) Harness architecture with \(graph.nodes.count) components")
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

private struct HarnessDetailPanel: View {
    let harness: HarnessCatalogEntry
    var compact = false
    var runtime: HarnessRuntimeProjection? = nil
    @State private var selectedNodeId: String?
    @State private var architecturePresentation = "Flow"
    @State private var showsCapabilities = false

    private var truthExplanation: String {
        switch harness.graph.level {
        case "composable": return "Declared nodes may be edited only where the Pack allows it."
        case "observable": return "Read-only structure confirmed by the Pack; OpenFish does not invent private internals."
        default: return "This Harness exposes only its runtime boundary. Private internals remain intentionally hidden."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(harness.name).font(compact ? .caption.weight(.semibold) : .headline)
                        if harness.verified { Image(systemName: "checkmark.seal.fill").foregroundStyle(.blue).font(.caption) }
                    }
                    Text("\(harness.publisher) · \(harness.protocolName.uppercased()) · \(harness.version)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(harness.graph.level.capitalized)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7).frame(height: 20)
                    .background(.secondary.opacity(0.12), in: Capsule())
            }
            if !compact, let description = harness.description {
                Text(description).font(.callout).foregroundStyle(.secondary)
            }
            if let boundary = harness.graph.boundary {
                HStack {
                    Label(boundary, systemImage: "square.dashed")
                    Spacer()
                    Text("Harness boundary").foregroundStyle(.secondary)
                }
                .font(.caption2.weight(.semibold))
            }
            if compact {
                HarnessArchitectureFlow(
                    graph: harness.graph, runtime: runtime,
                    selectedNodeId: selectedNodeId, onSelect: { selectedNodeId = $0 }, compact: true
                )
                .frame(height: min(230, max(150, CGFloat(harness.graph.nodes.count) * 28)))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Text("Architecture view")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        Picker("", selection: $architecturePresentation) {
                            Text("Operational lens").tag("Flow")
                            Text("Full relationship map").tag("Map")
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 285)
                        .accessibilityLabel("Architecture view")
                        Spacer()
                    }
                    if architecturePresentation == "Flow" {
                        HarnessArchitectureFlow(
                            graph: harness.graph, runtime: runtime,
                            selectedNodeId: selectedNodeId, onSelect: { selectedNodeId = $0 }
                        )
                        .frame(height: min(390, max(220, CGFloat(harness.graph.nodes.count) * 36)))
                    } else {
                        HarnessGraphPreview(
                            graph: harness.graph,
                            runtime: runtime,
                            interactive: true,
                            selectedNodeId: selectedNodeId,
                            onSelect: { selectedNodeId = $0 }
                        )
                        .frame(height: 330)
                    }
                    HStack(spacing: 12) {
                        Label(architecturePresentation == "Flow" ? "Grouped by operational responsibility" : "Every declared relationship", systemImage: architecturePresentation == "Flow" ? "rectangle.3.group" : "point.3.connected.trianglepath.dotted")
                        Label("Observed state", systemImage: "circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Text("Select a component to inspect its evidence")
                    }
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    if let node = selectedNode {
                        HarnessNodeEvidencePanel(node: node)
                    }
                }
            }
            Text(truthExplanation).font(.caption2).foregroundStyle(.secondary)
            if let publication = harness.publication {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: publication.status == "revoked" ? "exclamationmark.shield.fill" : publication.status == "published" ? "checkmark.seal.fill" : "doc.badge.clock")
                        .foregroundStyle(publication.status == "revoked" ? Color.red : publication.status == "published" ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(publication.status.replacingOccurrences(of: "-", with: " ").capitalized)
                            .font(.caption.weight(.semibold))
                        Text(publication.detail).font(.caption2).foregroundStyle(.secondary)
                        if let reason = publication.revokedReason {
                            Text(reason).font(.caption2.weight(.semibold)).foregroundStyle(.red)
                        }
                    }
                }
                .padding(9)
                .background(OpenCodexPalette.hover, in: RoundedRectangle(cornerRadius: 9))
            }
            if !compact {
                DisclosureGroup(isExpanded: $showsCapabilities) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(harness.capabilities) { capability in
                            HStack(spacing: 6) {
                                Image(systemName: capability.status == "supported" ? "checkmark.circle.fill" : capability.status == "runtime" ? "waveform.path.ecg" : "minus.circle")
                                    .foregroundStyle(capability.status == "supported" ? Color.green : capability.status == "runtime" ? Color.blue : Color.secondary)
                                Text(capability.id.replacingOccurrences(of: ".", with: " · "))
                                    .lineLimit(1).minimumScaleFactor(0.8)
                                Spacer(minLength: 0)
                            }
                            .font(.caption2)
                            .help(capability.detail ?? "Declared by \(capability.source)")
                        }
                    }
                    .padding(.top, 7)
                } label: {
                    HStack {
                        Text("Capabilities").font(.caption.weight(.semibold))
                        Text("\(harness.capabilities.filter { $0.status != "unsupported" }.count) available")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text(
                            "Driver API v\(harness.driver.apiVersion) · "
                                + (harness.driver.loaded ? "loaded" : "not loaded")
                                + " · \(driverAuthorizationLabel)"
                        )
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(9)
                .background(OpenCodexPalette.hover, in: RoundedRectangle(cornerRadius: 9))
            }
            if !compact, let evidence = harness.graph.evidence, !evidence.isEmpty {
                HStack(spacing: 6) {
                    Text("Evidence").font(.caption2.weight(.semibold))
                    ForEach(evidence) { item in
                        Text(item.kind.replacingOccurrences(of: "-", with: " ").capitalized)
                            .font(.caption2).padding(.horizontal, 7).frame(height: 20)
                            .background(evidenceColor(item.kind).opacity(0.13), in: Capsule())
                            .help("\(item.source)\(item.version.map { " · \($0)" } ?? "")")
                    }
                }
            }
            HStack(spacing: 12) {
                Label(harness.installation.status.replacingOccurrences(of: "-", with: " "), systemImage: "shippingbox")
                Label(harness.auth.status.replacingOccurrences(of: "-", with: " "), systemImage: "person.crop.circle.badge.checkmark")
                Label(driverAuthorizationLabel, systemImage: "checkmark.shield")
                Label(harness.compatibility.classification.replacingOccurrences(of: "-", with: " "), systemImage: harness.compatibility.classification == "incompatible" ? "exclamationmark.triangle" : "checkmark.shield")
            }
            .font(.caption2)
            .foregroundStyle(harness.compatibility.classification == "incompatible" ? Color.red : Color.secondary)
        }
        .padding(compact ? 9 : 14)
        .background(OpenCodexPalette.elevated, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(OpenCodexPalette.border))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(harness.name) Harness details, \(harness.graph.level) architecture")
        .onAppear { if selectedNodeId == nil { selectedNodeId = harness.graph.nodes.first?.id } }
        .onChange(of: harness.id) { _, _ in selectedNodeId = harness.graph.nodes.first?.id }
    }

    private var selectedNode: HarnessGraphNode? {
        harness.graph.nodes.first(where: { $0.id == selectedNodeId }) ?? harness.graph.nodes.first
    }

    private var driverAuthorizationLabel: String {
        switch harness.driver.authorization {
        case "authorized": return "exact Driver authorized"
        case "required": return "exact Driver authorization required"
        default: return "built-in Driver"
        }
    }

    private func evidenceColor(_ kind: String) -> Color {
        switch kind {
        case "runtime-observed": return .green
        case "source-derived": return .blue
        default: return .secondary
        }
    }
}

private struct HarnessArchitecturePhase: Identifiable {
    let id: String
    let title: String
    let summary: String
    let icon: String
    let nodes: [HarnessGraphNode]
}

private struct HarnessArchitectureFlow: View {
    let graph: HarnessGraph
    var runtime: HarnessRuntimeProjection? = nil
    var selectedNodeId: String? = nil
    var onSelect: ((String) -> Void)? = nil
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            if !compact {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Operational architecture")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("Stages come from the Pack's exact connections, including branches and cycles. OpenFish does not infer private categories; select a component for its responsibility, ports, and evidence.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 3)
            }

            // A small Harness usually moves only horizontally, but one real
            // operational stage may contain many parallel responsibilities.
            // Keep every declared node reachable instead of cropping a large
            // Pack to the inspector's fixed-height card.
            ScrollView([.horizontal, .vertical], showsIndicators: !compact) {
                HStack(alignment: .top, spacing: compact ? 8 : 10) {
                    ForEach(Array(phases.enumerated()), id: \.element.id) { index, phase in
                        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                            HStack(spacing: 7) {
                                Image(systemName: phase.icon)
                                    .font(.system(size: compact ? 11 : 12, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(phase.title)
                                        .font(.system(size: compact ? 10.5 : 11.5, weight: .semibold))
                                    if !compact {
                                        Text(phase.summary)
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                            }

                            ForEach(phase.nodes) { node in
                                Button { onSelect?(node.id) } label: {
                                    VStack(alignment: .leading, spacing: compact ? 3 : 5) {
                                        HStack(spacing: 6) {
                                            Circle()
                                                .fill(runtimeColor(node.id))
                                                .frame(width: 7, height: 7)
                                            Text(node.title)
                                                .font(.system(size: compact ? 10.5 : 11.5, weight: .semibold))
                                                .lineLimit(1)
                                            Spacer(minLength: 0)
                                            if node.editable {
                                                Image(systemName: "slider.horizontal.3")
                                                    .font(.system(size: 9, weight: .medium))
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        Text(node.responsibility ?? "Responsibility not declared by this Pack.")
                                            .font(.system(size: compact ? 9 : 10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(compact ? 2 : 3)
                                            .multilineTextAlignment(.leading)
                                        if !compact {
                                            Text(relationshipSummary(node.id))
                                                .font(.system(size: 9))
                                                .foregroundStyle(.tertiary)
                                                .lineLimit(2)
                                        }
                                        if !compact, let observed = runtime?.nodes[node.id] {
                                            Text(observed.activity)
                                                .font(.system(size: 9.5, weight: .medium))
                                                .foregroundStyle(runtimeColor(node.id))
                                                .lineLimit(1)
                                        }
                                    }
                                    .padding(compact ? 7 : 9)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        selectedNodeId == node.id ? Color.accentColor.opacity(0.11) : OpenCodexPalette.elevated,
                                        in: RoundedRectangle(cornerRadius: 8)
                                    )
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                                        selectedNodeId == node.id ? Color.accentColor.opacity(0.65) : OpenCodexPalette.softBorder
                                    ))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(node.title), \(phase.title), \(node.responsibility ?? node.kind)")
                            }
                        }
                        .padding(compact ? 8 : 10)
                        .frame(width: compact ? 176 : 212, alignment: .topLeading)
                        .background(OpenCodexPalette.hover, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(OpenCodexPalette.softBorder))

                        if index < phases.count - 1 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.top, compact ? 18 : 24)
                        }
                    }
                }
                .padding(8)
            }
            .background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(OpenCodexPalette.softBorder))
        }
    }

    private var phases: [HarnessArchitecturePhase] {
        guard !graph.nodes.isEmpty else { return [] }
        let order = Dictionary(uniqueKeysWithValues: graph.nodes.enumerated().map { ($0.element.id, $0.offset) })
        var assigned = Set<String>()
        var groups: [[HarnessGraphNode]] = []
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
            return HarnessArchitecturePhase(
                id: groupIndices.map(String.init).joined(separator: "-"),
                title: title,
                summary: summary,
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

    private func firstNodeOrder(_ nodes: [HarnessGraphNode], order: [String: Int]) -> Int {
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
        let receives = incoming.isEmpty ? "entry" : "from \(incoming.joined(separator: ", "))"
        let sends = outgoing.isEmpty ? "outcome" : "to \(outgoing.joined(separator: ", "))"
        return "\(receives) · \(sends)"
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

private struct HarnessNodeEvidencePanel: View {
    let node: HarnessGraphNode
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: node.editable ? "slider.horizontal.3" : "lock")
                Text(node.title).font(.caption.weight(.semibold))
                Spacer()
                Text(node.editable ? "Editable" : "Read only").font(.caption2).foregroundStyle(.secondary)
            }
            Text(node.responsibility ?? "This Pack has not supplied a responsibility statement.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let inputs = node.inputs, !inputs.isEmpty {
                Text("Inputs").font(.caption2.weight(.semibold))
                Text(inputs.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
            }
            if let outputs = node.outputs, !outputs.isEmpty {
                Text("Outputs").font(.caption2.weight(.semibold))
                Text(outputs.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
            }
            if let ports = node.ports, !ports.isEmpty {
                Divider()
                Text("Typed ports").font(.caption2.weight(.semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 6)], alignment: .leading, spacing: 5) {
                    ForEach(ports) { port in
                        HStack(spacing: 6) {
                            Image(systemName: port.direction == "input" ? "arrow.right.circle" : "arrow.left.circle")
                            Text(port.name).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(port.dataType).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .font(.caption2)
                    }
                }
            }
            if let fields = node.configSchema?.fields, !fields.isEmpty {
                Divider()
                Text("Executable controls").font(.caption2.weight(.semibold))
                ForEach(fields) { field in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(field.name).font(.caption2.weight(.medium))
                            Text("\(field.binding.kind) · \(field.binding.target)")
                                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text(configDisplayValue(node.config?[field.id]))
                            .font(.caption2.weight(.medium)).lineLimit(1)
                    }
                }
            }
            if let evidence = node.evidence, !evidence.isEmpty {
                Divider()
                ForEach(evidence) { item in
                    Label(item.kind.replacingOccurrences(of: "-", with: " ").capitalized, systemImage: "doc.text.magnifyingglass")
                        .font(.caption2.weight(.semibold))
                    Text("\(item.source)\(item.version.map { " · \($0)" } ?? "")")
                        .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .padding(11)
        .background(OpenCodexPalette.hover, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(OpenCodexPalette.border))
    }

    private func configDisplayValue(_ value: JSONValue?) -> String {
        guard let value else { return "Not set" }
        if let text = value.stringValue { return text }
        if let flag = value.boolValue { return flag ? "On" : "Off" }
        return "Configured"
    }
}

private struct EditableHarnessGraphCanvas: View {
    @Binding var nodes: [HarnessGraphNode]
    @Binding var edges: [HarnessGraphEdge]
    @Binding var positions: [String: CGPoint]
    @Binding var selectedNodeId: String?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(Array(edges.enumerated()), id: \.offset) { index, edge in
                    if let from = positions[edge.from], let to = positions[edge.to] {
                        Path { path in
                            path.move(to: from)
                            path.addCurve(to: to, control1: CGPoint(x: (from.x + to.x) / 2, y: from.y), control2: CGPoint(x: (from.x + to.x) / 2, y: to.y))
                        }
                        .stroke(Color.accentColor.opacity(0.65), lineWidth: 2)
                        .onTapGesture { edges.remove(at: index) }
                    }
                }
                ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                    HarnessEditableNode(node: node, selected: selectedNodeId == node.id)
                    .position(positions[node.id] ?? CGPoint(x: 90 + CGFloat(index) * 155, y: proxy.size.height / 2))
                    .simultaneousGesture(TapGesture().onEnded { selectedNodeId = node.id })
                    .gesture(DragGesture(coordinateSpace: .named("harnessGraphCanvas")).onChanged { value in
                        selectedNodeId = node.id
                        let x = min(max(CGFloat(70), value.location.x), proxy.size.width - 70)
                        let y = min(max(CGFloat(34), value.location.y), proxy.size.height - 34)
                        positions[node.id] = CGPoint(x: x, y: y)
                    })
                }
            }
            .background(.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.2)))
            .coordinateSpace(name: "harnessGraphCanvas")
        }
    }
}

private struct HarnessEditableNode: View {
    let node: HarnessGraphNode
    let selected: Bool

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: node.kind == "harness-runtime" ? "cpu" : "square.stack.3d.up")
            Text(node.title).font(.caption.weight(.semibold)).lineLimit(1)
            Text(node.kind).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 132, height: 62)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(
            selected ? Color.accentColor : OpenCodexPalette.border,
            lineWidth: selected ? 2 : 1
        ))
        .shadow(color: .black.opacity(selected ? 0.12 : 0.06), radius: selected ? 7 : 3, y: 2)
    }
}

private struct HarnessRuntimeSignalPicker: View {
    let title: String
    @Binding var signals: [String]
    let available: [String]
    var customPrefix: String? = nil
    var compact = false
    @State private var customSignal = ""
    @State private var showingCustomSignal = false

    var body: some View {
        HStack(spacing: 6) {
            if !compact { Text(title).font(.caption.weight(.semibold)) }
            Menu {
                ForEach(available, id: \.self) { signal in
                    Button {
                        if signals.contains(signal) { signals.removeAll { $0 == signal } }
                        else { signals.append(signal) }
                    } label: {
                        if signals.contains(signal) { Label(signal, systemImage: "checkmark") }
                        else { Text(signal) }
                    }
                }
                if customPrefix != nil {
                    Divider()
                    Button("Add Driver signal…") { showingCustomSignal = true }
                }
                if !signals.isEmpty {
                    Divider()
                    Button("Clear all") { signals.removeAll() }
                }
            } label: {
                Label(signals.isEmpty ? (compact ? "No live evidence" : "Choose signals") : "\(signals.count) signal\(signals.count == 1 ? "" : "s")", systemImage: "waveform.path.ecg")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            if showingCustomSignal, let customPrefix {
                HStack(spacing: 3) {
                    Text(customPrefix)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    TextField("signal", text: $customSignal)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: compact ? 86 : 120)
                    Button {
                        let suffix = customSignal.trimmingCharacters(in: .whitespacesAndNewlines)
                        let signal = "\(customPrefix)\(suffix)"
                        if !suffix.isEmpty, !signals.contains(signal) { signals.append(signal) }
                        customSignal = ""
                        showingCustomSignal = false
                    } label: { Image(systemName: "plus.circle.fill") }
                        .buttonStyle(.borderless)
                        .disabled(customSignal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if !compact {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(signals, id: \.self) { signal in
                            Text(signal)
                                .font(.system(size: 9.5, design: .monospaced))
                                .padding(.horizontal, 6).frame(height: 20)
                                .background(Color.blue.opacity(0.10), in: Capsule())
                        }
                    }
                }
            }
        }
    }
}

private struct HarnessPortsEditor: View {
    @Binding var node: HarnessGraphNode
    @Binding var edges: [HarnessGraphEdge]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Typed ports").font(.caption.weight(.semibold))
                Spacer()
                Button("Add input") { add(direction: "input") }.controlSize(.small)
                Button("Add output") { add(direction: "output") }.controlSize(.small)
            }
            ForEach(Array((node.ports ?? []).enumerated()), id: \.offset) { index, port in
                HStack(spacing: 6) {
                    Picker("Direction", selection: Binding(
                        get: { port.direction },
                        set: { update(index, id: port.id, name: port.name, direction: $0, dataType: port.dataType, required: port.required) }
                    )) {
                        Text("Input").tag("input")
                        Text("Output").tag("output")
                    }
                    .labelsHidden().frame(width: 80)
                    TextField("Port id", text: Binding(
                        get: { port.id },
                        set: { update(index, id: $0, name: port.name, direction: port.direction, dataType: port.dataType, required: port.required) }
                    )).textFieldStyle(.roundedBorder)
                    TextField("Label", text: Binding(
                        get: { port.name },
                        set: { update(index, id: port.id, name: $0, direction: port.direction, dataType: port.dataType, required: port.required) }
                    )).textFieldStyle(.roundedBorder)
                    TextField("Data type", text: Binding(
                        get: { port.dataType },
                        set: { update(index, id: port.id, name: port.name, direction: port.direction, dataType: $0, required: port.required) }
                    )).textFieldStyle(.roundedBorder)
                    Toggle("Required", isOn: Binding(
                        get: { port.required ?? false },
                        set: { update(index, id: port.id, name: port.name, direction: port.direction, dataType: port.dataType, required: $0) }
                    )).toggleStyle(.checkbox)
                    Button(role: .destructive) { remove(index) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            if (node.ports ?? []).isEmpty {
                Text("Optional. Ports make connection compatibility executable instead of decorative.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func add(direction: String) {
        var ports = node.ports ?? []
        let base = direction == "input" ? "input" : "output"
        var id = base
        var suffix = 2
        while ports.contains(where: { $0.id == id }) { id = "\(base)-\(suffix)"; suffix += 1 }
        ports.append(HarnessGraphPort(id: id, name: direction == "input" ? "Input" : "Output", direction: direction, dataType: "message"))
        replace(ports)
    }

    private func update(_ index: Int, id: String, name: String, direction: String, dataType: String, required: Bool?) {
        var ports = node.ports ?? []
        guard ports.indices.contains(index) else { return }
        let old = ports[index]
        ports[index] = HarnessGraphPort(id: id, name: name, direction: direction, dataType: dataType, required: required)
        edges = edges.compactMap { edge in
            if old.direction == "output", edge.from == node.id, edge.fromPort == old.id {
                guard direction == "output" else { return nil }
                return HarnessGraphEdge(from: edge.from, to: edge.to, fromPort: id, toPort: edge.toPort, label: edge.label, observes: edge.observes)
            }
            if old.direction == "input", edge.to == node.id, edge.toPort == old.id {
                guard direction == "input" else { return nil }
                return HarnessGraphEdge(from: edge.from, to: edge.to, fromPort: edge.fromPort, toPort: id, label: edge.label, observes: edge.observes)
            }
            return edge
        }
        replace(ports)
    }

    private func remove(_ index: Int) {
        var ports = node.ports ?? []
        guard ports.indices.contains(index) else { return }
        let removed = ports[index]
        ports.remove(at: index)
        edges.removeAll { edge in
            (removed.direction == "output" && edge.from == node.id && edge.fromPort == removed.id)
                || (removed.direction == "input" && edge.to == node.id && edge.toPort == removed.id)
        }
        replace(ports)
    }

    private func replace(_ ports: [HarnessGraphPort]) {
        node = HarnessGraphNode(
            id: node.id, kind: node.kind, title: node.title, editable: node.editable,
            responsibility: node.responsibility, inputs: node.inputs, outputs: node.outputs,
            ports: ports.isEmpty ? nil : ports, evidence: node.evidence, observes: node.observes,
            configSchema: node.configSchema, config: node.config
        )
    }
}

private struct PermissionPicker: View {
    @ObservedObject var store: OpenCodexStore
    @State private var fullAccessOption: PermissionOption?

    var body: some View {
        Menu {
            if let permissions = store.currentPermissions {
                ForEach(permissions.options.filter { $0.value != "custom" }) { option in
                    Button {
                        if option.value == "danger-full-access" {
                            fullAccessOption = option
                        } else {
                            Task { await store.choosePermission(option) }
                        }
                    } label: {
                        if option.value == permissions.currentValue {
                            Label(option.name, systemImage: "checkmark")
                        } else {
                            Text(option.name)
                        }
                    }
                }
            } else {
                Text("This Harness does not expose an access mode")
            }
        } label: {
            HStack(spacing: 5) {
                if store.isChangingPermission {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "shield")
                        .font(.system(size: 10))
                }
                Text(store.currentPermissionName)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .frame(maxWidth: 94, alignment: .leading)
            .background(OpenCodexPalette.hover, in: RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton)
        .disabled(store.currentPermissions == nil || store.isChangingPermission)
        .accessibilityIdentifier("OpenFish.AccessMode")
        .alert(
            "Enable Full Access?",
            isPresented: Binding(
                get: { fullAccessOption != nil },
                set: { if !$0 { fullAccessOption = nil } }
            ),
            presenting: fullAccessOption
        ) { option in
            Button("Cancel", role: .cancel) { fullAccessOption = nil }
            Button("Enable Full Access", role: .destructive) {
                fullAccessOption = nil
                Task { await store.choosePermission(option) }
            }
        } message: { option in
            Text(option.description ?? "OpenFish will be able to run commands and change files outside the workspace sandbox.")
        }
    }
}

private struct WorkspacePicker: View {
    @ObservedObject var store: OpenCodexStore

    var body: some View {
        Menu {
            Button("No Project") { store.changeNewTaskWorkspace(to: nil) }
            if !store.workspaces.isEmpty { Divider() }
            ForEach(store.workspaces) { workspace in
                Button {
                    store.changeNewTaskWorkspace(to: workspace.workspaceId)
                } label: {
                    if store.selectedWorkspaceId == workspace.workspaceId {
                        Label(workspace.title, systemImage: "checkmark")
                    } else {
                        Text(workspace.title)
                    }
                }
            }
            Divider()
            Button("Add project…") { Task { await store.addWorkspace() } }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                Text(store.currentWorkspace?.title ?? selectedWorkspaceTitle(store))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .frame(maxWidth: 130, alignment: .leading)
            .background(OpenCodexPalette.hover, in: RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton)
        .disabled(store.selectedSessionId != nil)
        .accessibilityIdentifier("OpenFish.WorkspacePicker")
        .accessibilityValue(store.currentWorkspace?.title ?? selectedWorkspaceTitle(store))
    }
}

private struct ModelPicker: View {
    @ObservedObject var store: OpenCodexStore

    var body: some View {
        Button { store.isModelBrowserPresented = true } label: {
            HStack(spacing: 5) {
                if store.isChangingModel || (store.isLoadingSessionModels && store.sessionModels == nil) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(store.isChangingModel ? "Switching model…" : "Loading models…")
                        .lineLimit(1)
                } else {
                    Text(store.currentModelName)
                        .lineLimit(1)
                    Image(systemName: store.sessionModelsError == nil ? "chevron.down" : "exclamationmark.triangle")
                        .font(.system(size: 7, weight: .bold))
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .frame(maxWidth: 200, alignment: .leading)
            .background(OpenCodexPalette.hover, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(store.isChangingModel || store.isChangingHarnessConfig)
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .accessibilityIdentifier("OpenFish.ModelPicker")
        .help(store.sessionModelsError == nil ? "Choose a model" : "Model choices could not be loaded. Open to retry.")
    }
}

private struct ModelSelectionChoice: Identifiable {
    let groupID: String
    let providerID: String
    let providerName: String
    let model: CatalogModel
    var id: String { "\(groupID):\(model.id)" }
}

private struct ModelSelectionSheet: View {
    @ObservedObject var store: OpenCodexStore
    let onDismiss: () -> Void
    @State private var query = ""
    @State private var providerID = "all"

    private var choices: [ModelSelectionChoice] {
        (store.sessionModels?.groups ?? []).flatMap { group in
            group.models.map { model in
                let rawProvider = group.id == "harness" ? (model.providerId ?? "harness-undisclosed") : group.id
                let providerName = group.id == "harness"
                    ? (model.providerName ?? "Provider not declared")
                    : group.name
                return ModelSelectionChoice(groupID: group.id, providerID: rawProvider, providerName: providerName, model: model)
            }
        }
    }

    private var providers: [(id: String, name: String)] {
        // A provider normally owns many models, so duplicate provider ids are
        // expected. Dictionary(uniqueKeysWithValues:) traps on that ordinary
        // catalog shape and used to crash as soon as this sheet opened.
        choices.reduce(into: [String: String]()) { providers, choice in
            if providers[choice.providerID] == nil {
                providers[choice.providerID] = choice.providerName
            }
        }
            .map { (id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var filtered: [ModelSelectionChoice] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return choices.filter { choice in
            (providerID == "all" || choice.providerID == providerID)
                && (needle.isEmpty
                    || choice.model.name.localizedCaseInsensitiveContains(needle)
                    || choice.model.id.localizedCaseInsensitiveContains(needle)
                    || choice.providerName.localizedCaseInsensitiveContains(needle))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Choose a model").font(.title2.weight(.semibold))
                    Text("Advertised by \(store.currentHarness.map { harnessDisplayName($0, among: store.harnesses) } ?? "the active Harness")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("OpenFish.ModelBrowser.Done")
            }
            .padding(18)

            TextField("Search by model or provider", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("OpenFish.ModelBrowser.Search")
                .padding(.horizontal, 18)
                .padding(.bottom, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    providerChip(id: "all", name: "All")
                    ForEach(providers, id: \.id) { provider in
                        providerChip(id: provider.id, name: provider.name)
                    }
                }
                .padding(.horizontal, 18)
            }
            .padding(.bottom, 12)

            Divider()

            if store.isLoadingSessionModels, choices.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading model choices…")
                        .font(.headline)
                    Text("Waiting for the active Harness to advertise its model catalog.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.sessionModelsError, choices.isEmpty {
                ContentUnavailableView {
                    Label("Models unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await store.retryCurrentModels() } }
                    Button("Open Settings") { store.isSettingsPresented = true; onDismiss() }
                }
            } else if choices.isEmpty {
                ContentUnavailableView {
                    Label("No models advertised", systemImage: "shippingbox")
                } description: {
                    Text("This Harness has not provided model choices for the current task yet.")
                } actions: {
                    Button("Refresh") { Task { await store.retryCurrentModels() } }
                    Button("Open Settings") { store.isSettingsPresented = true; onDismiss() }
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { choice in
                            modelRow(choice)
                            Divider().padding(.leading, 48)
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(store.currentHarness?.modelConfiguration?.owner == "harness"
                    ? "This catalog comes from the Harness. Provider identity is shown only when the live Harness declares it; listed models can still require credentials configured inside that Harness."
                    : "This catalog comes from the connected Host and reflects its current model routes.")
                if let account = store.sessionModels?.account {
                    Text("Account · \(account.label) · \(account.billing.replacingOccurrences(of: "-", with: " ").capitalized)")
                        .fontWeight(.medium)
                    Text(account.detail)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .frame(width: 720, height: 560)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("OpenFish.ModelBrowser")
    }

    private func providerChip(id: String, name: String) -> some View {
        Button { providerID = id } label: {
            Text(name)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(providerID == id ? Color.accentColor.opacity(0.16) : OpenCodexPalette.hover, in: Capsule())
                .foregroundStyle(providerID == id ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private func modelRow(_ choice: ModelSelectionChoice) -> some View {
        let selected = store.sessionModels?.current.provider == choice.groupID
            && store.sessionModels?.current.model == choice.model.id
        return Button {
            Task {
                let selected = await store.chooseModel(
                    provider: choice.groupID,
                    model: choice.model,
                    effort: choice.model.reasoning?.defaultEffort
                )
                if selected { onDismiss() }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.45))
                    .font(.system(size: 16))
                VStack(alignment: .leading, spacing: 3) {
                    Text(choice.model.name).font(.body.weight(selected ? .semibold : .regular))
                    Text("\(choice.providerName) · \(choice.model.id)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .frame(minHeight: 52)
        }
        .buttonStyle(.plain)
        .disabled(store.isChangingModel || store.isChangingHarnessConfig)
        .accessibilityIdentifier("OpenFish.ModelBrowser.Model.\(choice.groupID).\(choice.model.id)")
    }
}

private struct ReasoningPicker: View {
    @ObservedObject var store: OpenCodexStore

    var body: some View {
        Menu {
            if store.currentReasoningOptions.isEmpty {
                if store.isLoadingSessionModels {
                    Text("Discovering reasoning controls…")
                } else {
                    Text("This Harness and model did not advertise a reasoning control.")
                    Divider()
                    Button("Refresh capabilities") { Task { await store.retryCurrentModels() } }
                }
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
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 10))
                Text(store.currentReasoningLabel)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .frame(maxWidth: 140, alignment: .leading)
            .background(OpenCodexPalette.hover, in: RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton)
        .disabled(store.isChangingModel || store.isChangingHarnessConfig)
        .accessibilityIdentifier("OpenFish.ReasoningPicker")
        .help("Choose the reasoning level advertised by this Harness")
    }
}

private struct HarnessConfigPicker: View {
    @ObservedObject var store: OpenCodexStore

    private var options: [HarnessConfigOption] {
        (store.sessionModels?.harnessOptions ?? []).filter {
            $0.category != "model" && $0.category != "thought_level"
        }
    }

    var body: some View {
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
            HStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10))
                Text("Harness")
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(OpenCodexPalette.hover, in: RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton)
        .disabled(store.isChangingHarnessConfig || store.isChangingModel)
        .fixedSize()
        .accessibilityIdentifier("OpenFish.HarnessConfigPicker")
        .help("Configure options advertised by this Harness")
    }
}

private struct HarnessAccountBadge: View {
    @ObservedObject var store: OpenCodexStore
    var compact = false

    private var harness: HarnessCatalogEntry? { store.currentHarness }
    private var selectedMethod: String? { harness?.auth.selectedMethod }
    private var method: HarnessCatalogEntry.Authentication.Method? { harness?.auth.methods.first(where: { $0.id == selectedMethod }) }
    private var runtimeAccount: HarnessCatalogEntry.AccountDescriptor? { store.sessionModels?.account }
    private var title: String {
        runtimeAccount?.label ?? method?.account?.label ?? method?.name ?? harness?.account?.label
            ?? (harness?.auth.status == "not-required"
                ? "Billing not declared"
                : harness?.auth.status == "unknown" ? "Account discovered after install" : "Sign-in required")
    }
    private var detail: String {
        if let runtimeAccount { return runtimeAccount.detail }
        if let account = method?.account { return account.detail }
        if let account = harness?.account { return account.detail }
        if let method { return "\(harness?.name ?? "This Harness") is using the \(method.name) authentication method owned by its installed runtime. Billing was not declared by this Harness Pack." }
        return harness?.auth.detail
            ?? "Open Harness settings to choose and verify how this Harness authenticates and who pays for model usage."
    }

    var body: some View {
        Menu {
            Text(detail)
            Divider()
            Button("Open Harness Settings") { store.isSettingsPresented = true }
        } label: {
            let billing = runtimeAccount?.billing ?? method?.account?.billing ?? harness?.account?.billing
            HStack(spacing: 5) {
                Image(systemName: billing == "subscription" ? "person.crop.circle.badge.checkmark" : billing == "local" ? "desktopcomputer" : "key")
                    .font(.system(size: 10.5, weight: .medium))
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .frame(maxWidth: compact ? 148 : 196)
                .background(OpenCodexPalette.hover, in: RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: !compact, vertical: true)
        .help(detail)
        .accessibilityIdentifier("OpenFish.HarnessAccount")
    }
}

// MARK: - Voice

private struct VoiceConversationView: View {
    @ObservedObject var store: OpenCodexStore
    @ObservedObject private var voice: LocalVoiceService
    @Environment(\.dismiss) private var dismiss

    init(store: OpenCodexStore) {
        self.store = store
        voice = store.voice
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice with OpenFish")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Apple on-device mode · final text only")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    store.stopVoiceConversation()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("End voice conversation")
            }
            .padding(20)

            Spacer()

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: 210, height: 210)
                Circle()
                    .fill(Color.accentColor.opacity(voice.isListening || voice.isSpeaking ? 0.18 : 0.08))
                    .frame(width: voice.isListening || voice.isSpeaking ? 164 : 146, height: voice.isListening || voice.isSpeaking ? 164 : 146)
                    .animation(.easeInOut(duration: 0.7), value: voice.isListening || voice.isSpeaking)
                Image(systemName: voice.isSpeaking ? "speaker.wave.3.fill" : voice.isListening ? "waveform" : "sparkles")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.variableColor.iterative, isActive: voice.isListening || voice.isSpeaking)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(store.voiceConversationStatus)

            Text(store.voiceConversationStatus)
                .font(.system(size: 19, weight: .semibold))
                .padding(.top, 22)

            Text(store.voiceConversationTranscript.isEmpty
                ? "Speak naturally. Final transcripts are sent to the current Harness task exactly like typed prompts."
                : store.voiceConversationTranscript)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .frame(maxWidth: 350, minHeight: 62, alignment: .top)
                .padding(.top, 8)

            Spacer()

            HStack(spacing: 12) {
                Button {
                    Task { await store.interruptVoiceConversation() }
                } label: {
                    Label(voice.isSpeaking ? "Interrupt" : "Listen", systemImage: "mic.fill")
                        .frame(minWidth: 112)
                }
                .buttonStyle(.borderedProminent)

                Button("End") {
                    store.stopVoiceConversation()
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .padding(.bottom, 26)
        }
        .background(OpenCodexPalette.canvas)
        .onDisappear { store.stopVoiceConversation() }
    }
}

// MARK: - Settings

private struct OpenCodexSettingsView: View {
    @ObservedObject var store: OpenCodexStore
    @State private var selection = "general"

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("General", systemImage: "gearshape").tag("general")
                Label("Harnesses", systemImage: "shippingbox").tag("harnesses")
                Label("Models", systemImage: "cpu").tag("models")
                Label("Voice", systemImage: "waveform").tag("voice")
                Label("Plugins", systemImage: "puzzlepiece.extension").tag("plugins")
                Label("Remote", systemImage: "iphone.and.arrow.forward").tag("remote")
                Label("Data", systemImage: "externaldrive.badge.timemachine").tag("data")
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            Group {
                switch selection {
                case "harnesses": HarnessSettingsView(store: store)
                case "models": ModelsSettingsView(store: store)
                case "voice": VoiceSettingsView(store: store)
                case "plugins": PluginsSettingsView(store: store)
                case "remote": RemoteSettingsView(store: store)
                case "data": DataSettingsView(store: store)
                default: GeneralSettingsView(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { store.isSettingsPresented = false }
            }
        }
        .task { await store.loadSettings() }
    }
}

private struct HarnessOnboardingView: View {
    @ObservedObject var store: OpenCodexStore
    @State private var authSelection: HarnessAuthSelection?
    @State private var query = ""
    @State private var pendingCommunityHarness: HarnessCatalogEntry?
    @State private var pendingCommunityAuthSelection: HarnessAuthSelection?
    @State private var selectedHarnessId: String?
    @State private var lens = "Simple"
    @State private var showingCreateEditor = false

    init(store: OpenCodexStore, initialLens: String = "Simple") {
        self.store = store
        _lens = State(initialValue: initialLens)
    }

    private var filtered: [HarnessCatalogEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rows = needle.isEmpty ? store.harnesses : store.harnesses.filter {
            $0.id.lowercased().contains(needle) || $0.name.lowercased().contains(needle)
                || ($0.description?.lowercased().contains(needle) ?? false)
        }
        return rows.sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            if $0.verified != $1.verified { return $0.verified }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var selectedHarness: HarnessCatalogEntry? {
        if let selectedHarnessId, let selected = store.harnesses.first(where: { $0.id == selectedHarnessId }) {
            return selected
        }
        return filtered.first
    }

    private var pendingConsentHarness: HarnessCatalogEntry? {
        pendingCommunityAuthSelection?.harness ?? pendingCommunityHarness
    }

    private var harnessColumns: [GridItem] {
        if filtered.count <= 3 {
            return Array(repeating: GridItem(.flexible(minimum: 220), spacing: 11, alignment: .top), count: max(1, filtered.count))
        }
        return [GridItem(.adaptive(minimum: 220), spacing: 11, alignment: .top)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("OpenFish setup", systemImage: "shippingbox.and.arrow.backward")
                        .font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                    Text("Choose how OpenFish works").font(.system(size: 27, weight: .semibold))
                    Text("Pick the execution system that owns models, tools, guardrails, and resumable sessions. You can change the default later; existing tasks keep their original Harness.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                TextField("Find a Harness", text: $query).textFieldStyle(.roundedBorder).frame(width: 220)
            }

            if store.isLoadingHarnessCatalog && store.harnesses.isEmpty {
                ProgressView("Loading available Harnesses…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                VStack(spacing: 14) {
                    ContentUnavailableView(
                        store.harnesses.isEmpty ? "Harness catalog could not be loaded" : "No matching Harness",
                        systemImage: store.harnesses.isEmpty ? "exclamationmark.triangle" : "magnifyingglass",
                        description: Text(store.harnessCatalogError ?? "Try another name, import a Pack, or create one locally.")
                    )
                    HStack {
                        if store.harnesses.isEmpty {
                            Button("Retry catalog") { Task { await store.loadHarnessCatalogForOnboarding() } }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("Clear search") { query = "" }
                        }
                        Button("Import Pack") { chooseHarnessPackImport(store: store) }
                        Button("Create Pack") { showingCreateEditor = true }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        LazyVGrid(columns: harnessColumns, spacing: 11) {
                            ForEach(filtered) { harness in
                                HarnessChoiceCard(
                                    harness: harness,
                                    displayName: harnessDisplayName(harness, among: store.harnesses),
                                    selected: selectedHarness?.id == harness.id,
                                    action: { selectedHarnessId = harness.id }
                                )
                            }
                        }
                        if let harness = selectedHarness {
                            HarnessProgressiveLensPanel(
                                store: store,
                                harness: harness,
                                lens: $lens,
                                showingCreateEditor: $showingCreateEditor
                            )
                            if harness.modelConfiguration?.owner == "host"
                                && harness.modelConfiguration?.required == true
                                && store.hostModels.groups.isEmpty {
                                DshProviderQuickSetup(store: store)
                            }
                        }
                    }
                    .padding(1)
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if store.harnessOperationId != nil {
                    HarnessOperationStatus(store: store)
                }
                HStack {
                    Label("Credentials stay in the Mac Host credential service.", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let harness = selectedHarness { primaryControl(for: harness) }
                }
            }
        }
        .padding(26)
        .sheet(item: $authSelection) { selection in HarnessCredentialsSheet(store: store, selection: selection) }
        .sheet(isPresented: $showingCreateEditor) {
            HarnessPackEditor(store: store, isPresented: $showingCreateEditor)
        }
        .alert(harnessExecutionConsentTitle(pendingConsentHarness), isPresented: Binding(
            get: { pendingCommunityHarness != nil || pendingCommunityAuthSelection != nil },
            set: {
                if !$0 {
                    pendingCommunityHarness = nil
                    pendingCommunityAuthSelection = nil
                }
            }
        )) {
            Button("Cancel", role: .cancel) {
                pendingCommunityHarness = nil
                pendingCommunityAuthSelection = nil
            }
            Button("Install and use") {
                if var selection = pendingCommunityAuthSelection {
                    pendingCommunityAuthSelection = nil
                    selection.acceptUnverified = true
                    selection.acceptDriverBundle = true
                    authSelection = selection
                } else if let harness = pendingCommunityHarness {
                    pendingCommunityHarness = nil
                    Task {
                        await store.selectDefaultHarness(
                            harness, completesOnboarding: true,
                            acceptUnverified: true, acceptDriverBundle: true
                        )
                    }
                }
            }
        } message: {
            Text(harnessExecutionConsentMessage(pendingConsentHarness))
        }
        .task {
            async let settings: Void = store.loadSettings()
            async let catalog: Void = store.loadHarnessCatalogForOnboarding()
            _ = await (settings, catalog)
            if selectedHarnessId == nil { selectedHarnessId = filtered.first?.id }
        }
    }

    @ViewBuilder
    private func primaryControl(for harness: HarnessCatalogEntry) -> some View {
        let needsHostModels = harness.modelConfiguration?.owner == "host"
            && harness.modelConfiguration?.required == true
            && store.hostModels.groups.isEmpty
        let ready = harnessCanPrepare(harness) && !needsHostModels
        if harness.auth.status == "unknown" {
            Button(harness.installation.status == "installed" ? "Inspect sign-in setup again" : "Install and inspect setup") {
                requestDefault(harness)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.harnessOperationId != nil || !ready)
        } else if harness.auth.status != "not-required" && harness.auth.status != "configured" {
            Menu("Choose sign-in for \(harness.name)") {
                ForEach(harness.auth.methods) { method in
                    Button(method.name) { configure(harness, method: method) }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.harnessOperationId != nil)
        } else {
            Button(harness.installation.status == "builtin" || harness.installation.status == "installed" ? "Use \(harness.name)" : "Install and use \(harness.name)") {
                requestDefault(harness)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.harnessOperationId != nil || !ready)
        }
    }

    private func configure(_ harness: HarnessCatalogEntry, method: HarnessCatalogEntry.Authentication.Method) {
        let selection = HarnessAuthSelection(
            harness: harness, method: method, makeDefault: true, completesOnboarding: true
        )
        if harnessNeedsExecutionConsent(harness) {
            pendingCommunityAuthSelection = selection
        } else {
            authSelection = selection
        }
    }

    private func requestDefault(_ harness: HarnessCatalogEntry) {
        if harnessNeedsExecutionConsent(harness) {
            pendingCommunityHarness = harness
        } else {
            Task { await store.selectDefaultHarness(harness, completesOnboarding: true) }
        }
    }
}

/// Deterministic production-layout entry used by the release visual smoke.
struct HarnessOnboardingPreview: View {
    @ObservedObject var store: OpenCodexStore
    let initialLens: String

    init(store: OpenCodexStore, initialLens: String = "Simple") {
        self.store = store
        self.initialLens = initialLens
    }

    var body: some View {
        HarnessOnboardingView(store: store, initialLens: initialLens)
            .background(OpenCodexPalette.canvas)
    }
}

private struct HarnessChoiceCard: View {
    let harness: HarnessCatalogEntry
    let displayName: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(displayName).font(.system(size: 15, weight: .semibold))
                Spacer()
                if harness.verified {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.accentColor)
                }
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            Text(harness.description ?? "No description provided.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(3)
            HStack {
                Label(harness.protocolName.uppercased(), systemImage: "point.3.connected.trianglepath.dotted")
                Spacer()
                Text("v\(harness.version)")
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Label(
                    harness.installation.status == "builtin" || harness.installation.status == "installed" ? "Installed" : "Will install",
                    systemImage: "shippingbox"
                )
                Spacer()
                Text(harness.auth.status == "configured" || harness.auth.status == "not-required"
                    ? harness.compatibility.classification.replacingOccurrences(of: "-", with: " ").capitalized
                    : harness.auth.status == "unknown" ? "Setup discovered after install" : "Sign-in needed")
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 142, alignment: .leading)
        .background(OpenCodexPalette.elevated, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.accentColor : OpenCodexPalette.border, lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }
}

private struct HarnessProgressiveLensPanel: View {
    @ObservedObject var store: OpenCodexStore
    let harness: HarnessCatalogEntry
    @Binding var lens: String
    @Binding var showingCreateEditor: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Picker("Harness lens", selection: $lens) {
                Text("Simple").tag("Simple")
                Text("How it works").tag("Architecture")
                Text("Live task").tag("Runtime")
                Text("Manifest").tag("Manifest")
            }
            .pickerStyle(.segmented)
            switch lens {
            case "Simple": simple
            case "Runtime": HarnessRuntimePanel(store: store, harness: harness)
            case "Manifest": manifestEditor
            default: HarnessDetailPanel(harness: harness)
            }
        }
        .padding(12)
        .background(OpenCodexPalette.hover.opacity(0.55), in: RoundedRectangle(cornerRadius: 13))
    }

    private var simple: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 184), spacing: 10)], alignment: .leading, spacing: 10) {
            LensFact(title: "Recommended for", value: recommendedUse, icon: "target")
            LensFact(
                title: "What changes",
                value: "\(harness.description ?? "This Pack does not declare a usage summary.") New tasks can use it; existing tasks remain pinned to their original Harness and version.",
                icon: "arrow.triangle.branch"
            )
            LensFact(title: "Models & sign-in", value: modelAndSignInSummary, icon: "cpu")
            LensFact(title: "Install & updates", value: lifecycleSummary, icon: "shippingbox")
            LensFact(
                title: "Trust & compatibility",
                value: harness.compatibility.classification == "incompatible"
                    ? "Incompatible on this Mac"
                    : "\(harness.compatibility.classification.replacingOccurrences(of: "-", with: " ").capitalized) · \(harness.installation.integrity.status.replacingOccurrences(of: "-", with: " "))",
                icon: "checkmark.shield"
            )
            LensFact(title: "Permission boundary", value: permissionSummary, icon: "hand.raised")
        }
    }

    private var recommendedUse: String {
        if let description = harness.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            return description
        }
        if harness.protocolName.lowercased() == "acp" {
            return "Tasks supported by this Pack's ACP agent, with account, model, workspace, and permission ownership kept visible."
        }
        return "Tasks supported by this Pack's declared Driver and runtime capability contract."
    }

    private var lifecycleSummary: String {
        if harness.installation.status == "builtin" {
            return "Bundled inside this OpenFish build. It updates or rolls back only with the OpenFish app and cannot be removed separately."
        }
        if harness.installation.status == "installed" {
            let active = harness.installation.installedVersion ?? harness.version
            var parts = ["Installed exact version \(active)"]
            let available = harness.installation.availableVersion
            if available != active {
                parts.append("\(available) is available")
            }
            if !harness.installation.previousVersions.isEmpty {
                parts.append("\(harness.installation.previousVersions.count) rollback snapshot\(harness.installation.previousVersions.count == 1 ? "" : "s") retained")
            }
            return parts.joined(separator: " · ")
        }
        return "OpenFish will install exact version \(harness.installation.availableVersion) into its private runtime after you confirm."
    }

    private var permissionSummary: String {
        let tools = harness.capabilities.first(where: { $0.id == "interaction.tools" })?.status
        let approvals = harness.capabilities.first(where: { $0.id == "interaction.approvals" })?.status
        if tools == "unsupported" { return "This Driver does not advertise tool actions." }
        if approvals == "supported" || approvals == "runtime" {
            return "The Harness owns tool behavior; OpenFish shows its events and pauses advertised sensitive actions for approval under your permission preset."
        }
        return "The Harness owns tool behavior. Its Driver does not advertise an approval flow, so inspect its permissions before starting."
    }

    private var modelAndSignInSummary: String {
        if let selected = harness.auth.selectedMethod {
            return harness.auth.methods.first(where: { $0.id == selected })?.name ?? selected
        }
        if harness.auth.status != "not-required" {
            return harness.auth.detail ?? harness.auth.status.replacingOccurrences(of: "-", with: " ")
        }
        return harness.modelConfiguration?.detail
            ?? harness.account?.label
            ?? "Model and account contract not declared by this Pack"
    }

    private var manifestEditor: some View {
        HStack(spacing: 16) {
            Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 28)).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("Create or import a Harness").font(.headline)
                Text("Manifest Editor changes only Pack-declared composable components, validates exact distributions and credential references, runs a prompt-free live preflight, and submits a credential-free Pack to public review. A provider may still create its own session state or charge a setup cost.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Import Pack") { chooseHarnessPackImport(store: store) }
            Button("Create Pack") { showingCreateEditor = true }.buttonStyle(.borderedProminent)
        }
        .padding(10)
    }
}

private struct HarnessRuntimePanel: View {
    @ObservedObject var store: OpenCodexStore
    let harness: HarnessCatalogEntry

    private var runtime: HarnessRuntimeProjection? {
        guard store.currentHarness?.id == harness.id,
              store.currentHarness?.version == harness.version,
              let runtime = store.currentHarnessRuntime,
              runtime.harnessId == nil || runtime.harnessId == harness.id,
              runtime.version == nil || runtime.version == harness.version else { return nil }
        return runtime
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HarnessArchitectureFlow(graph: harness.graph, runtime: runtime)
                .frame(maxWidth: .infinity, minHeight: 260)
            VStack(alignment: .leading, spacing: 8) {
                Label("Observed in this task", systemImage: "waveform.path.ecg").font(.headline)
                if let runtime, !runtime.nodes.isEmpty {
                    ForEach(runtime.nodes.keys.sorted(), id: \.self) { nodeID in
                        if let activity = runtime.nodes[nodeID] {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(harness.graph.nodes.first(where: { $0.id == nodeID })?.title ?? nodeID)
                                    .font(.caption.weight(.semibold))
                                Text("\(activity.status.capitalized) · \(activity.activity)")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                    }
                    if let edges = runtime.edges, !edges.isEmpty {
                        Divider()
                        Text("Observed flows").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(edges.keys.sorted(), id: \.self) { edgeID in
                            if let activity = edges[edgeID] {
                                Text("\(activity.from) → \(activity.to) · \(activity.status.capitalized)")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                } else {
                    Text("Start a task with this Harness. OpenFish will light up only the declared components it actually observes, without capturing prompt or credential content for the graph.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 250, alignment: .topLeading)
        }
    }
}

private struct LensFact: View {
    let title: String
    let value: String
    let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon).font(.caption.weight(.semibold))
            Text(value).font(.caption).foregroundStyle(.secondary).lineLimit(3)
        }
        .padding(11).frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
        .background(OpenCodexPalette.elevated, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(OpenCodexPalette.border))
    }
}

private struct DshProviderQuickSetup: View {
    @ObservedObject var store: OpenCodexStore
    @State private var credentials: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect a model provider").font(.system(size: 12, weight: .semibold))
            ForEach(store.providers.filter { store.credentialRef(for: $0) != nil }.prefix(4)) { provider in
                if let ref = store.credentialRef(for: provider) {
                    HStack {
                        SecureField("\(provider.displayName) · \(ref)", text: Binding(
                            get: { credentials[provider.id] ?? "" }, set: { credentials[provider.id] = $0 }
                        )).textFieldStyle(.roundedBorder)
                        Button("Connect") {
                            let value = credentials.removeValue(forKey: provider.id) ?? ""
                            Task { await store.setCredential(ref: ref, value: value) }
                        }
                        .disabled((credentials[provider.id] ?? "").isEmpty)
                    }
                }
            }
            Text("Credentials are write-only. More providers and local endpoints are available in Settings → Models.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(OpenCodexPalette.hover, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct HarnessOperationStatus: View {
    @ObservedObject var store: OpenCodexStore

    var body: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text(store.harnessOperationPhase ?? "Preparing Harness…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            if store.canCancelHarnessOperation {
                Button("Cancel") { store.cancelHarnessOperation() }
                    .controlSize(.small)
            }
        }
        .padding(9)
        .background(OpenCodexPalette.hover, in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain)
    }
}

private struct HarnessSettingsView: View {
    @ObservedObject var store: OpenCodexStore
    @State private var authSelection: HarnessAuthSelection?
    @State private var query = ""
    @State private var inspectedHarnessId: String?
    @State private var showingCreateEditor = false
    @State private var editingHarness: HarnessCatalogEntry?
    @State private var publishingHarness: HarnessCatalogEntry?
    @State private var revokingHarness: HarnessCatalogEntry?
    @State private var pendingCommunityHarness: HarnessCatalogEntry?
    @State private var pendingCommunityAction = "default"
    @State private var pendingCommunityAuthSelection: HarnessAuthSelection?
    @State private var pendingDestructiveAction: HarnessDestructiveAction?
    @State private var lens = "Simple"

    private var filtered: [HarnessCatalogEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return store.harnesses }
        return store.harnesses.filter { $0.id.lowercased().contains(needle) || $0.name.lowercased().contains(needle) }
    }

    private var pendingConsentHarness: HarnessCatalogEntry? {
        pendingCommunityAuthSelection?.harness ?? pendingCommunityHarness
    }

    var body: some View {
        SettingsPage(
            title: "Harnesses",
            subtitle: "Choose the Harness Open Fish uses for new tasks. Existing tasks keep the Harness they started with."
        ) {
            HStack {
                TextField("Find a Harness", text: $query).textFieldStyle(.roundedBorder)
                Button("Import Pack") { chooseHarnessPackImport(store: store) }
                Button("Create Pack") { showingCreateEditor = true }
                    .buttonStyle(.borderedProminent)
            }
            if store.harnessOperationId != nil {
                HarnessOperationStatus(store: store)
            }
            VStack(spacing: 10) {
                ForEach(filtered) { harness in
                    HStack(spacing: 12) {
                        Image(systemName: harness.isDefault ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(harness.isDefault ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(harnessDisplayName(harness, among: store.harnesses)).font(.system(size: 13, weight: .semibold))
                            Text(harness.description ?? "No description provided.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                            Text("Registry: \(harness.verified ? "verified" : "community") · OpenFish: \(harness.compatibility.classification.replacingOccurrences(of: "-", with: " "))")
                                .font(.system(size: 10.5)).foregroundStyle(harness.compatibility.classification == "incompatible" ? Color.red : Color.secondary)
                            Text("Install trust: \(harness.installation.integrity.status.replacingOccurrences(of: "-", with: " "))")
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                                .help(harness.installation.integrity.detail)
                            if let publication = harness.publication {
                                Text("Community: \(publication.status.replacingOccurrences(of: "-", with: " ")) · \(publication.review.replacingOccurrences(of: "-", with: " "))")
                                    .font(.system(size: 10.5, weight: publication.status == "revoked" ? .semibold : .regular))
                                    .foregroundStyle(publication.status == "revoked" ? Color.red : publication.status == "revocation-requested" ? Color.orange : Color.secondary)
                                    .help(publication.detail)
                                if let reviewURL = publication.reviewUrl, let url = URL(string: reviewURL) {
                                    Button("Open community review") { NSWorkspace.shared.open(url) }
                                        .buttonStyle(.link)
                                        .font(.system(size: 10.5))
                                }
                                if let reason = publication.revokedReason {
                                    Text(reason).font(.system(size: 10.5)).foregroundStyle(.red).lineLimit(2)
                                }
                            }
                            if let methodID = harness.auth.selectedMethod,
                               let method = harness.auth.methods.first(where: { $0.id == methodID }) {
                                Text("Account: \(method.account?.label ?? method.name)\(method.account == nil ? " · billing not declared" : "")")
                                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            } else if let account = harness.account {
                                Text("Account: \(account.label)")
                                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            } else {
                                Text("Account and billing not declared by this Pack")
                                    .font(.system(size: 10.5)).foregroundStyle(.orange)
                            }
                            if let message = harness.compatibility.message, harness.compatibility.status == "failed" {
                                Text(message).font(.system(size: 10.5)).foregroundStyle(.red).lineLimit(2)
                            }
                        }
                        Spacer()
                        Button("Details") { inspectedHarnessId = harness.id }
                            .buttonStyle(.borderless)
                        if harness.source == "user" {
                            Menu("Manifest") {
                                Button("Edit Pack") { editingHarness = harness }
                                Button("Export Pack") { exportHarnessPack(store: store, harness: harness, publication: false) }
                                Button("Export review bundle") { exportHarnessPack(store: store, harness: harness, publication: true) }
                                if let reviewURL = harness.publication?.reviewUrl, let url = URL(string: reviewURL) {
                                    Button("Open community review") { NSWorkspace.shared.open(url) }
                                } else {
                                    Button("Submit for community review…") { publishingHarness = harness }
                                }
                            }
                        }
                        VStack(alignment: .trailing, spacing: 5) {
                            if !harness.auth.methods.isEmpty {
                                Menu(settingsAccountTitle(harness)) {
                                    ForEach(harness.auth.methods) { method in
                                        Button {
                                            requestAuthentication(HarnessAuthSelection(
                                                harness: harness, method: method, makeDefault: false, completesOnboarding: false
                                            ))
                                        } label: {
                                            if harness.auth.selectedMethod == method.id {
                                                Label(method.name, systemImage: "checkmark")
                                            } else {
                                                Text(method.name)
                                            }
                                        }
                                    }
                                }
                            }
                            Button(harness.isDefault ? "Default" : (harness.installation.status == "installed" || harness.installation.status == "builtin" ? "Make Default" : "Install & Use")) {
                                requestDefault(harness)
                            }
                            .disabled(
                                harness.isDefault || store.harnessOperationId != nil
                                    || !harnessCanPrepare(harness)
                                    || harness.publication?.status == "revoked"
                                    || (harness.auth.status != "not-required" && harness.auth.status != "configured")
                            )
                            HStack(spacing: 7) {
                                if harness.compatibility.status == "failed" {
                                    Button("Retry") { requestMutation("install", harness: harness) }
                                }
                                Button("Run preflight") { requestMutation("probe", harness: harness) }
                                if harness.installation.status != "builtin" {
                                    Menu("Manage") {
                                        if harness.installation.status == "installed" {
                                            if harness.installation.installedVersion != harness.installation.availableVersion {
                                                Button("Update to \(harness.installation.availableVersion)") {
                                                    requestMutation("update", harness: harness)
                                                }
                                            }
                                            if !harness.installation.previousVersions.isEmpty {
                                                Button("Roll back") { requestMutation("rollback", harness: harness) }
                                            }
                                            Button("Uninstall", role: .destructive) {
                                                pendingDestructiveAction = HarnessDestructiveAction(operation: "uninstall", harness: harness)
                                            }
                                        } else {
                                            Button("Install exact version \(harness.installation.availableVersion)") {
                                                requestMutation("install", harness: harness)
                                            }
                                        }
                                        if harness.source == "user" {
                                            Divider()
                                            Button("Remove Pack", role: .destructive) {
                                                pendingDestructiveAction = HarnessDestructiveAction(operation: "remove", harness: harness)
                                            }
                                        }
                                        if harness.source == "openfish-community" {
                                            Divider()
                                            Button("Report this Pack…") { reportHarness(harness) }
                                        }
                                        if harness.publication?.status == "published" {
                                            Divider()
                                            Button("Request exact-version revocation…", role: .destructive) {
                                                revokingHarness = harness
                                            }
                                        }
                                    }
                                }
                                if harness.auth.methods.contains(where: { $0.kind == "terminal" }) {
                                    Menu("Sign in again") {
                                        ForEach(harness.auth.methods.filter { $0.kind == "terminal" }) { method in
                                            Button(method.name) {
                                                requestAuthentication(HarnessAuthSelection(
                                                    harness: harness, method: method,
                                                    makeDefault: false, completesOnboarding: false
                                                ))
                                            }
                                        }
                                    }
                                }
                                Button { copyDiagnostics(harness) } label: { Image(systemName: "doc.on.doc") }
                                    .help("Copy redacted diagnostics")
                            }
                            .font(.caption)
                        }
                    }
                    .padding(12)
                    .background(OpenCodexPalette.elevated, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            if let inspected = store.harnesses.first(where: { $0.id == inspectedHarnessId }) {
                HarnessProgressiveLensPanel(
                    store: store,
                    harness: inspected,
                    lens: $lens,
                    showingCreateEditor: $showingCreateEditor
                )
            }
        }
        .sheet(item: $authSelection) { selection in HarnessCredentialsSheet(store: store, selection: selection) }
        .sheet(isPresented: $showingCreateEditor) {
            HarnessPackEditor(store: store, isPresented: $showingCreateEditor)
        }
        .sheet(item: $editingHarness) { harness in
            HarnessPackEditor(
                store: store,
                isPresented: Binding(
                    get: { editingHarness != nil },
                    set: { if !$0 { editingHarness = nil } }
                ),
                existing: harness
            )
        }
        .sheet(item: $publishingHarness) { harness in
            HarnessPublicationSheet(
                store: store,
                harness: harness,
                isPresented: Binding(
                    get: { publishingHarness != nil },
                    set: { if !$0 { publishingHarness = nil } }
                )
            )
        }
        .sheet(item: $revokingHarness) { harness in
            HarnessRevocationSheet(
                store: store,
                harness: harness,
                isPresented: Binding(
                    get: { revokingHarness != nil },
                    set: { if !$0 { revokingHarness = nil } }
                )
            )
        }
        .alert(harnessExecutionConsentTitle(pendingConsentHarness), isPresented: Binding(
            get: { pendingCommunityHarness != nil || pendingCommunityAuthSelection != nil },
            set: { if !$0 { clearPendingCommunityAction() } }
        )) {
            Button("Cancel", role: .cancel) { clearPendingCommunityAction() }
            Button(pendingConsentButtonTitle) {
                if var selection = pendingCommunityAuthSelection {
                    clearPendingCommunityAction()
                    selection.acceptUnverified = true
                    selection.acceptDriverBundle = true
                    authSelection = selection
                } else if let harness = pendingCommunityHarness {
                    let action = pendingCommunityAction
                    clearPendingCommunityAction()
                    if action == "default" {
                        Task {
                            await store.selectDefaultHarness(
                                harness, acceptUnverified: true, acceptDriverBundle: true
                            )
                        }
                    } else {
                        Task {
                            await store.mutateHarness(
                                action, harness: harness,
                                acceptUnverified: true, acceptDriverBundle: true
                            )
                        }
                    }
                }
            }
        } message: {
            Text(harnessExecutionConsentMessage(pendingConsentHarness))
        }
        .confirmationDialog(
            pendingDestructiveAction?.title ?? "Confirm Harness removal",
            isPresented: Binding(
                get: { pendingDestructiveAction != nil },
                set: { if !$0 { pendingDestructiveAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let action = pendingDestructiveAction {
                Button(action.confirmationTitle, role: .destructive) {
                    pendingDestructiveAction = nil
                    Task { await store.mutateHarness(action.operation, harness: action.harness) }
                }
            }
            Button("Cancel", role: .cancel) { pendingDestructiveAction = nil }
        } message: {
            Text(pendingDestructiveAction?.message ?? "")
        }
    }

    private func settingsAccountTitle(_ harness: HarnessCatalogEntry) -> String {
        guard let selected = harness.auth.selectedMethod else { return "Choose account" }
        let method = harness.auth.methods.first(where: { $0.id == selected })
        return "Account · \(method?.account?.label ?? method?.name ?? selected)"
    }

    private var pendingConsentButtonTitle: String {
        if pendingCommunityAuthSelection != nil { return "Continue to account setup" }
        switch pendingCommunityAction {
        case "default": return "Install and make default"
        case "update": return "Install exact update"
        case "probe": return "Install and run preflight"
        default: return "Install exact version"
        }
    }

    private func requestDefault(_ harness: HarnessCatalogEntry) {
        if harnessNeedsExecutionConsent(harness) {
            pendingCommunityHarness = harness
            pendingCommunityAction = "default"
        } else {
            Task { await store.selectDefaultHarness(harness) }
        }
    }

    private func requestAuthentication(_ selection: HarnessAuthSelection) {
        let harness = selection.harness
        if harnessNeedsExecutionConsent(harness) {
            pendingCommunityAuthSelection = selection
        } else {
            authSelection = selection
        }
    }

    private func requestMutation(_ action: String, harness: HarnessCatalogEntry) {
        if action == "rollback" {
            Task {
                guard let candidate = await store.rollbackHarnessCandidate(harness) else { return }
                if candidate.driverBundle != nil || (!candidate.verified && candidate.source != "user") {
                    pendingCommunityHarness = candidate
                    pendingCommunityAction = action
                } else {
                    await store.mutateHarness(action, harness: candidate)
                }
            }
            return
        }
        let introducesUnreviewedUpdate = !harness.verified && harness.source != "user"
            && harness.installation.installedVersion != harness.installation.availableVersion
        if introducesUnreviewedUpdate || harnessNeedsExecutionConsent(harness) {
            pendingCommunityHarness = harness
            pendingCommunityAction = action
        } else {
            Task { await store.mutateHarness(action, harness: harness) }
        }
    }

    private func clearPendingCommunityAction() {
        pendingCommunityHarness = nil
        pendingCommunityAction = "default"
        pendingCommunityAuthSelection = nil
    }

    private func copyDiagnostics(_ harness: HarnessCatalogEntry) {
        func redacted(_ value: String) -> String {
            value
                .replacingOccurrences(of: #"/Users/[^/\s]+"#, with: "$HOME", options: .regularExpression)
                .replacingOccurrences(of: #"\b(?:sk|key|token)-[A-Za-z0-9_-]{12,}\b"#, with: "[REDACTED]", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)((?:api[_-]?key|authorization|token)\s*[:=]\s*)[^\s,;]+"#, with: "$1[REDACTED]", options: .regularExpression)
        }
        let lines: [String?] = [
            "Open Fish Harness diagnostics", "id=\(harness.id)", "version=\(harness.version)",
            "source=\(harness.source)", "protocol=\(harness.protocolName)",
            "driver_api=\(harness.driver.apiVersion)", "driver_loaded=\(harness.driver.loaded)",
            "installation=\(harness.installation.status)", "auth=\(harness.auth.status)",
            "compatibility=\(harness.compatibility.classification)",
            "lastTest=\(harness.compatibility.status)",
            "capabilities=\(harness.capabilities.sorted { $0.id < $1.id }.map { "\($0.id):\($0.status):\($0.source)" }.joined(separator: ","))",
            harness.unavailableReason.map { "unavailable=\(redacted($0))" },
            harness.installation.error.map { "install_error=\(redacted($0))" },
            harness.compatibility.message.map { "compatibility_message=\(redacted($0))" },
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.compactMap { $0 }.joined(separator: "\n"), forType: .string)
    }

    private func reportHarness(_ harness: HarnessCatalogEntry) {
        var components = URLComponents(string: "https://github.com/Yusong-Enceladus/OpenFish/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: "Harness report: \(harness.id) \(harness.version)"),
            URLQueryItem(
                name: "body",
                value: "Harness id: `\(harness.id)`\nVersion: `\(harness.version)`\n\nDescribe the compatibility, provenance, or safety concern without including credentials, private paths, or conversation content."
            ),
            URLQueryItem(name: "labels", value: "area/harness"),
        ]
        if let url = components?.url { NSWorkspace.shared.open(url) }
    }
}

private struct HarnessPublicationSheet: View {
    @ObservedObject var store: OpenCodexStore
    let harness: HarnessCatalogEntry
    @Binding var isPresented: Bool
    @State private var token = ""
    @State private var submitting = false

    private var current: HarnessCatalogEntry {
        store.harnesses.first(where: { $0.id == harness.id }) ?? harness
    }

    private var ready: Bool {
        current.source == "user"
            && current.driver.loaded
            && current.installation.status == "installed"
            && current.installation.installedVersion == current.version
            && ["ready", "compatible"].contains(current.compatibility.status)
            && current.distribution?.kind != "executable"
            && !(current.distribution?.kind == "binary" && current.distribution?.sha256?.isEmpty != false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Image(systemName: "shippingbox.and.arrow.forward.fill")
                    .font(.system(size: 27)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Submit \(current.name) for review").font(.title2.bold())
                    Text("OpenFish will create a branch in your GitHub fork and open a pull request against the documented community catalog.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                publicationCheck("Credential-free manifest", passed: current.source == "user")
                publicationCheck("Exact version \(current.version) installed", passed: current.installation.status == "installed" && current.installation.installedVersion == current.version)
                publicationCheck("Driver API v\(current.driver.apiVersion) negotiated", passed: current.driver.loaded)
                publicationCheck("Prompt-free live preflight passed", passed: ["ready", "compatible"].contains(current.compatibility.status))
                publicationCheck("Portable distribution", passed: current.distribution?.kind != "executable")
            }
            .padding(12)
            .background(OpenCodexPalette.elevated, in: RoundedRectangle(cornerRadius: 10))

            SecureField("GitHub token (leave blank to use the saved Keychain authorization)", text: $token)
                .textFieldStyle(.roundedBorder)
            Text("The token is written directly to the Mac Host Keychain and resolved only for this GitHub operation. It is never added to the Pack, compatibility report, task, log, or iPhone state. A fine-grained token needs access to create a fork branch and pull request.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Forget saved GitHub authorization", role: .destructive) {
                Task { await store.forgetHarnessPublicationAuthorization() }
            }
            .buttonStyle(.link)

            if let publication = current.publication {
                Label(publication.detail, systemImage: publication.review == "pending" ? "clock" : "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                if let reviewURL = publication.reviewUrl, let url = URL(string: reviewURL) {
                    Button("Open current review") { NSWorkspace.shared.open(url) }
                }
            }

            HStack {
                Button("Cancel") { isPresented = false }
                Spacer()
                if !ready {
                    Text("Finish the failed checks before submission.").font(.caption).foregroundStyle(.orange)
                }
                Button(submitting ? "Submitting…" : "Submit to GitHub") {
                    submitting = true
                    let suppliedToken = token.isEmpty ? nil : token
                    token = ""
                    Task {
                        let succeeded = await store.submitHarnessPublication(current, githubToken: suppliedToken)
                        submitting = false
                        if succeeded { isPresented = false }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(submitting || !ready || current.publication?.reviewUrl != nil)
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    private func publicationCheck(_ title: String, passed: Bool) -> some View {
        Label(title, systemImage: passed ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(.caption)
            .foregroundStyle(passed ? Color.green : Color.orange)
    }
}

private struct HarnessRevocationSheet: View {
    @ObservedObject var store: OpenCodexStore
    let harness: HarnessCatalogEntry
    @Binding var isPresented: Bool
    @State private var reason = ""
    @State private var token = ""
    @State private var submitting = false

    private var current: HarnessCatalogEntry {
        store.harnesses.first(where: { $0.id == harness.id }) ?? harness
    }

    private var normalizedReason: String {
        reason.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        current.publication?.status == "published"
            && normalizedReason.count >= 20
            && normalizedReason.count <= 2_000
            && !submitting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 27))
                    .foregroundStyle(Color.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Request revocation of \(current.name) \(current.version)")
                        .font(.title2.bold())
                    Text("This opens a public maintainer review for this exact version. It does not delete the Pack or silently disable existing tasks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Public reason").font(.caption.weight(.semibold))
                TextEditor(text: $reason)
                    .font(.system(size: 12.5))
                    .frame(height: 112)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(OpenCodexPalette.border))
                    .accessibilityLabel("Public revocation reason")
                Text("Explain the compatibility, provenance, security, or maintenance reason without credentials, private paths, or conversation content. \(normalizedReason.count)/2,000")
                    .font(.caption2)
                    .foregroundStyle(normalizedReason.count > 2_000 ? Color.red : Color.secondary)
            }

            SecureField("GitHub token (leave blank to use saved Keychain authorization)", text: $token)
                .textFieldStyle(.roundedBorder)
            Text("OpenFish writes the request to the public revocation ledger only after GitHub creates a review PR. A merged ledger entry blocks new installs while preserving provenance for pinned tasks.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel") { isPresented = false }
                Spacer()
                if normalizedReason.count < 20 {
                    Text("Add at least 20 characters of evidence.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button(submitting ? "Submitting…" : "Open revocation review") {
                    submitting = true
                    let suppliedToken = token.isEmpty ? nil : token
                    let submittedReason = normalizedReason
                    token = ""
                    Task {
                        let succeeded = await store.submitHarnessRevocation(
                            current,
                            reason: submittedReason,
                            githubToken: suppliedToken
                        )
                        submitting = false
                        if succeeded { isPresented = false }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }
        }
        .padding(22)
        .frame(width: 580)
    }
}

private struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 22, weight: .semibold))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                content
            }
            .padding(28)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var store: OpenCodexStore
    @State private var host = ""
    @State private var code = ""

    var body: some View {
        SettingsPage(
            title: "General",
            subtitle: "Every OpenFish device connects to one authoritative OpenFish Host, powered by DSH."
        ) {
            GroupBox("Connection") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("https://mac-name.local:3081", text: $host)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Pairing code (remote Hosts)", text: $code)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Connect") { Task { await store.connect(host: host, pairingCode: code) } }
                            .buttonStyle(.borderedProminent)
                        Button("Use local Host") { Task { await store.useLocalHost() } }
                        Spacer()
                        Text(store.connectionState.label)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Text("Bearer credentials are stored in Keychain and are never copied into OpenFish settings files.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }
            GroupBox("Runtime") {
                VStack(alignment: .leading, spacing: 8) {
                    InspectorRow(label: "Host", value: store.connectionProfile.baseURL.absoluteString)
                    InspectorRow(label: "DSH engine", value: store.hostDescription?.version ?? "Not connected")
                    InspectorRow(label: "Model", value: store.hostDescription?.model ?? "Composition default")
                }
                .padding(8)
            }
        }
        .onAppear { host = store.connectionProfile.baseURL.absoluteString }
        .onChange(of: store.connectionProfile) { _, profile in host = profile.baseURL.absoluteString }
    }
}

private struct ModelsSettingsView: View {
    @ObservedObject var store: OpenCodexStore
    @State private var credentials: [String: String] = [:]

    var body: some View {
        SettingsPage(
            title: "Models",
            subtitle: "Provider routing and credentials are stored by the OpenFish Host and used only by the selected Harness route."
        ) {
            if !store.providers.isEmpty {
                GroupBox("Provider routes") {
                    VStack(spacing: 8) {
                        ForEach(store.providers) { provider in
                            let configured = store.hostModels.groups.contains(where: { $0.id == provider.provider })
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Circle()
                                        .fill(configured ? Color.green : Color.secondary.opacity(0.3))
                                        .frame(width: 7, height: 7)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(provider.displayName).font(.system(size: 13, weight: .medium))
                                        Text(provider.provider).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(configured ? "Configured" : (provider.active ? "Needs credential" : "Dormant"))
                                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                                }
                                if let ref = store.credentialRef(for: provider), !configured {
                                    HStack {
                                        SecureField(ref, text: Binding(
                                            get: { credentials[provider.id] ?? "" },
                                            set: { credentials[provider.id] = $0 }
                                        ))
                                        .textFieldStyle(.roundedBorder)
                                        Button("Save") {
                                            let value = credentials.removeValue(forKey: provider.id) ?? ""
                                            Task { await store.setCredential(ref: ref, value: value) }
                                        }
                                        .disabled((credentials[provider.id] ?? "").isEmpty)
                                    }
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    .padding(8)
                }
            }
            Text("Only providers with resolved credentials appear in task model pickers. Catalog-only models remain hidden until configured.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(store.settingsCatalog?.namespaces.filter { $0.ns.hasPrefix("llm-") } ?? []) { namespace in
                SettingsNamespaceEditor(store: store, namespace: namespace)
            }
        }
    }
}

private struct SettingsNamespaceEditor: View {
    @ObservedObject var store: OpenCodexStore
    let namespace: SettingsNamespaceView
    @State private var text = "{}"

    var body: some View {
        GroupBox(namespace.ns) {
            VStack(alignment: .leading, spacing: 9) {
                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 120, maxHeight: 240)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(OpenCodexPalette.border))
                HStack {
                    Text("Applies: \(namespace.applies) · revision \(namespace.revision)")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save") { Task { await store.replaceSettings(namespace, json: text) } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            .padding(8)
        }
        .onAppear { text = (namespace.user ?? .object([:])).prettyJSON }
        .onChange(of: namespace) { _, value in text = (value.user ?? .object([:])).prettyJSON }
    }
}

private struct VoiceSettingsView: View {
    @ObservedObject var store: OpenCodexStore
    @ObservedObject private var voice: LocalVoiceService

    init(store: OpenCodexStore) {
        self.store = store
        voice = store.voice
    }

    var body: some View {
        SettingsPage(
            title: "Voice",
            subtitle: "The apple-local Provider runs speech recognition and playback entirely on this Mac."
        ) {
            GroupBox("Host voice capability") {
                VStack(alignment: .leading, spacing: 9) {
                    InspectorRow(label: "Contract", value: store.nativeCapabilities?.voice?.contract ?? "Unavailable")
                    InspectorRow(label: "Provider", value: voice.providerName)
                    InspectorRow(label: "Transcript owner", value: store.nativeCapabilities?.voice?.transcriptAuthority ?? "Unavailable")
                    Text("OpenFish does not upload microphone audio to the Host or its own cloud service. It requests Apple’s on-device recognition mode; only finalized text is submitted to the selected Harness task.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }
            GroupBox("Playback") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Voice", selection: $voice.preferredVoiceIdentifier) {
                        Text("Automatic (best installed)").tag("")
                        ForEach(voice.availableVoices) { option in
                            Text("\(option.name) · \(option.quality)").tag(option.id)
                        }
                    }
                    HStack {
                        Text("Rate")
                        Slider(value: $voice.speechRate, in: 0.35...0.62)
                        Text(String(format: "%.2f", voice.speechRate))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 34)
                    }
                    Button(voice.isSpeaking ? "Stop preview" : "Preview voice") {
                        if voice.isSpeaking { voice.stopSpeaking() }
                        else { voice.speak("OpenFish voice is running locally on this Mac.") }
                    }
                }
                .padding(8)
            }
        }
    }
}

private struct PluginsSettingsView: View {
    @ObservedObject var store: OpenCodexStore
    @State private var driverBundles: [OpenFishDriverBundle] = []
    @State private var isLoadingDrivers = false
    @State private var isChangingDriver = false
    @State private var showsDriverInstaller = false
    @State private var pendingRemoval: OpenFishDriverBundle?
    @State private var driverNotice: String?

    var body: some View {
        SettingsPage(
            title: "Plugins",
            subtitle: "Add a non-ACP Harness Driver without installing DSH, Node, npm, or another developer tool."
        ) {
            GroupBox("Harness Driver Bundles") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Extend the shell, keep one runtime owner")
                                .font(.system(size: 13, weight: .semibold))
                            Text("ACP Harnesses need only a Pack. A different protocol ships as an exact-version Driver Bundle; OpenFish stages and validates it before activating it in the Host profile.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 16)
                        Button {
                            showsDriverInstaller = true
                        } label: {
                            Label("Add Driver", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!OpenFishDriverManager.isAvailable || isChangingDriver)
                    }

                    Divider()

                    if !OpenFishDriverManager.isAvailable {
                        Label(
                            "Driver management is available in the packaged OpenFish app. Reinstall the app if its embedded runtime is missing.",
                            systemImage: "shippingbox"
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                    } else if isLoadingDrivers {
                        HStack(spacing: 9) {
                            ProgressView().controlSize(.small)
                            Text("Reading the OpenFish Host profile…")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    } else if driverBundles.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("No custom Driver Bundles")
                                .font(.system(size: 12.5, weight: .medium))
                            Text("The built-in DSH, Codex, and ACP Drivers remain available. Add a Bundle only for a protocol they do not implement.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(driverBundles) { driver in
                            HStack(spacing: 10) {
                                Image(systemName: "shippingbox.fill")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(driver.packageName)
                                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                                    Text("v\(driver.version) · exact profile dependency")
                                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                                    Text(driver.installScriptsAllowed == true
                                         ? "npm lifecycle scripts explicitly allowed"
                                         : driver.installScriptsAllowed == false
                                            ? "npm lifecycle scripts blocked"
                                            : "Lifecycle-script consent unknown · reinstall before automatic rollback")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(driver.installScriptsAllowed == true ? Color.orange : Color.secondary)
                                }
                                Spacer()
                                Text(driver.active ? "Active after restart" : "Inactive")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(driver.active ? Color.green : Color.secondary)
                                Button(role: .destructive) {
                                    pendingRemoval = driver
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove \(driver.packageName)")
                                .disabled(isChangingDriver)
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    if let driverNotice {
                        Label(driverNotice, systemImage: "info.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
            }

            GroupBox("Loaded composition") {
                LazyVStack(spacing: 7) {
                    ForEach(store.plugins) { plugin in
                        HStack(spacing: 9) {
                            Circle()
                                .fill(plugin.fiberPhase == "active" ? Color.green : Color.orange)
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(plugin.moduleName ?? plugin.entryId)
                                    .font(.system(size: 13, weight: .medium))
                                Text(plugin.entryId)
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(plugin.enabled ? plugin.fiberPhase ?? "enabled" : "disabled")
                                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
            }
            Text("The list above is a live projection from the Cordis Loader. Driver installation updates that same x Profile and restarts the embedded Host; OpenFish does not keep a second plugin registry.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .task { await loadDriverBundles() }
        .sheet(isPresented: $showsDriverInstaller) {
            DriverBundleInstaller { spec, packageName, allowScripts in
                Task { await installDriver(spec: spec, packageName: packageName, allowScripts: allowScripts) }
            }
        }
        .alert(
            "Remove Driver Bundle?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { driver in
            Button("Remove", role: .destructive) {
                pendingRemoval = nil
                Task { await removeDriver(driver) }
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { driver in
            Text("\(driver.packageName) will be removed from the OpenFish Host profile. Existing tasks stay pinned to their Harness identity, but this Driver cannot resume them until reinstalled.")
        }
    }

    @MainActor
    private func loadDriverBundles() async {
        guard OpenFishDriverManager.isAvailable, !isLoadingDrivers else { return }
        isLoadingDrivers = true
        defer { isLoadingDrivers = false }
        do {
            driverBundles = try await OpenFishDriverManager.list().bundles
        } catch {
            driverNotice = "Could not read Driver Bundles: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func installDriver(spec: String, packageName: String?, allowScripts: Bool) async {
        guard !isChangingDriver else { return }
        isChangingDriver = true
        defer { isChangingDriver = false }
        do {
            let result = try await OpenFishDriverManager.install(
                spec: spec,
                expectedPackageName: packageName,
                allowScripts: allowScripts
            )
            driverBundles = result.bundles
            let restarted = !result.requiresRestart || OpenFishHostRuntime.restartManagedHost()
            driverNotice = restarted
                ? "\(result.changedPackage ?? "Driver Bundle") was admitted. The embedded Host is restarting so its Driver can negotiate with the Harness registry."
                : "The Bundle was admitted, but port 3080 belongs to an external Host. Restart that Host to activate the Driver."
        } catch {
            driverNotice = "Could not add this Driver Bundle: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func removeDriver(_ driver: OpenFishDriverBundle) async {
        guard !isChangingDriver else { return }
        isChangingDriver = true
        defer { isChangingDriver = false }
        do {
            let result = try await OpenFishDriverManager.remove(packageName: driver.packageName)
            driverBundles = result.bundles
            let restarted = !result.requiresRestart || OpenFishHostRuntime.restartManagedHost()
            driverNotice = restarted
                ? "\(driver.packageName) was removed. The embedded Host is restarting without that Driver."
                : "The Bundle was removed, but port 3080 belongs to an external Host. Restart that Host to finish unloading it."
        } catch {
            driverNotice = "Could not remove \(driver.packageName): \(error.localizedDescription)"
        }
    }
}

private struct DriverBundleInstaller: View {
    @Environment(\.dismiss) private var dismiss
    @State private var spec = ""
    @State private var expectedPackageName = ""
    @State private var allowScripts = false
    @State private var acceptsCodeExecution = false

    let install: (String, String?, Bool) -> Void

    private var isGitHubSpec: Bool {
        spec.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("github:")
    }

    private var canInstall: Bool {
        !spec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!isGitHubSpec || !expectedPackageName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && acceptsCodeExecution
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "shippingbox.and.arrow.backward")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.tint)
                Text("Add a Harness Driver")
                    .font(.system(size: 22, weight: .semibold))
                Text("Use this only when a Harness speaks a protocol the built-in Drivers do not support. ACP Harnesses need a Pack, not a custom Driver.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Exact package source")
                    .font(.system(size: 12.5, weight: .medium))
                TextField("@scope/openfish-driver-name@1.2.3", text: $spec)
                    .textFieldStyle(.roundedBorder)
                Text("Accepted: an exact npm version, or github:owner/repo# followed by a full 40-character commit.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }

            if isGitHubSpec {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Expected package name")
                        .font(.system(size: 12.5, weight: .medium))
                    TextField("@scope/openfish-driver-name", text: $expectedPackageName)
                        .textFieldStyle(.roundedBorder)
                    Text("OpenFish rejects the candidate if its package identity differs.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Allow npm lifecycle scripts (advanced)", isOn: $allowScripts)
                if allowScripts {
                    Label(
                        "Install scripts run before the Driver reaches OpenFish's structural admission checks. Enable this only for a source and exact commit you have reviewed.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Toggle(
                    "I understand that an admitted Driver runs code inside the local Host.",
                    isOn: $acceptsCodeExecution
                )
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Stage and Add") {
                    let trimmedSpec = spec.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedPackage = expectedPackageName.trimmingCharacters(in: .whitespacesAndNewlines)
                    install(trimmedSpec, trimmedPackage.isEmpty ? nil : trimmedPackage, allowScripts)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canInstall)
            }
        }
        .padding(24)
        .frame(width: 540)
    }
}

private struct RemoteSettingsView: View {
    @ObservedObject var store: OpenCodexStore

    var body: some View {
        SettingsPage(
            title: "Remote",
            subtitle: "Pair iPhone and Mac clients over LAN or Tailscale with short-lived one-time codes."
        ) {
            GroupBox("Pair a device") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        if let code = store.pairingCode {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(code.code)
                                    .font(.system(size: 21, weight: .semibold, design: .monospaced))
                                    .textSelection(.enabled)
                                if let hostURL = code.hostURL {
                                    Text(hostURL)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                } else {
                                    Text("Secure remote access is unavailable; restart the packaged Mac app to restore its TLS identity.")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            Text("Expires \(relativeTime(code.expiresAt))")
                                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        } else {
                            Text("Create a code on this Host, then enter it on the remote device.")
                                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                            Spacer()
                        }
                        Button("Create code") { Task { await store.createPairingCode() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(8)
            }
            GroupBox("Paired devices") {
                VStack(spacing: 8) {
                    if store.pairedDevices.isEmpty {
                        Text("No paired devices").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                    ForEach(store.pairedDevices) { device in
                        HStack {
                            Image(systemName: device.surface == "iphone" ? "iphone" : "laptopcomputer")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name).font(.system(size: 13, weight: .medium))
                                Text("Last seen \(relativeTime(device.lastSeenAt))")
                                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Revoke", role: .destructive) { Task { await store.revoke(device) } }
                        }
                    }
                }
                .padding(8)
            }
        }
    }
}

private struct DataSettingsView: View {
    @ObservedObject var store: OpenCodexStore

    var body: some View {
        SettingsPage(
            title: "Data",
            subtitle: "Export durable DSH task logs or import supported Codex and DSH archives."
        ) {
            GroupBox("Current task") {
                HStack {
                    Text("Exports include descendants and referenced images.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Export…") { exportTask(store: store) }
                        .disabled(store.selectedSessionId == nil)
                }
                .padding(8)
            }
            ImportArchiveControl(store: store)
        }
    }
}

private struct ImportArchiveControl: View {
    @ObservedObject var store: OpenCodexStore
    @State private var format = "auto"

    var body: some View {
        GroupBox("Import and migration") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Exports retain descendant tasks and referenced images. Imports currently convert supported DSH and Codex JSONL or ZIP sources into replayable DSH transcripts; imported attachments and source-side child relationships are not copied.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Picker("Source", selection: $format) {
                        Text("Detect automatically").tag("auto")
                        Text("DSH JSONL").tag("dsh-jsonl")
                        Text("DSH ZIP").tag("dsh-zip")
                        Text("Codex JSONL").tag("codex-jsonl")
                        Text("Codex ZIP").tag("codex-zip")
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    Spacer()
                    Button(store.isImporting ? "Importing…" : "Import…") {
                        chooseImportArchives(store: store, format: format)
                    }
                    .disabled(store.isImporting)
                }
                if let summary = store.lastImportSummary {
                    Label(summary, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                }
            }
            .padding(8)
        }
    }
}

// MARK: - Inspector

private struct TaskInspector: View {
    @ObservedObject var store: OpenCodexStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Task details")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    store.isInspectorPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 15)
            .padding(.top, 29)
            .padding(.bottom, 11)
            .frame(height: 68)
            .overlay(alignment: .bottom) {
                Rectangle().fill(OpenCodexPalette.softBorder).frame(height: 1)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    InspectorSection(title: "Run") {
                        InspectorRow(label: "Status", value: store.currentSession?.running == true ? "Working" : "Ready")
                        InspectorRow(
                            label: "Harness",
                            value: store.currentHarness.map { harnessDisplayName($0, among: store.harnesses) }
                                ?? store.currentHarnessId
                        )
                        InspectorRow(label: "Model", value: store.currentModelName)
                        InspectorRow(label: "Access", value: store.currentPermissionName)
                        InspectorRow(
                            label: "Location",
                            value: store.connectionProfile.isLocal
                                ? "Local"
                                : store.connectionProfile.baseURL.host ?? "Remote"
                        )
                    }
                    if let plan = store.currentPlan {
                        InspectorSection(title: "Plan") {
                            InspectorRow(label: "Mode", value: plan.active ? "On" : "Off")
                            if plan.pending { InspectorRow(label: "State", value: "Changing") }
                        }
                    }
                    if let todos = store.currentTodos, todos != .null {
                        InspectorSection(title: "Checklist") {
                            Text(todos.prettyJSON)
                                .font(.system(size: 12.5, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    if !store.subagents.isEmpty {
                        InspectorSection(title: "Subagents") {
                            ForEach(store.subagents) { child in
                                Button {
                                    Task { await store.openSubagent(child) }
                                } label: {
                                    HStack {
                                        Circle()
                                            .fill(child.activity == "running" ? Color.green : Color.secondary.opacity(0.3))
                                            .frame(width: 6, height: 6)
                                        Text(child.label ?? child.id)
                                            .font(.system(size: 12))
                                            .lineLimit(1)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 9))
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(child.kind != "child")
                            }
                        }
                    }
                    InspectorSection(title: "Project") {
                        InspectorRow(label: "Name", value: store.currentWorkspace?.title ?? "No Project")
                        InspectorRow(label: "Path", value: store.currentSession?.cwd ?? store.currentWorkspace?.path ?? "—")
                    }
                    if let harness = store.currentHarness {
                        InspectorSection(title: "Harness architecture · \(harness.graph.level)") {
                            HarnessArchitectureSummary(graph: harness.graph, runtime: store.currentHarnessRuntime)
                        }
                    }
                    InspectorSection(title: "Host runtime") {
                        InspectorRow(label: "Version", value: store.hostDescription?.version ?? "—")
                        InspectorRow(label: "Provider", value: store.sessionModels?.current.provider ?? store.hostDescription?.provider ?? "Default")
                        InspectorRow(label: "Preset", value: store.currentSession?.agentPreset ?? "Composition default")
                    }
                    InspectorSection(title: "Identity") {
                        InspectorRow(label: "Session", value: store.selectedSessionId ?? "—", monospaced: true)
                    }
                }
                .padding(16)
            }
        }
        .background(OpenCodexPalette.sidebar)
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.tertiary)
                .tracking(0.7)
            VStack(spacing: 8) { content }
        }
    }
}

private struct InspectorRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 12.5))
                .textSelection(.enabled)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Shared helpers

private struct OpenCodexMark: View {
    let size: CGFloat

    var body: some View {
        Image("OpenFishMark")
            .resizable()
            .renderingMode(.template)
            .foregroundStyle(Color.primary.opacity(0.92))
            .scaledToFit()
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(
        markdown: text,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(text)
}

private func activityIcon(_ card: String?) -> String {
    switch card {
    case "terminal": return "terminal"
    case "diff": return "doc.badge.gearshape"
    case "search": return "magnifyingglass"
    case "read": return "doc.text"
    case "web": return "globe"
    default: return "hammer"
    }
}

private func workspaceName(_ cwd: String?) -> String {
    guard let cwd else { return "No Project" }
    return cwd.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? cwd
}

@MainActor
private func selectedWorkspaceTitle(_ store: OpenCodexStore) -> String {
    guard let id = store.selectedWorkspaceId else { return "No Project" }
    return store.workspaces.first(where: { $0.workspaceId == id })?.title ?? "No Project"
}

private func relativeTime(_ milliseconds: Double) -> String {
    let date = Date(timeIntervalSince1970: milliseconds / 1_000)
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

@MainActor
private func exportTask(store: OpenCodexStore) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.zip]
    panel.nameFieldStringValue = "OpenFish-task.zip"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await store.exportCurrentSession(to: url) }
}

@MainActor
private func chooseImages(store: OpenCodexStore) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = ["png", "jpg", "jpeg", "webp", "gif"].compactMap {
        UTType(filenameExtension: $0)
    }
    guard panel.runModal() == .OK else { return }
    let urls = panel.urls
    Task { await store.addImages(urls) }
}

@MainActor
private func chooseImportArchives(store: OpenCodexStore, format: String) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = ["jsonl", "zip"].compactMap { UTType(filenameExtension: $0) }
    panel.message = "Select a DSH export, Codex rollout, or a folder containing rollout JSONL files."
    guard panel.runModal() == .OK else { return }
    Task { await store.importArchives(panel.urls, format: format) }
}

@MainActor
private func chooseHarnessPackImport(store: OpenCodexStore) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.json]
    panel.message = "Choose an OpenFish Harness Pack JSON document. Secrets must not be stored in the Pack."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { _ = await store.importCustomHarness(from: url) }
}

@MainActor
private func exportHarnessPack(store: OpenCodexStore, harness: HarnessCatalogEntry, publication: Bool) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "\(harness.id).openfish-harness.json"
    panel.message = publication
        ? "Save the validated public manifest. OpenFish also writes a redacted compatibility report and opens the community upload flow."
        : "Export a portable Harness Pack without credential values."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
        guard await store.exportHarness(harness, to: url, forPublication: publication), publication else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        if let upload = URL(string: "https://github.com/Yusong-Enceladus/OpenFish/upload/main/community/harnesses/packs") {
            NSWorkspace.shared.open(upload)
        }
    }
}
