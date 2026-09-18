import SwiftUI
import ClaudeRemoteCore

struct ChatView: View {
    @Environment(AppModel.self) private var model
    let sessionId: String
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    private var transcript: Transcript { model.transcripts[sessionId] ?? Transcript() }
    private var state: SessionState? { model.states[sessionId] }
    private var summary: SessionSummary? { model.summary(for: sessionId) }
    private var pending: PermissionRequest? { model.pendingPermission(for: sessionId) }
    private var isRunning: Bool { state?.status == .running || state?.status == .awaitingPermission }
    private var isDesktop: Bool { (state?.origin ?? summary?.origin) == .desktop }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ConnectionBanner()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(transcript.items) { item in
                            TranscriptRow(item: item).id(item.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .overlay {
                    if transcript.items.isEmpty {
                        ContentUnavailableView {
                            Label(isDesktop ? "Watching" : "New session", systemImage: isDesktop ? "eye" : "bubble.left.and.text.bubble.right")
                        } description: {
                            Text(isDesktop ? "This session is open on the Mac. New activity shows up here live." : "Send a message to start.")
                        }
                    }
                }
                .onChange(of: scrollSignature) {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: transcript.items.count) { old, new in
                    // A big batch (history load) lays out lazily; scroll again once it has settled.
                    guard new - old > 5 else { return }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            if let error = state?.lastError, state?.status == .exited {
                Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal, 16).padding(.vertical, 6)
            }
            if let error = model.errorBanner {
                HStack {
                    Text(error).font(.footnote).lineLimit(3)
                    Spacer()
                    Button { model.errorBanner = nil } label: { Image(systemName: "xmark") }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color.red.opacity(0.12))
            }
            if let pending {
                Button {
                    presentedPermission = pending
                } label: {
                    Label("\(pending.toolName) needs approval — \(ToolSummary.line(name: pending.toolName, input: pending.input))", systemImage: "hand.raised.fill")
                        .lineLimit(2).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent).tint(.orange)
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            if isDesktop {
                Text("Open in \(summary?.sourceLabel ?? "Desktop") on the Mac — messages are delivered there; permission prompts are answered on the Mac.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.top, 6)
            }
            composer
        }
        .navigationTitle(summary?.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if !isDesktop {
                        modelSection
                        permissionSection
                    }
                    Button("Reload transcript") { model.open(sessionId) }
                    Button("Continue a copy on the phone") { model.fork(sessionId) }
                    if state?.origin == .host {
                        Button("Stop session on Mac", role: .destructive) {
                            model.close(sessionId)
                            model.path.removeAll { $0 == sessionId }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if let s = state { StatusDot(status: s.status, origin: s.origin) }
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(item: $presentedPermission) { request in
            PermissionSheet(request: request)
                .presentationDetents([.medium, .large])
        }
        .onChange(of: pending?.id) {
            // Surface new requests immediately while this session is on screen.
            if let pending, presentedPermission == nil { presentedPermission = pending }
            if pending == nil { presentedPermission = nil }
        }
        .onAppear {
            model.openIfNeeded(sessionId)
            if let pending { presentedPermission = pending }
        }
    }

    @State private var presentedPermission: PermissionRequest?

    private var modelSection: some View {
        Section("Model") {
            ForEach(NewSessionView.models, id: \.id) { m in
                Button { model.setModel(sessionId, model: m.id) } label: {
                    if state?.model?.hasPrefix(m.id) == true { Label(m.label, systemImage: "checkmark") } else { Text(m.label) }
                }
            }
        }
    }

    private var permissionSection: some View {
        Section("Permissions") {
            ForEach(PermissionMode.allCases, id: \.self) { mode in
                Button { model.setPermissionMode(sessionId, mode: mode.rawValue) } label: {
                    let selected = state?.permissionMode == mode.rawValue || (mode == .manual && state?.permissionMode == "default")
                    if selected { Label(mode.label, systemImage: "checkmark") } else { Text(mode.label) }
                }
            }
        }
    }

    /// Changes whenever something worth scrolling to happens (new row or streamed text growth).
    private var scrollSignature: String {
        guard let last = transcript.items.last else { return "" }
        switch last.kind {
        case .assistantText(let t, _), .thinking(let t, _): return "\(transcript.items.count):\(last.id):\(t.count)"
        default: return "\(transcript.items.count):\(last.id)"
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message Claude", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                .focused($composerFocused)
                .disabled(!model.isConnected)
            if isRunning {
                Button { model.interrupt(sessionId) } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 30))
                }
                .tint(.red)
                .disabled(isDesktop)   // interrupting a Desktop session is only possible on the Mac
            }
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.isConnected)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.prompt(sessionId, text: text)
        draft = ""
    }
}
