import SwiftUI
import ClaudeRemoteCore

/// Full details of a permission request; the inline dock card is the quick path. This is where you can
/// review the repo's working-tree changes (git diff) before approving, and choose to remember the rule.
struct PermissionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: PermissionRequest

    @State private var showDiff = false
    @State private var diffSelection: Set<Int> = []

    private var diff: String? { model.gitDiffs[request.sessionId] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Image(systemName: ToolIcon.symbol(for: request.toolName))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(CDS.warning)
                            .frame(width: 32, height: 32)
                            .background(CDS.warningBackground, in: RoundedRectangle(cornerRadius: CDS.radius - 2))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(request.displayName ?? ToolSummary.displayName(request.toolName))
                                .font(.headline).foregroundStyle(CDS.textPrimary)
                            if let title = request.title { Text(title).font(CDS.body).foregroundStyle(CDS.textSecondary) }
                        }
                    }
                    if let description = request.description, !description.isEmpty {
                        Text(description).font(.footnote).foregroundStyle(CDS.textSecondary)
                    }
                    ToolInputDetail(name: request.toolName, input: request.input)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(CDS.surface2, in: RoundedRectangle(cornerRadius: CDS.radius))
                        .overlay(RoundedRectangle(cornerRadius: CDS.radius).strokeBorder(CDS.border))
                    reviewSection
                    if let reason = request.decisionReason, !reason.isEmpty {
                        Text(reason).font(CDS.caption).foregroundStyle(CDS.textMuted)
                    }
                    if let session = model.summary(for: request.sessionId) {
                        Text("\(session.projectName) · \(session.title)").font(CDS.caption).foregroundStyle(CDS.textMuted).lineLimit(2)
                    }
                }
                .padding()
            }
            .background(CDS.surface0)
            .safeAreaInset(edge: .bottom) { actionBar }
            .navigationTitle("Permission")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CDS.surface0, for: .navigationBar)
        }
    }

    // MARK: review (git diff)

    @ViewBuilder private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if !showDiff { model.requestGitDiff(request.sessionId) }
                withAnimation { showDiff.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").font(.caption)
                    Text(showDiff ? "Hide working-tree changes" : "Review working-tree changes")
                        .font(CDS.bodyMedium)
                    Spacer()
                    Chevron(expanded: showDiff)
                }
                .foregroundStyle(CDS.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showDiff {
                if let diff {
                    if diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("No uncommitted changes.").font(CDS.caption).foregroundStyle(CDS.textMuted)
                    } else {
                        ScrollView {
                            DiffText(diff: diff, selection: $diffSelection).padding(8)
                        }
                        .frame(maxHeight: 280)
                        .background(CDS.surface2, in: RoundedRectangle(cornerRadius: CDS.radius))
                        .overlay(RoundedRectangle(cornerRadius: CDS.radius).strokeBorder(CDS.border))
                        DiffSelectionBar(sessionId: request.sessionId, diff: diff, selection: $diffSelection) { dismiss() }
                        if diffSelection.isEmpty {
                            Text("Tap a line, then another, to select a range and ask about it.")
                                .font(CDS.caption).foregroundStyle(CDS.textMuted)
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading diff…").font(CDS.caption).foregroundStyle(CDS.textMuted)
                    }
                }
            }
        }
    }

    // MARK: actions

    private var actionBar: some View {
        VStack(spacing: 10) {
            if request.canRemember {
                Button {
                    model.decide(request, allow: true, remember: true)
                    dismiss()
                } label: {
                    Label("Allow & don't ask again", systemImage: "checkmark.seal")
                }
                .buttonStyle(CDSButtonStyle(variant: .primary, fullWidth: true))
            }
            HStack(spacing: 10) {
                Button("Deny") {
                    model.decide(request, allow: false)
                    dismiss()
                }
                .buttonStyle(CDSButtonStyle(variant: .secondary, fullWidth: true))
                Button(request.canRemember ? "Allow once" : "Allow") {
                    model.decide(request, allow: true)
                    dismiss()
                }
                .buttonStyle(CDSButtonStyle(variant: request.canRemember ? .secondary : .primary, fullWidth: true))
            }
        }
        .padding()
        .background(CDS.surface0)
        .overlay(alignment: .top) { Divider().overlay(CDS.border) }
    }
}

