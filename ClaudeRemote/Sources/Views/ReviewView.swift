import SwiftUI
import ClaudeRemoteCore

/// A branch reviewed like a pull request: every changed file against the base, remarks on ranges of
/// lines, and all of them handed to the agent as one message.
struct ReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sessionId: String

    @State private var changingBase = false
    @State private var baseText = ""
    @State private var generalRemark = false
    @State private var remarkText = ""

    private var review: AppModel.ReviewState? { model.reviews[sessionId] }
    private var comments: [ReviewComment] { model.reviewDrafts[sessionId] ?? [] }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if review?.loading == true && (review?.files.isEmpty ?? true) {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading the branch…").font(CDS.caption).foregroundStyle(CDS.textMuted) }
                            .listRowBackground(CDS.surface0)
                    }
                    if let error = review?.error {
                        Text(error).font(CDS.caption).foregroundStyle(CDS.danger).listRowBackground(CDS.surface0)
                    }
                    if let files = review?.files, files.isEmpty, review?.loading == false, review?.error == nil {
                        Text("No changes against the base.").font(CDS.body).foregroundStyle(CDS.textMuted).listRowBackground(CDS.surface0)
                    }
                    ForEach(review?.files ?? []) { file in
                        NavigationLink {
                            ReviewFileView(sessionId: sessionId, file: file)
                        } label: {
                            fileRow(file)
                        }
                        .listRowBackground(CDS.surface0)
                    }
                } header: {
                    HStack {
                        Text(review?.base.map { "Against \($0.count == 40 ? String($0.prefix(7)) : $0)" } ?? "Changes")
                        Spacer()
                        Button("Change base") { baseText = review?.base ?? ""; changingBase = true }.font(.caption)
                    }
                } footer: {
                    if let files = review?.files, !files.isEmpty {
                        let add = files.reduce(0) { $0 + $1.additions }, del = files.reduce(0) { $0 + $1.deletions }
                        Text("\(files.count) file\(files.count == 1 ? "" : "s") · +\(add) −\(del) · tap lines in a file to comment on them")
                    }
                }
                if !comments.isEmpty {
                    Section("Your remarks") {
                        ForEach(comments) { comment in
                            VStack(alignment: .leading, spacing: 3) {
                                if let path = comment.path { Text(path).font(CDS.codeSmall).foregroundStyle(CDS.textMuted).lineLimit(1).truncationMode(.middle) }
                                Text(comment.text).font(CDS.body).foregroundStyle(CDS.textPrimary)
                            }
                            .listRowBackground(CDS.surface0)
                        }
                        .onDelete { offsets in
                            for id in offsets.map({ comments[$0].id }) { model.removeReviewComment(sessionId, id: id) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(CDS.surface0)
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CDS.surface0, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Add a general remark…", systemImage: "text.bubble") { remarkText = ""; generalRemark = true }
                        Button("Reload", systemImage: "arrow.clockwise") { model.requestReview(sessionId, base: review?.base) }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !comments.isEmpty {
                    Button {
                        model.sendReview(sessionId)
                        model.present(sessionId, kind: .agent)
                        dismiss()
                    } label: {
                        Label("Send \(comments.count) remark\(comments.count == 1 ? "" : "s") to the agent", systemImage: "arrow.up.message")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(CDSButtonStyle(variant: .primary, fullWidth: true))
                    .padding(12)
                    .background(CDS.surface0)
                }
            }
            .alert("Compare against", isPresented: $changingBase) {
                TextField("origin/main, a branch or a commit", text: $baseText)
                Button("Compare") { model.requestReview(sessionId, base: baseText.trimmingCharacters(in: .whitespaces)) }
                Button("Cancel", role: .cancel) {}
            }
            .alert("A remark on the whole change", isPresented: $generalRemark) {
                TextField("Remark", text: $remarkText, axis: .vertical)
                Button("Add") {
                    let text = remarkText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { model.addReviewComment(sessionId, ReviewComment(path: nil, quote: nil, text: text)) }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .onAppear { if review == nil { model.requestReview(sessionId) } }
    }

    private func fileRow(_ file: ReviewFile) -> some View {
        HStack(spacing: 8) {
            Text(file.status == "?" ? "U" : file.status)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(badgeColor(file.status))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.fileName).font(CDS.body).foregroundStyle(CDS.textPrimary).lineLimit(1)
                if file.path != file.fileName {
                    Text(file.path).font(CDS.caption).foregroundStyle(CDS.textMuted).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            let count = comments.filter { $0.path == file.path }.count
            if count > 0 { CDSChip(text: "\(count)", style: .accent, systemImage: "text.bubble") }
            Text("+\(file.additions) −\(file.deletions)").font(CDS.caption.monospacedDigit()).foregroundStyle(CDS.textMuted)
        }
    }

    private func badgeColor(_ status: String) -> Color {
        switch status {
        case "A", "?": return CDS.success
        case "D": return CDS.danger
        default: return CDS.warningFill
        }
    }
}

/// One file of the review: its diff, where a tapped range of lines becomes a remark.
struct ReviewFileView: View {
    @Environment(AppModel.self) private var model
    let sessionId: String
    let file: ReviewFile
    @State private var selection: Set<Int> = []
    @State private var commenting = false
    @State private var fileRemark = false
    @State private var text = ""

    private var remarks: [ReviewComment] { (model.reviewDrafts[sessionId] ?? []).filter { $0.path == file.path } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if file.truncated {
                    Text("This diff is long; only its beginning came to the phone.").font(CDS.caption).foregroundStyle(CDS.textMuted)
                }
                DiffText(diff: file.diff, selection: $selection)
                ForEach(remarks) { remark in
                    VStack(alignment: .leading, spacing: 4) {
                        if let quote = remark.quote { Text(quote.components(separatedBy: "\n").first ?? "").font(CDS.caption).foregroundStyle(CDS.textMuted) }
                        Text(remark.text).font(CDS.body)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CDS.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: CDS.radius))
                }
            }
            .padding(8)
        }
        .background(CDS.surface0)
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty {
                HStack {
                    Button("Clear") { selection = [] }.buttonStyle(CDSButtonStyle(variant: .secondary))
                    Spacer()
                    Button { text = ""; commenting = true } label: { Label("Comment on these lines", systemImage: "text.bubble") }
                        .buttonStyle(CDSButtonStyle(variant: .primary))
                }
                .padding(12)
                .background(CDS.surface0)
            }
        }
        .navigationTitle(file.fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(CDS.surface0, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { text = ""; fileRemark = true } label: { Image(systemName: "text.bubble") }
                    .accessibilityLabel("Remark on the file")
            }
        }
        .alert("Your remark", isPresented: $commenting) {
            TextField("What should change here?", text: $text, axis: .vertical)
            Button("Add") {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                model.addReviewComment(sessionId, ReviewComment(path: file.path, quote: DiffLines(file.diff).quote(ids: selection), text: trimmed))
                selection = []
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("A remark on \(file.fileName)", isPresented: $fileRemark) {
            TextField("Remark", text: $text, axis: .vertical)
            Button("Add") {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { model.addReviewComment(sessionId, ReviewComment(path: file.path, quote: nil, text: trimmed)) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
