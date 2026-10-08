#if os(macOS) || os(Linux)
import Foundation
import ClaudeRemoteCore

/// A short tool-less chat that looks at a task after it ran.
enum AnalysisJob: Sendable {
    case planCheck(taskId: String, plan: [String])
    case postmortem(taskId: String)
}

/// Checking a task against its plan, the post-mortem of a failed one, editing a project file from the
/// phone, and packing a session up to continue on another host.
extension SessionManager {
    // MARK: review chats

    /// The agent's own words in a session, oldest first (Claude transcript or Codex rollout).
    func assistantTexts(sessionId: String) -> [String] {
        let entries: [JSONValue]
        if let path = codexThreads.first(where: { $0.id == sessionId })?.path {
            entries = SessionManager.digestEntries(rollout: path)
        } else if let stored = store.session(id: sessionId) {
            entries = SessionManager.digestEntries(transcript: stored.path)
        } else {
            return []
        }
        return entries.filter { $0["type"]?.string == "assistant" }.flatMap { entry in
            (entry["message"]?["content"]?.array ?? []).compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }
        }
    }

    private func startReview(_ job: AnalysisJob, brief: String, agent: AgentKind) async {
        do {
            let chat = try await create(.chat(agent: agent))
            analysisSessions[chat.id] = job
            try await prompt(sessionId: chat.id, text: brief)
        } catch {
            log("review chat failed to start: \(error)")
        }
    }

    /// A finished task that planned first: read the plan from its first reply, then have a reviewer
    /// compare it with the change.
    func checkPlan(taskId: String) async {
        guard let task = tasks.first(where: { $0.id == taskId }), task.planFirst, let sessionId = task.sessionId else { return }
        guard let plan = assistantTexts(sessionId: sessionId).lazy.compactMap(TaskReview.extractPlan).first else {
            updateTask(taskId) { $0.planCheck = PlanCheck(steps: [], summary: "The agent did not write a plan.") }
            return
        }
        updateTask(taskId) { $0.plan = plan }
        let diff: String
        if let worktree = task.worktreePath, let base = task.baseCommit {
            diff = await offActor { [self] in changes(in: worktree, against: base).diff }
        } else if let snapshot = task.snapshot {
            let repo = task.cwd
            diff = await offActor { [self] in runGit(["-C", repo, "diff", snapshot.commit], timeout: 60).out }
        } else {
            diff = ""
        }
        let brief = TaskReview.planBrief(task: task.prompt, plan: plan, diff: diff, summary: task.resultSummary ?? "")
        await startReview(.planCheck(taskId: taskId, plan: plan), brief: brief, agent: reviewAgent(task.agent))
    }

    /// A failed task: what it tried and what it needs, in a few lines.
    func writePostmortem(taskId: String, ciLog: String? = nil) async {
        guard let task = tasks.first(where: { $0.id == taskId }), task.postmortem == nil else { return }
        let tail = task.sessionId.map { assistantTexts(sessionId: $0).suffix(12).joined(separator: "\n\n---\n\n") } ?? ""
        let brief = TaskReview.postmortemBrief(task: task.prompt, error: task.error ?? task.resultSummary ?? "It failed.",
                                               transcriptTail: tail, ciLog: ciLog)
        await startReview(.postmortem(taskId: taskId), brief: brief, agent: reviewAgent(task.agent))
    }

    private func reviewAgent(_ preferred: AgentKind) -> AgentKind {
        if preferred == .claude, !hasClaude, codex != nil { return .codex }
        if preferred == .codex, codex == nil { return .claude }
        return preferred
    }

    /// A review chat answered. Returns false when the session was not one.
    func reviewFinished(sessionId: String, isError: Bool, reply: String) -> Bool {
        guard let job = analysisSessions.removeValue(forKey: sessionId) else { return false }
        switch job {
        case .planCheck(let taskId, let plan):
            let check = isError ? nil : TaskReview.parsePlanCheck(reply, plan: plan)
            updateTask(taskId) { $0.planCheck = check ?? PlanCheck(steps: [], summary: "The plan check did not come back readable.") }
            if let check, let task = tasks.first(where: { $0.id == taskId }) {
                let missing = check.steps.count - check.doneCount
                recordEvent(HostEvent(kind: .task, severity: missing == 0 ? .success : .warning,
                                      title: "\"\(task.title)\": \(check.doneCount) of \(check.steps.count) plan steps done",
                                      detail: check.summary.isEmpty ? nil : check.summary, taskId: taskId))
            }
        case .postmortem(let taskId):
            let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            updateTask(taskId) { $0.postmortem = isError || text.isEmpty ? nil : String(text.prefix(2000)) }
            if !isError, let task = tasks.first(where: { $0.id == taskId }) {
                announce(.task, .error, "Why \"\(task.title)\" failed", detail: String(text.prefix(400)), taskId: taskId, notify: .error)
            }
        }
        // The review chat has done its job.
        Task { await close(sessionId: sessionId) }
        return true
    }

    func updateTask(_ id: String, _ change: (inout AgentTask) -> Void) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&tasks[i])
        saveTasks()
        broadcastTasks()
    }

    // MARK: editing a file

    public func writeFile(sessionId: String, path: String, content: String, baseHash: String?, user: String?) throws -> String {
        guard let cwd = cwdFor(sessionId) else { throw ManagerError.unknownSession(sessionId) }
        let full = (((path as NSString).isAbsolutePath ? path : (cwd as NSString).appendingPathComponent(path)) as NSString).standardizingPath
        let root = (cwd as NSString).standardizingPath
        guard full.hasPrefix(root + "/") else { throw GitError.refused("Only files inside the session's project can be edited.") }
        guard mayRead(full, user: user) else { throw GitError.refused("That file is not yours to edit.") }
        if let baseHash, let current = FileManager.default.contents(atPath: full), FileHash.hex(current) != baseHash {
            throw GitError.refused("The file changed on the Mac since you opened it — reload it and edit again.")
        }
        let data = Data(content.utf8)
        try data.write(to: URL(fileURLWithPath: full), options: .atomic)
        recordEvent(HostEvent(kind: .session, title: "Edited \((full as NSString).lastPathComponent) from the phone",
                              detail: String(full.dropFirst(root.count + 1)), sessionId: sessionId))
        return FileHash.hex(data)
    }

    // MARK: handing a session over

    public func exportSession(sessionId: String) async throws -> SessionPackage {
        let codexPath = codexThreads.first(where: { $0.id == sessionId })?.path
        let agent: AgentKind = codexPath != nil ? .codex : .claude
        guard let transcriptPath = codexPath ?? store.session(id: sessionId)?.path,
              let raw = FileManager.default.contents(atPath: transcriptPath) else { throw ManagerError.unknownSession(sessionId) }
        let transcript = await offActor { SessionPackage.strippingImages(raw) }
        guard transcript.count < 40 * 1024 * 1024 else { throw GitError.refused("The session is too long to hand over (over 40 MB of text).") }
        guard let cwd = cwdFor(sessionId) else { throw ManagerError.unknownSession(sessionId) }
        let title = listSessions().first { $0.id == sessionId }?.title ?? "Session"
        let repo: (remote: String?, branch: String?, base: String?, bundle: String?, patch: String?) = await offActor { [self] in
            guard runGit(["-C", cwd, "rev-parse", "--is-inside-work-tree"]).code == 0 else { return (nil, nil, nil, nil, nil) }
            func out(_ args: [String]) -> String? {
                let r = runGit(["-C", cwd] + args, timeout: 60)
                let t = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
                return r.code == 0 && !t.isEmpty ? t : nil
            }
            let remote = out(["remote", "get-url", "origin"])
            let branch = out(["rev-parse", "--abbrev-ref", "HEAD"]).flatMap { $0 == "HEAD" ? nil : $0 }
            // Where the branch left what the remote has: its upstream, or the default branch.
            let base = out(["merge-base", "HEAD", "@{upstream}"]) ?? out(["merge-base", "HEAD", "origin/HEAD"])
                ?? out(["merge-base", "HEAD", "origin/main"]) ?? out(["merge-base", "HEAD", "origin/master"])
            var bundle: String?
            if let base, let branch, (Int(out(["rev-list", "--count", "\(base)..HEAD"]) ?? "0") ?? 0) > 0 {
                let file = NSTemporaryDirectory() + "ccremote-\(UUID().uuidString).bundle"
                if runGit(["-C", cwd, "bundle", "create", file, branch, "^\(base)"], timeout: 120).code == 0,
                   let data = FileManager.default.contents(atPath: file) {
                    bundle = data.base64EncodedString()
                }
                try? FileManager.default.removeItem(atPath: file)
            }
            var patch = runGit(["-C", cwd, "diff", "HEAD", "--binary"], timeout: 120).out
            for path in runGit(["-C", cwd, "ls-files", "--others", "--exclude-standard"], timeout: 60).out.split(separator: "\n").map(String.init) where !path.isEmpty {
                patch += runGit(["-C", cwd, "diff", "--binary", "--no-index", "--", "/dev/null", path], timeout: 30).out
            }
            return (remote, branch, base, bundle, patch.isEmpty ? nil : patch)
        }
        return SessionPackage(agent: agent, title: title, sessionId: sessionId, cwd: cwd, remoteURL: repo.remote, branch: repo.branch,
                              baseCommit: repo.base, transcript: transcript.base64EncodedString(), gitBundle: repo.bundle,
                              patch: repo.patch, from: Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
    }

    /// Recreates the session here: the repository (a clone that is already here, or a fresh one), the
    /// branch with its commits and uncommitted changes, and the transcript under the new path. Returns the
    /// session id to open and where it lives.
    public func importSession(_ package: SessionPackage, cwd requested: String?, user: String?) async throws -> (sessionId: String, cwd: String) {
        guard let transcriptData = Data(base64Encoded: package.transcript) else { throw GitError.refused("The package is damaged.") }
        let workspace = user.map { memberWorkspace($0) } ?? workspaceRoot
        let slug = SessionManager.worktreeSlug(package.title).isEmpty ? "handoff" : SessionManager.worktreeSlug(package.title)
        var cwd = requested ?? ""
        if cwd.isEmpty, let remote = package.remoteURL {
            let known = projects(for: user).map(\.path)
            cwd = await offActor { [self] in
                known.first { runGit(["-C", $0, "remote", "get-url", "origin"]).out.trimmingCharacters(in: .whitespacesAndNewlines) == remote } ?? ""
            }
            if cwd.isEmpty {
                let target = (workspace as NSString).appendingPathComponent(((remote as NSString).lastPathComponent as NSString).deletingPathExtension)
                let clone = await offActor { [self] in runGit(["clone", "-q", remote, target], timeout: 900) }
                guard clone.code == 0 || FileManager.default.fileExists(atPath: target + "/.git") else {
                    throw GitError.refused("Could not clone \(remote): \(clone.err.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
                cwd = target
            }
        }
        if cwd.isEmpty {
            cwd = (workspace as NSString).appendingPathComponent(slug)
            try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        }
        if let user, !inMemberWorkspace(cwd, user: user) { throw GitError.refused("That folder is outside your workspace.") }
        let target = cwd
        // The branch: its commits from the bundle, then the uncommitted changes on top.
        let gitResult: String? = await offActor { [self] in
            guard runGit(["-C", target, "rev-parse", "--is-inside-work-tree"]).code == 0 else { return nil }
            _ = runGit(["-C", target, "fetch", "-q", "origin"], timeout: 180)
            let branchName = "handoff/\(slug)-\(package.sessionId.prefix(4))"
            if let bundle = package.gitBundle.flatMap({ Data(base64Encoded: $0) }), let branch = package.branch {
                let file = NSTemporaryDirectory() + "ccremote-\(UUID().uuidString).bundle"
                try? bundle.write(to: URL(fileURLWithPath: file))
                defer { try? FileManager.default.removeItem(atPath: file) }
                guard runGit(["-C", target, "fetch", "-q", file, branch], timeout: 120).code == 0,
                      runGit(["-C", target, "checkout", "-q", "-B", branchName, "FETCH_HEAD"], timeout: 60).code == 0 else {
                    return "Could not take over the branch's commits."
                }
            } else if let base = package.baseCommit {
                guard runGit(["-C", target, "checkout", "-q", "-B", branchName, base], timeout: 60).code == 0 else {
                    return "The commit the session started from (\(base.prefix(8))) is not in this clone."
                }
            }
            if let patch = package.patch, !patch.isEmpty {
                let file = NSTemporaryDirectory() + "ccremote-\(UUID().uuidString).patch"
                try? patch.write(toFile: file, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(atPath: file) }
                let applied = runGit(["-C", target, "apply", "--whitespace=nowarn", file], timeout: 60)
                if applied.code != 0 { return "The uncommitted changes did not apply: \(applied.err.trimmingCharacters(in: .whitespacesAndNewlines))" }
            }
            return nil
        }
        if let problem = gitResult { log("import: \(problem)") }

        // The transcript, with its paths moved to where it now lives.
        let text = SessionPackage.rewrite(transcript: String(decoding: transcriptData, as: UTF8.self), from: package.cwd, to: cwd)
        let sessionId = package.sessionId
        let file: String
        switch package.agent {
        case .claude:
            let encoded = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
            let dir = NSHomeDirectory() + "/.claude/projects/" + encoded
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            file = dir + "/\(sessionId).jsonl"
        case .codex:
            let day = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            let dir = NSHomeDirectory() + String(format: "/.codex/sessions/%04d/%02d/%02d", day.year ?? 2026, day.month ?? 1, day.day ?? 1)
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-").prefix(19)
            file = dir + "/rollout-\(stamp)-\(sessionId).jsonl"
        }
        guard !FileManager.default.fileExists(atPath: file) else { throw GitError.refused("That session is already on this host.") }
        try Data(text.utf8).write(to: URL(fileURLWithPath: file))
        if let user { claim(sessionId, for: user) }
        announce(.session, .info, "Took over \"\(package.title)\" from \(package.from)", detail: gitResult ?? (cwd as NSString).lastPathComponent, sessionId: sessionId)
        if package.agent == .codex { await refreshSources() }
        broadcast(.sessions(items: listSessions()))
        return (sessionId, cwd)
    }
}
#endif
