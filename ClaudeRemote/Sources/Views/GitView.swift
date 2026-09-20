import SwiftUI
import ClaudeRemoteCore

/// The session repo from the phone: branch and sync state, staged / unstaged / untracked files with
/// per-file diffs, a commit box, and push / pull / fetch — the "fix → commit → push" loop without the Mac.
struct GitView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sessionId: String

    @State private var commitMessage = ""
    @State private var confirmDiscard: [String]? = nil   // nil = no dialog; [] = everything
    @State private var newBranchName = ""
    @State private var showNewBranch = false
    @State private var showNewPR = false
    @State private var prTitle = ""
    @State private var prBody = ""
    @State private var prDraft = false
    @FocusState private var messageFocused: Bool

    private var status: GitStatus? { model.gitStatuses[sessionId] }
    private var error: String? { model.gitErrors[sessionId] }
    private var busy: Bool { model.gitBusy.contains(sessionId) }
    private var result: AppModel.GitResult? { model.gitResults[sessionId] }
    private var agentRunning: Bool { model.states[sessionId]?.status == .running }

    var body: some View {
        NavigationStack {
            Group {
                if let status {
                    list(status)
                } else if let error {
                    ContentUnavailableView(error, systemImage: "arrow.triangle.branch")
                        .foregroundStyle(CDS.textMuted)
                } else {
                    ProgressView().tint(CDS.textMuted)
                }
            }
            .background(CDS.surface0)
            .navigationTitle("Git")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CDS.surface0, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Menu {
                            Button("Refresh", systemImage: "arrow.clockwise") { model.requestGitStatus(sessionId) }
                            Button("Fetch", systemImage: "arrow.down.to.line") { run(.fetch) }
                            Divider()
                            Button("Stage all", systemImage: "plus.square.on.square") { run(.stage(paths: [])) }
                            Button("Unstage all", systemImage: "minus.square") { run(.unstage(paths: [])) }
                            Button("Discard all changes…", systemImage: "trash", role: .destructive) { confirmDiscard = [] }
                        } label: {
                            Image(systemName: "ellipsis.circle").foregroundStyle(CDS.textSecondary)
                        }
                        .disabled(status == nil)
                    }
                }
            }
            .navigationDestination(for: GitFile.self) { file in
                GitFileDiffView(sessionId: sessionId, file: file)
            }
            .confirmationDialog(discardTitle, isPresented: Binding(get: { confirmDiscard != nil }, set: { if !$0 { confirmDiscard = nil } }),
                                titleVisibility: .visible) {
                Button("Discard", role: .destructive) {
                    if let paths = confirmDiscard { run(.discard(paths: paths)) }
                    confirmDiscard = nil
                }
            } message: {
                Text("Working-tree changes are thrown away and untracked files deleted. This can't be undone.")
            }
            .alert("New branch", isPresented: $showNewBranch) {
                TextField("branch-name", text: $newBranchName)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Create") { run(.createBranch(name: newBranchName)); newBranchName = "" }
                Button("Cancel", role: .cancel) { newBranchName = "" }
            } message: {
                Text("Creates the branch from the current commit and switches to it.")
            }
        }
        .onAppear { model.requestGitStatus(sessionId); model.requestPullRequest(sessionId) }
        .sheet(isPresented: $showNewPR) { newPullRequestSheet }
    }

    // MARK: pull request

    private var pr: AppModel.PullRequestState? { model.pullRequests[sessionId] }

    @ViewBuilder private func pullRequestRow(_ status: GitStatus) -> some View {
        if let info = pr?.info {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: info.state == "MERGED" ? "arrow.triangle.merge" : "arrow.triangle.pull")
                        .foregroundStyle(info.state == "MERGED" ? CDS.accent : (info.state == "CLOSED" ? CDS.danger : CDS.success))
                    Text("#\(info.number) \(info.title)").font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary).lineLimit(2)
                    Spacer(minLength: 4)
                    if pr?.loading == true { ProgressView().controlSize(.mini) }
                }
                HStack(spacing: 6) {
                    prBadge(info.isDraft ? "Draft" : info.state.capitalized)
                    if let review = info.reviewDecision { prBadge(review.replacingOccurrences(of: "_", with: " ").capitalized) }
                    if info.mergeable == "CONFLICTING" { prBadge("Conflicts", tint: CDS.danger) }
                    if let base = info.baseBranch { Text("→ \(base)").font(CDS.caption).foregroundStyle(CDS.textMuted) }
                }
                if !info.checks.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(info.checks) { check in
                            HStack(spacing: 6) {
                                Image(systemName: check.isDone ? (check.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill") : "circle.dotted")
                                    .font(.caption)
                                    .foregroundStyle(check.isDone ? (check.isSuccess ? CDS.success : CDS.danger) : CDS.warning)
                                Text(check.name).font(CDS.caption).foregroundStyle(CDS.textSecondary).lineLimit(1)
                                Spacer(minLength: 0)
                                if let url = check.url.flatMap(URL.init) {
                                    Link(destination: url) { Image(systemName: "arrow.up.right.square").font(.caption).foregroundStyle(CDS.textMuted) }
                                }
                            }
                        }
                    }
                    .padding(8)
                    .background(CDS.fillNeutral, in: RoundedRectangle(cornerRadius: CDS.radius - 2))
                }
                HStack(spacing: 8) {
                    if let url = URL(string: info.url) {
                        Link(destination: url) { Label("Open on GitHub", systemImage: "safari") }
                            .buttonStyle(CDSButtonStyle(variant: .secondary, fullWidth: true))
                    }
                    Button { model.requestPullRequest(sessionId, force: true) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(CDSButtonStyle(variant: .secondary))
                }
            }
            .listRowBackground(CDS.surface0)
        } else if let error = pr?.error {
            Label(error, systemImage: "arrow.triangle.pull").font(CDS.caption).foregroundStyle(CDS.textMuted)
                .listRowBackground(CDS.surface0)
        } else if status.branch != nil, pr?.loading != true {
            Button { prTitle = status.lastCommit.map { String($0.drop(while: { $0 != " " }).dropFirst()) } ?? ""; showNewPR = true } label: {
                Label("Create pull request…", systemImage: "arrow.triangle.pull")
            }
            .buttonStyle(CDSButtonStyle(variant: .secondary, fullWidth: true))
            .listRowBackground(CDS.surface0)
            .disabled(agentRunning)
        } else {
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Checking for a pull request…").font(CDS.caption).foregroundStyle(CDS.textMuted) }
                .listRowBackground(CDS.surface0)
        }
    }

    private func prBadge(_ text: String, tint: Color = CDS.textSecondary) -> some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(CDS.fillNeutral, in: Capsule())
    }

    private var newPullRequestSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $prTitle)
                    TextField("Description (Markdown)", text: $prBody, axis: .vertical).lineLimit(4...12)
                    Toggle("Draft", isOn: $prDraft)
                } footer: {
                    Text("Pushes the branch with an upstream if it has none, then runs `gh pr create` on the Mac.")
                }
            }
            .navigationTitle("New pull request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showNewPR = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        run(.createPullRequest(title: prTitle, body: prBody, draft: prDraft))
                        showNewPR = false
                        // The result banner reports the URL; the row picks the PR up on the next fetch.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { model.requestPullRequest(sessionId, force: true) }
                    }
                    .disabled(prTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var discardTitle: String {
        guard let paths = confirmDiscard else { return "" }
        return paths.isEmpty ? "Discard all changes?" : (paths.count == 1 ? "Discard changes to \((paths[0] as NSString).lastPathComponent)?" : "Discard \(paths.count) files?")
    }

    private func run(_ action: GitAction) {
        model.runGit(sessionId, action)
    }

    // MARK: list

    private func list(_ status: GitStatus) -> some View {
        List {
            Section {
                branchHeader(status)
                syncRow(status)
                pullRequestRow(status)
                if let result { resultRow(result) }
                if agentRunning {
                    Label("The agent is working in this repo — actions wait for the turn to finish.", systemImage: "hourglass")
                        .font(CDS.caption).foregroundStyle(CDS.warning)
                        .listRowBackground(CDS.surface0)
                }
            }
            commitSection(status)
            if !status.staged.isEmpty {
                Section {
                    ForEach(status.staged) { file in
                        fileRow(file, staged: true)
                            .swipeActions(edge: .trailing) {
                                Button("Unstage", systemImage: "minus.square") { run(.unstage(paths: [file.path])) }.tint(CDS.textMuted)
                            }
                    }
                } header: { header("Staged", status.staged.count) }
            }
            if !status.unstaged.isEmpty {
                Section {
                    ForEach(status.unstaged) { file in
                        fileRow(file, staged: false)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Discard", systemImage: "trash", role: .destructive) { confirmDiscard = [file.path] }
                                Button("Stage", systemImage: "plus.square") { run(.stage(paths: [file.path])) }.tint(CDS.successFill)
                            }
                    }
                } header: { header("Changes", status.unstaged.count) }
            }
            if !status.untracked.isEmpty {
                Section {
                    ForEach(status.untracked) { file in
                        fileRow(file, staged: false)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Delete", systemImage: "trash", role: .destructive) { confirmDiscard = [file.path] }
                                Button("Stage", systemImage: "plus.square") { run(.stage(paths: [file.path])) }.tint(CDS.successFill)
                            }
                    }
                } header: { header("Untracked", status.untracked.count) }
            }
            if status.isClean {
                Section {
                    Label("Working tree clean", systemImage: "checkmark.circle")
                        .font(CDS.body).foregroundStyle(CDS.textMuted)
                        .listRowBackground(CDS.surface0)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .refreshable { model.requestGitStatus(sessionId) }
        .disabled(busy)
    }

    private func header(_ title: String, _ count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption2.weight(.semibold)).textCase(.uppercase)
            Text("\(count)").font(.caption2).foregroundStyle(CDS.textMuted.opacity(0.6))
        }
        .foregroundStyle(CDS.textMuted)
        .padding(.top, 8)
        .listRowInsets(EdgeInsets(top: 0, leading: CDS.gutter, bottom: 4, trailing: CDS.gutter))
    }

    // MARK: branch & sync

    private func branchHeader(_ status: GitStatus) -> some View {
        HStack(spacing: 10) {
            Menu {
                Section("Branches") {
                    ForEach(status.branches, id: \.self) { branch in
                        Button {
                            if branch != status.branch { run(.checkout(branch: branch)) }
                        } label: {
                            if branch == status.branch { Label(branch, systemImage: "checkmark") } else { Text(branch) }
                        }
                    }
                }
                Button("New branch…", systemImage: "plus") { showNewBranch = true }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 13, weight: .medium))
                    Text(status.branch ?? "HEAD detached at \(status.detachedAt ?? "?")")
                        .font(CDS.bodyMedium).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(CDS.textMuted)
                }
                .foregroundStyle(CDS.textPrimary)
                .padding(.horizontal, 10).frame(height: 32)
                .background(CDS.fillNeutral, in: Capsule())
            }
            Spacer(minLength: 0)
            if status.ahead > 0 || status.behind > 0 {
                HStack(spacing: 6) {
                    if status.ahead > 0 { Label("\(status.ahead)", systemImage: "arrow.up") }
                    if status.behind > 0 { Label("\(status.behind)", systemImage: "arrow.down") }
                }
                .font(.caption.weight(.medium)).foregroundStyle(CDS.textSecondary)
            }
        }
        .listRowBackground(CDS.surface0)
        .listRowSeparator(.hidden)
    }

    private func syncRow(_ status: GitStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let last = status.lastCommit {
                Text(last).font(CDS.codeSmall).foregroundStyle(CDS.textMuted).lineLimit(1)
            }
            HStack(spacing: 8) {
                Button { run(.pull) } label: { Label("Pull", systemImage: "arrow.down.circle") }
                    .buttonStyle(CDSButtonStyle(variant: .secondary, fullWidth: true))
                    .disabled(status.upstream == nil)
                Button { run(.push(setUpstream: status.upstream == nil)) } label: {
                    Label(status.upstream == nil ? "Publish" : (status.ahead > 0 ? "Push \(status.ahead)" : "Push"), systemImage: "arrow.up.circle")
                }
                .buttonStyle(CDSButtonStyle(variant: status.ahead > 0 || status.upstream == nil ? .primary : .secondary, fullWidth: true))
                .disabled(status.branch == nil)
            }
            if let upstream = status.upstream {
                Text("Tracking \(upstream)").font(CDS.caption).foregroundStyle(CDS.textMuted)
            } else if status.branch != nil {
                Text("No upstream — Publish pushes to origin and sets it.").font(CDS.caption).foregroundStyle(CDS.textMuted)
            }
        }
        .listRowBackground(CDS.surface0)
        .listRowSeparator(.hidden)
    }

    private func resultRow(_ result: AppModel.GitResult) -> some View {
        let failed = result.error != nil
        let text = result.error ?? (result.output.isEmpty ? "\(result.action.label): done" : result.output)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.footnote).foregroundStyle(failed ? CDS.danger : CDS.success)
            Text(text).font(failed ? CDS.caption : CDS.codeSmall).foregroundStyle(failed ? CDS.danger : CDS.textSecondary)
                .lineLimit(6).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(failed ? CDS.dangerFill.opacity(0.10) : CDS.fillNeutral, in: RoundedRectangle(cornerRadius: CDS.radius))
        .listRowBackground(CDS.surface0)
        .listRowSeparator(.hidden)
    }

    // MARK: commit

    private func commitSection(_ status: GitStatus) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Commit message", text: $commitMessage, axis: .vertical)
                    .lineLimit(1...6)
                    .font(CDS.prose)
                    .foregroundStyle(CDS.textPrimary)
                    .focused($messageFocused)
                    .padding(10)
                    .background(CDS.surface2, in: RoundedRectangle(cornerRadius: CDS.radius))
                    .overlay(RoundedRectangle(cornerRadius: CDS.radius).strokeBorder(messageFocused ? CDS.borderStrong : CDS.border))
                HStack(spacing: 8) {
                    Button {
                        run(.commit(message: commitMessage, all: false)); commitMessage = ""; messageFocused = false
                    } label: {
                        Label(status.staged.isEmpty ? "Commit" : "Commit \(status.staged.count) staged", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(CDSButtonStyle(variant: .primary, fullWidth: true))
                    .disabled(commitMessage.trimmingCharacters(in: .whitespaces).isEmpty || status.staged.isEmpty)
                    Button {
                        run(.commit(message: commitMessage, all: true)); commitMessage = ""; messageFocused = false
                    } label: {
                        Label("Commit all", systemImage: "checkmark.circle.badge.plus")
                    }
                    .buttonStyle(CDSButtonStyle(variant: .secondary, fullWidth: true))
                    .disabled(commitMessage.trimmingCharacters(in: .whitespaces).isEmpty || (status.staged.isEmpty && status.unstaged.isEmpty))
                }
            }
            .listRowBackground(CDS.surface0)
            .listRowSeparator(.hidden)
        } header: { header("Commit", status.staged.count + status.unstaged.count) }
    }

    // MARK: files

    private func fileRow(_ file: GitFile, staged: Bool) -> some View {
        NavigationLink(value: GitFile(path: file.path, indexStatus: file.indexStatus, workStatus: file.workStatus,
                                      untracked: file.untracked, conflicted: file.conflicted)) {
            HStack(spacing: 10) {
                Text(file.badge)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(badgeColor(file), in: RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.fileName).font(CDS.body).foregroundStyle(CDS.textPrimary).lineLimit(1)
                    let dir = (file.path as NSString).deletingLastPathComponent
                    if !dir.isEmpty {
                        Text(dir).font(CDS.caption).foregroundStyle(CDS.textMuted).lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: 0)
                if file.isStaged && file.hasWorkChanges && !file.untracked {
                    // Partly staged: the row appears in both sections.
                    CDSChip(text: staged ? "+ unstaged" : "+ staged")
                }
            }
            .padding(.vertical, 2)
        }
        .listRowBackground(CDS.surface0)
    }

    private func badgeColor(_ file: GitFile) -> Color {
        if file.conflicted { return CDS.dangerFill }
        switch file.badge {
        case "A", "U": return CDS.successFill
        case "D": return CDS.dangerFill
        case "R", "C": return CDS.accent
        default: return CDS.warningFill
        }
    }
}

