#if os(macOS) || os(Linux)
import Foundation
import ClaudeRemoteCore

/// Claude against Codex: one prompt, two worktrees, then a verdict from the project's tests, the size of
/// each change and a judge who reads both diffs without knowing which agent wrote which.
extension SessionManager {
    public func duelList() -> [Duel] { duels }

    func broadcastDuels() {
        broadcast(.duels(items: duels))
    }

    public func startDuel(title: String, prompt: String, cwd: String, claudeMode: String?, codexPolicy: String?, judge: AgentKind) async throws -> Duel {
        guard codex != nil else { throw GitError.refused("Codex is not installed on this host — a duel needs both agents.") }
        guard hasClaude else { throw GitError.refused("The Claude CLI is not installed on this host — a duel needs both agents.") }
        guard FileManager.default.fileExists(atPath: cwd), runGit(["-C", cwd, "rev-parse", "--is-inside-work-tree"]).code == 0 else {
            throw GitError.refused("A duel runs in two worktrees, so the project has to be a git repository.")
        }
        let name = title.trimmingCharacters(in: .whitespaces).isEmpty ? AgentTask.title(fromPrompt: prompt) : title
        let duelId = UUID().uuidString.lowercased()
        let claudeTask = AgentTask(title: "\(name) · Claude", prompt: prompt, cwd: cwd, agent: .claude,
                                   permissionMode: claudeMode ?? PermissionMode.acceptEdits.rawValue, inWorktree: true, duelId: duelId)
        let codexTask = AgentTask(title: "\(name) · Codex", prompt: prompt, cwd: cwd, agent: .codex,
                                  permissionMode: codexPolicy ?? CodexApprovalPolicy.never.rawValue, inWorktree: true, duelId: duelId)
        let duel = Duel(id: duelId, title: name, prompt: prompt, cwd: cwd, taskIds: [claudeTask.id, codexTask.id], judge: judge)
        duels.insert(duel, at: 0)
        saveTasks()
        broadcastDuels()
        await addTask(claudeTask)
        await addTask(codexTask)
        log("duel \(duelId.prefix(6)) started: \(name.prefix(60))")
        return duel
    }

    /// One side finished; once both have, gather the evidence and call the judge.
    func duelTaskFinished(duelId: String) async {
        guard let duel = duels.first(where: { $0.id == duelId }), duel.status == .running else { return }
        let sides = duel.taskIds.compactMap { id in tasks.first { $0.id == id } }
        guard sides.count == duel.taskIds.count, sides.allSatisfy({ $0.status.isFinished }) else { return }
        await runJudge(duelId: duelId, judge: nil)
    }

    func runJudge(duelId: String, judge: AgentKind?) async {
        guard let i = duels.firstIndex(where: { $0.id == duelId }) else { return }
        if let judge { duels[i].judge = judge }
        // The judge is a quick chat; with only one agent installed, that one judges.
        if duels[i].judge == .claude, !hasClaude { duels[i].judge = .codex }
        if duels[i].judge == .codex, codex == nil { duels[i].judge = .claude }
        duels[i].status = .judging
        duels[i].error = nil
        duels[i].verdict = nil
        saveTasks()
        broadcastDuels()

        // Evidence per side: its diff and size against where it started, and the project's tests.
        var contestants: [DuelJudge.Contestant] = []
        for taskId in duels[i].taskIds {
            guard let task = tasks.first(where: { $0.id == taskId }) else { continue }
            var diff = "", stat: DiffStat?, check: TaskCheck?
            if let worktree = task.worktreePath, let base = task.baseCommit, FileManager.default.fileExists(atPath: worktree) {
                let measured = await offActor { [self] in
                    (changes(in: worktree, against: base), runCheck(in: worktree))
                }
                diff = measured.0.diff
                stat = measured.0.stat
                check = measured.1
                if let t = tasks.firstIndex(where: { $0.id == taskId }) {
                    tasks[t].diffStat = stat
                    tasks[t].check = check
                }
            }
            contestants.append(DuelJudge.Contestant(taskId: taskId, summary: task.resultSummary ?? task.error ?? "", diff: diff,
                                                    diffStat: stat, check: check, failed: task.status != .done))
        }
        broadcastTasks()
        guard let j = duels.firstIndex(where: { $0.id == duelId }), contestants.count >= 2 else {
            failDuel(duelId, "One side of the duel is missing.")
            return
        }
        // Shuffled, so neither agent is always "A".
        contestants.shuffle()
        let labels = ["A", "B", "C", "D"].prefix(contestants.count).map { $0 }
        duels[j].blindLabels = Dictionary(uniqueKeysWithValues: zip(labels, contestants.map(\.taskId)))
        let brief = DuelJudge.brief(task: duels[j].prompt, contestants: contestants, labels: labels)
        do {
            let chat = try await create(.chat(agent: duels[j].judge))
            judgeSessions[chat.id] = duelId
            if let k = duels.firstIndex(where: { $0.id == duelId }) {
                duels[k].verdict = DuelVerdict(winnerTaskId: nil, scores: [:], summary: "", judgeSessionId: chat.id)
            }
            try await prompt(sessionId: chat.id, text: brief)
            saveTasks()
            broadcastDuels()
            log("duel \(duelId.prefix(6)): judging in \(chat.id.prefix(8))")
        } catch {
            failDuel(duelId, "The judge could not start: \(error)")
        }
    }

