import SwiftUI
import ClaudeRemoteCore

struct WatchRootView: View {
    @Environment(WatchClient.self) private var client
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch client.status {
                case .noPairing:
                    hint("Open ClaudeRemote on your iPhone and pair a Mac — it syncs here automatically.", systemImage: "iphone")
                case .connecting:
                    VStack(spacing: 8) { ProgressView(); Text("Connecting…").font(.footnote).foregroundStyle(.secondary) }
                case .offline:
                    hint("Can't reach \(client.hostName). It reconnects on its own.", systemImage: "wifi.exclamationmark")
                case .connected:
                    SessionListView()
                }
            }
            .navigationTitle("ccremote")
            .navigationDestination(for: String.self) { SessionDetailView(sessionId: $0) }
        }
        .onOpenURL { url in
            // From the complication: ccwatch://session/<id> jumps to that session; ccwatch://open just opens.
            guard url.scheme == "ccwatch" else { return }
            if url.host == "session" {
                let id = url.lastPathComponent
                if !id.isEmpty { path = [id] }
            } else {
                path = []
            }
        }
    }

    private func hint(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.title2).foregroundStyle(.secondary)
            Text(text).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .padding()
    }
}

struct SessionListView: View {
    @Environment(WatchClient.self) private var client

    private var sessions: [SessionSummary] {
        // Surface anything needing approval first, then the rest.
        client.sessions.sorted { a, b in
            let pa = client.pendingPermission(for: a.id) != nil
            let pb = client.pendingPermission(for: b.id) != nil
            if pa != pb { return pa }
            return a.updatedAt > b.updatedAt
        }
    }

    var body: some View {
        List {
            ForEach(sessions) { session in
                NavigationLink(value: session.id) {
                    row(session)
                }
            }
        }
        .onAppear { client.refresh() }
    }

    private func row(_ session: SessionSummary) -> some View {
        HStack(spacing: 8) {
            WatchStatusDot(status: client.status(for: session.id))
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(.footnote).lineLimit(2)
                if client.pendingPermission(for: session.id) != nil {
                    Text("Needs approval").font(.caption2).foregroundStyle(.orange)
                } else {
                    Text(session.projectName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

struct SessionDetailView: View {
    @Environment(WatchClient.self) private var client
    let sessionId: String
    @State private var composing = false

    private var session: SessionSummary? { client.sessions.first { $0.id == sessionId } }
    private var pending: PermissionRequest? { client.pendingPermission(for: sessionId) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let pending {
                    PermissionCard(request: pending)
                }
                if let text = client.latestAssistantText(for: sessionId) {
                    Text(text).font(.footnote)
                } else {
                    Text("No reply yet.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle(session?.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button {
                    composing = true
                } label: {
                    Label("Reply", systemImage: "mic.fill")
                }
            }
        }
        .sheet(isPresented: $composing) {
            ComposeView(sessionId: sessionId)
        }
        .onAppear { client.open(sessionId) }
        .onChange(of: client.isConnected) { _, connected in
            if connected { client.open(sessionId) }   // opened via deep link before connecting → retry
        }
    }
}

struct PermissionCard: View {
    @Environment(WatchClient.self) private var client
    let request: PermissionRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(request.displayName ?? request.toolName, systemImage: "hand.raised.fill")
                .font(.footnote.weight(.semibold)).foregroundStyle(.orange)
            let summary = ToolSummary.line(name: request.toolName, input: request.input)
            if !summary.isEmpty {
                Text(summary).font(.caption2).foregroundStyle(.secondary).lineLimit(4)
            }
            HStack(spacing: 8) {
                Button(role: .destructive) { client.decide(request, allow: false) } label: {
                    Text("Deny").frame(maxWidth: .infinity)
                }
                Button { client.decide(request, allow: true) } label: {
                    Text("Allow").frame(maxWidth: .infinity)
                }
                .tint(.green)
            }
            .font(.footnote)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ComposeView: View {
    @Environment(WatchClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    let sessionId: String
    @State private var text = ""

    var body: some View {
        VStack(spacing: 10) {
            TextField("Message", text: $text, axis: .vertical)
                .lineLimit(1...5)
            Button {
                client.prompt(sessionId, text: text)
                dismiss()
            } label: {
                Label("Send", systemImage: "arrow.up.circle.fill").frame(maxWidth: .infinity)
            }
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding()
    }
}

struct WatchStatusDot: View {
    let status: SessionStatus
    var body: some View { Circle().fill(color).frame(width: 8, height: 8) }
    private var color: Color {
        switch status {
        case .running: return .green
        case .awaitingPermission: return .orange
        case .idle: return .blue
        case .exited: return .red
        case .unknown: return .gray
        }
    }
}
