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
                .frame(width: 292)

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
                    Text("Add project from DSH Host")
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
            }
            .padding(.horizontal, 16)
            .padding(.top, 34)
            .padding(.bottom, 16)

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
                .padding(.horizontal, 11)
                .frame(height: 40)
                .background(OpenCodexPalette.elevated.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(OpenCodexPalette.softBorder))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)
            .padding(.horizontal, 10)

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

private struct WorkspaceSection: View {
    @ObservedObject var store: OpenCodexStore
    let workspace: WorkspaceView?
    @State private var isExpanded = true
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var confirmDelete = false

    private var sessions: [SessionSummary] { store.sessions(in: workspace) }

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
                    Image(systemName: workspace == nil ? "tray" : "folder")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(workspace?.title ?? "No Project")
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
        store.workspaces.first(where: { $0.sessionIds.contains(session.sessionId) })?.title ?? "No Project"
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
            Text(isDemoMode ? "Demo data · offline" : state == .connected ? "DSH host connected" : state.label)
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
        VStack(spacing: 0) {
            if let session = store.currentSession {
                TaskHeader(store: store, session: session)
                if let error = store.errorBanner {
                    ErrorBanner(text: error, dismiss: store.dismissError)
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
        .background(OpenCodexPalette.canvas)
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
                    Text(store.currentWorkspace?.title ?? "No project")
                        .lineLimit(1)
                    Text("·")
                    Text(store.connectionProfile.isLocal ? "Local" : store.connectionProfile.baseURL.host ?? "Remote")
                    Text("·")
                    Label(store.currentHarness?.name ?? store.currentHarnessId, systemImage: "shippingbox")
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
            Text(store.connectionState == .connected ? "Local DSH" : store.connectionState.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(OpenCodexPalette.hover, in: Capsule())
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

// MARK: - New task

private struct NewTaskSurface: View {
    @ObservedObject var store: OpenCodexStore

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: max(72, geometry.size.height * 0.16))
                    OpenCodexMark(size: 38)
                        .padding(.bottom, 22)
                    Text("What are we building?")
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .tracking(-0.5)
                    Text("Start a task in your project. OpenFish will work through DSH, show every action, and ask before sensitive operations.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .frame(maxWidth: 520)
                        .padding(.top, 10)
                        .padding(.bottom, 28)

                    Composer(store: store, prominent: true)
                        .frame(width: min(720, max(320, geometry.size.width - 72)))

                    HStack(spacing: 18) {
                        CapabilityHint(icon: "terminal", text: "Run code")
                        CapabilityHint(icon: "doc.text.magnifyingglass", text: "Review changes")
                        CapabilityHint(icon: "checkmark.shield", text: "Approval aware")
                    }
                    .padding(.top, 18)
                    .padding(.bottom, 80)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 36)
            }
        }
    }
}

private struct CapabilityHint: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.tertiary)
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
                        ConversationItemView(item: item, voice: store.voice)
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
    @ObservedObject var voice: LocalVoiceService

    @ViewBuilder
    var body: some View {
        switch item.kind {
        case .user:
            UserMessage(item: item)
        case .assistant:
            AssistantMessage(item: item, voice: voice)
        case .activity:
            ActivityCard(item: item)
        case .notice:
            NoticeCard(item: item)
        }
    }
}

private struct UserMessage: View {
    let item: ConversationItem

    var body: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 88)
            Text(markdown(item.text))
                .font(.system(size: 15))
                .lineSpacing(3)
                .textSelection(.enabled)
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .background(Color.accentColor.opacity(0.105), in: RoundedRectangle(cornerRadius: 15))
        }
    }
}

