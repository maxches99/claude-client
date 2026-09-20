import SwiftUI
import ClaudeRemoteCore

/// One tab's list: work sessions in projects, or tool-less quick chats.
struct SessionListView: View {
    enum Scope { case sessions, chats }

    let scope: Scope
    @Environment(AppModel.self) private var model
    @State private var showNewSession = false
    @State private var showSettings = false
    @State private var showSimulator = false
    @State private var showAddMac = false
    @State private var confirmForget = false
    @State private var search = ""
    @State private var collapsedProjects: Set<String> = []
    @State private var newSessionCwd: String?
    @State private var showArchived = false
    @State private var renaming: SessionSummary?
    @State private var renameText = ""
    @State private var searchTask: Task<Void, Never>?

    private var isChats: Bool { scope == .chats }

    /// Sessions grouped by their project folder, newest project first, for the Sessions tab.
    private struct ProjectGroup: Identifiable {
        let id: String
        let name: String
        let cwd: String
        let sessions: [SessionSummary]
        let latest: Date
    }

    private var projectGroups: [ProjectGroup] {
        Dictionary(grouping: filtered) { $0.cwd }
            .map { cwd, sessions in
                let sorted = sessions.sorted { $0.updatedAt > $1.updatedAt }
                return ProjectGroup(id: cwd, name: sorted.first?.projectName ?? cwd,
                                    cwd: cwd, sessions: sorted, latest: sorted.first?.updatedAt ?? .distantPast)
            }
            .sorted { $0.latest > $1.latest }
    }