    func judgeFinished(duelId: String, isError: Bool, reply: String) {
        guard let i = duels.firstIndex(where: { $0.id == duelId }) else { return }
        guard !isError else { failDuel(duelId, "The judge failed: \(reply.prefix(300))"); return }
        guard let parsed = DuelJudge.parse(reply), let labels = duels[i].blindLabels else {
            failDuel(duelId, "The judge's answer had no verdict in it — ask again.")
            return
        }
        let (winner, scores) = SessionManager.resolveVerdict(parsed, labels: labels)
        let judgeSession = duels[i].verdict?.judgeSessionId
        duels[i].verdict = DuelVerdict(winnerTaskId: winner, scores: scores, summary: parsed.summary, judgeSessionId: judgeSession)
        duels[i].status = .decided
        duels[i].decidedAt = Date()
        saveTasks()
        broadcastDuels()
        let names = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.agent.label) })
        let line = winner.flatMap { names[$0] }.map { "\($0) won" } ?? "a tie"
        let totals = duels[i].taskIds.compactMap { id in scores[id].map { "\(names[id] ?? "?") \(String(format: "%.1f", $0.total))" } }.joined(separator: " · ")
        notifier?.notify(.done, body: "Duel \"\(duels[i].title)\": \(line) (\(totals))")
        log("duel \(duelId.prefix(6)) decided: \(line)")
    }

    /// The judge's labels turned back into task ids. A winner the judge named off-script (not one of
    /// the labels) falls back to the higher total; "tie" stays a tie.
    static func resolveVerdict(_ parsed: DuelJudge.ParsedVerdict, labels: [String: String]) -> (winner: String?, scores: [String: DuelScore]) {
        var scores: [String: DuelScore] = [:]
        for (label, score) in parsed.scores { if let taskId = labels[label] { scores[taskId] = score } }
        var winner = parsed.winnerLabel.flatMap { labels[$0] }
        if parsed.winnerLabel != nil, winner == nil, let best = scores.max(by: { $0.value.total < $1.value.total }) { winner = best.key }
        return (winner, scores)
    }

    private func failDuel(_ duelId: String, _ why: String) {
        guard let i = duels.firstIndex(where: { $0.id == duelId }) else { return }
        duels[i].status = .failed
        duels[i].error = why
        saveTasks()
        broadcastDuels()
        log("duel \(duelId.prefix(6)) failed: \(why)")
    }

    public func duelAction(id: String, action: DuelAction) async throws {
        guard let i = duels.firstIndex(where: { $0.id == id }) else { throw GitError.refused("That duel is gone.") }
        switch action {
        case .keep(let taskId):
            guard duels[i].taskIds.contains(taskId) else { throw GitError.refused("That task is not part of the duel.") }
            for other in duels[i].taskIds where other != taskId { await discardWorktree(ofTask: other) }
            duels[i].keptTaskId = taskId
        case .rejudge(let judge):
            await runJudge(duelId: id, judge: judge)
            return
        case .delete:
            let kept = duels[i].keptTaskId
            for taskId in duels[i].taskIds {
                if let task = tasks.first(where: { $0.id == taskId }), task.status == .running, let sessionId = task.sessionId {
                    try? await interrupt(sessionId: sessionId)
                }
                if taskId != kept { await discardWorktree(ofTask: taskId) }
                tasks.removeAll { $0.id == taskId }
            }
            duels.removeAll { $0.id == id }
            broadcastTasks()
        }
        saveTasks()
        broadcastDuels()
    }

    /// Closes the task's session, then removes its worktree and branch.
    private func discardWorktree(ofTask taskId: String) async {
        guard let task = tasks.first(where: { $0.id == taskId }), let worktree = task.worktreePath else { return }
        if let sessionId = task.sessionId, hosted[sessionId] != nil { await close(sessionId: sessionId) }
        let repo = task.cwd, branch = task.branch
        await offActor { [self] in
            _ = runGit(["-C", repo, "worktree", "remove", "--force", worktree], timeout: 60)
            if let branch { _ = runGit(["-C", repo, "branch", "-D", branch], timeout: 30) }
        }
        if let t = tasks.firstIndex(where: { $0.id == taskId }) { tasks[t].worktreePath = nil }
        broadcastTasks()
    }

    /// The project's test command in `dir`, run with a generous limit; nil when the project has none.
    nonisolated func runCheck(in dir: String) -> TaskCheck? {
        guard let command = SessionManager.projectCommands(cwd: dir).first(where: { $0.name.lowercased().contains("test") })?.command else { return nil }
        let limit: TimeInterval = 900
        let started = Date()
        let r = runTool(HostPaths.shell, ["-lc", command], cwd: dir, timeout: limit)
        let timedOut = Date().timeIntervalSince(started) >= limit - 1
        return TaskCheck(command: command, exitCode: timedOut ? nil : r.code, outputTail: String((r.out + r.err).suffix(4000)), timedOut: timedOut)
    }
}
#endif
