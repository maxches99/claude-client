#if os(macOS)
import Foundation
import ClaudeRemoteCore

/// The Mac's task queue: prompts typed on the phone that the daemon works off on its own, one at a
/// time or several in parallel, now or on a schedule. Each task gets its own session, so its
/// transcript is an ordinary session you can open, follow and take over.
extension SessionManager {
    // MARK: reading

    public func taskList() -> (items: [AgentTask], settings: TaskQueueSettings) {
        (tasks, taskSettings)
    }

    func broadcastTasks() {
        broadcast(.tasks(items: tasks, settings: taskSettings))
    }

    // MARK: editing

    public func addTask(_ task: AgentTask) async {
        var task = task
        if task.title.trimmingCharacters(in: .whitespaces).isEmpty { task.title = AgentTask.title(fromPrompt: task.prompt) }
        if let minutes = task.dailyAtMinutes {
            task.runAt = task.runAt ?? SessionManager.nextDaily(minutes: minutes)
            task.status = .scheduled
        } else if let at = task.runAt, at > Date() {
            task.status = .scheduled
        } else {
            task.status = .queued
            task.runAt = nil
        }
        tasks.append(task)
        saveTasks()
        broadcastTasks()
        await pumpTasks()
    }

    /// Replaces a task that has not started yet (a running one keeps what it was given).
    public func updateTask(_ task: AgentTask) async {
        guard let idx = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        guard tasks[idx].status != .running else { return }
        var updated = task
        updated.sessionId = tasks[idx].sessionId
        updated.createdAt = tasks[idx].createdAt
        if updated.title.trimmingCharacters(in: .whitespaces).isEmpty { updated.title = AgentTask.title(fromPrompt: updated.prompt) }
        if let minutes = updated.dailyAtMinutes {
            updated.runAt = SessionManager.nextDaily(minutes: minutes)
            updated.status = .scheduled
        } else if let at = updated.runAt, at > Date() {
            updated.status = .scheduled
        } else if !updated.status.isFinished {
            updated.status = .queued
            updated.runAt = nil
        }
        tasks[idx] = updated
        saveTasks()
        broadcastTasks()
        await pumpTasks()
    }

    public func performTaskAction(id: String, action: TaskAction) async {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        switch action {
        case .runNow:
            tasks[idx].status = .queued
            tasks[idx].runAt = nil
        case .cancel:
            if tasks[idx].status == .running, let sessionId = tasks[idx].sessionId {
                try? await interrupt(sessionId: sessionId)
            }
            tasks[idx].status = .cancelled
            tasks[idx].finishedAt = Date()
        case .retry:
            tasks[idx].status = .queued
            tasks[idx].runAt = nil
            tasks[idx].sessionId = nil
            tasks[idx].error = nil
            tasks[idx].resultSummary = nil
            tasks[idx].startedAt = nil
            tasks[idx].finishedAt = nil
        case .delete:
            if tasks[idx].status == .running, let sessionId = tasks[idx].sessionId {
                try? await interrupt(sessionId: sessionId)
            }
            tasks.remove(at: idx)
        case .openPullRequest:
            let taskId = tasks[idx].id
            do {
                _ = try await openPullRequest(forTask: taskId)
            } catch {
                if let i = tasks.firstIndex(where: { $0.id == taskId }) { tasks[i].error = "\(error)" }
            }
        case .pushFix:
            let taskId = tasks[idx].id
            do {
                try await pushFix(taskId: taskId)
            } catch {
                if let i = tasks.firstIndex(where: { $0.id == taskId }) { tasks[i].error = "\(error)" }
            }
        case .toggleFixCI:
            tasks[idx].fixCI.toggle()
            if tasks[idx].fixCI { Task { await self.checkCI() } }
        case .restoreSnapshot:
            let taskId = tasks[idx].id
            do {
                try await restoreTaskSnapshot(taskId: taskId)
            } catch {
                if let i = tasks.firstIndex(where: { $0.id == taskId }) { tasks[i].error = "\(error)" }
            }
        }
        saveTasks()
        broadcastTasks()
        await pumpTasks()
    }

    public func setTaskSettings(_ settings: TaskQueueSettings) async {
        taskSettings = TaskQueueSettings(maxParallel: min(max(1, settings.maxParallel), 4), paused: settings.paused)
        saveTasks()
        broadcastTasks()
        await pumpTasks()
    }

    // MARK: running

