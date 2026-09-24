import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ClaudeRemoteCore

struct ChatView: View {
    @Environment(AppModel.self) private var model
    let sessionId: String
    @State private var draft = ""
    @State private var files: [Attachment] = []
    @State private var macFiles: [String] = []
    @State private var expandedGroups: Set<String> = []
    @State private var expandedSteps: Set<String> = []
    @State private var presentedPermission: PermissionRequest?
    @State private var showSimulator = false
    @State private var showLimits = false
    @State private var showGit = false
    @State private var showBrowser = false
    @State private var showCommands = false
    @State private var showTurnChanges = false
    @State private var showProcesses = false
    @State private var showWorktrees = false
    @State private var confirmRewind: String?
    @State private var showTerminals = false
    @State private var showShareLink = false
    @State private var confirmHandoff: HandoffTarget?
    @State private var showReview = false
    /// Replies are read aloud and the mic opens for the next prompt — a conversation without looking.
    @State private var handsFree = false
    @State private var showFind = false
    @State private var findQuery = ""
    @State private var findIndex = 0
    /// The block the find bar wants on screen; `scrollPosition` (unlike `scrollTo`) lays lazy rows out
    /// on the way there instead of landing in unmeasured space.
    @State private var findTarget: String?
    /// A file the agent linked in its reply (`[Bar.tsx:42](src/Bar.tsx:42)`), opened from the Mac.
    @State private var linkedFile: LinkedFile?
    @FocusState private var composerFocused: Bool
    @FocusState private var findFocused: Bool

    private var transcript: Transcript { model.transcripts[sessionId] ?? Transcript() }
    private var state: SessionState? { model.states[sessionId] }
    private var summary: SessionSummary? { model.summary(for: sessionId) }
    private var pending: PermissionRequest? { model.pendingPermission(for: sessionId) }
    private var isRunning: Bool { state?.status == .running || state?.status == .awaitingPermission }
    private var isDesktop: Bool { (state?.origin ?? summary?.origin) == .desktop }
    private var agent: AgentKind { state?.agent ?? summary?.agent ?? .claude }
    private var agentName: String { agent.label }
    private var isChat: Bool { (state?.kind ?? summary?.kind ?? .agent) == .chat }
    private var blocks: [TranscriptBlock] { TranscriptLayout.blocks(for: transcript.items, sessionRunning: isRunning) }

