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
    @State private var showArchived = false

    private var isChats: Bool { model.tab == .chats }
    private var unified: Bool { model.showAllMacs && model.macs.count > 1 }
    private var selectedId: String? { isChats ? model.chatPath.last : model.sessionPath.last }

    private struct Group: Identifiable {
        let id: String
        let name: String
        let macId: String
        let cwd: String
        let sessions: [MacSession]
    }

    private var filtered: [MacSession] {
        let wanted: SessionKind = isChats ? .chat : .agent
        let base: [MacSession] = unified
            ? model.allSessions(kind: wanted)
            : model.sessions.filter { $0.kind == wanted }.map { MacSession(macId: model.activeMacId ?? "", session: $0) }
        let scoped = base.filter { showArchived || !model.archivedSessions.contains($0.session.id) }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return scoped.sorted { $0.session.updatedAt > $1.session.updatedAt } }
        return scoped.filter { $0.session.title.lowercased().contains(q) || $0.session.projectName.lowercased().contains(q) }
    }

    private var pinned: [MacSession] { filtered.filter { model.pinnedSessions.contains($0.session.id) } }

    private var groups: [Group] {
        Dictionary(grouping: filtered.filter { !model.pinnedSessions.contains($0.session.id) }) { "\($0.macId)\n\($0.session.cwd)" }
            .map { key, items in
                let sorted = items.sorted { $0.session.updatedAt > $1.session.updatedAt }
                let first = sorted.first
                let name = (first?.session.projectName ?? "") + (unified ? " · " + model.macName(first?.macId ?? "") : "")
                return Group(id: key, name: name, macId: first?.macId ?? "", cwd: first?.session.cwd ?? "", sessions: sorted)
            }
            .sorted { ($0.sessions.first?.session.updatedAt ?? .distantPast) > ($1.sessions.first?.session.updatedAt ?? .distantPast) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            UpdateBanner()
            searchField.padding(.horizontal, 10).padding(.top, 4)
            newRow.padding(.horizontal, 10).padding(.top, 6)
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
                        ForEach(groups) { group in
                            groupHeader(group)
                            if !collapsed.contains(group.id) || !search.isEmpty {
                                ForEach(group.sessions) { row($0, showsProject: false) }
                            }
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
    }

    // MARK: top

    /// Chats / code, as the two-icon toggle in the corner of the desktop app's sidebar.
    private var header: some View {
        HStack(spacing: 8) {
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
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(CDS.textMuted) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(CDS.fillNeutral, in: RoundedRectangle(cornerRadius: 8))
    }

    private var newRow: some View {
        SidebarButton {
            if isChats { model.startChat(model.defaultAgent) } else { newSessionCwd = nil; showNewSession = true }
        } label: {
            Image(systemName: "plus").font(.system(size: 13, weight: .medium)).frame(width: 16)
            Text(isChats ? "New chat" : "New session").font(CDS.body)
            Spacer()
        }
        .disabled(!model.isConnected)
        .foregroundStyle(CDS.textPrimary)
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
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    if busy { Circle().fill(CDS.brand).frame(width: 6, height: 6) }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } trailing: {
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
        .font(CDS.body)
        .foregroundStyle(CDS.textMuted)
        .padding(.top, 10)
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
                .font(CDS.body)
                .foregroundStyle(selected ? CDS.textPrimary : CDS.textSecondary)
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
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.activeMac?.displayName ?? "No host").font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary).lineLimit(1)
                    Text(model.connection.status.label).font(CDS.caption).foregroundStyle(CDS.textMuted).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(CDS.textMuted)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(CDS.border).frame(height: 1) }
    }

    private func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2)
        let letters = words.compactMap(\.first).map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "?" : letters
    }

    private static let collapsedKey = "ccremote.mac.collapsedProjects"
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