    /// Starts whatever the queue allows: scheduled tasks whose time has come, then queued ones up to
    /// the parallel limit.
    func pumpTasks() async {
        var changed = false
        let now = Date()
        for i in tasks.indices where tasks[i].status == .scheduled {
            if let at = tasks[i].runAt, at <= now {
                tasks[i].status = .queued
                changed = true
            }
        }
        if !taskSettings.paused {
            while tasks.filter({ $0.status == .running }).count < max(1, taskSettings.maxParallel),
                  let idx = tasks.firstIndex(where: { $0.status == .queued }) {
                await startTask(at: idx)
                changed = true
            }
        }
        if changed {
            saveTasks()
            broadcastTasks()
        }
    }

    private func startTask(at index: Int) async {
        var task = tasks[index]
        task.status = .running
        task.startedAt = Date()
        task.error = nil
        tasks[index] = task
        do {
            var cwd = task.cwd
            guard FileManager.default.fileExists(atPath: cwd) else { throw ManagerError.cwdMissing(cwd) }
            if task.inWorktree {
                let slug = SessionManager.worktreeSlug(task.title)
                let name = slug.isEmpty ? "task-\(task.id.prefix(6))" : "\(slug)-\(task.id.prefix(4))"
                task.baseCommit = runGit(["-C", task.cwd, "rev-parse", "HEAD"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
                cwd = try addWorktree(repo: task.cwd, name: name, branch: "task/\(name)", base: nil)
                task.worktreePath = cwd
                task.branch = "task/\(name)"
            } else {
                // Working in the project itself: keep how it was, to put back in one tap.
                let repo = cwd, id = task.id
                task.snapshot = await offActor { [self] in takeSnapshot(repo: repo, id: id) }
            }
            if task.wantsPreview {
                tasks[index] = task
                await takePreview(taskId: task.id, phase: .before)
                if let i = tasks.firstIndex(where: { $0.id == task.id }) { task.preview = tasks[i].preview }
            }
            // A task is there to change the project: Codex gets write access to its folder (its own
            // default can be read-only, which leaves it describing the fix instead of making it).
            let options = NewSessionOptions(cwd: cwd, model: task.model, permissionMode: task.permissionMode, effort: task.effort, agent: task.agent,
                                            sandbox: task.agent == .codex ? CodexSandboxMode.workspaceWrite.rawValue : nil)
            let state = try await create(options)
            task.sessionId = state.id
            tasks[index] = task
            try await prompt(sessionId: state.id, text: task.prompt)
            log("task started: \(task.title.prefix(60)) → \(state.id.prefix(8))")
            recordEvent(HostEvent(kind: .task, title: "Started \"\(task.title)\"", detail: task.projectName, sessionId: state.id, taskId: task.id))
        } catch {
            task.status = .failed
            task.error = "\(error)"
            task.finishedAt = Date()
            log("task failed to start: \(task.title.prefix(60)): \(error)")
            announce(.task, .error, "Task \"\(task.title)\" could not start", detail: "\(error)", taskId: task.id, notify: .error)
        }
        if let idx = tasks.firstIndex(where: { $0.id == task.id }) { tasks[idx] = task }
    }

    /// A session finished a turn: if it belongs to a running task, that task is done (or re-armed,
    /// when it repeats daily).
    func taskTurnFinished(sessionId: String, isError: Bool, summary: String?) {
        if let duelId = judgeSessions.removeValue(forKey: sessionId) {
            judgeFinished(duelId: duelId, isError: isError, reply: summary ?? "")
            return
        }
        guard let idx = tasks.firstIndex(where: { $0.status == .running && $0.sessionId == sessionId }) else { return }
        var task = tasks[idx]
        let text = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        task.resultSummary = text.map { $0.count > 400 ? String($0.prefix(400)) + "…" : $0 }
        task.finishedAt = Date()
        if isError {
            task.status = .failed
            task.error = text
        } else {
            task.status = .done
        }
        announce(.task, isError ? .error : .success, "Task \"\(task.title)\" \(isError ? "failed" : "finished")",
                 detail: task.resultSummary.map { String($0.prefix(200)) }, sessionId: sessionId, taskId: task.id, notify: isError ? .error : .done)
        if let minutes = task.dailyAtMinutes, !isError {
            // A daily task keeps its row: it is armed again for tomorrow with the last result on it.
            task.status = .scheduled
            task.runAt = SessionManager.nextDaily(minutes: minutes)
            task.sessionId = nil
        }
        tasks[idx] = task
        saveTasks()
        broadcastTasks()
        let taskId = task.id
        Task { await self.afterTask(taskId, succeeded: !isError) }
        Task { await self.pumpTasks() }
    }

    /// What follows a finished worktree task: measure the change, then open its pull request or hand
    /// it to its duel.
    func afterTask(_ taskId: String, succeeded: Bool) async {
        guard let task = tasks.first(where: { $0.id == taskId }) else { return }
        if task.repairOf != nil {
            await repairFinished(task, succeeded: succeeded)
            return
        }
        if task.wantsPreview { await takePreview(taskId: taskId, phase: .after) }
        if let worktree = task.worktreePath, let base = task.baseCommit, FileManager.default.fileExists(atPath: worktree) {
            let stat = await offActor { [self] in changes(in: worktree, against: base).stat }
            if let i = tasks.firstIndex(where: { $0.id == taskId }) {
                tasks[i].diffStat = stat
                saveTasks()
                broadcastTasks()
            }
        }
        if let duelId = task.duelId {
            await duelTaskFinished(duelId: duelId)
        } else if succeeded, task.openPullRequest, task.worktreePath != nil {
            do {
                let url = try await openPullRequest(forTask: taskId)
                announce(.task, .success, "Pull request for \"\(task.title)\"", detail: url, taskId: taskId, url: url, notify: .done)
                if task.fixCI, let i = tasks.firstIndex(where: { $0.id == taskId }) {
                    tasks[i].ci = TaskCI(state: .pending)
                    saveTasks(); broadcastTasks()
                }
            } catch {
                if let i = tasks.firstIndex(where: { $0.id == taskId }) {
                    tasks[i].error = "Pull request: \(error)"
                    saveTasks()
                    broadcastTasks()
                }
            }
        }
    }

    // MARK: scheduling

    func startTaskTimer() {
        taskTimer?.cancel()
        taskTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self else { return }
                await self.pumpTasks()
            }
        }
    }

