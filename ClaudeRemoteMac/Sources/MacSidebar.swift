import SwiftUI
import ClaudeRemoteCore

/// The sidebar, laid out like the desktop app: chats / code toggle, search, "New", then the
/// sessions grouped by project (one line each, the open one highlighted), and the host at the bottom.
struct MacSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(MacUI.self) private var ui
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var collapsed: Set<String> = MacSidebar.loadCollapsed()
    @State private var renaming: SessionSummary?
    @State private var renameText = ""
    @State private var newSessionCwd: String?
    @State private var showNewSession = false
    @AppStorage("ccremote.mac.showArchived") private var showArchived = false
    // View options, from the filter button in the header (as in the desktop app's sidebar).
    @AppStorage("ccremote.mac.groupBy") private var groupBy: GroupBy = .folder
    @AppStorage("ccremote.mac.sortBy") private var sortBy: SortBy = .updated
    @AppStorage("ccremote.mac.onlyActive") private var onlyActive = false
    @AppStorage("ccremote.mac.showExternal") private var showExternal = true
    /// Show Claude Desktop's own pins and sections on its host (read from Desktop, never written).
    @AppStorage("ccremote.mac.followDesktop") private var followDesktop = true
    /// Bumped whenever custom sections change, so the views reading them from UserDefaults refresh.
    @State private var sectionsRevision = 0
    @State private var newSectionName = ""
    /// Set while the "New Section" alert is up; `session` is moved into it once it is made.
    @State private var newSectionFor: (macId: String, session: String?)?
    /// The search field shows once the magnifier at the bottom (or ⌘F in the sidebar) asks for it.
    @State private var searching = false
    @FocusState private var searchFocused: Bool

    private var isChats: Bool { model.tab == .chats }
    private var unified: Bool { model.showAllMacs && model.macs.count > 1 }
    private var selectedId: String? { isChats ? model.chatPath.last : model.sessionPath.last }

    private struct Group: Identifiable {
        let id: String
        let name: String
        let macId: String
        /// nil for groups that are not one folder (a host, a custom section), so "+" asks for one.
        let cwd: String?
        var section: String? = nil
        let sessions: [MacSession]
    }

    enum GroupBy: String, CaseIterable { case folder, host, none }
    enum SortBy: String, CaseIterable { case updated, name, desktop }

    private var isDefaultView: Bool {
        groupBy == .folder && sortBy == .updated && !onlyActive && showExternal && !showArchived && followDesktop
    }

    private func ordered(_ items: [MacSession]) -> [MacSession] {
        switch sortBy {
        case .updated, .desktop: return items.sorted { $0.session.updatedAt > $1.session.updatedAt }
        case .name: return items.sorted { $0.session.title.localizedStandardCompare($1.session.title) == .orderedAscending }
        }
    }

    private func orderedGroups(_ groups: [Group]) -> [Group] {
        switch sortBy {
        case .updated: return groups.sorted { ($0.sessions.first?.session.updatedAt ?? .distantPast) > ($1.sessions.first?.session.updatedAt ?? .distantPast) }
        case .name: return groups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .desktop:
            // Desktop's project order first, the rest after it by recency.
            func rank(_ g: Group) -> Int {
                guard let cwd = g.cwd else { return Int.max }
                return model.desktopLayoutByMac[g.macId]?.projectOrder.firstIndex(of: cwd) ?? Int.max
            }
            return groups.sorted { a, b in
                let (ra, rb) = (rank(a), rank(b))
                if ra != rb { return ra < rb }
                return (a.sessions.first?.session.updatedAt ?? .distantPast) > (b.sessions.first?.session.updatedAt ?? .distantPast)
            }
        }
    }

    /// Claude Desktop's layout for a host, when the sidebar follows it.
    private func desktopLayout(_ macId: String) -> DesktopLayout? {
        followDesktop ? model.desktopLayoutByMac[macId] : nil
    }

    private func isPinned(_ item: MacSession) -> Bool {
        model.pinnedSessions.contains(item.session.id) || desktopLayout(item.macId)?.pinned.contains(item.session.id) == true
    }

    /// The Desktop section a session sits in, if any.
    private func desktopSection(of item: MacSession) -> DesktopLayout.Section? {
        desktopLayout(item.macId)?.sections.first { $0.sessionIds.contains(item.session.id) }
    }

    private var filtered: [MacSession] {
        let wanted: SessionKind = isChats ? .chat : .agent
        let base: [MacSession] = unified
            ? model.allSessions(kind: wanted)
            : model.sessions.filter { $0.kind == wanted }.map { MacSession(macId: model.activeMacId ?? "", session: $0) }
        let scoped = base.filter {
            (showArchived || !model.archivedSessions.contains($0.session.id))
                && (!onlyActive || $0.session.status == .running || $0.session.status == .awaitingPermission)
                && (showExternal || $0.session.origin != .desktop)
        }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return ordered(scoped) }
        return ordered(scoped.filter { $0.session.title.lowercased().contains(q) || $0.session.projectName.lowercased().contains(q) })
    }

    private var pinned: [MacSession] { filtered.filter(isPinned) }

    /// Unpinned sessions outside any custom section.
    private var ungrouped: [MacSession] {
        filtered.filter { !isPinned($0) && section(of: $0) == nil && desktopSection(of: $0) == nil }
    }

    private var groups: [Group] {
        let items = ungrouped
        switch groupBy {
        case .none:
            return []
        case .host:
            return orderedGroups(Dictionary(grouping: items, by: \.macId).map { macId, sessions in
                Group(id: "host:" + macId, name: model.macName(macId), macId: macId, cwd: nil, sessions: ordered(sessions))
            })
        case .folder:
            return orderedGroups(Dictionary(grouping: items) { "\($0.macId)\n\($0.session.cwd)" }.map { key, sessions in
                let sorted = ordered(sessions)
                let first = sorted.first
                let name = (first?.session.projectName ?? "") + (unified ? " · " + model.macName(first?.macId ?? "") : "")
                return Group(id: key, name: name, macId: first?.macId ?? "", cwd: first?.session.cwd ?? "", sessions: sorted)
            })
        }
    }

    /// Custom sections of the hosts in view, in the order they were made, empty ones included.
    private var sectionGroups: [Group] {
        let macIds = unified ? model.macs.map(\.id) : [model.activeMacId ?? ""]
        let candidates = filtered.filter { !isPinned($0) }
        let desktop = macIds.flatMap { macId in
            (desktopLayout(macId)?.sections ?? []).map { section in
                let members = candidates.filter { $0.macId == macId && section.sessionIds.contains($0.session.id) }
                return Group(id: "desktop:\(macId)\n\(section.id)", name: section.name + (unified ? " · " + model.macName(macId) : ""),
                             macId: macId, cwd: nil, sessions: ordered(members))
            }
        }
        return desktop + macIds.flatMap { macId in
            let store = sections(macId)
            return store.names.map { name in
                let members = candidates.filter { $0.macId == macId && store.assigned[$0.session.id] == name && desktopSection(of: $0) == nil }
                return Group(id: "section:\(macId)\n\(name)", name: name + (unified ? " · " + model.macName(macId) : ""),
                             macId: macId, cwd: nil, section: name, sessions: ordered(members))
            }
        }
    }

    // MARK: custom sections

    /// Named sections a user made on one host, and which session sits in which.
    private struct Sections: Codable {
        var names: [String] = []
        var assigned: [String: String] = [:]
    }

    private func sections(_ macId: String) -> Sections {
        _ = sectionsRevision
        guard let data = UserDefaults.standard.data(forKey: Self.sectionsKey + macId),
              let store = try? JSONDecoder().decode(Sections.self, from: data) else { return Sections() }
        return store
    }

    private func updateSections(_ macId: String, _ change: (inout Sections) -> Void) {
        var store = sections(macId)
        change(&store)
        store.assigned = store.assigned.filter { store.names.contains($0.value) }
        UserDefaults.standard.set(try? JSONEncoder().encode(store), forKey: Self.sectionsKey + macId)
        sectionsRevision += 1
    }

    private func section(of item: MacSession) -> String? { sections(item.macId).assigned[item.session.id] }

    private func move(_ item: MacSession, to name: String?) {
        updateSections(item.macId) { $0.assigned[item.session.id] = name }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            UpdateBanner()
            if searching || !search.isEmpty {
                searchField.padding(.horizontal, 10).padding(.top, 4)
            }
            ConnectionBanner()
            if let error = model.errorBanner {
                CDSBanner(kind: .danger, text: error, systemImage: "exclamationmark.triangle.fill") { model.errorBanner = nil }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if isChats {
                        ForEach(filtered) { row($0, showsProject: false) }
                    } else {
                        if !pinned.isEmpty {
                            sectionTitle("Pinned")
                            ForEach(pinned) { row($0, showsProject: true) }
                        }
                        ForEach(sectionGroups + groups) { group in
                            groupHeader(group)
                            if !collapsed.contains(group.id) || !search.isEmpty {
                                ForEach(group.sessions) { row($0, showsProject: group.cwd == nil) }
                            }
                        }
                        if groupBy == .none {
                            if !sectionGroups.isEmpty, !ungrouped.isEmpty { sectionTitle("Sessions") }
                            ForEach(ungrouped) { row($0, showsProject: true) }
                        }
                    }
                    transcriptHits
                    if filtered.isEmpty, model.isConnected, search.isEmpty {
                        Text(isChats ? "No chats yet" : "No sessions yet")
                            .font(CDS.body).foregroundStyle(CDS.textMuted)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            hostBar
        }
        .background(CDS.surface0)
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
        .onChange(of: collapsed) { _, new in UserDefaults.standard.set(Array(new), forKey: Self.collapsedKey) }
        // Desktop's pins and sections change while it runs; it saves them to its settings file.
        .task(id: "\(followDesktop)\(model.activeMacId ?? "")\(model.isConnected)") {
            while followDesktop, !Task.isCancelled {
                for macId in unified ? model.macs.map(\.id) : [model.activeMacId].compactMap({ $0 }) { model.loadDesktopLayout(mac: macId) }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        .sheet(isPresented: $showNewSession) {
            NewSessionView(initialCwd: newSessionCwd).formStyle(.grouped).frame(minWidth: 560, minHeight: 520)
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Save") {
                if let s = renaming { model.renameSession(s.id, title: renameText) }
                renaming = nil
            }
            .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("The title is saved with the session on the host.")
        }
        .alert("New Section", isPresented: Binding(get: { newSectionFor != nil }, set: { if !$0 { newSectionFor = nil } })) {
            TextField("Name", text: $newSectionName)
            Button("Create") {
                let name = newSectionName.trimmingCharacters(in: .whitespaces)
                if let target = newSectionFor, !name.isEmpty {
                    updateSections(target.macId) { store in
                        if !store.names.contains(name) { store.names.append(name) }
                        if let id = target.session { store.assigned[id] = name }
                    }
                }
                newSectionFor = nil
            }
            .disabled(newSectionName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { newSectionFor = nil }
        } message: {
            Text("Sections are kept on this Mac, per host. Move sessions in from their context menu.")
        }
    }

    // MARK: top

    /// Chats / code, as the two-icon toggle in the corner of the desktop app's sidebar.
    private var header: some View {
        HStack(spacing: 8) {
            Button {
                if isChats { model.startChat(model.defaultAgent) } else { newSessionCwd = nil; showNewSession = true }
            } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 13, weight: .medium)).frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(CDS.textSecondary)
            .disabled(!model.isConnected)
            .help(isChats ? "New chat (⇧⌘N)" : "New session (⌘N)")
            viewOptionsMenu
            Spacer()
            ApprovalsToolbarButton(isPresented: Binding(get: { ui.sheet == .inbox }, set: { ui.sheet = $0 ? .inbox : nil }))
                .buttonStyle(.plain)
            HStack(spacing: 2) {
                modeButton(.chats, systemImage: "bubble.left.and.text.bubble.right", help: "Chats")
                modeButton(.sessions, systemImage: "chevron.left.forwardslash.chevron.right", help: "Code sessions")
            }
            .padding(2)
            .background(CDS.fillNeutral, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
    }

    /// Group, sort and filter the list, like the filter button over the desktop app's sidebar.
    private var viewOptionsMenu: some View {
        Menu {
            if !isChats {
                Picker("Group by", selection: $groupBy) {
                    Text("Folder").tag(GroupBy.folder)
                    Text("Host").tag(GroupBy.host)
                    Text("None").tag(GroupBy.none)
                }
                .pickerStyle(.menu)
            }
            Picker("Sort by", selection: $sortBy) {
                Text("Last Updated").tag(SortBy.updated)
                Text("Name").tag(SortBy.name)
                if !isChats { Text("Desktop Order").tag(SortBy.desktop) }
            }
            .pickerStyle(.menu)
            Menu("Show") {
                Toggle("Archived Sessions", isOn: $showArchived)
                Toggle("Only Running or Awaiting", isOn: $onlyActive)
                Toggle("Desktop & Terminal Sessions", isOn: $showExternal)
                Toggle("Claude Desktop's Pins & Sections", isOn: $followDesktop)
            }
            if !isChats {
                Divider()
                Button("New Section…") { newSectionName = ""; newSectionFor = (model.activeMacId ?? "", nil) }
                    .disabled(model.activeMacId == nil)
            }
            Divider()
            Button("Reset to Defaults") {
                groupBy = .folder; sortBy = .updated; onlyActive = false; showExternal = true; showArchived = false; followDesktop = true
            }
            .disabled(isDefaultView)
            Button("View All") {
                onlyActive = false; showExternal = true; search = ""
                withAnimation(.easeInOut(duration: 0.15)) { collapsed = [] }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isDefaultView ? CDS.textSecondary : CDS.brand)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Group, sort and filter")
    }

    private func modeButton(_ tab: AppTab, systemImage: String, help: String) -> some View {
        Button { model.tab = tab } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(model.tab == tab ? CDS.textPrimary : CDS.textMuted)
                .frame(width: 30, height: 24)
                .background(model.tab == tab ? CDS.surface3 : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(CDS.textMuted)
            TextField("Search", text: $search)
                .textFieldStyle(.plain)
                .font(CDS.body)
                .focused($searchFocused)
                .onExitCommand { search = ""; searching = false }
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(CDS.textMuted) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(CDS.fillNeutral, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: list

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(CDS.caption).foregroundStyle(CDS.textMuted)
            .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 4)
    }

    private func groupHeader(_ group: Group) -> some View {
        let isCollapsed = collapsed.contains(group.id)
        let busy = group.sessions.contains { $0.session.status == .running || $0.session.status == .awaitingPermission }
        return GroupHeader {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isCollapsed { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(group.name).lineLimit(1)
                    Chevron(expanded: !isCollapsed)
                    if busy { Circle().fill(CDS.brand).frame(width: 6, height: 6) }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } trailing: {
            if group.section == nil {
                Button {
                    if group.macId != model.activeMacId { model.switchTo(group.macId) }
                    newSessionCwd = group.cwd
                    showNewSession = true
                } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.isConnected)
                .help("New session in \(group.name)")
            }
        }
        .font(CDS.body)
        .foregroundStyle(CDS.textMuted)
        .padding(.top, 10)
        .contextMenu {
            if let name = group.section {
                // Its sessions go back to their folders.
                Button("Delete Section") { updateSections(group.macId) { $0.names.removeAll { $0 == name } } }
            }
        }
    }

    private func row(_ item: MacSession, showsProject: Bool) -> some View {
        let session = item.session
        let selected = selectedId == session.id && item.macId == model.activeMacId
        return SidebarButton(selected: selected) {
            model.open(item)
        } label: {
            if session.status == .running || session.status == .awaitingPermission {
                StatusDot(status: session.status, origin: session.origin, agent: session.agent)
            }
            Text(session.title)
                .font(CDS.prose)
                .foregroundStyle(CDS.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if showsProject {
                Text(session.projectName).font(CDS.caption).foregroundStyle(CDS.textMuted).lineLimit(1)
            }
            if session.origin == .desktop {
                Image(systemName: "desktopcomputer").font(.system(size: 10)).foregroundStyle(CDS.textMuted)
                    .help(session.sourceLabel)
            }
        }
        .contextMenu {
            if item.macId != model.activeMacId {
                Button("Switch to \(model.macName(item.macId))") { model.switchTo(item.macId) }
            }
            Button("Rename…") { renameText = session.title; renaming = session }
                .disabled(!model.isConnected)
            if model.pinnedSessions.contains(session.id) {
                Button("Unpin") { model.setPinned(session.id, false) }
            } else {
                Button("Pin") { model.setPinned(session.id, true) }
            }
            if model.archivedSessions.contains(session.id) {
                Button("Unarchive") { model.setArchived(session.id, false) }
            } else {
                Button("Archive") { model.setArchived(session.id, true) }
            }
            if !isChats, !model.pinnedSessions.contains(session.id) {
                let current = section(of: item)
                Menu("Move to Section") {
                    ForEach(sections(item.macId).names, id: \.self) { name in
                        Button { move(item, to: name) } label: {
                            if name == current { Label(name, systemImage: "checkmark") } else { Text(name) }
                        }
                    }
                    if current != nil { Button("Remove from Section") { move(item, to: nil) } }
                    Divider()
                    Button("New Section…") { newSectionName = ""; newSectionFor = (item.macId, session.id) }
                }
            }
            Button("Open in New Window") {
                if item.macId != model.activeMacId { model.switchTo(item.macId) }
                openWindow(id: MacUI.sessionWindowId, value: SessionWindowRef(macId: item.macId, sessionId: session.id))
            }
            Divider()
            Button("Copy Session ID") { UIPasteboard.general.string = session.id }
        }
    }

    /// Transcript hits from the host for the current query.
    @ViewBuilder private var transcriptHits: some View {
        let q = search.trimmingCharacters(in: .whitespaces)
        if q.count >= 2 {
            sectionTitle("In transcripts")
            if model.sessionSearchInFlight, model.sessionSearch?.query != q {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Searching…").font(CDS.caption).foregroundStyle(CDS.textMuted) }
                    .padding(.horizontal, 8)
            } else if let result = model.sessionSearch, result.query == q {
                if result.hits.isEmpty {
                    Text("No transcript mentions it.").font(CDS.caption).foregroundStyle(CDS.textMuted).padding(.horizontal, 8)
                }
                ForEach(result.hits) { hit in
                    SidebarButton(selected: selectedId == hit.sessionId) {
                        model.pendingFind[hit.sessionId] = q
                        model.openDeepLink(sessionId: hit.sessionId)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.title).font(CDS.body).foregroundStyle(CDS.textSecondary).lineLimit(1)
                            Text(hit.snippet).font(CDS.caption).foregroundStyle(CDS.textMuted).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    // MARK: bottom

    /// The host this window is talking to, where the desktop app shows the account: switch, add, settings.
    private var hostBar: some View {
        HStack(spacing: 6) {
            hostMenu
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")
            Button {
                searching.toggle()
                if searching { DispatchQueue.main.async { searchFocused = true } } else { search = "" }
            } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.plain)
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .help("Search sessions and transcripts (⇧⌘F)")
        }
        .font(.system(size: 13))
        .foregroundStyle(CDS.textSecondary)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(CDS.border).frame(height: 1) }
    }

    private var hostMenu: some View {
        Menu {
            ForEach(model.macs) { mac in
                Button {
                    model.switchTo(mac.id)
                } label: {
                    if mac.id == model.activeMacId { Label(mac.displayName, systemImage: "checkmark") } else { Text(mac.displayName) }
                }
            }
            Divider()
            if model.macs.count > 1 {
                Toggle("Show Every Host", isOn: Binding(get: { model.showAllMacs }, set: { model.showAllMacs = $0 }))
            }
            Toggle("Show Archived", isOn: $showArchived)
            if let hook = model.permissionHookOn, !model.isMember {
                // Sessions in the desktop app or a terminal on the host ask here before prompting there.
                Toggle("Approve Desktop Sessions Here", isOn: Binding(get: { hook }, set: { model.setPermissionHook($0) }))
            }
            Divider()
            Button("Add Host…") { ui.sheet = .addHost }
            SettingsLink { Text("Settings…") }
        } label: {
            HStack(spacing: 8) {
                Text(initials(model.activeMac?.displayName ?? "?"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CDS.textPrimary)
                    .frame(width: 24, height: 24)
                    .background(CDS.fillControl, in: Circle())
                    .overlay(alignment: .bottomTrailing) {
                        Circle().fill(model.isConnected ? CDS.successFill : CDS.textMuted)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().strokeBorder(CDS.surface0, lineWidth: 1.5))
                    }
                // "Max · Connected ⌄", where the desktop app shows the account.
                (Text(model.activeMac?.displayName ?? "No host").font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary)
                 + Text(" · " + model.connection.status.label).font(CDS.body).foregroundStyle(CDS.textMuted))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(CDS.textMuted)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2)
        let letters = words.compactMap(\.first).map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "?" : letters
    }

    private static let collapsedKey = "ccremote.mac.collapsedProjects"
    private static let sectionsKey = "ccremote.mac.sections."
    private static func loadCollapsed() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: collapsedKey) ?? [])
    }
}

/// A full-width sidebar row: highlighted when selected, a lighter fill on hover.
private struct SidebarButton<Label: View>: View {
    var selected = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) { label() }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? CDS.fillControl : (hovering ? CDS.fillNeutral : .clear), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A project header whose trailing "+" only shows on hover, as in the desktop app.
private struct GroupHeader<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            leading()
            trailing().opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .onHover { hovering = $0 }
    }
}
