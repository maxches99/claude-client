import SwiftUI
import ClaudeRemoteCore

/// Full details of a permission request; the inline dock card is the quick path. This is where you can
/// review the repo's working-tree changes (git diff) before approving, and choose to remember the rule.
struct PermissionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: PermissionRequest

    @State private var showDiff = false

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
                            Text(diff)
                                .font(CDS.codeSmall).foregroundStyle(CDS.textSecondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(maxHeight: 280)
                        .background(CDS.surface2, in: RoundedRectangle(cornerRadius: CDS.radius))
                        .overlay(RoundedRectangle(cornerRadius: CDS.radius).strokeBorder(CDS.border))
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