    private var filtered: [SessionSummary] {
        let wanted: SessionKind = isChats ? .chat : .agent
        let scoped = model.sessions.filter { $0.kind == wanted && (showArchived || !model.archivedSessions.contains($0.id)) }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return scoped }
        return scoped.filter { $0.title.lowercased().contains(q) || $0.projectName.lowercased().contains(q) }
    }

    private var pinned: [SessionSummary] { filtered.filter { model.pinnedSessions.contains($0.id) } }
    private var archivedCount: Int {
        let wanted: SessionKind = isChats ? .chat : .agent
        return model.sessions.filter { $0.kind == wanted && model.archivedSessions.contains($0.id) }.count
    }

    /// Transcript hits from the Mac for the current query (only sessions of this tab).
    @ViewBuilder private var transcriptHits: some View {
        let q = search.trimmingCharacters(in: .whitespaces)
        if q.count >= 2 {
            let wanted: SessionKind = isChats ? .chat : .agent
            let result = model.sessionSearch
            Section {
                if model.sessionSearchInFlight, result?.query != q {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Searching transcripts…").font(CDS.caption).foregroundStyle(CDS.textMuted) }
                        .listRowBackground(CDS.surface0)
                } else if let result, result.query == q {
                    let hits = result.hits.filter { hit in (model.summary(for: hit.sessionId)?.kind ?? .agent) == wanted }
                    if hits.isEmpty {
                        Text("No transcript mentions it.").font(CDS.caption).foregroundStyle(CDS.textMuted).listRowBackground(CDS.surface0)
                    }
                    ForEach(hits) { hit in
                        ZStack {
                            NavigationLink(value: hit.sessionId) { EmptyView() }.opacity(0)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(hit.title).font(CDS.body).foregroundStyle(CDS.textPrimary).lineLimit(1)
                                Text(hit.snippet).font(CDS.caption).foregroundStyle(CDS.textSecondary).lineLimit(2)
                                HStack(spacing: 5) {
                                    Text((hit.cwd as NSString).lastPathComponent)
                                    Text("·")
                                    Text(RelativeTime.string(hit.updatedAt))
                                }
                                .font(CDS.caption).foregroundStyle(CDS.textMuted)
                            }
                        }
                        .listRowBackground(CDS.surface0)
                        .listRowSeparator(.hidden)
                        .simultaneousGesture(TapGesture().onEnded { model.pendingFind[hit.sessionId] = q })
                    }
                }
            } header: { sectionHeader("In transcripts") }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ConnectionBanner()
            if let error = model.errorBanner {
                CDSBanner(kind: .danger, text: error, systemImage: "exclamationmark.triangle.fill") { model.errorBanner = nil }
            }
            if model.hostNeedsUpdate {
                CDSBanner(kind: .warning, text: "The ClaudeRemote Host app on the Mac is older than this app — update it to use chats and Codex.", systemImage: "arrow.down.circle")
            }
            if model.host?.loggedIn == false {
                CDSBanner(kind: .warning, text: "claude on the Mac is not logged in — run `claude auth login` there.", systemImage: "person.crop.circle.badge.exclamationmark")
            }
            List {
                if isChats {
                    let active = filtered.filter { $0.origin != .stored }
                    let stored = filtered.filter { $0.origin == .stored }
                    Section {
                        if model.supportsChats { newChatRow }
                    }
                    if !active.isEmpty {
                        Section {
                            ForEach(active) { session in row(session) }
                        } header: { sectionHeader("Open") }
                    }
                    if !stored.isEmpty {
                        Section {
                            ForEach(stored) { session in row(session) }
                        } header: { sectionHeader("Recent") }
                    }
                } else {
                    Section {
                        Button { newSessionCwd = nil; showNewSession = true } label: {
                            newRowLabel("New session", systemImage: "plus")
                        }
                        .disabled(!model.isConnected)
                        .listRowBackground(CDS.surface0)
                        .listRowSeparator(.hidden)
                    }
                    if !pinned.isEmpty {
                        Section {
                            ForEach(pinned) { session in row(session) }
                        } header: { sectionHeader("Pinned") }
                    }
                    ForEach(projectGroups) { group in
                        Section {
                            if !isCollapsed(group) {
                                ForEach(group.sessions) { session in row(session) }
                            }
                        } header: { projectHeader(group) }
                    }
                }
                transcriptHits
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(CDS.surface0)
            .searchable(text: $search, prompt: isChats ? "Search chats" : "Search sessions and transcripts")
            .onChange(of: search) { _, q in
                searchTask?.cancel()
                let trimmed = q.trimmingCharacters(in: .whitespaces)
                guard trimmed.count >= 2, model.isConnected else { return }
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    guard !Task.isCancelled else { return }
                    model.searchSessions(trimmed)
                }
            }
            .refreshable { model.refresh() }
            .overlay {
                if filtered.isEmpty, model.isConnected {
                    Text(isChats ? (model.supportsChats ? "No chats yet" : "Update the Mac app to use chats") : "No sessions yet")
                        .font(CDS.body).foregroundStyle(CDS.textMuted)
                        .multilineTextAlignment(.center).padding(.horizontal, 32)
                }
            }
        }
        .background(CDS.surface0)
        .toolbarBackground(CDS.surface0, for: .navigationBar)
        .navigationTitle(isChats ? "Chats" : (model.activeMac?.displayName ?? "Sessions"))
        .navigationBarTitleDisplayMode(.inline)
        // Tapping the title switches between paired Macs (the title shows a chevron when a menu is attached).
        .toolbarTitleMenu {
            MacSwitcherMenu(showAddMac: $showAddMac)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                SimulatorToolbarButton(isPresented: $showSimulator)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
                    if archivedCount > 0 || showArchived {
                        Toggle(isOn: $showArchived) { Label("Show archived (\(archivedCount))", systemImage: "archivebox") }
                    }
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                    Divider()
                    Button("Add Mac…", systemImage: "plus") { showAddMac = true }
                    Button("Forget this Mac", systemImage: "minus.circle", role: .destructive) { confirmForget = true }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(CDS.textSecondary)
                }
            }
        }
        .confirmationDialog(
            "Forget \(model.activeMac?.displayName ?? "this Mac")?",
            isPresented: $confirmForget, titleVisibility: .visible
        ) {
            Button("Forget", role: .destructive) {
                if let id = model.activeMacId { model.forget(id) }
            }
        } message: {
            Text("You'll need to scan its pairing QR code again to reconnect.")
        }
        .sheet(isPresented: $showNewSession) {
            NewSessionView(initialCwd: newSessionCwd)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showAddMac) { PairingView() }
        .sheet(isPresented: $showSimulator) { SimulatorView() }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Save") {
                if let s = renaming { model.renameSession(s.id, title: renameText) }
                renaming = nil
            }
            .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("The title is saved with the session on the Mac.")
        }
        .onAppear {
            if model.isConnected { model.refresh() }
            if collapsedProjects.isEmpty { collapsedProjects = Self.loadCollapsed() }
        }
        .onChange(of: collapsedProjects) { _, new in Self.saveCollapsed(new) }
    }

    private static let collapsedKey = "collapsedProjects"
    private static func loadCollapsed() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: collapsedKey) ?? [])
    }
    private static func saveCollapsed(_ set: Set<String>) {
        UserDefaults.standard.set(Array(set), forKey: collapsedKey)
    }

    /// One tap starts a chat; with Codex around, the agent is picked from a menu.
    @ViewBuilder
    private var newChatRow: some View {
        Group {
            if model.hasCodex {
                Menu {
                    Button("Chat with Claude") { model.startChat(.claude) }
                    Button("Chat with Codex") { model.startChat(.codex) }
                } label: {
                    newRowLabel("New chat", systemImage: "bubble.left.and.bubble.right")
                }
            } else {
                Button { model.startChat(.claude) } label: {
                    newRowLabel("New chat", systemImage: "bubble.left.and.bubble.right")
                }
            }
        }
        .disabled(!model.isConnected)
        .listRowBackground(CDS.surface0)
        .listRowSeparator(.hidden)
    }

    private func newRowLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(CDS.fillNeutral, in: RoundedRectangle(cornerRadius: CDS.radiusSmall))
            Text(title).font(CDS.bodyMedium)
        }
        .foregroundStyle(model.isConnected ? CDS.textPrimary : CDS.textMuted)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(CDS.textMuted)
            .textCase(.uppercase)
            .padding(.top, 6)
            .listRowInsets(EdgeInsets(top: 0, leading: CDS.gutter, bottom: 4, trailing: CDS.gutter))
    }

    /// A search always reveals matches, so collapse only applies when not searching.
    private func isCollapsed(_ group: ProjectGroup) -> Bool {
        search.trimmingCharacters(in: .whitespaces).isEmpty && collapsedProjects.contains(group.id)
    }

    /// How many sessions in a project are waiting on the user — shown as a badge even when collapsed.
    private func pendingCount(_ group: ProjectGroup) -> Int {
        group.sessions.filter { $0.status == .awaitingPermission || model.pendingPermission(for: $0.id) != nil }.count
    }

    /// Collapsible project header with a "+" to start a session in that project — the Claude Code sidebar look.
    private func projectHeader(_ group: ProjectGroup) -> some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if collapsedProjects.contains(group.id) { collapsedProjects.remove(group.id) }
                    else { collapsedProjects.insert(group.id) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isCollapsed(group) ? 0 : 90))
                    Text(group.name)
                        .font(.caption2.weight(.semibold)).textCase(.uppercase)
                    Text("\(group.sessions.count)")
                        .font(.caption2).foregroundStyle(CDS.textMuted.opacity(0.6))
                    if pendingCount(group) > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "bell.badge.fill").font(.system(size: 9))
                            Text("\(pendingCount(group))").font(.caption2.weight(.bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(CDS.warningFill, in: Capsule())
                        .textCase(nil)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { newSessionCwd = group.cwd; showNewSession = true } label: {
                Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!model.isConnected)
        }
        .foregroundStyle(CDS.textMuted)
        .padding(.top, 6)
        .listRowInsets(EdgeInsets(top: 0, leading: CDS.gutter, bottom: 4, trailing: CDS.gutter))
    }

    private func row(_ session: SessionSummary) -> some View {
        ZStack {
            // Sidebar rows navigate without a disclosure chevron; the link stays for the tap.
            NavigationLink(value: session.id) { EmptyView() }.opacity(0)
            HStack(alignment: .top, spacing: 10) {
                StatusDot(status: session.status, origin: session.origin, agent: session.agent)
                    .frame(width: 8)
                    .padding(.top, 7)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        if model.pinnedSessions.contains(session.id) {
                            Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(CDS.textMuted)
                        }
                        Text(session.title)
                            .font(CDS.body)
                            .foregroundStyle(CDS.textPrimary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 5) {
                        if session.kind == .chat {
                            Text(session.agent.label).foregroundStyle(session.agent.tint).lineLimit(1)
                        } else {
                            Text(session.projectName).lineLimit(1)
                        }
                        Text("·")
                        Text(RelativeTime.string(session.updatedAt))
                        if session.origin == .desktop { CDSChip(text: session.sourceLabel, style: .agent(session.agent.tint)) }
                        if session.kind == .agent, session.origin == .host { CDSChip(text: "Phone", systemImage: "iphone") }
                        if session.kind == .agent, session.agent == .codex, session.origin != .desktop {
                            CDSChip(text: "Codex", style: .agent(CDS.agentCodex))
                        }
                        if session.status == .awaitingPermission || model.pendingPermission(for: session.id) != nil {
                            CDSChip(text: "Needs approval", style: .warning)
                        }
                    }
                    .font(CDS.caption).foregroundStyle(CDS.textMuted)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        }
        .listRowBackground(CDS.surface0)
        .listRowSeparator(.hidden)
        .contextMenu {
            Button("Rename…", systemImage: "pencil") { renameText = session.title; renaming = session }
                .disabled(!model.isConnected)
            if model.pinnedSessions.contains(session.id) {
                Button("Unpin", systemImage: "pin.slash") { model.setPinned(session.id, false) }
            } else {
                Button("Pin", systemImage: "pin") { model.setPinned(session.id, true) }
            }
            if model.archivedSessions.contains(session.id) {
                Button("Unarchive", systemImage: "tray.and.arrow.up") { model.setArchived(session.id, false) }
            } else {
                Button("Archive", systemImage: "archivebox") { model.setArchived(session.id, true) }
            }
        }
        .swipeActions(edge: .leading) {
            Button { model.setPinned(session.id, !model.pinnedSessions.contains(session.id)) } label: {
                Label(model.pinnedSessions.contains(session.id) ? "Unpin" : "Pin", systemImage: "pin")
            }
            .tint(CDS.accent)
        }
        .swipeActions(edge: .trailing) {
            Button { model.setArchived(session.id, !model.archivedSessions.contains(session.id)) } label: {
                Label(model.archivedSessions.contains(session.id) ? "Unarchive" : "Archive", systemImage: "archivebox")
            }
            .tint(CDS.textMuted)
        }
    }
}

