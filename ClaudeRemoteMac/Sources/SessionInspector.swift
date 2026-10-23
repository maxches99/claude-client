import SwiftUI
import ClaudeRemoteCore

/// The panel on the right of a session, after the desktop app's: where it runs (host, folder, branch),
/// how full the context window is, and what changed in the working tree.
struct SessionInspector: View {
    @Environment(AppModel.self) private var model
    let sessionId: String
    let onShowGit: () -> Void
    /// The file whose diff is shown in a popover from the Changes card.
    @State private var diffFile: GitFile?

    private var state: SessionState? { model.states[sessionId] }
    private var summary: SessionSummary? { model.summary(for: sessionId) }
    private var transcript: Transcript { model.transcripts[sessionId] ?? Transcript() }
    private var agent: AgentKind { state?.agent ?? summary?.agent ?? .claude }
    private var isChat: Bool { (state?.kind ?? summary?.kind ?? .agent) == .chat }
    private var cwd: String { state?.cwd ?? summary?.cwd ?? "" }
    private var git: GitStatus? { model.gitStatuses[sessionId] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                environment
                context
                if !isChat { changes }
            }
            .padding(12)
        }
        .background(CDS.surface0)
        .task(id: sessionId) {
            guard !isChat, model.isConnected else { return }
            model.requestGitStatus(sessionId)
        }
        .onChange(of: state?.status) { _, status in
            // A finished turn may have touched files.
            if status == .idle, !isChat { model.requestGitStatus(sessionId) }
        }
    }

    // MARK: cards

    private var environment: some View {
        InspectorCard(title: "Environment") {
            InspectorRow(systemImage: "desktopcomputer", text: model.activeMac?.displayName ?? "Host") {
                Circle().fill(model.isConnected ? CDS.successFill : CDS.textMuted).frame(width: 7, height: 7)
            }
            if !isChat, !cwd.isEmpty {
                InspectorRow(systemImage: "folder", text: (cwd as NSString).lastPathComponent, detail: abbreviated(cwd))
            }
            if let git {
                InspectorRow(systemImage: "arrow.triangle.branch", text: git.branch ?? git.detachedAt.map { "detached at \($0)" } ?? "—") {
                    if git.ahead > 0 || git.behind > 0 {
                        Text(aheadBehind(git)).font(CDS.caption.monospacedDigit()).foregroundStyle(CDS.textMuted)
                    }
                }
            }
            InspectorRow(systemImage: agent == .codex ? "circle.hexagongrid" : "asterisk",
                         text: model.modelLabel(state?.model ?? transcript.model, agent: agent),
                         detail: originLabel)
        }
    }

    private var context: some View {
        InspectorCard(title: "Context", summary: { contextSummary }) {
            if let usage = model.contextUsage(sessionId) {
                if usage.isTight {
                    Text("The agent compacts the conversation on its own soon.")
                        .font(CDS.caption).foregroundStyle(CDS.textMuted)
                }
                if state?.origin != .desktop {
                    Button("Compact now") { model.compact(sessionId) }
                        .buttonStyle(CDSButtonStyle(variant: .secondary))
                        .disabled(!model.isConnected)
                }
            }
            if transcript.totalCostUSD > 0 {
                HStack {
                    Text("Cost").font(CDS.body).foregroundStyle(CDS.textSecondary)
                    Spacer()
                    Text(String(format: transcript.totalCostUSD < 0.1 ? "$%.3f" : "$%.2f", transcript.totalCostUSD))
                        .font(CDS.body.monospacedDigit()).foregroundStyle(CDS.textSecondary)
                }
            }
        }
    }

    /// "12% used · 122.6k / 1M" and the bar: what the card shows even when folded.
    @ViewBuilder private var contextSummary: some View {
        if let usage = model.contextUsage(sessionId) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(usage.percentLabel) used").font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary)
                Spacer()
                Text(usage.label).font(CDS.caption.monospacedDigit()).foregroundStyle(CDS.textMuted)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(CDS.fillNeutral)
                    Capsule().fill(usage.isCritical ? CDS.dangerFill : (usage.isTight ? CDS.warningFill : CDS.accent))
                        .frame(width: max(4, geo.size.width * usage.fraction))
                }
            }
            .frame(height: 5)
        } else {
            Text("Shows up after the first reply.").font(CDS.caption).foregroundStyle(CDS.textMuted)
        }
    }

    private var changes: some View {
        InspectorCard(title: "Changes", summary: { changesSummary }) {
            if let git {
                if git.isClean {
                    EmptyView()
                } else {
                    HStack(spacing: 12) {
                        count(git.staged.count, "staged", CDS.gitAdded)
                        count(git.unstaged.count, "changed", CDS.gitModified)
                        count(git.untracked.count, "new", CDS.textSecondary)
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(git.files.prefix(12)) { file in
                            Button { showDiff(file) } label: { fileRow(file) }
                                .buttonStyle(.plain)
                                .popover(item: Binding(get: { diffFile?.id == file.id ? diffFile : nil }, set: { diffFile = $0 }), arrowEdge: .leading) { file in
                                    diffPopover(file)
                                }
                        }
                        if git.files.count > 12 {
                            Text("and \(git.files.count - 12) more").font(CDS.caption).foregroundStyle(CDS.textMuted)
                        }
                    }
                }
                Button("Review changes…", action: onShowGit)
                    .buttonStyle(CDSButtonStyle(variant: .secondary))
            }
        }
    }

    /// "+37,128 −4,404  [Create PR]": what the card shows even when folded.
    @ViewBuilder private var changesSummary: some View {
        if let git {
            if git.isClean {
                Text("Working tree is clean.").font(CDS.caption).foregroundStyle(CDS.textMuted)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "plus.forwardslash.minus").font(.system(size: 11)).foregroundStyle(CDS.textMuted)
                    if let added = git.linesAdded, let removed = git.linesRemoved {
                        Text("+\(added.formatted())").foregroundStyle(CDS.gitAdded)
                        Text("−\(removed.formatted())").foregroundStyle(CDS.gitRemoved)
                    } else {
                        Text("\(git.files.count) files").foregroundStyle(CDS.textSecondary)
                    }
                    Spacer(minLength: 4)
                    // The pull request form lives in the Git sheet (title, body, draft).
                    Button("Create PR", action: onShowGit)
                        .buttonStyle(CDSButtonStyle(variant: .secondary))
                        .controlSize(.small)
                        .disabled(git.branch == nil)
                }
                .font(CDS.bodyMedium.monospacedDigit())
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Reading git status…").font(CDS.caption).foregroundStyle(CDS.textMuted)
            }
        }
    }

    private func fileRow(_ file: GitFile) -> some View {
        HStack(spacing: 6) {
            Text(letter(file)).font(CDS.codeSmall).foregroundStyle(color(file)).frame(width: 12)
            Text(file.fileName)
                .font(CDS.caption).foregroundStyle(CDS.textSecondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if let added = file.added, added > 0 { Text("+\(added)").foregroundStyle(CDS.gitAdded) }
            if let removed = file.removed, removed > 0 { Text("−\(removed)").foregroundStyle(CDS.gitRemoved) }
        }
        .font(CDS.caption.monospacedDigit())
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .help(file.path)
    }

    /// Staged-only changes are diffed against HEAD from the index; anything else from the working tree.
    private func diffKey(_ file: GitFile) -> AppModel.GitFileKey {
        AppModel.GitFileKey(sessionId: sessionId, path: file.path, staged: file.isStaged && !file.hasWorkChanges)
    }

    private func showDiff(_ file: GitFile) {
        let key = diffKey(file)
        if !file.untracked { model.requestGitFileDiff(sessionId, path: key.path, staged: key.staged) }
        diffFile = file
    }

    private func diffPopover(_ file: GitFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(file.path).font(CDS.codeSmall).foregroundStyle(CDS.textSecondary).lineLimit(2).truncationMode(.middle)
            if file.untracked {
                Text(file.added.map { "New file · \($0) lines" } ?? "New file").font(CDS.caption).foregroundStyle(CDS.textMuted)
            } else if let diff = model.gitFileDiffs[diffKey(file)] {
                ScrollView([.vertical, .horizontal]) { DiffText(diff: diff) }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .frame(width: 560, height: file.untracked ? 80 : 420)
    }

    // MARK: helpers

    private var originLabel: String? {
        switch state?.origin ?? summary?.origin {
        case .desktop: return "open on \(summary?.sourceLabel ?? "the host")"
        case .host: return "running on the host"
        default: return nil
        }
    }

    private func abbreviated(_ path: String) -> String {
        path.replacingOccurrences(of: #"^/(Users|home)/[^/]+"#, with: "~", options: .regularExpression)
    }

    private func aheadBehind(_ git: GitStatus) -> String {
        [git.ahead > 0 ? "↑\(git.ahead)" : nil, git.behind > 0 ? "↓\(git.behind)" : nil].compactMap { $0 }.joined(separator: " ")
    }

    private func count(_ n: Int, _ label: String, _ tint: Color) -> some View {
        HStack(spacing: 3) {
            Text("\(n)").font(CDS.bodyMedium.monospacedDigit()).foregroundStyle(n > 0 ? tint : CDS.textMuted)
            Text(label).font(CDS.caption).foregroundStyle(CDS.textMuted)
        }
    }

    private func letter(_ file: GitFile) -> String {
        if file.untracked { return "U" }
        if file.conflicted { return "!" }
        let s = file.workStatus != "." ? file.workStatus : file.indexStatus
        return s == "." ? "M" : s
    }

    private func color(_ file: GitFile) -> Color {
        switch letter(file) {
        case "A", "U": return CDS.gitAdded
        case "D", "!": return CDS.gitRemoved
        default: return CDS.gitModified
        }
    }
}

/// A rounded card with a small title, the way the desktop app's side panel groups things.
/// A rounded card with a title that folds it (▾), the way the desktop app's side panel groups things.
/// `summary` stays visible when folded; the fold is remembered per card.
private struct InspectorCard<Summary: View, Content: View>: View {
    let title: String
    @ViewBuilder let summary: () -> Summary
    @ViewBuilder let content: () -> Content
    @AppStorage private var folded: Bool

    init(title: String, @ViewBuilder summary: @escaping () -> Summary = { EmptyView() }, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.summary = summary
        self.content = content
        _folded = AppStorage(wrappedValue: false, "ccremote.mac.panel.folded.\(title)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { folded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text(title).font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary)
                    Chevron(expanded: !folded)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            summary()
            if !folded { content() }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CDS.surface1, in: RoundedRectangle(cornerRadius: CDS.radiusComposer))
        .overlay(RoundedRectangle(cornerRadius: CDS.radiusComposer).strokeBorder(CDS.border))
    }
}

private struct InspectorRow<Trailing: View>: View {
    let systemImage: String
    let text: String
    var detail: String?
    @ViewBuilder var trailing: () -> Trailing

    init(systemImage: String, text: String, detail: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.systemImage = systemImage
        self.text = text
        self.detail = detail
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: systemImage).font(.system(size: 12)).foregroundStyle(CDS.textMuted).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(text).font(CDS.body).foregroundStyle(CDS.textPrimary).lineLimit(1)
                if let detail {
                    Text(detail).font(CDS.caption).foregroundStyle(CDS.textMuted).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            trailing()
        }
    }
}