    /// The next time today or tomorrow that is `minutes` past local midnight.
    static func nextDaily(minutes: Int, from now: Date = Date(), calendar: Calendar = .current) -> Date {
        let clamped = min(max(0, minutes), 24 * 60 - 1)
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = clamped / 60
        components.minute = clamped % 60
        components.second = 0
        let today = calendar.date(from: components) ?? now
        return today > now ? today : (calendar.date(byAdding: .day, value: 1, to: today) ?? now.addingTimeInterval(86_400))
    }

    // MARK: persistence

    public static func taskStorePath(supportDirectory: String) -> String {
        supportDirectory + "/tasks.json"
    }

    func loadTasks() {
        guard let path = taskStorePath, let data = FileManager.default.contents(atPath: path) else { return }
        struct Stored: Decodable {
            var tasks: [AgentTask]
            var settings: TaskQueueSettings?
            var duels: [Duel]?
        }
        guard let stored = try? ProtocolCoding.decoder.decode(Stored.self, from: data) else { return }
        taskSettings = stored.settings ?? TaskQueueSettings()
        // A duel caught mid-judging lost its judge with the restart.
        duels = (stored.duels ?? []).map { duel in
            var duel = duel
            if duel.status == .judging { duel.status = .failed; duel.error = "The host restarted while judging — ask for a new verdict." }
            return duel
        }
        // A task that was running when the daemon stopped has no process behind it any more.
        tasks = stored.tasks.map { task in
            var task = task
            if task.status == .running {
                task.status = .failed
                task.error = "The Mac app restarted while this task was running."
                task.finishedAt = Date()
            }
            if task.status == .scheduled, let minutes = task.dailyAtMinutes, (task.runAt ?? .distantPast) < Date() {
                task.runAt = SessionManager.nextDaily(minutes: minutes)
            }
            return task
        }
        // Finished one-off tasks are history; keep the recent ones only.
        let finished = tasks.filter { $0.status.isFinished && $0.dailyAtMinutes == nil && $0.duelId == nil }
            .sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
        let drop = Set(finished.dropFirst(30).map(\.id))
        if !drop.isEmpty { tasks.removeAll { drop.contains($0.id) } }
    }

    func saveTasks() {
        guard let path = taskStorePath else { return }
        struct Stored: Encodable {
            var tasks: [AgentTask]
            var settings: TaskQueueSettings
            var duels: [Duel]
        }
        guard let data = try? ProtocolCoding.encoder.encode(Stored(tasks: tasks, settings: taskSettings, duels: duels)) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
#endif