/// One file's diff (index side for a staged row, working tree otherwise), with stage / unstage in the toolbar.
struct GitFileDiffView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sessionId: String
    let file: GitFile

    @State private var showStaged: Bool
    @State private var selection: Set<Int> = []

    init(sessionId: String, file: GitFile) {
        self.sessionId = sessionId
        self.file = file
        _showStaged = State(initialValue: file.isStaged && !file.hasWorkChanges)
    }

    /// The row as it is now — stage / unstage from here changes which sides exist.
    private var current: GitFile? { model.gitStatuses[sessionId]?.files.first { $0.path == file.path } }
    private var hasBothSides: Bool { (current ?? file).isStaged && (current ?? file).hasWorkChanges && !file.untracked }

    private var diff: String? {
        model.gitFileDiffs[AppModel.GitFileKey(sessionId: sessionId, path: file.path, staged: showStaged)]
    }

    var body: some View {
        ScrollView {
            if let diff {
                if diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(showStaged ? "Nothing staged for this file." : "No working-tree changes.")
                        .font(CDS.caption).foregroundStyle(CDS.textMuted).padding()
                } else {
                    DiffText(diff: diff, selection: $selection).padding(8)
                }
            } else {
                ProgressView().tint(CDS.textMuted).padding()
            }
        }
        .background(CDS.surface0)
        .safeAreaInset(edge: .bottom) {
            if let diff, !selection.isEmpty {
                DiffSelectionBar(sessionId: sessionId, diff: diff, selection: $selection).padding(12)
            } else if diff?.isEmpty == false {
                Text("Tap a line, then another, to select a range and ask the agent about it.")
                    .font(CDS.caption).foregroundStyle(CDS.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(CDS.surface0.opacity(0.95))
            }
        }
        .navigationTitle(file.fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(CDS.surface0, for: .navigationBar)
        .toolbar {
            if hasBothSides {
                ToolbarItem(placement: .principal) {
                    Picker("Side", selection: $showStaged) {
                        Text("Unstaged").tag(false)
                        Text("Staged").tag(true)
                    }
                    .pickerStyle(.segmented).frame(width: 180)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if model.gitBusy.contains(sessionId) {
                    ProgressView().controlSize(.small)
                } else if showStaged {
                    Button("Unstage") { model.runGit(sessionId, .unstage(paths: [file.path])) }
                } else {
                    Button("Stage") { model.runGit(sessionId, .stage(paths: [file.path])) }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let diff, !diff.isEmpty {
                    ShareLink(item: diff, preview: SharePreview("\(file.fileName).diff")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .task(id: showStaged) { selection = []; model.requestGitFileDiff(sessionId, path: file.path, staged: showStaged) }
        .onChange(of: model.gitStatuses[sessionId]) {
            // After stage / unstage the file may only have one side left — follow it, or leave when it's gone.
            guard let current else { dismiss(); return }
            if current.isStaged, !current.hasWorkChanges { showStaged = true }
            else if !current.isStaged { showStaged = false }
            else { model.requestGitFileDiff(sessionId, path: file.path, staged: showStaged) }
        }
    }
}
