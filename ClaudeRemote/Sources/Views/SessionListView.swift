import SwiftUI
import ClaudeRemoteCore

struct SessionListView: View {
    @Environment(AppModel.self) private var model
    @State private var showNewSession = false
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
                HStack {
                    Text(error).font(.footnote).lineLimit(3)
                    Spacer()
                    Button { model.errorBanner = nil } label: { Image(systemName: "xmark") }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color.red.opacity(0.12))
            }
            if model.connection.host?.loggedIn == false {
                Text("claude on the Mac is not logged in — run `claude auth login` there.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color.yellow.opacity(0.15))
            }
            List {
                let active = filtered.filter { $0.origin != .stored }
                let stored = filtered.filter { $0.origin == .stored }
                if !active.isEmpty {
                    Section("Active on Mac") {
                        ForEach(active) { session in row(session) }
                    }
                }
                Section(stored.isEmpty ? "" : "Recent") {
                    ForEach(stored) { session in row(session) }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, prompt: "Search sessions")
            .refreshable { model.refresh() }
        }
        .navigationTitle(model.connection.host?.hostName ?? "Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("Refresh") { model.refresh() }
                    Button("Unpair", role: .destructive) { model.unpair() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNewSession = true } label: { Image(systemName: "plus") }
                    .disabled(!model.isConnected)
            }
        }
        .sheet(isPresented: $showNewSession) {
            NewSessionView()
        }
        .onAppear { if model.isConnected { model.refresh() } }
    }

    private func row(_ session: SessionSummary) -> some View {
        NavigationLink(value: session.id) {
            HStack(alignment: .top, spacing: 10) {
                StatusDot(status: session.status, origin: session.origin)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title).font(.body).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(session.projectName).lineLimit(1)
                        Text("·")
                        Text(RelativeTime.string(session.updatedAt))
                        if session.origin == .desktop { OriginBadge(text: session.sourceLabel) }
                        if session.origin == .host { OriginBadge(text: "Phone", tint: .blue) }
                        if model.pendingPermission(for: session.id) != nil { OriginBadge(text: "Needs approval", tint: .orange) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
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

struct StatusDot: View {
    let status: SessionStatus
    let origin: SessionOrigin

    var body: some View {
        Circle().fill(color).frame(width: 9, height: 9)
    }

    private var color: Color {
        switch status {
        case .running: return .green
        case .awaitingPermission: return .orange
        case .idle: return origin == .stored ? .clear : .blue
        case .exited: return .red
        case .unknown: return .clear
        }
    }
}

struct OriginBadge: View {
    var text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}