private struct AssistantMessage: View {
    let item: ConversationItem
    @ObservedObject var voice: LocalVoiceService

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            OpenCodexMark(size: 26)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 10) {
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

            HStack(spacing: 8) {
                ComposerCapabilityMenu(store: store)
                WorkspacePicker(store: store)
                PermissionPicker(store: store)
                if store.canChooseHarness {
                    HarnessPicker(store: store)
                }
                if store.currentHarnessId == "dsh" || store.sessionModels?.groups.isEmpty == false {
                    ModelPicker(store: store)
                }
                if store.sessionModels?.harnessOptions?.contains(where: {
                    $0.category != "model" && $0.category != "thought_level"
                }) == true {
                    HarnessConfigPicker(store: store)
                }
                if store.currentHarnessId == "codex-acp" {
                    HarnessAccountBadge(store: store)
                }
                if store.canChooseAgentPreset {
                    AgentPresetPicker(store: store)
                }
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
                Spacer()

                Button {
                    Task { await store.toggleDictation() }
                } label: {
                    Image(systemName: store.voice.isListening ? "waveform.circle.fill" : "mic")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(store.voice.isListening ? Color.red : Color.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
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

private struct ComposerCapabilityMenu: View {
    @ObservedObject var store: OpenCodexStore
    @State private var creatingGoal = false
    @State private var goalObjective = ""

    var body: some View {
        Menu {
            Button {
                chooseImages(store: store)
            } label: {
                Label("Attach images…", systemImage: "photo.badge.plus")
            }
            Divider()
            if !store.skills.isEmpty {
                Menu("Skills") {
                    ForEach(store.skills) { skill in
                        Button(skill.name) { store.draft = "/\(skill.name) " }
                    }
                }
            }
            if !store.commands.isEmpty {
                Menu("Commands") {
                    ForEach(Array(store.commands.enumerated()), id: \.offset) { _, command in
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

private struct HarnessPicker: View {
    @ObservedObject var store: OpenCodexStore
    @State private var showingCatalog = false
    @State private var showingEditor = false
    @State private var authSelection: HarnessAuthSelection?
    @State private var query = ""

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

    var body: some View {
        Button { showingCatalog.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "cpu")
                Text(store.currentHarness?.name ?? store.currentHarnessId).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(OpenCodexPalette.hover, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingCatalog, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Find a Harness", text: $query)
                        .textFieldStyle(.roundedBorder)
                    Button { Task { await store.refreshHarnessCatalog() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh ACP Registry")
                    Button { showingEditor = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("Create a custom Harness Pack")
                }
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(filtered) { harness in
                            HStack(alignment: .top, spacing: 4) {
                                Button {
                                    if (harness.auth.status == "not-required" || harness.auth.status == "configured") {
                                        store.chooseHarness(harness)
                                        showingCatalog = false
                                    } else if let method = harness.auth.methods.first {
                                        if method.fields.isEmpty {
                                            Task {
                                                if await store.configureHarness(harness, method: method) { store.chooseHarness(harness) }
                                            }
                                        } else {
                                            authSelection = HarnessAuthSelection(harness: harness, method: method, makeDefault: false, completesOnboarding: false, selectForDraft: true)
                                        }
                                    }
                                } label: {
                                HStack(alignment: .top, spacing: 9) {
                                    Image(systemName: harness.id == store.currentHarnessId ? "checkmark.circle.fill" : "circle")
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 5) {
                                            Text(harness.name).font(.system(size: 12.5, weight: .semibold))
                                            if harness.verified { Image(systemName: "checkmark.seal.fill").foregroundStyle(.blue).font(.caption2) }
                                            Text(harness.installation.status.replacingOccurrences(of: "-", with: " "))
                                                .font(.system(size: 8.5, weight: .medium)).foregroundStyle(.secondary)
                                                .padding(.horizontal, 4).padding(.vertical, 1)
                                                .background(.secondary.opacity(0.1), in: Capsule())
                                        }
                                        Text(subtitle(harness))
                                            .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
                                        if let reason = harness.unavailableReason {
                                            Text(reason).font(.system(size: 10)).foregroundStyle(.red).lineLimit(2)
                                        }
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                                .padding(7)
                                }
                                .buttonStyle(.plain)
                                .disabled(store.harnessOperationId != nil || !harness.available)
                                if harness.id != "dsh" {
                                    Menu {
                                        if harness.installation.status == "installed" {
                                            if harness.installation.installedVersion != harness.installation.availableVersion {
                                                Button("Update") { Task { await store.mutateHarness("update", harness: harness) } }
                                            }
                                            if !harness.installation.previousVersions.isEmpty {
                                                Button("Roll back") { Task { await store.mutateHarness("rollback", harness: harness) } }
                                            }
                                            Button("Uninstall", role: .destructive) { Task { await store.mutateHarness("uninstall", harness: harness) } }
                                        } else {
                                            Button("Install") { Task { await store.mutateHarness("install", harness: harness) } }
                                        }
                                        if harness.source == "user" {
                                            Divider()
                                            Button("Remove Pack", role: .destructive) { Task { await store.mutateHarness("remove", harness: harness) } }
                                        }
                                        if !harness.auth.methods.isEmpty {
                                            Divider()
                                            ForEach(harness.auth.methods) { method in
                                                Button("Use \(method.name)") {
                                                    if method.fields.isEmpty {
                                                        Task {
                                                            if await store.configureHarness(harness, method: method) { store.chooseHarness(harness) }
                                                        }
                                                    } else {
                                                        authSelection = HarnessAuthSelection(harness: harness, method: method, makeDefault: false, completesOnboarding: false, selectForDraft: true)
                                                    }
                                                }
                                            }
                                        }
                                    } label: {
                                        if store.harnessOperationId == harness.id { ProgressView().controlSize(.small) }
                                        else { Image(systemName: "ellipsis.circle") }
                                    }
                                    .menuStyle(.borderlessButton)
                                    .frame(width: 24)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
                if let selected = store.currentHarness {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("Architecture").font(.caption.weight(.semibold))
                            Spacer()
                            Text(selected.graph.level.capitalized).font(.caption2).foregroundStyle(.secondary)
                        }
                        HarnessGraphPreview(graph: selected.graph)
                            .frame(height: 112)
                    }
                }
            }
            .padding(12)
            .frame(width: 390)
        }
        .sheet(isPresented: $showingEditor) { HarnessPackEditor(store: store, isPresented: $showingEditor) }
        .sheet(item: $authSelection) { selection in HarnessCredentialsSheet(store: store, selection: selection) }
    }
}

private struct HarnessAuthSelection: Identifiable {
    let harness: HarnessCatalogEntry
    let method: HarnessCatalogEntry.Authentication.Method
    let makeDefault: Bool
    let completesOnboarding: Bool
    var selectForDraft = false
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
            Text("Secrets are written to the Host credential service and are never returned to the app or stored in the Harness Pack.")
                .font(.callout).foregroundStyle(.secondary)
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
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save and use") {
                    let submitted = values
                    values = [:]
                    saving = true
                    Task {
                        let saved = await store.configureHarness(
                            selection.harness,
                            method: selection.method,
                            credentials: submitted,
                            makeDefault: selection.makeDefault,
                            completesOnboarding: selection.completesOnboarding
                        )
                        saving = false
                        if saved {
                            if selection.selectForDraft { store.chooseHarness(selection.harness) }
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
    }
}

private struct HarnessPackEditor: View {
    @ObservedObject var store: OpenCodexStore
    @Binding var isPresented: Bool
    @State private var id = ""
    @State private var name = ""
    @State private var version = "1.0.0"
    @State private var protocolName = "acp"
    @State private var distributionKind = "npx"
    @State private var packageOrCommand = ""
    @State private var binaryCommand = ""
    @State private var sha256 = ""
    @State private var arguments = ""
    @State private var distributionEnvironment = ""
    @State private var graphLevel = "composable"
    @State private var authMethodId = ""
    @State private var authMethodName = ""
    @State private var authKind = "agent"
    @State private var authFieldRef = ""
    @State private var authFieldName = ""
    @State private var authFieldEnv = ""
    @State private var terminalAuthArguments = ""
    @State private var terminalAuthEnvironment = ""
    @State private var nodes: [HarnessGraphNode] = [HarnessGraphNode(id: "runtime", kind: "harness-runtime", title: "Runtime", editable: true, config: nil)]
    @State private var edges: [HarnessGraphEdge] = []
    @State private var positions: [String: CGPoint] = ["runtime": CGPoint(x: 120, y: 90)]
    @State private var edgeFrom = "runtime"
    @State private var edgeTo = "runtime"
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Custom Harness Pack").font(.title2.bold())
            Form {
                TextField("Identifier", text: $id)
                TextField("Name", text: $name)
                TextField("Version", text: $version)
                TextField("Protocol / Driver id", text: $protocolName)
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
                Picker("Graph truthfulness", selection: $graphLevel) {
                    Text("Opaque").tag("opaque"); Text("Observable").tag("observable"); Text("Composable").tag("composable")
                }
                Section("Authentication (optional)") {
                    TextField("Method id", text: $authMethodId)
                    TextField("Method name", text: $authMethodName)
                    Picker("Method type", selection: $authKind) {
                        Text("Harness / browser").tag("agent"); Text("Environment credential").tag("environment"); Text("Terminal login").tag("terminal")
                    }
                    if authKind == "environment" {
                        TextField("Credential reference", text: $authFieldRef)
                        TextField("Field label", text: $authFieldName)
                        TextField("Environment variable", text: $authFieldEnv)
                    } else if authKind == "terminal" {
                        TextField("Login arguments (one per line)", text: $terminalAuthArguments, axis: .vertical).lineLimit(2...4)
                        TextField("Login environment (NAME=value, one per line)", text: $terminalAuthEnvironment, axis: .vertical).lineLimit(2...4)
                    }
                }
            }
            Text("Architecture graph").font(.headline)
            EditableHarnessGraphCanvas(nodes: $nodes, edges: $edges, positions: $positions)
                .frame(minHeight: 210)
            ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        TextField("Node id", text: Binding(get: { nodes[index].id }, set: {
                        let oldID = nodes[index].id
                        let newID = $0
                        nodes[index] = HarnessGraphNode(id: newID, kind: node.kind, title: node.title, editable: node.editable, config: node.config)
                        positions[newID] = positions.removeValue(forKey: oldID)
                        edges = edges.map { edge in
                            HarnessGraphEdge(from: edge.from == oldID ? newID : edge.from, to: edge.to == oldID ? newID : edge.to)
                        }
                        }))
                        TextField("Title", text: Binding(get: { nodes[index].title }, set: { nodes[index] = HarnessGraphNode(id: node.id, kind: node.kind, title: $0, editable: node.editable, config: node.config) }))
                        TextField("Kind", text: Binding(get: { nodes[index].kind }, set: { nodes[index] = HarnessGraphNode(id: node.id, kind: $0, title: node.title, editable: node.editable, config: node.config) }))
                        Toggle("Editable", isOn: Binding(get: { nodes[index].editable }, set: { nodes[index] = HarnessGraphNode(id: node.id, kind: node.kind, title: node.title, editable: $0, config: node.config) }))
                            .toggleStyle(.checkbox)
                            .disabled(graphLevel != "composable")
                        Button(role: .destructive) { nodes.remove(at: index); positions.removeValue(forKey: node.id); edges.removeAll { $0.from == node.id || $0.to == node.id } } label: { Image(systemName: "trash") }
                    }
                    HarnessNodeConfigEditor(node: Binding(get: { nodes[index] }, set: { nodes[index] = $0 }))
                }
            }
            HStack {
                Button("Add node") {
                    let node = HarnessGraphNode(id: "node-\(nodes.count + 1)", kind: "step", title: "Step", editable: graphLevel == "composable", config: nil)
                    nodes.append(node); positions[node.id] = CGPoint(x: 140 + nodes.count * 35, y: 100 + nodes.count * 20)
                    edgeTo = node.id
                }
                if nodes.count >= 2 {
                    Picker("From", selection: $edgeFrom) { ForEach(nodes) { Text($0.title).tag($0.id) } }.frame(width: 130)
                    Picker("To", selection: $edgeTo) { ForEach(nodes) { Text($0.title).tag($0.id) } }.frame(width: 130)
                    Button("Connect") {
                        let edge = HarnessGraphEdge(from: edgeFrom, to: edgeTo)
                        if !edges.contains(edge) { edges.append(edge) }
                    }
                    .disabled(edgeFrom == edgeTo)
                }
                Spacer()
                Text("\(nodes.count) nodes · \(edges.count) edges").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Save") {
                    saving = true
                    Task {
                        let args = arguments.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
                        let saved = await store.saveCustomHarness(
                            id: id, name: name, version: version, protocolName: protocolName,
                            distributionKind: distributionKind, packageOrCommand: packageOrCommand, arguments: args,
                            distributionEnvironment: distributionEnvironment,
                            binaryCommand: binaryCommand, sha256: sha256, graphLevel: graphLevel,
                            authMethodId: authMethodId, authMethodName: authMethodName, authKind: authKind,
                            authFieldRef: authFieldRef, authFieldName: authFieldName, authFieldEnv: authFieldEnv,
                            terminalAuthArguments: terminalAuthArguments, terminalAuthEnvironment: terminalAuthEnvironment,
                            nodes: nodes, edges: edges, positions: positions
                        )
                        saving = false
                        if saved { isPresented = false }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(saving || id.isEmpty || name.isEmpty || packageOrCommand.isEmpty || nodes.isEmpty || (distributionKind == "binary" && binaryCommand.isEmpty))
            }
        }
        .padding(22)
        .frame(width: 720, height: 760)
        .onChange(of: graphLevel) { _, level in
            guard level != "composable" else { return }
            nodes = nodes.map { HarnessGraphNode(id: $0.id, kind: $0.kind, title: $0.title, editable: false, config: $0.config) }
        }
    }
}

private struct HarnessNodeConfigEditor: View {
    @Binding var node: HarnessGraphNode
    @State private var text = "{}"
    @State private var error: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("Config JSON").font(.caption).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
            TextEditor(text: $text).font(.system(.caption, design: .monospaced)).frame(height: 54)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(error == nil ? OpenCodexPalette.border : Color.red))
            Button("Apply") { apply() }.disabled(!node.editable)
        }
        .onAppear { text = encoded(node.config ?? [:]) }
        .onChange(of: node.id) { _, _ in text = encoded(node.config ?? [:]) }
        if let error { Text(error).font(.caption2).foregroundStyle(.red).padding(.leading, 84) }
    }

    private func encoded(_ object: [String: JSONValue]) -> String {
        guard let data = try? JSONEncoder().encode(JSONValue.object(object)),
              let value = String(data: data, encoding: .utf8) else { return "{}" }
        return value
    }

    private func apply() {
        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            guard case let .object(config) = value else {
                error = "Node config must be a JSON object."
                return
            }
            node = HarnessGraphNode(id: node.id, kind: node.kind, title: node.title, editable: node.editable, config: config)
            error = nil
        } catch {
            self.error = "Invalid JSON: \(error.localizedDescription)"
        }
    }
}

private struct HarnessGraphPreview: View {
    let graph: HarnessGraph

    var body: some View {
        GeometryReader { proxy in
            let points = Dictionary(uniqueKeysWithValues: graph.nodes.enumerated().map { index, node in
                (node.id, CGPoint(x: 70 + CGFloat(index % 3) * max(105, (proxy.size.width - 140) / 2), y: 34 + CGFloat(index / 3) * 62))
            })
            ZStack {
                ForEach(Array(graph.edges.enumerated()), id: \.offset) { _, edge in
                    if let from = points[edge.from], let to = points[edge.to] {
                        Path { path in path.move(to: from); path.addLine(to: to) }
                            .stroke(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                }
                ForEach(graph.nodes) { node in
                    VStack(spacing: 1) {
                        Text(node.title).font(.caption2.weight(.semibold)).lineLimit(1)
                        Text(node.kind).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(width: 112)
                    .background(.background, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(.secondary.opacity(0.35)))
                    .position(points[node.id] ?? .zero)
                }
            }
            .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct EditableHarnessGraphCanvas: View {
    @Binding var nodes: [HarnessGraphNode]
    @Binding var edges: [HarnessGraphEdge]
    @Binding var positions: [String: CGPoint]

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
                    HarnessEditableNode(node: node)
                    .position(positions[node.id] ?? CGPoint(x: 90 + CGFloat(index) * 155, y: proxy.size.height / 2))
                    .gesture(DragGesture(coordinateSpace: .named("harnessGraphCanvas")).onChanged { value in
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

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: node.kind == "harness-runtime" ? "cpu" : "square.stack.3d.up")
            Text(node.title).font(.caption.weight(.semibold)).lineLimit(1)
            Text(node.kind).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 132, height: 62)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.7), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
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
                Text("Access modes are managed by DSH")
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
            .background(OpenCodexPalette.hover, in: RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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
            Button("No project") { store.changeNewTaskWorkspace(to: nil) }
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
            .background(OpenCodexPalette.hover, in: RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(store.selectedSessionId != nil)
    }
}

private struct ModelPicker: View {
    @ObservedObject var store: OpenCodexStore

    private func harnessProvider(_ model: CatalogModel) -> String {
        let provider = model.id.split(separator: "/", maxSplits: 1).first.map(String.init) ?? "Harness"
        return provider.replacingOccurrences(of: "-", with: " ").capitalized
    }

    @ViewBuilder
    private func modelButton(_ model: CatalogModel, groupID: String, catalog: SessionModels) -> some View {
        if let efforts = model.reasoning?.efforts, !efforts.isEmpty {
            Menu(model.name) {
                ForEach(efforts) { effort in
                    Button {
                        Task { await store.chooseModel(provider: groupID, model: model, effort: effort.id) }
                    } label: {
                        if catalog.current.provider == groupID,
                           catalog.current.model == model.id,
                           catalog.current.reasoningEffort == effort.id {
                            Label(effort.name, systemImage: "checkmark")
                        } else {
                            Text(effort.name)
                        }
                    }
                }
            }
        } else {
            Button {
                Task { await store.chooseModel(provider: groupID, model: model) }
            } label: {
                if catalog.current.provider == groupID, catalog.current.model == model.id {
                    Label(model.name, systemImage: "checkmark")
                } else {
                    Text(model.name)
                }
            }
        }
    }

    var body: some View {
        Menu {
            if store.isLoadingSessionModels, store.sessionModels == nil {
                Text("Loading model choices…")
            } else if let catalog = store.sessionModels, !catalog.groups.isEmpty {
                ForEach(catalog.groups) { group in
                    Section(group.name) {
                        if group.id == "harness" {
                            let providers = Dictionary(grouping: group.models, by: harnessProvider)
                            ForEach(providers.keys.sorted(), id: \.self) { provider in
                                Menu(provider) {
                                    ForEach(providers[provider] ?? []) { model in
                                        modelButton(model, groupID: group.id, catalog: catalog)
                                    }
                                }
                            }
                        } else {
                            ForEach(group.models) { model in
                                modelButton(model, groupID: group.id, catalog: catalog)
                            }
                        }
                    }
                }
            } else if let error = store.sessionModelsError {
                Text("Could not load model choices")
                Text(error)
                Divider()
                Button("Retry") { Task { await store.retryCurrentModels() } }
            } else {
                Text("No model choices are configured")
                Divider()
                Button("Open Settings") { store.isSettingsPresented = true }
            }
        } label: {
            HStack(spacing: 5) {
                if store.isLoadingSessionModels, store.sessionModels == nil {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Loading models…")
                        .lineLimit(1)
                } else {
                    Text(store.currentModelLabel)
                        .lineLimit(1)
                    Image(systemName: store.sessionModelsError == nil ? "chevron.down" : "exclamationmark.triangle")
                        .font(.system(size: 7, weight: .bold))
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(OpenCodexPalette.hover, in: RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("OpenFish.ModelPicker")
        .help(store.sessionModelsError == nil ? "Choose a model" : "Model choices could not be loaded. Open to retry.")
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
        .fixedSize()
        .accessibilityIdentifier("OpenFish.HarnessConfigPicker")
        .help("Configure options advertised by this Harness")
    }
}

private struct HarnessAccountBadge: View {
    @ObservedObject var store: OpenCodexStore

    private var selectedMethod: String? { store.currentHarness?.auth.selectedMethod }
    private var title: String {
        switch selectedMethod {
        case "chat-gpt": "ChatGPT · Codex plan"
        case "api-key": "OpenAI API · usage billing"
        default: "Codex sign-in unknown"
        }
    }
    private var detail: String {
        switch selectedMethod {
        case "chat-gpt": "This task reuses the Codex login on this Mac and uses ChatGPT subscription access."
        case "api-key": "This task uses an OpenAI API key and is billed to the OpenAI Platform account."
        default: "Open Harness settings to choose and verify a Codex authentication method."
        }
    }

    var body: some View {
        Menu {
            Text(detail)
            Divider()
            Button("Open Harness Settings") { store.isSettingsPresented = true }
        } label: {
            Label(title, systemImage: selectedMethod == "chat-gpt" ? "person.crop.circle.badge.checkmark" : "key")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(OpenCodexPalette.hover, in: RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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
                    Text("Local audio · DSH task")
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
                ? "Speak naturally. Final transcripts are sent through the same DSH session API as typed prompts."
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

    private var filtered: [HarnessCatalogEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rows = needle.isEmpty ? store.harnesses : store.harnesses.filter {
            $0.id.lowercased().contains(needle) || $0.name.lowercased().contains(needle)
                || ($0.description?.lowercased().contains(needle) ?? false)
        }
        let featured = ["dsh": 0, "pi-acp": 1, "oh-my-pi": 2, "codex-acp": 3, "opencode": 4]
        return rows.sorted {
            let lhs = featured[$0.id] ?? 100
            let rhs = featured[$1.id] ?? 100
            return lhs == rhs ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending : lhs < rhs
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: "shippingbox.and.arrow.backward")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text("Choose your default Harness")
                    .font(.system(size: 26, weight: .semibold))
                Text("Open Fish will install and configure it. Every new task uses this Harness unless you choose another one before the task starts.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Find a Harness by name", text: $query)
                .textFieldStyle(.roundedBorder)

            Group {
                if store.isLoadingHarnessCatalog && store.harnesses.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading available Harnesses…")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filtered.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: store.harnesses.isEmpty ? "exclamationmark.triangle" : "magnifyingglass")
                            .font(.system(size: 28))
                            .foregroundStyle(store.harnesses.isEmpty ? Color.orange : Color.secondary)
                        Text(store.harnesses.isEmpty ? "Harness catalog could not be loaded" : "No Harnesses match your search")
                            .font(.system(size: 15, weight: .semibold))
                        if let error = store.harnessCatalogError, store.harnesses.isEmpty {
                            Text(error)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(4)
                        }
                        if store.harnesses.isEmpty {
                            Button("Try Again") {
                                Task { await store.loadHarnessCatalogForOnboarding(forceRefresh: true) }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                            ForEach(filtered) { harness in
                                VStack(spacing: 8) {
                                    HarnessChoiceCard(
                                        harness: harness,
                                        busy: store.harnessOperationId != nil,
                                        ready: harness.available && (harness.id != "dsh" || !store.hostModels.groups.isEmpty),
                                        action: { Task { await store.selectDefaultHarness(harness, completesOnboarding: true) } },
                                        authAction: { method in
                                            if method.fields.isEmpty {
                                                Task {
                                                    _ = await store.configureHarness(
                                                        harness, method: method, makeDefault: true, completesOnboarding: true
                                                    )
                                                }
                                            } else {
                                                authSelection = HarnessAuthSelection(
                                                    harness: harness, method: method, makeDefault: true, completesOnboarding: true
                                                )
                                            }
                                        }
                                    )
                                    if harness.id == "dsh" && store.hostModels.groups.isEmpty {
                                        DshProviderQuickSetup(store: store)
                                    }
                                }
                            }
                        }
                        .padding(1)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(32)
        .sheet(item: $authSelection) { selection in HarnessCredentialsSheet(store: store, selection: selection) }
        .task {
            async let settings: Void = store.loadSettings()
            async let catalog: Void = store.loadHarnessCatalogForOnboarding()
            _ = await (settings, catalog)
        }
    }
}

private struct HarnessChoiceCard: View {
    let harness: HarnessCatalogEntry
    let busy: Bool
    let ready: Bool
    let action: () -> Void
    let authAction: (HarnessCatalogEntry.Authentication.Method) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(harness.name).font(.system(size: 15, weight: .semibold))
                Spacer()
                if harness.verified {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.accentColor)
                }
            }
            Text(harness.description ?? "No description provided.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Spacer(minLength: 0)
            HStack {
                Text(harness.protocolName.uppercased())
                Spacer()
                Text(harness.installation.status == "builtin" || harness.installation.status == "installed" ? "Installed" : "Will install")
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            if harness.auth.status != "not-required" && harness.auth.status != "configured" {
                Divider()
                Text("Choose how to sign in")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(harness.auth.methods) { method in
                    Button(method.name) { authAction(method) }
                        .buttonStyle(.bordered)
                        .disabled(busy)
                }
            } else {
                Button(harness.installation.status == "builtin" || harness.installation.status == "installed" ? "Use this Harness" : "Install and use") {
                    action()
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || !ready)
                if !ready {
                    Text("Configure at least one usable model provider below.")
                        .font(.system(size: 10.5)).foregroundStyle(.orange)
                }
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
        .background(OpenCodexPalette.elevated, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(OpenCodexPalette.border))
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

private struct HarnessSettingsView: View {
    @ObservedObject var store: OpenCodexStore
    @State private var authSelection: HarnessAuthSelection?
    @State private var query = ""

    private var filtered: [HarnessCatalogEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return store.harnesses }
        return store.harnesses.filter { $0.id.lowercased().contains(needle) || $0.name.lowercased().contains(needle) }
    }

    var body: some View {
        SettingsPage(
            title: "Harnesses",
            subtitle: "Choose the Harness Open Fish uses for new tasks. Existing tasks keep the Harness they started with."
        ) {
            TextField("Find a Harness", text: $query).textFieldStyle(.roundedBorder)
            VStack(spacing: 10) {
                ForEach(filtered) { harness in
                    HStack(spacing: 12) {
                        Image(systemName: harness.isDefault ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(harness.isDefault ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(harness.name).font(.system(size: 13, weight: .semibold))
                            Text(harness.description ?? "No description provided.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                            Text("Registry: \(harness.verified ? "verified" : "community") · Open Fish: \(harness.compatibility.status)")
                                .font(.system(size: 10.5)).foregroundStyle(harness.compatibility.status == "failed" ? Color.red : Color.secondary)
                            if harness.id == "codex-acp" {
                                Text(harness.auth.selectedMethod == "chat-gpt"
                                     ? "Account: ChatGPT sign-in · uses Codex plan access"
                                     : harness.auth.selectedMethod == "api-key"
                                        ? "Account: OpenAI API key · usage-based API billing"
                                        : "Account: choose a Codex sign-in method")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            }
                            if let message = harness.compatibility.message, harness.compatibility.status == "failed" {
                                Text(message).font(.system(size: 10.5)).foregroundStyle(.red).lineLimit(2)
                            }
                        }
                        Spacer()
                        if harness.auth.status != "not-required" && harness.auth.status != "configured" {
                            Menu("Configure") {
                                ForEach(harness.auth.methods) { method in
                                    Button(method.name) {
                                        if method.fields.isEmpty {
                                            Task { _ = await store.configureHarness(harness, method: method) }
                                        } else {
                                            authSelection = HarnessAuthSelection(
                                                harness: harness, method: method, makeDefault: false, completesOnboarding: false
                                            )
                                        }
                                    }
                                }
                            }
                        } else {
                            VStack(alignment: .trailing, spacing: 5) {
                                Button(harness.isDefault ? "Default" : (harness.installation.status == "installed" || harness.installation.status == "builtin" ? "Make Default" : "Install & Use")) {
                                    Task { await store.selectDefaultHarness(harness) }
                                }
                                .disabled(harness.isDefault || store.harnessOperationId != nil)
                                HStack(spacing: 7) {
                                    if harness.compatibility.status == "failed" {
                                        Button("Retry") { Task { await store.mutateHarness("install", harness: harness) } }
                                    }
                                    if harness.auth.methods.contains(where: { $0.kind == "terminal" }) {
                                        Menu("Sign in again") {
                                            ForEach(harness.auth.methods.filter { $0.kind == "terminal" }) { method in
                                                Button(method.name) { Task { _ = await store.configureHarness(harness, method: method) } }
                                            }
                                        }
                                    }
                                    Button { copyDiagnostics(harness) } label: { Image(systemName: "doc.on.doc") }
                                        .help("Copy redacted diagnostics")
                                }
                                .font(.caption)
                            }
                        }
                    }
                    .padding(12)
                    .background(OpenCodexPalette.elevated, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .sheet(item: $authSelection) { selection in HarnessCredentialsSheet(store: store, selection: selection) }
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
            "installation=\(harness.installation.status)", "auth=\(harness.auth.status)",
            "compatibility=\(harness.compatibility.status)",
            harness.unavailableReason.map { "unavailable=\(redacted($0))" },
            harness.installation.error.map { "install_error=\(redacted($0))" },
            harness.compatibility.message.map { "compatibility_message=\(redacted($0))" },
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.compactMap { $0 }.joined(separator: "\n"), forType: .string)
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
            subtitle: "OpenFish is a native client of one authoritative DSH Host."
        ) {
            GroupBox("Connection") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("http://host:3080", text: $host)
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
                    InspectorRow(label: "DSH", value: store.hostDescription?.version ?? "Not connected")
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
            subtitle: "Provider routing and credentials are written through DSH's settings and credential services."
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
            GroupBox("DSH voice capability") {
                VStack(alignment: .leading, spacing: 9) {
                    InspectorRow(label: "Contract", value: store.nativeCapabilities?.voice?.contract ?? "Unavailable")
                    InspectorRow(label: "Provider", value: voice.providerName)
                    InspectorRow(label: "Transcript owner", value: store.nativeCapabilities?.voice?.transcriptAuthority ?? "Unavailable")
                    Text("Microphone audio is never uploaded to the Host or a cloud speech service. Only the finalized text is submitted to the selected DSH task.")
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

    var body: some View {
        SettingsPage(
            title: "Plugins",
            subtitle: "The live Cordis Loader remains the owner; this is its current projection."
        ) {
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
            Text("Install, remove, and author plugins through the OpenFish CLI or the DSH profile document; the native app does not maintain a second plugin registry.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
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
                            Text(code.code)
                                .font(.system(size: 24, weight: .semibold, design: .monospaced))
                                .textSelection(.enabled)
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
                Text("DSH exports retain descendant tasks and referenced images. Codex rollout JSONL is converted into a replayable DSH transcript; DSH remains the only state owner after import.")
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
                        InspectorRow(label: "Harness", value: store.currentHarness?.name ?? store.currentHarnessId)
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
                        InspectorRow(label: "Name", value: store.currentWorkspace?.title ?? "No project")
                        InspectorRow(label: "Path", value: store.currentSession?.cwd ?? store.currentWorkspace?.path ?? "—")
                    }
                    if let harness = store.currentHarness {
                        InspectorSection(title: "Harness architecture · \(harness.graph.level)") {
                            ForEach(harness.graph.nodes) { node in
                                HStack(spacing: 8) {
                                    Image(systemName: node.editable ? "slider.horizontal.3" : "square.dashed")
                                        .foregroundStyle(node.editable ? Color.accentColor : Color.secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(node.title).font(.system(size: 12, weight: .medium))
                                        Text(node.kind).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                }
                                .padding(7)
                                .background(OpenCodexPalette.hover, in: RoundedRectangle(cornerRadius: 7))
                            }
                        }
                    }
                    InspectorSection(title: "DSH runtime") {
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
    guard let cwd else { return "No project" }
    return cwd.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? cwd
}

@MainActor
private func selectedWorkspaceTitle(_ store: OpenCodexStore) -> String {
    guard let id = store.selectedWorkspaceId else { return "No project" }
    return store.workspaces.first(where: { $0.workspaceId == id })?.title ?? "No project"
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
