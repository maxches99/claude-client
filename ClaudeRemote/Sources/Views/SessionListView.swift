import SwiftUI
import ClaudeRemoteCore

/// The session sidebar: "New session" on top, then live sessions and recent transcripts.
struct SessionListView: View {
    @Environment(AppModel.self) private var model
    @State private var showNewSession = false
    @State private var showSettings = false
    @State private var showSimulator = false
    @State private var showAddMac = false
    @State private var confirmForget = false
    @State private var search = ""

    private var filtered: [SessionSummary] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.sessions }
        return model.sessions.filter { $0.title.lowercased().contains(q) || $0.projectName.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ConnectionBanner()
            if let error = model.errorBanner {
                CDSBanner(kind: .danger, text: error, systemImage: "exclamationmark.triangle.fill") { model.errorBanner = nil }
            }
            if model.connection.host?.loggedIn == false {
                CDSBanner(kind: .warning, text: "claude on the Mac is not logged in — run `claude auth login` there.", systemImage: "person.crop.circle.badge.exclamationmark")
            }
            List {
                let active = filtered.filter { $0.origin != .stored }
                let stored = filtered.filter { $0.origin == .stored }
                Section {
                    Button { showNewSession = true } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 22, height: 22)
                                .background(CDS.fillNeutral, in: RoundedRectangle(cornerRadius: CDS.radiusSmall))
                            Text("New session").font(CDS.bodyMedium)
                        }
                        .foregroundStyle(model.isConnected ? CDS.textPrimary : CDS.textMuted)
                        .padding(.vertical, 4)
                    }
                    .disabled(!model.isConnected)
                    .listRowBackground(CDS.surface0)
                    .listRowSeparator(.hidden)
                }
                if !active.isEmpty {
                    Section {
                        ForEach(active) { session in row(session) }
                    } header: {
                        sectionHeader("Active on Mac")
                    }
                }
                if !stored.isEmpty {
                    Section {
                        ForEach(stored) { session in row(session) }
                    } header: {
                        sectionHeader("Recent")
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(CDS.surface0)
            .searchable(text: $search, prompt: "Search sessions")
            .refreshable { model.refresh() }
            .overlay {
                if model.sessions.isEmpty, model.isConnected {
                    Text("No sessions yet")
                        .font(CDS.body).foregroundStyle(CDS.textMuted)
                }
            }
        }
        .background(CDS.surface0)
        .toolbarBackground(CDS.surface0, for: .navigationBar)
        .navigationTitle(model.activeMac?.displayName ?? "Sessions")
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
            NewSessionView()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showAddMac) { PairingView() }
        .sheet(isPresented: $showSimulator) { SimulatorView() }
        .onAppear { if model.isConnected { model.refresh() } }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(CDS.textMuted)
            .textCase(.uppercase)
            .padding(.top, 6)
            .listRowInsets(EdgeInsets(top: 0, leading: CDS.gutter, bottom: 4, trailing: CDS.gutter))
    }

    private func row(_ session: SessionSummary) -> some View {
        ZStack {
            // Sidebar rows navigate without a disclosure chevron; the link stays for the tap.
            NavigationLink(value: session.id) { EmptyView() }.opacity(0)
            HStack(alignment: .top, spacing: 10) {
                StatusDot(status: session.status, origin: session.origin)
                    .frame(width: 8)
                    .padding(.top, 7)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(CDS.body)
                        .foregroundStyle(CDS.textPrimary)
                        .lineLimit(2)
                    HStack(spacing: 5) {
                        Text(session.projectName).lineLimit(1)
                        Text("·")
                        Text(RelativeTime.string(session.updatedAt))
                        if session.origin == .desktop { CDSChip(text: session.sourceLabel) }
                        if session.origin == .host { CDSChip(text: "Phone", systemImage: "iphone") }
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
        case .running: return CDS.brand
        case .awaitingPermission: return CDS.warningFill
        case .idle: return origin == .stored ? .clear : CDS.textMuted.opacity(0.6)
        case .exited: return CDS.dangerFill
        case .unknown: return .clear
        }
    }
}
