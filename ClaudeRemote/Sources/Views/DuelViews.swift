import SwiftUI
import ClaudeRemoteCore

/// A duel in the queue's list.
struct DuelRow: View {
    @Environment(AppModel.self) private var model
    let duel: Duel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(duel.title).font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary).lineLimit(2)
            }
            Text(line).font(CDS.caption).foregroundStyle(CDS.textMuted).lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch duel.status {
        case .running: return "figure.fencing"
        case .judging: return "scalemass"
        case .decided: return duel.verdict?.winnerTaskId == nil ? "equal.circle" : "trophy.fill"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch duel.status {
        case .decided: return CDS.brand
        case .failed: return CDS.danger
        default: return CDS.textMuted
        }
    }

    private var line: String {
        let sides = model.tasks(of: duel)
        switch duel.status {
        case .running:
            return duel.projectName + " · " + sides.map { "\($0.agent.label): \($0.status.label.lowercased())" }.joined(separator: ", ")
        case .judging:
            return duel.projectName + " · running the tests and asking the judge"
        case .decided:
            guard let verdict = duel.verdict else { return duel.projectName }
            let totals = sides.compactMap { side in verdict.scores[side.id].map { "\(side.agent.label) \(String(format: "%.1f", $0.total))" } }.joined(separator: " vs ")
            let winner = verdict.winnerTaskId.flatMap { id in sides.first { $0.id == id }?.agent.label }
            return (winner.map { "\($0) won" } ?? "A tie") + (totals.isEmpty ? "" : " · " + totals)
        case .failed:
            return duel.error ?? "Failed"
        }
    }
}

