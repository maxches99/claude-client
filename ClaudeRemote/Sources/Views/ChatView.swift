import SwiftUI
import PhotosUI
import ClaudeRemoteCore

struct ChatView: View {
    @Environment(AppModel.self) private var model
    let sessionId: String
    @State private var draft = ""
    @State private var attachments: [InlineImage] = []
    @State private var expandedGroups: Set<String> = []
    @State private var expandedSteps: Set<String> = []
    @State private var presentedPermission: PermissionRequest?
    @State private var showSimulator = false
    @FocusState private var composerFocused: Bool

    private var transcript: Transcript { model.transcripts[sessionId] ?? Transcript() }
    private var state: SessionState? { model.states[sessionId] }
    private var summary: SessionSummary? { model.summary(for: sessionId) }
    private var pending: PermissionRequest? { model.pendingPermission(for: sessionId) }
    private var isRunning: Bool { state?.status == .running || state?.status == .awaitingPermission }
    private var isDesktop: Bool { (state?.origin ?? summary?.origin) == .desktop }
    private var blocks: [TranscriptBlock] { TranscriptLayout.blocks(for: transcript.items, sessionRunning: isRunning) }

    var body: some View {
        VStack(spacing: 0) {
            ConnectionBanner()
            if let error = model.errorBanner {
                CDSBanner(kind: .danger, text: error, systemImage: "exclamationmark.triangle.fill") { model.errorBanner = nil }
            }
            transcriptView
            ComposerDock(
                draft: $draft,
                attachments: $attachments,
                focused: $composerFocused,
                sessionId: sessionId,
                state: state,
                summary: summary,
                modelId: state?.model ?? transcript.model,
                pending: pending,
                isRunning: isRunning,
                isDesktop: isDesktop,
                onSend: send,
                onShowPermission: { presentedPermission = $0 }
            )
        }
        .background(CDS.surface0)
        .toolbarBackground(CDS.surface0, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { header }
            ToolbarItem(placement: .topBarTrailing) {
                SimulatorToolbarButton(isPresented: $showSimulator)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Reload transcript", systemImage: "arrow.clockwise") { model.open(sessionId) }
                    Button("Continue a copy on the phone", systemImage: "arrow.triangle.branch") { model.fork(sessionId) }
                    if state?.origin == .host {
                        Button("Stop session on Mac", systemImage: "xmark.circle", role: .destructive) {
                            model.close(sessionId)
                            model.path.removeAll { $0 == sessionId }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(CDS.textSecondary)
                }
            }
        }
        .sheet(item: $presentedPermission) { request in
            PermissionSheet(request: request)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSimulator) { SimulatorView() }
        .onChange(of: pending?.id) {
            // The inline card is the prompt; a stale details sheet just goes away.
            if pending == nil { presentedPermission = nil }
        }
        .onAppear { model.openIfNeeded(sessionId) }
    }

    // MARK: header

    private var header: some View {
        VStack(spacing: 1) {
            Text(summary?.title ?? "Session")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(CDS.textPrimary)
                .lineLimit(1)
            HStack(spacing: 5) {
                if let s = state { StatusDot(status: s.status, origin: s.origin) }
                Text(subtitle).font(.caption2).foregroundStyle(CDS.textMuted).lineLimit(1)
            }
        }
        .frame(maxWidth: 240)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let project = summary?.projectName, !project.isEmpty { parts.append(project) }
        if isDesktop { parts.append("on \(summary?.sourceLabel ?? "Mac")") }
        switch state?.status {
        case .running: parts.append("Working")
        case .awaitingPermission: parts.append("Needs approval")
        case .exited: parts.append("Stopped")
        case .idle where !isDesktop: parts.append("Idle")
        default: break
        }
        return parts.joined(separator: " · ")
    }

    // MARK: transcript

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(blocks) { block in
                        blockView(block).id(block.id)
                    }
                    if isRunning, !lastBlockIsStreamingText {
                        WorkingStatusRow(status: liveStatus)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, CDS.gutter).padding(.top, 12).padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [CDS.surface0.opacity(0), CDS.surface0], startPoint: .top, endPoint: .bottom)
                    .frame(height: 24)
                    .allowsHitTesting(false)
            }
            .overlay {
                if transcript.items.isEmpty { emptyState }
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
    }

    @ViewBuilder
    private func blockView(_ block: TranscriptBlock) -> some View {
        switch block {
        case .user(let item):
            if case .user(let text, let images) = item.kind {
                UserMessageView(text: text, images: images, keyPrefix: item.id)
            }
        case .assistant(let item):
            if case .assistantText(let text, let streaming) = item.kind {
                AssistantMessageView(text: text, streaming: streaming)
            }
        case .activity(let group):
            ActivityGroupView(group: group, expandedGroups: $expandedGroups, expandedSteps: $expandedSteps)
        case .note(let item):
            if case .note(let text) = item.kind {
                Text(text).font(CDS.caption).foregroundStyle(CDS.textMuted).frame(maxWidth: .infinity)
            }
        case .turnError(let item):
            if case .turnEnd(let text, _) = item.kind {
                Label(text.isEmpty ? "Turn failed" : text, systemImage: "exclamationmark.triangle")
                    .font(CDS.caption).foregroundStyle(CDS.danger)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: isDesktop ? "eye" : "asterisk")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(isDesktop ? CDS.textMuted : CDS.brand)
            Text(isDesktop ? "Watching" : (summary?.projectName ?? "New session"))
                .font(.title3.weight(.semibold)).foregroundStyle(CDS.textPrimary)
            Text(isDesktop ? "This session is open on the Mac. New activity shows up here live." : "What should Claude work on?")
                .font(CDS.body).foregroundStyle(CDS.textMuted).multilineTextAlignment(.center)
        }
        .padding(32)
    }

    private var lastBlockIsStreamingText: Bool {
        if case .assistant(let item)? = blocks.last, case .assistantText(_, true) = item.kind { return true }
        return false
    }

    private var liveStatus: String {
        if state?.status == .awaitingPermission { return "Waiting for approval…" }
        if case .activity(let group)? = blocks.last, group.isLive { return group.liveStatus }
        return "Working…"
    }

    /// Changes whenever something worth scrolling to happens (new row or streamed text growth).
    private var scrollSignature: String {
        guard let last = transcript.items.last else { return "" }
        switch last.kind {
        case .assistantText(let t, _), .thinking(let t, _): return "\(transcript.items.count):\(last.id):\(t.count)"
        default: return "\(transcript.items.count):\(last.id)"
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        model.prompt(sessionId, text: text, images: attachments)
        draft = ""
        attachments = []
    }
}