/// Renders a unified git diff with added / removed / hunk lines coloured, like a compact diff viewer.
/// Lazy so a large diff scrolls smoothly; caps very long diffs with a trailing note. With a
/// `selection` binding, content lines are tappable: tap one line, then another, to select the range
/// between them (tap a selected line to clear); the owner shows `DiffSelectionBar` for it.
struct DiffText: View {
    let diff: String
    var selection: Binding<Set<Int>>? = nil

    private static let maxLines = 1500

    private let parsed: DiffLines
    private let truncated: Bool

    @State private var anchor: Int?

    init(diff: String, selection: Binding<Set<Int>>? = nil) {
        self.diff = diff
        self.selection = selection
        parsed = DiffLines(diff, maxLines: Self.maxLines)
        truncated = diff.split(separator: "\n", omittingEmptySubsequences: false).count > Self.maxLines
    }

    var body: some View {
        let lines = parsed.lines
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                let selected = selection?.wrappedValue.contains(line.id) ?? false
                Text(line.text.isEmpty ? " " : line.text)
                    .font(CDS.codeSmall)
                    .foregroundStyle(color(for: line.text))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .background(selected ? CDS.accent.opacity(0.22) : background(for: line.text))
                    .overlay(alignment: .leading) {
                        if selected { Rectangle().fill(CDS.accent).frame(width: 2) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if selection != nil, line.isContent { tap(line.id, lines: lines) } }
            }
            if truncated {
                Text("… diff truncated")
                    .font(CDS.caption).foregroundStyle(CDS.textMuted).padding(.top, 4)
            }
        }
        .textSelection(.enabled)
    }

    private func tap(_ id: Int, lines: [DiffLines.Line]) {
        guard let selection else { return }
        var set = selection.wrappedValue
        if let anchor, anchor != id {
            // Second tap: the range between the two, content lines only.
            let lo = min(anchor, id), hi = max(anchor, id)
            set = Set(lines.filter { $0.id >= lo && $0.id <= hi && $0.isContent }.map(\.id))
            self.anchor = nil
        } else if set.contains(id) {
            set = []
            anchor = nil
        } else {
            set = [id]
            anchor = id
        }
        selection.wrappedValue = set
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("# ") { return CDS.textPrimary }
        if line.hasPrefix("@@") { return CDS.accent }
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff --git") || line.hasPrefix("index ") {
            return CDS.textMuted
        }
        if line.hasPrefix("+") { return CDS.success }
        if line.hasPrefix("-") { return CDS.danger }
        return CDS.textSecondary
    }

    private func background(for line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .clear }
        if line.hasPrefix("+") { return CDS.successFill.opacity(0.10) }
        if line.hasPrefix("-") { return CDS.dangerFill.opacity(0.10) }
        return .clear
    }
}

/// What to do with selected diff lines: quote them into the session's composer ("about these lines…"),
/// copy them, or clear the selection.
struct DiffSelectionBar: View {
    @Environment(AppModel.self) private var model
    let sessionId: String
    let diff: String
    @Binding var selection: Set<Int>
    var onAsk: (() -> Void)? = nil

    private var quote: String? { DiffLines(diff).quote(ids: selection) }

    var body: some View {
        if !selection.isEmpty {
            HStack(spacing: 8) {
                Text("\(selection.count) line\(selection.count == 1 ? "" : "s")")
                    .font(CDS.captionMedium).foregroundStyle(CDS.textSecondary)
                Spacer(minLength: 0)
                Button {
                    if let quote { UIPasteboard.general.string = quote }
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(CDSButtonStyle(variant: .secondary))
                    .accessibilityLabel("Copy selection")
                Button {
                    if let quote {
                        model.insertIntoComposer(sessionId, text: quote)
                        selection = []
                        onAsk?()
                    }
                } label: { Label("Ask about this", systemImage: "text.bubble") }
                    .buttonStyle(CDSButtonStyle(variant: .primary))
                Button { selection = [] } label: { Image(systemName: "xmark") }
                    .buttonStyle(CDSButtonStyle(variant: .secondary))
                    .accessibilityLabel("Clear selection")
            }
            .padding(10)
            .background(CDS.surface2, in: RoundedRectangle(cornerRadius: CDS.radiusComposer))
            .overlay(RoundedRectangle(cornerRadius: CDS.radiusComposer).strokeBorder(CDS.border))
            .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        }
    }
}