/// Both sides of a duel, and the verdict.
struct DuelView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let duelId: String
    @State private var reviewing: String?
    @State private var confirmKeep: AgentTask?
    @State private var confirmDelete = false
    @State private var showPrompt = false

    private var duel: Duel? { model.duels.first { $0.id == duelId } }

    var body: some View {
        Group {
            if let duel {
                List {
                    header(duel)
                    if duel.status == .judging {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Running each side's tests, then the \(duel.judge.label) judge reads both diffs without knowing which agent wrote which.")
                                .font(CDS.caption).foregroundStyle(CDS.textSecondary)
                        }
                        .listRowBackground(CDS.surface0)
                    }
                    if let error = duel.error, duel.status == .failed {
                        Text(error).font(CDS.caption).foregroundStyle(CDS.danger).listRowBackground(CDS.surface0)
                    }
                    if duel.status == .decided, let verdict = duel.verdict { verdictSection(duel, verdict) }
                    ForEach(model.tasks(of: duel)) { side in lane(duel, side) }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            } else {
                Text("This duel is gone.").font(CDS.body).foregroundStyle(CDS.textMuted)
            }
        }
        .background(CDS.surface0)
        .navigationTitle("Duel")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(CDS.surface0, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let duel, duel.status == .decided || duel.status == .failed {
                        Section("Ask the judge again") {
                            Button("Claude judges") { model.duelAction(duelId, .rejudge(judge: .claude)) }
                            Button("Codex judges") { model.duelAction(duelId, .rejudge(judge: .codex)) }
                        }
                    }
                    Button("Delete the duel…", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(item: Binding(get: { reviewing.map { ReviewTarget(sessionId: $0) } }, set: { reviewing = $0?.sessionId })) { target in
            ReviewView(sessionId: target.sessionId)
        }
        .confirmationDialog("Keep this result?", isPresented: Binding(get: { confirmKeep != nil }, set: { if !$0 { confirmKeep = nil } }), titleVisibility: .visible) {
            Button("Keep \(confirmKeep?.agent.label ?? "")'s") {
                if let side = confirmKeep { model.duelAction(duelId, .keep(taskId: side.id)) }
                confirmKeep = nil
            }
        } message: {
            Text("The other worktree and its branch are removed on the Mac. This one stays, ready to review or turn into a pull request.")
        }
        .confirmationDialog("Delete this duel?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                model.duelAction(duelId, .delete)
                dismiss()
            }
        } message: {
            Text("Its tasks go too, and every worktree that was not kept.")
        }
    }

    private func header(_ duel: Duel) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(duel.title).font(.headline).foregroundStyle(CDS.textPrimary)
                Text("\(duel.projectName) · \(duel.status.label) · judged by \(duel.judge.label)")
                    .font(CDS.caption).foregroundStyle(CDS.textMuted)
                Text(duel.prompt).font(CDS.caption).foregroundStyle(CDS.textSecondary).lineLimit(showPrompt ? nil : 3)
                    .onTapGesture { showPrompt.toggle() }
            }
            .listRowBackground(CDS.surface0)
        }
    }

    @ViewBuilder
    private func verdictSection(_ duel: Duel, _ verdict: DuelVerdict) -> some View {
        let sides = model.tasks(of: duel)
        let winner = verdict.winnerTaskId.flatMap { id in sides.first { $0.id == id } }
        Section("Verdict") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: winner == nil ? "equal.circle.fill" : "trophy.fill").foregroundStyle(winner?.agent.tint ?? CDS.textMuted)
                    Text(winner.map { "\($0.agent.label) did it better" } ?? "A tie").font(.headline)
                }
                if !verdict.summary.isEmpty { Text(verdict.summary).font(CDS.body).foregroundStyle(CDS.textSecondary) }
                ForEach([("Correctness", \DuelScore.correctness), ("Completeness", \DuelScore.completeness),
                         ("Code quality", \DuelScore.quality), ("Tests", \DuelScore.tests)], id: \.0) { name, key in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name).font(.caption2.weight(.semibold)).foregroundStyle(CDS.textMuted).textCase(.uppercase)
                        ForEach(sides) { side in
                            if let score = verdict.scores[side.id] { scoreBar(side.agent, value: score[keyPath: key]) }
                        }
                    }
                }
                if let judgeSession = verdict.judgeSessionId {
                    Button("Read the judge's reasoning", systemImage: "text.bubble") {
                        model.present(judgeSession, kind: .chat)
                        dismiss()
                    }
                    .font(CDS.caption)
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(CDS.surface0)
        }
    }

    private func scoreBar(_ agent: AgentKind, value: Double) -> some View {
        HStack(spacing: 6) {
            Text(agent.label).font(CDS.caption).foregroundStyle(agent.tint).frame(width: 50, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(CDS.fillNeutral)
                    Capsule().fill(agent.tint).frame(width: geo.size.width * value / 10)
                }
            }
            .frame(height: 6)
            Text(String(format: "%.0f", value)).font(CDS.caption.monospacedDigit()).foregroundStyle(CDS.textSecondary).frame(width: 20, alignment: .trailing)
        }
    }

    private func lane(_ duel: Duel, _ side: AgentTask) -> some View {
        let score = duel.verdict?.scores[side.id]
        let isWinner = duel.verdict?.winnerTaskId == side.id
        return Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(side.agent.label).font(.headline).foregroundStyle(side.agent.tint)
                    if isWinner { Image(systemName: "trophy.fill").foregroundStyle(CDS.brand) }
                    if duel.keptTaskId == side.id { CDSChip(text: "Kept", style: .accent) }
                    Spacer()
                    if let score { Text(String(format: "%.1f", score.total)).font(.title3.weight(.semibold).monospacedDigit()) }
                }
                Text(side.status.label + (side.diffStat.map { " · \($0.label)" } ?? "")).font(CDS.caption).foregroundStyle(CDS.textMuted)
                if let check = side.check {
                    // Not a Label: inside a List row it gets the row's wide icon column.
                    HStack(spacing: 4) {
                        Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        Text(check.timedOut ? "Tests timed out" : (check.passed ? "Tests pass" : "Tests fail (exit \(check.exitCode.map(String.init) ?? "?"))"))
                    }
                    .font(CDS.caption).foregroundStyle(check.passed ? CDS.success : CDS.danger)
                } else if duel.status == .decided {
                    HStack(spacing: 4) {
                        Image(systemName: "questionmark.circle")
                        Text("No test command found in the project")
                    }
                    .font(CDS.caption).foregroundStyle(CDS.textMuted)
                }
                if let notes = score?.notes, !notes.isEmpty { Text(notes).font(CDS.caption).foregroundStyle(CDS.textSecondary) }
                if let summary = side.resultSummary, !summary.isEmpty {
                    Text(summary).font(CDS.caption).foregroundStyle(CDS.textSecondary).lineLimit(4)
                }
                if let error = side.error, !error.isEmpty { Text(error).font(CDS.caption).foregroundStyle(CDS.danger).lineLimit(3) }
                HStack(spacing: 8) {
                    if let sessionId = side.sessionId {
                        Button("Session") { model.present(sessionId, kind: .agent); dismiss() }
                            .buttonStyle(CDSButtonStyle(variant: .secondary))
                        if side.worktreePath != nil {
                            Button("Diff") { reviewing = sessionId }.buttonStyle(CDSButtonStyle(variant: .secondary))
                        }
                    }
                    Spacer()
                    if duel.keptTaskId == nil, side.status.isFinished, side.worktreePath != nil, duel.status != .running {
                        Button("Keep") { confirmKeep = side }.buttonStyle(CDSButtonStyle(variant: isWinner ? .primary : .secondary))
                    } else if duel.keptTaskId == side.id, side.pullRequestURL == nil, model.host?.hasGitHubCLI == true {
                        Button("Draft PR") { model.taskAction(side.id, .openPullRequest) }.buttonStyle(CDSButtonStyle(variant: .primary))
                    } else if let pr = side.pullRequestURL, let url = URL(string: pr) {
                        Link("Pull request", destination: url).font(CDS.bodyMedium)
                    }
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(isWinner ? side.agent.tint.opacity(0.07) : CDS.surface0)
        }
    }
}