    var body: some View {
        VStack(spacing: 0) {
            ConnectionBanner()
            if let error = model.errorBanner {
                CDSBanner(kind: .danger, text: error, systemImage: "exclamationmark.triangle.fill") { model.errorBanner = nil }
            }
            if showFind { findBar }
            if let message = model.handoffMessage {
                CDSBanner(kind: message.isError ? .danger : .info, text: message.text,
                          systemImage: message.isError ? "exclamationmark.triangle.fill" : "desktopcomputer") { model.handoffMessage = nil }
            }
            if let notice = model.rewindNotice, notice.sessionId == sessionId {
                CDSBanner(kind: .info,
                          text: "Rewound: this is a copy without the last \(notice.dropped) transcript entr\(notice.dropped == 1 ? "y" : "ies"). Files on the Mac were not reverted.",
                          systemImage: "arrow.counterclockwise") { model.rewindNotice = nil }
            }
            transcriptView
            ComposerDock(
                draft: $draft,
                files: $files,
                macFiles: $macFiles,
                focused: $composerFocused,
                sessionId: sessionId,
                state: state,
                summary: summary,
                modelId: state?.model ?? transcript.model,
                pending: pending,
                isRunning: isRunning,
                isDesktop: isDesktop,
                isChat: isChat,
                handsFree: $handsFree,
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
            if !isChat {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showGit = true } label: {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(CDS.textSecondary)
                            .overlay(alignment: .topTrailing) {
                                if let ci = ciColor {
                                    Circle().fill(ci).frame(width: 7, height: 7).offset(x: 3, y: -2)
                                }
                            }
                    }
                    .accessibilityLabel("Git")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if !usageSummary.isEmpty || model.contextUsage(sessionId) != nil {
                        Section("Usage") {
                            if !usageSummary.isEmpty { Label(usageSummary, systemImage: "dollarsign.circle") }
                            if let context = model.contextUsage(sessionId) {
                                Label("Context \(context.percentLabel) · \(context.label)", systemImage: "gauge.with.dots.needle.33percent")
                            }
                        }
                    }
                    Button("Plan limits…", systemImage: "gauge.with.dots.needle.67percent") { showLimits = true }
                    Button("Find in transcript", systemImage: "magnifyingglass") { openFind() }
                    if !isChat {
                        Section {
                            Button("Browse files…", systemImage: "folder") { showBrowser = true }
                            Button("Run a command…", systemImage: "terminal") { showCommands = true }
                            if model.supportsMacTools {
                                Button("Terminal…", systemImage: "apple.terminal") { showTerminals = true }
                            }
                            if model.supportsQueue {
                                Button("Background processes…", systemImage: "bolt.horizontal") { showProcesses = true }
                            }
                            Button("Changes by turn…", systemImage: "arrow.uturn.backward.square") { showTurnChanges = true }
                            if model.supportsPipelines {
                                Button("Review changes…", systemImage: "text.magnifyingglass") { showReview = true }
                            }
                            if model.supportsQueue {
                                Button("Worktrees…", systemImage: "square.split.2x1") { showWorktrees = true }
                            }
                        }
                    }
                    if !isDesktop, agent == .claude {
                        Section {
                            Button("Compact the conversation", systemImage: "arrow.down.right.and.arrow.up.left") { model.compact(sessionId) }
                                .disabled(isRunning || !model.isConnected)
                        }
                    }
                    Section {
                        if model.narrator.isSpeaking {
                            Button("Stop reading", systemImage: "speaker.slash") { model.narrator.stop() }
                        } else {
                            Button("Read last reply aloud", systemImage: "speaker.wave.2") {
                                model.narrator.speak(TranscriptExport.lastReply(items: transcript.items))
                            }
                            .disabled(TranscriptExport.lastReply(items: transcript.items).isEmpty)
                        }
                        Toggle("Hands-free voice", systemImage: "waveform.and.mic", isOn: $handsFree)
                    }
                    Section {
                        ShareLink(item: exportDocument, preview: SharePreview(summary?.title ?? "Transcript", image: Image(systemName: "doc.text"))) {
                            Label("Share transcript…", systemImage: "square.and.arrow.up")
                        }
                        if model.canShareLinks {
                            Button("Share as a link…", systemImage: "link") { showShareLink = true }
                                .disabled(transcript.items.isEmpty)
                        }
                        Button("Copy last reply", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = TranscriptExport.lastReply(items: transcript.items)
                        }
                        .disabled(TranscriptExport.lastReply(items: transcript.items).isEmpty)
                    }
                    if model.supportsMacTools, let targets = model.handoffTargets[sessionId], !targets.isEmpty {
                        Menu {
                            ForEach(targets) { target in
                                Button(target.label, systemImage: target.systemImage) {
                                    if target.kind == .session { confirmHandoff = target } else { model.handoff(sessionId, to: target) }
                                }
                            }
                        } label: {
                            Label("Continue on the Mac", systemImage: "desktopcomputer.and.arrow.down")
                        }
                    }
                    Button("Reload transcript", systemImage: "arrow.clockwise") { model.open(sessionId) }
                    if !isChat {
                        Button("Continue a copy on the phone", systemImage: "arrow.triangle.branch") { model.fork(sessionId) }
                    }
                    if state?.origin == .host {
                        Button(isChat ? "Close chat on Mac" : "Stop session on Mac", systemImage: "xmark.circle", role: .destructive) {
                            model.close(sessionId)
                            model.dismiss(sessionId)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(CDS.textSecondary)
                }
            }
        }
        .sheet(item: $presentedPermission) { request in
            if request.isQuestion {
                QuestionSheet(request: request).presentationDetents([.large])
            } else if request.isPlanReview {
                PlanSheet(request: request).presentationDetents([.large])
            } else {
                PermissionSheet(request: request).presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $showSimulator) { SimulatorView { files.append($0) } }
        .sheet(isPresented: $showLimits) { LimitsView(sessionId: sessionId) }
        .sheet(isPresented: $showGit) { GitView(sessionId: sessionId) }
        .sheet(isPresented: $showBrowser) { ProjectBrowserView(sessionId: sessionId) }
        .sheet(isPresented: $showCommands) { CommandsView(sessionId: sessionId) }
        .sheet(isPresented: $showTurnChanges) { TurnChangesView(sessionId: sessionId) }
        .sheet(isPresented: $showProcesses) { ProcessesView(sessionId: sessionId) }
        .sheet(isPresented: $showWorktrees) { WorktreesView(sessionId: sessionId) }
        .sheet(isPresented: $showTerminals) { TerminalsView(sessionId: isChat ? nil : sessionId) }
        .sheet(isPresented: $showShareLink) { ShareLinkSheet(sessionId: sessionId) }
        .sheet(isPresented: $showReview) { ReviewView(sessionId: sessionId) }
        .sheet(item: $linkedFile) { file in
            NavigationStack {
                RemoteFileContent(path: file.link.path, line: file.link.line, sessionId: isChat ? nil : sessionId, attachPath: file.link.relativePath)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { linkedFile = nil } } }
            }
        }
        .confirmationDialog(confirmHandoff?.label ?? "", isPresented: Binding(get: { confirmHandoff != nil }, set: { if !$0 { confirmHandoff = nil } }), titleVisibility: .visible) {
            Button("Continue there") {
                if let target = confirmHandoff { model.handoff(sessionId, to: target) }
                confirmHandoff = nil
            }
        } message: {
            Text(state?.origin == .host
                 ? "The phone lets go of this session (its transcript stays), and it continues on the Mac. You can still follow it from here."
                 : "It opens on the Mac. You can still follow it from here.")
        }
        .confirmationDialog("Rewind to this prompt?", isPresented: Binding(get: { confirmRewind != nil }, set: { if !$0 { confirmRewind = nil } }), titleVisibility: .visible) {
            Button("Rewind") {
                if let itemId = confirmRewind { model.rewind(sessionId, toItemId: itemId) }
                confirmRewind = nil
            }
        } message: {
            Text("The Mac copies the conversation up to just before that prompt into a new session and opens it. This session stays as it is, and no files are reverted — use “Changes by turn” for that.")
        }
        .alert("Couldn't rewind", isPresented: Binding(get: { model.rewindError != nil }, set: { if !$0 { model.rewindError = nil } })) {
            Button("OK", role: .cancel) { model.rewindError = nil }
        } message: {
            Text(model.rewindError ?? "")
        }
        .onChange(of: pending?.id) {
            // The inline card is the prompt; a stale details sheet just goes away.
            if pending == nil { presentedPermission = nil }
        }
        .onChange(of: model.macFileInsert?.token) { _, _ in
            guard let insert = model.macFileInsert, insert.sessionId == sessionId else { return }
            model.macFileInsert = nil
            if !macFiles.contains(insert.path) { macFiles.append(insert.path) }
            showBrowser = false
            composerFocused = true
        }
        .onChange(of: model.composerInsert) { _, insert in
            // A quoted diff selection from the Git screen or the permission sheet lands in the draft.
            guard let insert, insert.sessionId == sessionId else { return }
            model.composerInsert = nil
            showGit = false
            showCommands = false
            presentedPermission = nil
            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            draft = (trimmed.isEmpty ? "" : draft + "\n\n") + insert.text + "\n\n"
            composerFocused = true
        }
        .onAppear {
            model.openIfNeeded(sessionId)
            if let insert = model.composerInsert, insert.sessionId == sessionId {
                model.composerInsert = nil
                draft = (draft.isEmpty ? "" : draft + "\n\n") + insert.text + "\n\n"
                composerFocused = true
            }
            if !isChat, model.supportsQueue, model.palettes[sessionId] == nil { model.requestPalette(sessionId) }
            if model.supportsMacTools { model.requestHandoffTargets(sessionId) }
            if let q = model.pendingFind.removeValue(forKey: sessionId) { findQuery = q; openFind() }
            if !isChat, model.gitStatuses[sessionId] != nil || model.pullRequests[sessionId] != nil { model.requestPullRequest(sessionId) }
        }
        .onDisappear { if handsFree { handsFree = false; model.narrator.stop() } }
    }

    /// The branch's CI, as a dot on the Git icon (only once the PR has been looked up).
    private var ciColor: Color? {
        switch model.pullRequests[sessionId]?.info?.ciState {
        case .success: return CDS.successFill
        case .failure: return CDS.dangerFill
        case .pending: return CDS.warningFill
        default: return nil
        }
    }

    // MARK: header

    private var header: some View {
        VStack(spacing: 1) {
            Text(summary?.title ?? "Session")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(CDS.textPrimary)
                .lineLimit(1)
            HStack(spacing: 5) {
                if let s = state { StatusDot(status: s.status, origin: s.origin, agent: agent) }
                Text(subtitle).font(.caption2).foregroundStyle(CDS.textMuted).lineLimit(1)
            }
        }
        .frame(maxWidth: 240)
    }