// MARK: - Composer dock

/// Everything pinned above the keyboard: permission card, notices, and the composer itself.
struct ComposerDock: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: String
    @Binding var attachments: [InlineImage]
    var focused: FocusState<Bool>.Binding
    let sessionId: String
    let state: SessionState?
    let summary: SessionSummary?
    let modelId: String?
    let pending: PermissionRequest?
    let isRunning: Bool
    let isDesktop: Bool
    let onSend: () -> Void
    let onShowPermission: (PermissionRequest) -> Void

    @State private var pickerItems: [PhotosPickerItem] = []

    // Images ride on phone-hosted sessions (base64 over stdin); desktop sessions are text-only.
    private var canAttach: Bool { !isDesktop && model.isConnected }
    private var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) && model.isConnected
    }

    var body: some View {
        VStack(spacing: 8) {
            if let pending {
                PermissionDockCard(request: pending, onDetails: { onShowPermission(pending) })
            }
            if let error = state?.lastError, state?.status == .exited {
                notice(error, tint: CDS.danger)
            }
            if isDesktop {
                notice("Open in \(summary?.sourceLabel ?? "Desktop") on the Mac — messages are delivered there; permission prompts are answered on the Mac.", tint: CDS.textMuted)
            }
            composer
        }
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
        .background(CDS.surface0)
    }

    private func notice(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption).foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty { attachmentStrip }
            TextField(isDesktop ? "Message this session" : "Message Claude", text: $draft, axis: .vertical)
                .lineLimit(1...8)
                .textFieldStyle(.plain)
                .font(CDS.prose)
                .foregroundStyle(CDS.textPrimary)
                .focused(focused)
                .disabled(!model.isConnected)
                .padding(.horizontal, 6).padding(.top, 6)
            HStack(spacing: 6) {
                if canAttach {
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 4, matching: .images) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(CDS.textSecondary)
                            .frame(width: 32, height: 32)
                            .background(CDS.fillControl, in: Circle())
                    }
                    .accessibilityLabel("Attach image")
                }
                if !isDesktop {
                    Menu { modelSection } label: { ComposerChipLabel(text: modelLabel) }
                    Menu { permissionSection } label: { ComposerChipLabel(text: modeLabel, systemImage: modeIcon) }
                }
                Spacer(minLength: 0)
                if isRunning, !isDesktop {   // a Desktop session can only be interrupted on the Mac
                    Button { model.interrupt(sessionId) } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(CDS.onPrimary)
                            .frame(width: 32, height: 32)
                            .background(CDS.fillPrimary, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop")
                }
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(canSend ? .white : CDS.textMuted)
                        .frame(width: 32, height: 32)
                        .background(canSend ? CDS.brand : CDS.fillControl, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(8)
        .background(CDS.surface2, in: RoundedRectangle(cornerRadius: CDS.radiusComposer))
        .overlay(RoundedRectangle(cornerRadius: CDS.radiusComposer).strokeBorder(focused.wrappedValue ? CDS.borderStrong : CDS.border))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
        .onChange(of: pickerItems) { _, items in loadPicked(items) }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { index, image in
                    ZStack(alignment: .topTrailing) {
                        if let ui = UIImage(data: Data(base64Encoded: image.base64) ?? Data()) {
                            Image(uiImage: ui).resizable().scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        Button { attachments.remove(at: index) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.white, .black.opacity(0.5))
                        }
                        .padding(2)
                    }
                }
            }
            .padding(.horizontal, 6)
        }
    }

    private func loadPicked(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task { @MainActor in
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self), let image = Media.inlineImage(from: data) {
                    attachments.append(image)
                }
            }
            pickerItems = []
        }
    }

    private var modelLabel: String {
        guard let id = modelId else { return "Model" }
        if let known = NewSessionView.models.first(where: { id.hasPrefix($0.id) }) { return known.label }
        return id.replacingOccurrences(of: "claude-", with: "").replacingOccurrences(of: "-", with: " ").capitalized
    }

    private var currentMode: PermissionMode? {
        guard let raw = state?.permissionMode else { return nil }
        if raw == "default" { return .manual }
        return PermissionMode(rawValue: raw)
    }

    private var modeLabel: String { currentMode?.shortLabel ?? "Permissions" }
    private var modeIcon: String { currentMode?.symbol ?? "shield" }

    private var modelSection: some View {
        Section("Model") {
            ForEach(NewSessionView.models, id: \.id) { m in
                Button { model.setModel(sessionId, model: m.id) } label: {
                    if modelId?.hasPrefix(m.id) == true { Label(m.label, systemImage: "checkmark") } else { Text(m.label) }
                }
            }
        }
    }

    private var permissionSection: some View {
        Section("Permissions") {
            ForEach(PermissionMode.allCases, id: \.self) { mode in
                Button { model.setPermissionMode(sessionId, mode: mode.rawValue) } label: {
                    if currentMode == mode { Label(mode.label, systemImage: "checkmark") } else { Label(mode.label, systemImage: mode.symbol) }
                }
            }
        }
    }
}