/// One prompt for both agents.
struct DuelEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var title = ""
    @State private var cwd = ""
    @State private var claudeMode = PermissionMode.acceptEdits.rawValue
    @State private var codexPolicy = CodexApprovalPolicy.never.rawValue
    @State private var judge: AgentKind = .claude

    var body: some View {
        NavigationStack {
            Form {
                Section("Prompt") {
                    TextField("What should both agents do?", text: $prompt, axis: .vertical).lineLimit(3...10).font(CDS.prose)
                }
                Section {
                    Picker("Project", selection: $cwd) {
                        ForEach(model.projects) { Text($0.name).tag($0.path) }
                    }
                } footer: {
                    Text("Each agent works in its own fresh worktree of this repository, so they can run at the same time — set the queue to run two at once.")
                }
                Section("Unattended") {
                    Picker("Claude", selection: $claudeMode) {
                        ForEach([PermissionMode.acceptEdits, .auto, .dontAsk], id: \.self) { Text($0.label).tag($0.rawValue) }
                    }
                    Picker("Codex", selection: $codexPolicy) {
                        ForEach(CodexApprovalPolicy.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                    }
                }
                Section {
                    Picker("Judge", selection: $judge) {
                        ForEach(AgentKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: { Text("Who compares them") } footer: {
                    Text("When both finish, the Mac runs the project's tests in each worktree, then the judge reads both diffs as “A” and “B” in a random order — it is not told which agent wrote which. You can ask the other agent to judge afterwards.")
                }
                Section("Name") { TextField("Optional", text: $title) }
            }
            .scrollContentBackground(.hidden)
            .background(CDS.surface0)
            .navigationTitle("New duel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        model.startDuel(title: title, prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines), cwd: cwd,
                                        claudeMode: claudeMode, codexPolicy: codexPolicy, judge: judge)
                        dismiss()
                    }
                    .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty || cwd.isEmpty)
                }
            }
        }
        .onAppear {
            if cwd.isEmpty { cwd = model.projects.first?.path ?? "" }
            if model.projects.isEmpty { model.refresh() }
        }
    }
}