    private var subtitle: String {
        var parts: [String] = []
        if isChat {
            parts.append("Chat · \(agentName)")
        } else if let project = summary?.projectName, !project.isEmpty {
            parts.append(project)
        }
        if !isChat, agent == .codex { parts.append("Codex") }
        if isDesktop { parts.append("on \(summary?.sourceLabel ?? "Mac")") }
        switch state?.status {
        case .running: parts.append("Working")
        case .awaitingPermission: parts.append("Needs approval")
        case .exited: parts.append("Stopped")
        case .idle where !isDesktop: parts.append("Idle")
        default: break
        }
        if let costLabel { parts.append(costLabel) }
        return parts.joined(separator: " · ")
    }

    /// Compact session cost (finer precision for small amounts), nil until the first result lands.
    private var costLabel: String? {
        let c = transcript.totalCostUSD
        guard c > 0 else { return nil }
        return c < 0.1 ? String(format: "$%.3f", c) : String(format: "$%.2f", c)
    }

    /// "$0.12 · 15.2k in · 3.4k out" for the overflow menu; empty when nothing is recorded.
    private var usageSummary: String {
        var parts: [String] = []
        if let costLabel { parts.append(costLabel) }
        if transcript.inputTokens > 0 { parts.append("\(Self.formatTokens(transcript.inputTokens)) in") }
        if transcript.outputTokens > 0 { parts.append("\(Self.formatTokens(transcript.outputTokens)) out") }
        return parts.joined(separator: " · ")
    }

