import SwiftUI
import ClaudeRemoteCore

extension AppModel {
    /// Sessions in the order the sidebar lists them (pinned first, then projects by their latest
    /// session), without archived ones — what ⌥⌘↑ / ⌥⌘↓ step through.
    func sidebarOrder(kind: SessionKind) -> [MacSession] {
        let base: [MacSession] = showAllMacs && macs.count > 1
            ? allSessions(kind: kind)
            : sessions.filter { $0.kind == kind }.map { MacSession(macId: activeMacId ?? "", session: $0) }
        let visible = base.filter { !archivedSessions.contains($0.session.id) }
            .sorted { $0.session.updatedAt > $1.session.updatedAt }
        if kind == .chat { return visible }
        let pinned = visible.filter { pinnedSessions.contains($0.session.id) }
        let rest = visible.filter { !pinnedSessions.contains($0.session.id) }
        let groups = Dictionary(grouping: rest) { "\($0.macId)\n\($0.session.cwd)" }.values
            .map { $0.sorted { $0.session.updatedAt > $1.session.updatedAt } }
            .sorted { ($0.first?.session.updatedAt ?? .distantPast) > ($1.first?.session.updatedAt ?? .distantPast) }
        return pinned + groups.flatMap { $0 }
    }

    /// Opens the session `offset` places away from the open one in the sidebar's order.
    func stepSession(_ offset: Int) {
        let kind: SessionKind = tab == .chats ? .chat : .agent
        let order = sidebarOrder(kind: kind)
        guard !order.isEmpty else { return }
        let current = tab == .chats ? chatPath.last : sessionPath.last
        let index = order.firstIndex { $0.session.id == current && $0.macId == activeMacId }
        let next = index.map { min(max($0 + offset, 0), order.count - 1) } ?? 0
        open(order[next])
    }
}

/// ⌘K: jump to any session or chat by name, or run a command — arrows to move, Return to go.
struct MacQuickOpen: View {
    @Environment(AppModel.self) private var model
    @Environment(MacUI.self) private var ui
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private struct Item: Identifiable {
        let id: String
        let icon: String
        let title: String
        var detail: String = ""
        let run: () -> Void
    }

    private var items: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var actions: [Item] = [
            Item(id: "new-session", icon: "plus", title: "New session") { ui.tab(.sessions); ui.sheet = .newSession },
            Item(id: "new-chat", icon: "bubble.left", title: "New chat") { ui.tab(.chats); model.startChat(model.defaultAgent) },
            Item(id: "inbox", icon: "tray.full", title: "Approvals inbox") { ui.sheet = .inbox },
            Item(id: "terminal", icon: "apple.terminal", title: ui.showTerminal ? "Hide terminal" : "Show terminal") { ui.showTerminal.toggle() },
            Item(id: "refresh", icon: "arrow.clockwise", title: "Refresh") { model.refresh() },
            Item(id: "settings", icon: "gearshape", title: "Settings") { openSettings() },
        ]
        if model.supportsQueue { actions.append(Item(id: "tasks", icon: "list.bullet.rectangle", title: "Task queue") { ui.sheet = .tasks }) }
        if model.supportsMacTools { actions.append(Item(id: "terminals", icon: "rectangle.stack", title: "All terminals") { ui.sheet = .terminals }) }
        for mac in model.macs where mac.id != model.activeMacId {
            actions.append(Item(id: "host-\(mac.id)", icon: "desktopcomputer", title: "Switch to \(mac.displayName)") { model.switchTo(mac.id) })
        }
        let sessions = (model.sidebarOrder(kind: .agent) + model.sidebarOrder(kind: .chat)).map { item in
            Item(id: "s-\(item.macId)-\(item.session.id)", icon: item.session.kind == .chat ? "bubble.left.and.bubble.right" : "chevron.left.forwardslash.chevron.right",
                 title: item.session.title,
                 detail: item.session.kind == .chat ? "Chat" : item.session.projectName) { model.open(item) }
        }
        guard !q.isEmpty else { return Array((sessions.prefix(8) + actions)) }
        func matches(_ item: Item) -> Bool { item.title.lowercased().contains(q) || item.detail.lowercased().contains(q) }
        return Array((sessions.filter(matches) + actions.filter(matches)).prefix(40))
    }

    var body: some View {
        let list = items
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(CDS.textMuted)
                TextField("Sessions, chats and commands", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onKeyPress(.downArrow) { move(1, in: list.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, in: list.count); return .handled }
                    .onSubmit { run(list) }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                            Button { run(list, at: index) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: item.icon).frame(width: 18).foregroundStyle(CDS.textMuted)
                                    Text(item.title).foregroundStyle(CDS.textPrimary).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(item.detail).font(CDS.caption).foregroundStyle(CDS.textMuted).lineLimit(1)
                                }
                                .font(CDS.body)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(index == highlighted ? CDS.fillControl : .clear, in: RoundedRectangle(cornerRadius: 7))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: highlighted) { _, i in proxy.scrollTo(i) }
            }
        }
        .frame(width: 560, height: 420)
        .background(CDS.surface1)
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onAppear { focused = true }
    }

    private func move(_ delta: Int, in count: Int) {
        guard count > 0 else { return }
        highlighted = (highlighted + delta + count) % count
    }

    private func run(_ list: [Item], at index: Int? = nil) {
        let i = index ?? highlighted
        guard list.indices.contains(i) else { return }
        let item = list[i]
        dismiss()
        // Let the palette go before what it opens (a sheet can't present over a closing one).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { item.run() }
    }
}
