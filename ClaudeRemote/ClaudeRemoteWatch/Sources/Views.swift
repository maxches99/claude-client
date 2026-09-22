import SwiftUI
import ClaudeRemoteCore

/// Where the Watch's navigation can go.
enum WatchRoute: Hashable {
    case session(String)
    case approval(String)
    case ask
}

struct WatchRootView: View {
    @Environment(WatchClient.self) private var client
    @State private var path: [WatchRoute] = []

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
                    HomeView()
                }
            }
            .navigationTitle("ccremote")
            .navigationDestination(for: WatchRoute.self) { route in
                switch route {
                case .session(let id): SessionDetailView(sessionId: id)
                case .approval(let id): ApprovalView(requestId: id)
                case .ask: AskView()
                }
            }
        }
        .onOpenURL { url in
            // From the complication: ccwatch://session/<id> jumps to that session; ccwatch://open just opens.
            guard url.scheme == "ccwatch" else { return }
            if url.host == "session" {
                let id = url.lastPathComponent
                if !id.isEmpty {
                    // Straight to the question when that is what the session is waiting on.
                    if let pending = client.pendingPermission(for: id) { path = [.session(id), .approval(pending.id)] } else { path = [.session(id)] }
                }
            } else {
                path = []
            }
        }
        .onChange(of: client.startedChatId) { _, id in
            // A chat asked by voice was created: its reply shows up in the session view.
            if let id { path = [.session(id)] }
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

/// Waiting approvals first — the reason to raise a wrist — then "ask by voice" and the sessions.
struct HomeView: View {
    @Environment(WatchClient.self) private var client

    private var sessions: [SessionSummary] {
        client.sessions.sorted { a, b in
            let pa = client.pendingPermission(for: a.id) != nil
            let pb = client.pendingPermission(for: b.id) != nil
            if pa != pb { return pa }
            let ra = client.status(for: a.id) == .running, rb = client.status(for: b.id) == .running
            if ra != rb { return ra }
            return a.updatedAt > b.updatedAt
        }
        .filter { $0.origin != .stored || client.pendingPermission(for: $0.id) != nil || $0.updatedAt > Date().addingTimeInterval(-3 * 86_400) }
    }

    var body: some View {
        List {
            if !client.permissions.isEmpty {
                Section {
                    ForEach(client.permissions) { request in
                        NavigationLink(value: WatchRoute.approval(request.id)) { approvalRow(request) }
                    }
                } header: {
                    Text("Waiting · \(client.permissions.count)").foregroundStyle(.orange)
                }
            }
            Section {
                NavigationLink(value: WatchRoute.ask) {
                    Label("Ask Claude", systemImage: "mic.fill").foregroundStyle(.orange)
                }
            }
            Section("Sessions") {
                ForEach(sessions.prefix(30)) { session in
                    NavigationLink(value: WatchRoute.session(session.id)) { row(session) }
                }
            }
        }
        .onAppear { client.refresh() }
    }

    private func approvalRow(_ request: PermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(request.isQuestion ? "Question" : (request.isPlanReview ? "Plan" : ToolSummary.displayName(request.toolName)),
                  systemImage: request.isQuestion ? "questionmark.bubble" : (request.isPlanReview ? "list.bullet.clipboard" : "hand.raised.fill"))
                .font(.footnote.weight(.semibold)).foregroundStyle(.orange)
            let title = client.sessions.first { $0.id == request.sessionId }?.title ?? "Session"
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func row(_ session: SessionSummary) -> some View {
        HStack(spacing: 8) {
            WatchStatusDot(status: client.status(for: session.id))
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(.footnote).lineLimit(2)
                if client.pendingPermission(for: session.id) != nil {
                    Text("Needs you").font(.caption2).foregroundStyle(.orange)
                } else if let phase = client.livePhase(for: session.id) {
                    Text(phase).font(.caption2).foregroundStyle(.green).lineLimit(1)
                } else {
                    Text(session.kind == .chat ? "Chat" : session.projectName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

/// One request, answered on the wrist: Allow / Deny, a plan to approve, or a question's options.
struct ApprovalView: View {
    @Environment(WatchClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    let requestId: String
    @State private var picked: [String: Set<String>] = [:]
    @State private var step = 0

    private var request: PermissionRequest? { client.permissions.first { $0.id == requestId } }

    var body: some View {
        ScrollView {
            if let request {
                VStack(alignment: .leading, spacing: 10) {
                    if request.isQuestion {
                        question(request)
                    } else if request.isPlanReview {
                        plan(request)
                    } else {
                        tool(request)
                    }
                }
                .padding(.horizontal, 4)
            } else {
                Text("Already answered.").font(.footnote).foregroundStyle(.secondary)
                    .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { dismiss() } }
            }
        }
        .navigationTitle(client.sessions.first { $0.id == request?.sessionId }?.title ?? "Approval")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func tool(_ request: PermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(request.displayName ?? ToolSummary.displayName(request.toolName), systemImage: "hand.raised.fill")
                .font(.footnote.weight(.semibold)).foregroundStyle(.orange)
            let summary = ToolSummary.line(name: request.toolName, input: request.input)
            if !summary.isEmpty { Text(summary).font(.system(.caption2, design: .monospaced)).lineLimit(8) }
            if let reason = request.decisionReason, !reason.isEmpty { Text(reason).font(.caption2).foregroundStyle(.secondary) }
            Button { client.decide(request, allow: true); dismiss() } label: {
                Label("Allow", systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .tint(.green)
            Button(role: .destructive) { client.decide(request, allow: false); dismiss() } label: {
                Label("Deny", systemImage: "xmark").frame(maxWidth: .infinity)
            }
        }
    }

    private func plan(_ request: PermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Plan ready", systemImage: "list.bullet.clipboard").font(.footnote.weight(.semibold)).foregroundStyle(.orange)
            if let text = PlanReview.plan(in: request.input) {
                Text(text).font(.caption2)
            }
            Button { client.decide(request, allow: true); dismiss() } label: {
                Label("Approve", systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .tint(.green)
            Button(role: .destructive) {
                client.decide(request, allow: false, reason: "Not yet — revise the plan.")
                dismiss()
            } label: { Label("Not yet", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity) }
        }
    }

    @ViewBuilder
    private func question(_ request: PermissionRequest) -> some View {
        let questions = AskUserQuestion.questions(in: request.input)
        if questions.isEmpty {
            Text("Answer this one on the phone.").font(.footnote).foregroundStyle(.secondary)
        } else {
            let q = questions[min(step, questions.count - 1)]
            if questions.count > 1 {
                Text("\(min(step, questions.count - 1) + 1) of \(questions.count)").font(.caption2).foregroundStyle(.secondary)
            }
            Text(q.question).font(.footnote.weight(.semibold))
            ForEach(q.options) { option in
                Button {
                    toggle(option.label, in: q, questions: questions, request: request)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.label).font(.footnote)
                            if !option.description.isEmpty { Text(option.description).font(.caption2).foregroundStyle(.secondary).lineLimit(3) }
                        }
                        Spacer(minLength: 0)
                        if picked[q.question, default: []].contains(option.label) { Image(systemName: "checkmark").foregroundStyle(.green) }
                    }
                }
            }
            if q.multiSelect {
                Button { next(questions: questions, request: request) } label: {
                    Text(step + 1 < questions.count ? "Next" : "Send").frame(maxWidth: .infinity)
                }
                .tint(.orange)
                .disabled(picked[q.question, default: []].isEmpty)
            }
        }
    }

    /// Single choice answers and moves on; multiple choice toggles until Next / Send.
    private func toggle(_ label: String, in q: AskUserQuestion.Question, questions: [AskUserQuestion.Question], request: PermissionRequest) {
        if q.multiSelect {
            if picked[q.question, default: []].contains(label) { picked[q.question]?.remove(label) } else { picked[q.question, default: []].insert(label) }
        } else {
            picked[q.question] = [label]
            next(questions: questions, request: request)
        }
    }

    private func next(questions: [AskUserQuestion.Question], request: PermissionRequest) {
        if step + 1 < questions.count {
            step += 1
            return
        }
        let answers = picked.mapValues { Array($0) }
        client.answer(request, answers: answers)
        dismiss()
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
                    NavigationLink(value: WatchRoute.approval(pending.id)) {
                        Label(pending.isQuestion ? "Answer the question" : (pending.isPlanReview ? "Review the plan" : "Approve \(ToolSummary.displayName(pending.toolName))"),
                              systemImage: "hand.raised.fill")
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .tint(.orange)
                }
                if let phase = client.livePhase(for: sessionId) {
                    HStack(spacing: 6) {
                        ProgressView().frame(width: 14, height: 14)
                        Text(phase).font(.caption2).foregroundStyle(.green).lineLimit(2)
                    }
                }
                if let text = client.latestAssistantText(for: sessionId) {
                    Text(text).font(.footnote)
                } else if client.livePhase(for: sessionId) == nil {
                    Text("No reply yet.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle(session?.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                if client.status(for: sessionId) == .running {
                    Button { client.interrupt(sessionId) } label: { Image(systemName: "stop.fill") }
                }
                Spacer()
                Button { composing = true } label: { Label("Reply", systemImage: "mic.fill") }
            }
        }
        .sheet(isPresented: $composing) {
            ComposeView { text in client.prompt(sessionId, text: text) }
        }
        .onAppear { client.open(sessionId) }
        .onChange(of: client.isConnected) { _, connected in
            if connected { client.open(sessionId) }   // opened via deep link before connecting → retry
        }
    }
}

/// A question for a fresh chat, dictated.
struct AskView: View {
    @Environment(WatchClient.self) private var client
    @State private var text = ""
    @State private var sent = false

    var body: some View {
        VStack(spacing: 10) {
            if sent {
                ProgressView()
                Text("Asking…").font(.footnote).foregroundStyle(.secondary)
            } else {
                TextField("Ask anything", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                Button {
                    sent = true
                    client.startChat(text)
                } label: {
                    Label("Ask", systemImage: "arrow.up.circle.fill").frame(maxWidth: .infinity)
                }
                .tint(.orange)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                Text("A quick chat on the Mac: no project, no tools.").font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 4)
        .navigationTitle("Ask")
    }
}

/// A reply: tap a ready-made one, or dictate.
struct ComposeView: View {
    @Environment(\.dismiss) private var dismiss
    let send: (String) -> Void
    @State private var text = ""

    static let quickReplies = ["Yes, go ahead", "No", "Continue", "Run the tests", "Stop and explain what you're doing"]

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                TextField("Message", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                Button {
                    send(text)
                    dismiss()
                } label: {
                    Label("Send", systemImage: "arrow.up.circle.fill").frame(maxWidth: .infinity)
                }
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                ForEach(ComposeView.quickReplies, id: \.self) { reply in
                    Button {
                        send(reply)
                        dismiss()
                    } label: {
                        Text(reply).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
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