    private static func formatTokens(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    // MARK: find

    private var findMatches: [TranscriptMatch] { TranscriptSearch.matches(in: blocks, query: findQuery) }
    private var currentMatch: TranscriptMatch? {
        let m = findMatches
        guard !m.isEmpty else { return nil }
        return m[min(findIndex, m.count - 1)]
    }

    private func openFind() {
        withAnimation(.easeInOut(duration: 0.15)) { showFind = true }
        findFocused = true
    }

    private func closeFind() {
        withAnimation(.easeInOut(duration: 0.15)) { showFind = false }
        findQuery = ""
        findIndex = 0
        findFocused = false
    }

    private func stepFind(_ delta: Int) {
        let count = findMatches.count
        guard count > 0 else { return }
        findIndex = ((findIndex + delta) % count + count) % count
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(CDS.textMuted)
                TextField("Find in transcript", text: $findQuery)
                    .font(CDS.body).foregroundStyle(CDS.textPrimary)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($findFocused)
                    .onSubmit { stepFind(1) }
                if !findQuery.isEmpty {
                    Text(findMatches.isEmpty ? "0" : "\(min(findIndex, findMatches.count - 1) + 1)/\(findMatches.count)")
                        .font(.caption.monospacedDigit()).foregroundStyle(CDS.textMuted)
                    Button { findQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(CDS.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).frame(height: 34)
            .background(CDS.surface2, in: RoundedRectangle(cornerRadius: CDS.radius))
            .overlay(RoundedRectangle(cornerRadius: CDS.radius).strokeBorder(findFocused ? CDS.borderStrong : CDS.border))
            Button { stepFind(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(findMatches.isEmpty)
            Button { stepFind(1) } label: { Image(systemName: "chevron.down") }
                .disabled(findMatches.isEmpty)
            Button("Done") { closeFind() }.font(CDS.bodyMedium)
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(CDS.textSecondary)
        .padding(.horizontal, CDS.gutter).padding(.vertical, 8)
        .background(CDS.surface0)
        .overlay(alignment: .bottom) { Divider().overlay(CDS.border) }
        .onChange(of: findQuery) { findIndex = 0 }
    }

    /// Unfolds the group / step a match lives in so the row is actually on screen after the scroll.
    private func reveal(_ match: TranscriptMatch) {
        guard let stepId = match.stepId else { return }
        expandedGroups.insert(match.blockId)
        expandedSteps.insert(stepId)
    }

    // MARK: export

    /// Lazily rendered Markdown of the whole transcript, handed to the share sheet as a `.md` file.
    private var exportDocument: TranscriptDocument {
        var parts: [String] = []
        if let project = summary?.projectName, !project.isEmpty, !isChat { parts.append(project) }
        parts.append(isChat ? "Chat with \(agentName)" : agentName)
        if let modelId = state?.model ?? transcript.model { parts.append(model.modelLabel(modelId, agent: agent)) }
        parts.append(Date().formatted(date: .abbreviated, time: .shortened))
        let options = TranscriptExport.Options(title: summary?.title ?? "Session", subtitle: parts.joined(separator: " · "), agentName: agentName)
        return TranscriptDocument(items: transcript.items, options: options)
    }

    // MARK: transcript

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(blocks) { block in
                        blockView(block)
                            .id(block.id)
                            .overlay {
                                if showFind, currentMatch?.blockId == block.id {
                                    RoundedRectangle(cornerRadius: CDS.radius + 2)
                                        .strokeBorder(CDS.brand.opacity(0.7), lineWidth: 1.5)
                                        .padding(-6)
                                        .allowsHitTesting(false)
                                }
                            }
                    }
                    if isRunning, !lastBlockIsStreamingText {
                        WorkingStatusRow(startedAt: transcript.turnStartedAt, outputTokens: transcript.turnOutputTokens, phase: livePhase)
                            .id("status")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .scrollTargetLayout()
                .padding(.horizontal, CDS.gutter).padding(.top, 12).padding(.bottom, 8)
            }
            // Write-only from our side: if the scroll view could write the top row back into the binding,
            // every drag inside a tall row would re-apply "row at top" and snap the transcript in place.
            .scrollPosition(id: Binding(get: { findTarget }, set: { _ in }), anchor: .top)
            // Bottom-anchored so new rows keep the latest reply in view — except while finding: the anchor
            // also re-pins the bottom whenever a lazy row gets measured, which would drag every jump back down.
            .defaultScrollAnchor(showFind ? .top : .bottom)
            .scrollDismissesKeyboard(.interactively)
            .environment(\.openURL, OpenURLAction { url in
                guard let link = FileLink.parse(url.absoluteString, cwd: state?.cwd ?? summary?.cwd ?? "") else { return .systemAction }
                linkedFile = LinkedFile(link: link)
                return .handled
            })
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [CDS.surface0.opacity(0), CDS.surface0], startPoint: .top, endPoint: .bottom)
                    .frame(height: 24)
                    .allowsHitTesting(false)
            }
            .overlay {
                if transcript.items.isEmpty { emptyState }
            }
            .onChange(of: scrollSignature) {
                withAnimation(.easeOut(duration: 0.15)) { scrollToEnd(proxy) }
            }
            .onChange(of: blocks.count) { old, new in
                // A whole history lands at once and the rows above are measured only as they are
                // drawn, so a single scroll can settle past the end — nudge it until it holds.
                guard new - old > 3 else { return }
                Task { @MainActor in
                    for delay in [0.05, 0.25, 0.6, 1.2] {
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        scrollToEnd(proxy)
                    }
                }
            }
            .task(id: sessionId) {
                try? await Task.sleep(nanoseconds: 400_000_000)
                scrollToEnd(proxy)
            }
            .onChange(of: currentMatch) { _, match in
                guard let match else { return }
                reveal(match)
                Task { @MainActor in
                    // Let the unfolded rows exist before asking the scroll view to go there; a second
                    // pass settles the offset once the group's real height is known. The nil in between
                    // needs its own frame, or SwiftUI sees id → id and does nothing.
                    for delay in [0.05, 0.45] {
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        guard currentMatch == match else { return }
                        findTarget = nil
                        try? await Task.sleep(nanoseconds: 40_000_000)
                        guard currentMatch == match else { return }
                        findTarget = match.blockId
                    }
                }
            }
        }
    }

    /// Anchors on the last row rather than a trailing spacer: inside a `LazyVStack` the spacer can
    /// be placed before the rows above it are measured, which leaves the view scrolled past the end.
    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if isRunning, !lastBlockIsStreamingText {
            proxy.scrollTo("status", anchor: .bottom)
        } else if let last = blocks.last?.id {
            proxy.scrollTo(last, anchor: .bottom)
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    @ViewBuilder
    private func blockView(_ block: TranscriptBlock) -> some View {
        switch block {
        case .user(let item):
            if case .user(let text, let images) = item.kind {
                UserMessageView(text: text, images: images, keyPrefix: item.id)
                    .contextMenu { messageMenu(text, itemId: item.id) }
            }
        case .assistant(let item):
            if case .assistantText(let text, let streaming) = item.kind {
                AssistantMessageView(text: text, streaming: streaming)
                    .contextMenu { messageMenu(text, itemId: item.id) }
            }
        case .activity(let group):
            ActivityGroupView(group: group, expandedGroups: $expandedGroups, expandedSteps: $expandedSteps, subagents: transcript.subagents)
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

    /// Can the conversation be cut here? Only at a prompt of a Claude session the Mac still has.
    private func canRewind(_ itemId: String) -> Bool {
        guard !isChat, agent == .claude, model.supportsQueue, AppModel.entryUUID(forItemId: itemId) != nil else { return false }
        return model.isConnected && !isRunning
    }

    @ViewBuilder
    private func messageMenu(_ text: String, itemId: String) -> some View {
        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
        Button("Read aloud", systemImage: "speaker.wave.2") { model.narrator.speak(text) }
        ShareLink(item: text) { Label("Share…", systemImage: "square.and.arrow.up") }
        Button("Quote in reply", systemImage: "text.quote") {
            let quoted = text.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
            draft = draft.isEmpty ? quoted + "\n\n" : draft + "\n\n" + quoted + "\n\n"
            composerFocused = true
        }
        if canRewind(itemId) {
            Button("Rewind to here…", systemImage: "arrow.counterclockwise") { confirmRewind = itemId }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: isDesktop ? "eye" : (isChat ? "bubble.left.and.bubble.right" : "asterisk"))
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(isDesktop ? CDS.textMuted : agent.tint)
            Text(isDesktop ? "Watching" : (isChat ? "Quick chat" : (summary?.projectName ?? "New session")))
                .font(.title3.weight(.semibold)).foregroundStyle(CDS.textPrimary)
            Text(isDesktop ? "This session is open on the Mac. New activity shows up here live."
                 : (isChat ? "Ask \(agentName) anything — no project, no tools." : "What should \(agentName) work on?"))
                .font(CDS.body).foregroundStyle(CDS.textMuted).multilineTextAlignment(.center)
        }
        .padding(32)
    }

    private var lastBlockIsStreamingText: Bool {
        if case .assistant(let item)? = blocks.last, case .assistantText(_, true) = item.kind { return true }
        return false
    }

    private var livePhase: String {
        if state?.status == .awaitingPermission { return "Waiting for approval…" }
        if case .activity(let group)? = blocks.last, group.isLive { return group.phase }
        return "Working…"
    }

    /// Changes whenever something worth scrolling to happens (new row or streamed text growth).
    private var scrollSignature: String {
        guard let last = transcript.items.last else { return "" }
        switch last.kind {
        case .assistantText(let t, _), .thinking(let t, _): return "\(transcript.items.count):\(last.id):\(t.count)"
        default: return "\(transcript.items.count):\(last.id):\(isRunning)"
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !files.isEmpty || !macFiles.isEmpty else { return }
        // Files already on the Mac travel as path references (the agent reads them in place), not bytes.
        var fullText = text
        if !macFiles.isEmpty {
            let refs = macFiles.map { "- \($0)" }.joined(separator: "\n")
            fullText += (fullText.isEmpty ? "" : "\n\n") + "Attached files on the Mac:\n\(refs)"
        }
        model.prompt(sessionId, text: fullText, attachments: files.isEmpty ? nil : files)
        draft = ""
        files = []
        macFiles = []
    }
}

// MARK: - Composer dock

/// Everything pinned above the keyboard: permission card, notices, and the composer itself.
struct ComposerDock: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: String
    @Binding var files: [Attachment]
    @Binding var macFiles: [String]
    var focused: FocusState<Bool>.Binding
    let sessionId: String
    let state: SessionState?
    let summary: SessionSummary?
    let modelId: String?
    let pending: PermissionRequest?
    let isRunning: Bool
    let isDesktop: Bool
    let isChat: Bool
    @Binding var handsFree: Bool
    let onSend: () -> Void
    let onShowPermission: (PermissionRequest) -> Void

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showMacPicker = false
    @State private var recorder = VoiceRecorder()
    @State private var dictation = Dictation()
    /// The draft as it was when dictation started; live results are appended after it.
    @State private var dictationBase = ""
    @State private var attachError: String?
    @State private var fileSearchTask: Task<Void, Never>?
    /// Hands-free: the reply already read out, and the pause that sends what was dictated.
    @State private var spokenReplyId: String?
    @State private var showPalette = false
    @State private var showCamera = false
    @State private var markup: MarkupTarget?

    /// An image in the attachment strip being drawn on.
    private struct MarkupTarget: Identifiable {
        let index: Int
        let image: UIImage
        let filename: String
        var id: Int { index }
    }
    @State private var silenceTask: Task<Void, Never>?

    private var agent: AgentKind { state?.agent ?? summary?.agent ?? .claude }
    private var isCodex: Bool { agent == .codex }
    /// Claude chats run on Sonnet by default; the model chip still switches it.

    // Attachments work on every session: hosted sessions get inline images, while desktop / watched
    // sessions receive all files (images included) staged to disk on the Mac and referenced by path.
    private var canAttach: Bool { model.isConnected }
    private var hasAttachments: Bool { !files.isEmpty || !macFiles.isEmpty }
    private var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasAttachments) && model.isConnected
    }

    var body: some View {
        VStack(spacing: 8) {
            if let pending {
                if pending.isQuestion {
                    QuestionCard(request: pending, compact: true, onDetails: { onShowPermission(pending) })
                        .id(pending.id)
                } else if pending.isPlanReview {
                    PlanDockCard(request: pending, onReview: { onShowPermission(pending) })
                } else {
                    PermissionDockCard(request: pending, onDetails: { onShowPermission(pending) })
                }
            }
            if let queued = state?.queued, !queued.isEmpty {
                QueuedPromptsStrip(sessionId: sessionId, queued: queued)
            }
            if handsFree { handsFreeStrip }
            if let error = state?.lastError, state?.status == .exited {
                notice(error, tint: CDS.danger)
            }
            if isDesktop {
                notice(desktopNotice, tint: CDS.textMuted)
            }
            suggestionsPanel
            composer
        }
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
        .background(CDS.surface0)
        .onChange(of: draft) { _, _ in handleDraftChange() }
        .onChange(of: state?.status) { _, status in
            if handsFree, status == .idle { speakLatestReply() }
        }
        .onChange(of: handsFree) { _, on in
            if on {
                spokenReplyId = lastReply?.id   // start with the next reply, not one already read
                if state?.status != .running, state?.status != .awaitingPermission, !isRunning { Task { await startDictation() } }
            } else {
                model.narrator.stop()
                silenceTask?.cancel()
                if dictation.isListening { dictation.cancel() }
            }
        }
        .onChange(of: dictation.isListening) { was, listening in
            // The recognizer gave up on its own (silence): in hands-free, whatever was said goes out.
            if handsFree, was, !listening { silenceTask?.cancel(); sendDictated() }
        }
    }

    private var handsFreeStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: model.narrator.isSpeaking ? "speaker.wave.2.fill" : (dictation.isListening ? "mic.fill" : "waveform.and.mic"))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(agent.tint)
            Text(model.narrator.isSpeaking ? "Hands-free · reading the reply" : (dictation.isListening ? "Hands-free · listening, pause to send" : (isRunning ? "Hands-free · waiting for the reply" : "Hands-free · tap the mic or wait")))
                .font(CDS.caption).foregroundStyle(CDS.textSecondary).lineLimit(1)
            Spacer(minLength: 4)
            if model.narrator.isSpeaking {
                Button("Skip") { model.narrator.stop(); Task { await startDictation() } }.font(CDS.caption)
            }
            Button { handsFree = false } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(CDS.textMuted) }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(CDS.surface2, in: RoundedRectangle(cornerRadius: CDS.radius))
        .overlay(RoundedRectangle(cornerRadius: CDS.radius).strokeBorder(agent.tint.opacity(0.4)))
    }

    private var lastReply: TranscriptItem? {
        model.transcripts[sessionId]?.items.last { if case .assistantText = $0.kind { return true } else { return false } }
    }

    /// Reads the reply that just finished, then opens the mic for the answer.
    private func speakLatestReply() {
        guard let reply = lastReply, reply.id != spokenReplyId, case .assistantText(let text, false) = reply.kind else { return }
        spokenReplyId = reply.id
        model.narrator.speak(text, itemId: reply.id) {
            guard handsFree else { return }
            Task { await startDictation() }
        }
    }

    /// In hands-free, a pause of a couple of seconds after speaking sends the prompt.
    private func armSilenceTimer() {
        silenceTask?.cancel()
        guard handsFree, dictation.isListening else { return }
        silenceTask = Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled, handsFree, dictation.isListening else { return }
            dictation.stop()
            sendDictated()
        }
    }

    private func sendDictated() {
        guard handsFree, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSend()
    }

    /// What "this session lives on the Mac" means for the agent in question.
    private var desktopNotice: String {
        if agent == .codex {
            return "Open in the Codex app on the Mac — this is a live view; what you send is queued there for the session to pick up."
        }
        return "Open in \(summary?.sourceLabel ?? "Desktop") on the Mac — messages are delivered there. Permission prompts come here when the Mac's hook is on (Host → Settings), otherwise they're answered on the Mac."
    }

    private func notice(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption).foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasAttachments || recorder.isRecording { attachmentStrip }
            if dictation.isListening { dictationStrip }
            TextField(isDesktop ? "Message this session" : "Message \(agent.label)", text: $draft, axis: .vertical)
                .lineLimit(1...8)
                .textFieldStyle(.plain)
                .font(CDS.prose)
                .foregroundStyle(CDS.textPrimary)
                .focused(focused)
                .disabled(!model.isConnected)
                .padding(.horizontal, 6).padding(.top, 6)
            HStack(spacing: 6) {
                if canAttach {
                    if recorder.isRecording {
                        recordingControls
                    } else if dictation.isListening {
                        dictationControls
                    } else {
                        attachButton
                        micButton
                    }
                }
                if !isChat, model.supportsQueue, !recorder.isRecording, !dictation.isListening {
                    paletteButton
                }
                // A chat has no tools, so there is nothing to approve — only the model matters.
                // A session owned by the Mac cannot be reconfigured from here at all.
                if isDesktop {
                    EmptyView()
                } else if isCodex {
                    Menu { codexModelSection } label: { ComposerChipLabel(text: modelLabel) }
                    if !isChat {
                        Menu { codexControlSection } label: { ComposerChipLabel(text: codexModeLabel, systemImage: codexModeIcon) }
                    }
                } else if !isDesktop {
                    Menu { modelSection } label: { ComposerChipLabel(text: modelLabel) }
                    if !isChat {
                        Menu { permissionSection } label: { ComposerChipLabel(text: modeLabel, systemImage: modeIcon) }
                    }
                }
                if let context = model.contextUsage(sessionId), context.fraction >= 0.5 {
                    contextChip(context)
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
                        .background(canSend ? agent.tint : CDS.fillControl, in: Circle())
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
        .onChange(of: dictation.text) { _, text in
            guard dictation.isListening || !text.isEmpty else { return }
            let sep = dictationBase.isEmpty || dictationBase.hasSuffix("\n") || dictationBase.hasSuffix(" ") ? "" : " "
            draft = dictationBase + (text.isEmpty ? "" : sep + text)
            if !text.isEmpty { armSilenceTimer() }
        }
        .onChange(of: dictation.failure) { _, failure in
            switch failure {
            case .microphone: attachError = "Microphone access is off. Enable it in Settings to dictate."
            case .speech: attachError = "Speech recognition is off. Enable it in Settings to dictate."
            case .unavailable: attachError = "Speech recognition isn't available right now."
            case nil: break
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItems, maxSelectionCount: 4,
                      matching: .any(of: [.images, .videos]))
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in loadFiles(result) }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let data = image.jpegData(compressionQuality: 0.9),
                   let att = Media.imageAttachment(from: data, filename: "photo-\(shortStamp()).jpg") {
                    files.append(att)
                }
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $markup) { target in
            MarkupView(image: target.image) { marked in
                guard target.index < files.count, let data = marked.jpegData(compressionQuality: 0.9),
                      let att = Media.imageAttachment(from: data, filename: target.filename) else { return }
                files[target.index] = att
            }
        }
        .sheet(isPresented: $showPalette) {
            PaletteView(sessionId: sessionId, draft: draft) { insert in
                let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                draft = trimmed.isEmpty ? insert : draft + (draft.hasSuffix(" ") || draft.hasSuffix("\n") ? "" : "\n\n") + insert
                focused.wrappedValue = true
            }
        }
        .sheet(isPresented: $showMacPicker) {
            MacFilePicker(sessionId: sessionId) { path in
                if !macFiles.contains(path) { macFiles.append(path) }
            }
        }
        .alert("Can't do that", isPresented: Binding(get: { attachError != nil }, set: { if !$0 { attachError = nil } })) {
            Button("OK", role: .cancel) { attachError = nil }
        } message: { Text(attachError ?? "") }
    }

    // MARK: attach controls

    /// Opens the palette: the project's commands, skills and sub-agents, plus your saved prompts.
    private var paletteButton: some View {
        Button { showPalette = true } label: {
            Image(systemName: "command")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(CDS.textSecondary)
                .frame(width: 32, height: 32)
                .background(CDS.fillControl, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!model.isConnected)
        .accessibilityLabel("Commands, skills and saved prompts")
    }

    /// How full the context window is, once it is worth knowing — tap to compact.
    private func contextChip(_ usage: ContextWindow.Usage) -> some View {
        Menu {
            Section("Context") { Text("\(usage.label) · \(usage.percentLabel) of the window") }
            Button("Compact the conversation", systemImage: "arrow.down.right.and.arrow.up.left") { model.compact(sessionId) }
                .disabled(isRunning || isDesktop || agent != .claude || !model.isConnected)
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .trim(from: 0, to: usage.fraction)
                    .stroke(contextTint(usage), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 11, height: 11)
                    .background(Circle().stroke(CDS.border, lineWidth: 2.5).frame(width: 11, height: 11))
                Text(usage.percentLabel)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(usage.isTight ? contextTint(usage) : CDS.textSecondary)
            .padding(.horizontal, 8).frame(height: 28)
            .background(CDS.fillNeutral, in: Capsule())
            .contentShape(Capsule())
        }
        .accessibilityLabel("Context \(usage.percentLabel) full")
    }

    private func contextTint(_ usage: ContextWindow.Usage) -> Color {
        if usage.isCritical { return CDS.dangerFill }
        if usage.isTight { return CDS.warningFill }
        return CDS.textSecondary
    }

    private var attachButton: some View {
        Menu {
            if CameraPicker.isAvailable {
                Button("Take Photo", systemImage: "camera") { showCamera = true }
            }
            Button("Photo or Video", systemImage: "photo.on.rectangle") { showPhotoPicker = true }
            Button("File", systemImage: "doc") { showFileImporter = true }
            Button("File on Mac", systemImage: "externaldrive") { showMacPicker = true }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(CDS.textSecondary)
                .frame(width: 32, height: 32)
                .background(CDS.fillControl, in: Circle())
        }
        .accessibilityLabel("Attach a photo, video, or file")
    }

    /// Tap dictates straight into the draft; hold for the older voice-memo attachment.
    private var micButton: some View {
        Menu {
            Button("Dictate", systemImage: "waveform") { Task { await startDictation() } }
            Button("Record a voice memo", systemImage: "mic") { Task { await startRecording() } }
        } label: {
            Image(systemName: "mic")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(CDS.textSecondary)
                .frame(width: 32, height: 32)
                .background(CDS.fillControl, in: Circle())
        } primaryAction: {
            Task { await startDictation() }
        }
        .accessibilityLabel("Dictate (hold for a voice memo)")
    }

    /// While dictating the mic becomes a live meter with cancel / done.
    private var dictationControls: some View {
        HStack(spacing: 6) {
            Button { dictation.cancel(); draft = dictationBase } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(CDS.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(CDS.fillControl, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel dictation")

            LevelMeter(level: dictation.level)
                .padding(.horizontal, 10).frame(height: 32)
                .background(CDS.fillControl, in: Capsule())

            Button { dictation.stop(); focused.wrappedValue = true } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(CDS.onPrimary)
                    .frame(width: 32, height: 32)
                    .background(CDS.fillPrimary, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Finish dictation")
        }
    }

    private var dictationStrip: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform").font(.system(size: 12, weight: .medium)).foregroundStyle(agent.tint)
            ShimmerText(text: dictation.text.isEmpty ? "Listening…" : "Dictating…")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
    }

    private func startDictation() async {
        guard !recorder.isRecording else { return }
        dictationBase = draft
        _ = await dictation.start()
    }

    /// The mic swaps for a live timer + cancel/stop while recording.
    private var recordingControls: some View {
        HStack(spacing: 6) {
            Button { recorder.cancel() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(CDS.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(CDS.fillControl, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel recording")

            HStack(spacing: 5) {
                Circle().fill(CDS.danger).frame(width: 8, height: 8)
                Text(timeString(recorder.elapsed)).font(.caption.monospacedDigit()).foregroundStyle(CDS.textSecondary)
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(CDS.fillControl, in: Capsule())

            Button { Task { await finishRecording() } } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(CDS.onPrimary)
                    .frame(width: 32, height: 32)
                    .background(CDS.danger, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop recording")
        }
    }

    // MARK: slash commands & @-file mentions

    private struct SuggestionRow: Identifiable {
        let id: String
        let icon: String
        let title: String
        let mono: Bool
        let pick: () -> Void
    }

    /// The "/" command query when the draft is a single leading-slash token (no space yet).
    private var slashQuery: String? {
        guard draft.first == "/" else { return nil }
        let rest = draft.dropFirst()
        guard !rest.contains(where: { $0.isWhitespace }) else { return nil }
        return String(rest)
    }

    /// The "@" mention query being typed at the end of the draft (preceded by start/space), if any.
    private var mentionQuery: String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at > draft.startIndex, !draft[draft.index(before: at)].isWhitespace { return nil }
        let after = draft[draft.index(after: at)...]
        guard !after.contains(where: { $0.isWhitespace }) else { return nil }
        return String(after)
    }

    /// What "/" offers: the CLI's own commands plus the project's commands and skills from `.claude`.
    private var slashCommands: [String] {
        let advertised = (state?.slashCommands ?? []).map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
        let fromPalette = (model.palettes[sessionId] ?? []).filter { $0.kind != .agent }.map(\.name)
        var seen = Set<String>()
        return (fromPalette + advertised).filter { seen.insert($0).inserted }
    }

    private var slashMatches: [String] {
        guard let q = slashQuery, !slashCommands.isEmpty else { return [] }
        let hits = q.isEmpty ? slashCommands : slashCommands.filter { $0.lowercased().contains(q.lowercased()) }
        return Array(hits.prefix(30))
    }

    private var mentionMatches: [String] {
        guard let q = mentionQuery else { return [] }
        let all = model.fileMatches
        let hits = q.isEmpty ? all : all.filter { $0.lowercased().contains(q.lowercased()) }
        return Array(hits.prefix(30))
    }

    private var suggestionRows: [SuggestionRow] {
        if !slashMatches.isEmpty {
            return slashMatches.map { cmd in
                SuggestionRow(id: "/\(cmd)", icon: "terminal", title: "/\(cmd)", mono: true) { draft = "/\(cmd) " }
            }
        }
        if mentionQuery != nil {
            return mentionMatches.map { path in
                SuggestionRow(id: path, icon: "doc", title: path, mono: false) { insertMention(path) }
            }
        }
        return []
    }

    @ViewBuilder private var suggestionsPanel: some View {
        let rows = suggestionRows
        if !rows.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        Button(action: row.pick) {
                            HStack(spacing: 8) {
                                Image(systemName: row.icon)
                                    .font(.system(size: 13)).foregroundStyle(CDS.textMuted).frame(width: 18)
                                Text(row.title)
                                    .font(row.mono ? CDS.code : CDS.body).foregroundStyle(CDS.textPrimary)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if row.id != rows.last?.id { Divider().overlay(CDS.border).padding(.leading, 36) }
                    }
                }
            }
            .frame(maxHeight: 220)
            .background(CDS.surface2, in: RoundedRectangle(cornerRadius: CDS.radius))
            .overlay(RoundedRectangle(cornerRadius: CDS.radius).strokeBorder(CDS.border))
        }
    }

    private func insertMention(_ path: String) {
        guard let at = draft.lastIndex(of: "@") else { return }
        draft = String(draft[..<at]) + "@" + path + " "
    }

    /// Debounced file search for the "@" picker; cancels when the mention token goes away.
    private func handleDraftChange() {
        guard let q = mentionQuery else { fileSearchTask?.cancel(); return }
        fileSearchTask?.cancel()
        fileSearchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            model.requestFiles(sessionId, query: q)
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(files.enumerated()), id: \.offset) { index, file in
                    fileChip(file) { files.remove(at: index) }
                        .onTapGesture {
                            // Tapping a picture opens it for drawing on.
                            guard file.mediaType.hasPrefix("image/"), let data = Data(base64Encoded: file.base64),
                                  let image = UIImage(data: data) else { return }
                            markup = MarkupTarget(index: index, image: image, filename: file.filename)
                        }
                }
                ForEach(Array(macFiles.enumerated()), id: \.offset) { index, path in
                    macFileChip(path) { macFiles.remove(at: index) }
                }
            }
            .padding(.horizontal, 6)
        }
    }

    private func macFileChip(_ path: String, remove: @escaping () -> Void) -> some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive")
                    .font(.system(size: 16)).foregroundStyle(CDS.textSecondary).frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text((path as NSString).lastPathComponent).font(.caption).foregroundStyle(CDS.textPrimary).lineLimit(1)
                    Text("on Mac").font(.caption2).foregroundStyle(CDS.textMuted)
                }
            }
            .padding(.leading, 8).padding(.trailing, 16).padding(.vertical, 8)
            .frame(maxWidth: 190, alignment: .leading)
            .background(CDS.fillControl, in: RoundedRectangle(cornerRadius: 8))
            removeBadge(remove)
        }
    }

    /// Images show as thumbnails, everything else as a name + size chip.
    private func fileChip(_ file: Attachment, remove: @escaping () -> Void) -> some View {
        ZStack(alignment: .topTrailing) {
            if file.mediaType.hasPrefix("image/"), let ui = UIImage(data: Data(base64Encoded: file.base64) ?? Data()) {
                Image(uiImage: ui).resizable().scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .bottomLeading) {
                        Image(systemName: "pencil.tip.crop.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(.white, .black.opacity(0.5))
                            .padding(3)
                    }
                    .accessibilityHint("Tap to mark up")
            } else {
            HStack(spacing: 8) {
                Image(systemName: iconName(for: file.mediaType))
                    .font(.system(size: 18))
                    .foregroundStyle(CDS.textSecondary)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.filename).font(.caption).foregroundStyle(CDS.textPrimary).lineLimit(1)
                    Text(Media.humanSize(file.approxBytes)).font(.caption2).foregroundStyle(CDS.textMuted)
                }
            }
            .padding(.leading, 8).padding(.trailing, 16).padding(.vertical, 8)
            .frame(maxWidth: 190, alignment: .leading)
            .background(CDS.fillControl, in: RoundedRectangle(cornerRadius: 8))
            }
            removeBadge(remove)
        }
    }

    private func removeBadge(_ remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.white, .black.opacity(0.5))
        }
        .buttonStyle(.plain)
        .padding(2)
    }

    private func iconName(for mediaType: String) -> String {
        if mediaType.hasPrefix("video/") { return "film" }
        if mediaType.hasPrefix("audio/") { return "waveform" }
        if mediaType == "application/pdf" { return "doc.richtext" }
        if mediaType.hasPrefix("text/") { return "doc.text" }
        return "doc"
    }

    private func loadPicked(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task { @MainActor in
            for item in items {
                let types = item.supportedContentTypes
                let videoType = types.first { $0.conforms(to: .movie) || $0.conforms(to: .video) }
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                if let videoType {
                    let ext = videoType.preferredFilenameExtension ?? "mov"
                    let mime = videoType.preferredMIMEType ?? "video/quicktime"
                    if let att = Media.attachment(data: data, filename: "video-\(shortStamp()).\(ext)", mediaType: mime) {
                        files.append(att)
                    } else {
                        attachError = "That video is larger than \(Media.humanSize(Media.maxAttachmentBytes))."
                    }
                } else if let att = Media.imageAttachment(from: data, filename: "photo-\(shortStamp()).jpg") {
                    // As a file, not an inline image block: files reach every kind of session (hosted ones
                    // inline them, desktop ones get them staged on the Mac), inline images only hosted ones.
                    files.append(att)
                } else {
                    attachError = "That image could not be read."
                }
            }
            pickerItems = []
        }
    }

    private func loadFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            if let att = Media.attachment(fileURL: url) {
                files.append(att)
            } else {
                attachError = "\(url.lastPathComponent) is empty or larger than \(Media.humanSize(Media.maxAttachmentBytes))."
            }
        }
    }

    private func startRecording() async {
        if dictation.isListening { dictation.stop() }
        let ok = await recorder.start()
        if !ok { attachError = "Microphone access is off. Enable it in Settings to record voice memos." }
    }

    private func finishRecording() async {
        recorder.stop()
        if let att = recorder.attachment() { files.append(att) }
        let transcript = await recorder.transcribe()
        recorder.discardFile()
        if !transcript.isEmpty {
            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            draft = trimmed.isEmpty ? transcript : trimmed + "\n" + transcript
        }
    }

    private func shortStamp() -> String {
        let f = DateFormatter(); f.dateFormat = "HHmmss"; return f.string(from: Date())
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t); return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var modelLabel: String { model.modelLabel(modelId, agent: agent) }

    // MARK: Codex chips

    private var codexPolicy: CodexApprovalPolicy? { state?.permissionMode.flatMap(CodexApprovalPolicy.init(rawValue:)) }
    private var codexSandbox: CodexSandboxMode? { state?.sandbox.flatMap(CodexSandboxMode.init(rawValue:)) }
    private var codexModeLabel: String { codexPolicy?.shortLabel ?? "Approvals" }
    private var codexModeIcon: String { codexPolicy?.symbol ?? "shield" }

    private var codexModelSection: some View {
        Section("Model") {
            if model.codexModels.isEmpty {
                Button("Loading models…") { model.requestCodexModels() }
            }
            ForEach(model.codexModels) { m in
                Button { model.setModel(sessionId, model: m.id) } label: {
                    if modelId == m.id { Label(m.label, systemImage: "checkmark") } else { Text(m.label) }
                }
            }
        }
    }

    /// Approval policy, plus sandbox and reasoning effort as submenus — all take effect on the next turn.
    @ViewBuilder
    private var codexControlSection: some View {
        Section("Ask before acting") {
            ForEach(CodexApprovalPolicy.allCases, id: \.self) { policy in
                Button { model.setPermissionMode(sessionId, mode: policy.rawValue) } label: {
                    Label(policy.label, systemImage: codexPolicy == policy ? "checkmark" : policy.symbol)
                }
            }
        }
        Menu {
            ForEach(CodexSandboxMode.allCases, id: \.self) { mode in
                Button { model.setSandbox(sessionId, mode: mode.rawValue) } label: {
                    Label(mode.label, systemImage: codexSandbox == mode ? "checkmark" : mode.symbol)
                }
            }
        } label: {
            Label("Sandbox: \(codexSandbox?.label ?? "default")", systemImage: codexSandbox?.symbol ?? "folder")
        }
        if let efforts = model.codexModels.first(where: { $0.id == modelId })?.efforts, !efforts.isEmpty {
            Menu {
                ForEach(efforts, id: \.self) { effort in
                    Button { model.setEffort(sessionId, effort: effort) } label: {
                        if state?.effort == effort { Label(effort.capitalized, systemImage: "checkmark") } else { Text(effort.capitalized) }
                    }
                }
            } label: {
                Label("Reasoning: \(state?.effort?.capitalized ?? "default")", systemImage: "brain")
            }
        }
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

/// Fuzzy-search the Mac's project files and attach the picked one — the same `listFiles` backend the
/// composer's "@" mentions use, presented as a sheet for attaching files that live on the Mac.
struct MacFilePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sessionId: String
    let onPick: (String) -> Void
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if model.fileMatches.isEmpty {
                    Text(query.isEmpty ? "Type to search files on the Mac" : "No matching files")
                        .font(CDS.body).foregroundStyle(CDS.textMuted)
                        .listRowBackground(CDS.surface0)
                } else {
                    ForEach(model.fileMatches, id: \.self) { path in
                        Button { onPick(path); dismiss() } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "doc").font(.system(size: 14)).foregroundStyle(CDS.textMuted).frame(width: 20)
                                Text(path).font(CDS.body).foregroundStyle(CDS.textPrimary)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(CDS.surface0)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(CDS.surface0)
            .searchable(text: $query, prompt: "Search files on the Mac")
            .onChange(of: query) { _, q in model.requestFiles(sessionId, query: q) }
            .onAppear { model.requestFiles(sessionId, query: "") }
            .navigationTitle("Attach from Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CDS.surface0, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// The transcript as a shareable Markdown file, rendered only when the share sheet actually asks for it.
struct TranscriptDocument: Transferable {
    let items: [TranscriptItem]
    let options: TranscriptExport.Options

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: UTType(filenameExtension: "md") ?? .plainText) { doc in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ccremote-export", isDirectory: true)
                .appendingPathComponent(TranscriptExport.fileName(for: doc.options.title))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try TranscriptExport.markdown(items: doc.items, options: doc.options).write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
        ProxyRepresentation { doc in TranscriptExport.markdown(items: doc.items, options: doc.options) }
    }
}

/// A row of bars that follow the microphone level while dictating.
struct LevelMeter: View {
    let level: Float
    private let bars = 9

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<bars, id: \.self) { i in
                Capsule()
                    .fill(CDS.textSecondary)
                    .frame(width: 3, height: height(for: i))
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }

    private func height(for i: Int) -> CGFloat {
        // Centre bars react most, edges least — reads like a waveform rather than a VU strip.
        let centre = Double(bars - 1) / 2
        let weight = 1 - abs(Double(i) - centre) / (centre + 1)
        return 4 + CGFloat(Double(level) * weight) * 14
    }
}

private struct LinkedFile: Identifiable {
    let link: FileLink
    var id: String { "\(link.path):\(link.line ?? 0)" }
}