/// The paired Macs with a checkmark on the current one, plus "Add Mac…". Lives in the title menu of
/// the session list; picking a Mac reconnects the whole app to it.
struct MacSwitcherMenu: View {
    @Environment(AppModel.self) private var model
    @Binding var showAddMac: Bool

    var body: some View {
        Picker("Mac", selection: Binding(get: { model.activeMacId ?? "" }, set: { model.switchTo($0) })) {
            ForEach(model.macs) { mac in
                Label(mac.displayName, systemImage: "desktopcomputer").tag(mac.id)
            }
        }
        .pickerStyle(.inline)
        Button("Add Mac…", systemImage: "plus") { showAddMac = true }
    }
}

enum RelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func string(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 { return "now" }
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Session state at a glance: clay pulse while working, yellow when waiting on you.
struct StatusDot: View {
    let status: SessionStatus
    let origin: SessionOrigin
    var agent: AgentKind = .claude
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(status == .running && pulsing ? 0.35 : 1)
            .animation(status == .running ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: pulsing)
            .onAppear { pulsing = true }
    }

    private var color: Color {
        switch status {
        case .running: return agent.tint
        case .awaitingPermission: return CDS.warningFill
        case .idle: return origin == .stored ? .clear : CDS.textMuted.opacity(0.6)
        case .exited: return CDS.dangerFill
        case .unknown: return .clear
        }
    }
}