/// A permission request pinned above the composer, answerable in place (details open the sheet).
struct PermissionDockCard: View {
    @Environment(AppModel.self) private var model
    let request: PermissionRequest
    let onDetails: () -> Void

    private var isBash: Bool { request.toolName == "Bash" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onDetails) {
                HStack(spacing: 8) {
                    Image(systemName: ToolIcon.symbol(for: request.toolName))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CDS.warning)
                        .frame(width: 18)
                    Text("\(request.displayName ?? ToolSummary.displayName(request.toolName)) needs permission")
                        .font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("Details").font(CDS.caption).foregroundStyle(CDS.textMuted)
                    Chevron(expanded: false)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            let line = request.title ?? ToolSummary.line(name: request.toolName, input: request.input)
            if !line.isEmpty {
                Text(line)
                    .font(isBash ? CDS.codeSmall : CDS.body)
                    .foregroundStyle(CDS.textSecondary)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(CDS.fillNeutral, in: RoundedRectangle(cornerRadius: CDS.radius - 2))
            }
            HStack(spacing: 8) {
                Button("Deny") { model.decide(request, allow: false) }
                    .buttonStyle(CDSButtonStyle(variant: .secondary, fullWidth: true))
                Button("Allow") { model.decide(request, allow: true) }
                    .buttonStyle(CDSButtonStyle(variant: .primary, fullWidth: true))
            }
        }
        .padding(10)
        .background(CDS.surface2, in: RoundedRectangle(cornerRadius: CDS.radiusComposer))
        .overlay(RoundedRectangle(cornerRadius: CDS.radiusComposer).strokeBorder(CDS.warningFill.opacity(0.6)))
    }
}

extension PermissionMode {
    /// Fits a composer chip.
    var shortLabel: String {
        switch self {
        case .manual: return "Default"
        case .acceptEdits: return "Accept edits"
        case .plan: return "Plan"
        case .auto: return "Auto"
        case .dontAsk: return "Don't ask"
        case .bypassPermissions: return "Bypass"
        }
    }

    var symbol: String {
        switch self {
        case .manual: return "hand.raised"
        case .acceptEdits: return "pencil"
        case .plan: return "list.bullet.clipboard"
        case .auto: return "bolt"
        case .dontAsk: return "bell.slash"
        case .bypassPermissions: return "shield.slash"
        }
    }
}
