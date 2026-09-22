import Foundation
import ClaudeRemoteCore

/// A prompt you keep around and reuse — the phone's own, so it follows you between Macs.
struct PromptSnippet: Codable, Identifiable, Equatable, Sendable {
    var id: String = UUID().uuidString
    var title: String
    var text: String

    private static let key = "ccremote.snippets"

    static func load() -> [PromptSnippet] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([PromptSnippet].self, from: data) else { return [] }
        return items
    }

    static func save(_ items: [PromptSnippet]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// One Mac's session, for the list that shows every paired Mac at once.
struct MacSession: Identifiable, Equatable {
    let macId: String
    let session: SessionSummary
    var id: String { session.id }
}

/// An approval waiting somewhere — the inbox reads across every paired Mac.
struct PendingApproval: Identifiable, Equatable {
    let macId: String
    let request: PermissionRequest
    var id: String { request.id }
}

@MainActor
extension AppModel {

    // MARK: every Mac at once

    /// Sessions of every connected Mac (or just the active one when watching is off), newest first.
    func allSessions(kind: SessionKind) -> [MacSession] {
        let macIds = showAllMacs ? macs.map(\.id) : [activeMacId].compactMap { $0 }
        return macIds.flatMap { macId in
            (sessionsByMac[macId] ?? []).filter { $0.kind == kind }.map { MacSession(macId: macId, session: $0) }
        }
        .sorted { $0.session.updatedAt > $1.session.updatedAt }
    }

    /// Opens a session that may live on another Mac: the app switches over first.
    func open(_ item: MacSession) {
        if item.macId != activeMacId { switchTo(item.macId) }
        present(item.session.id, kind: item.session.kind)
    }

    var connectedMacCount: Int {
        connections.values.filter { $0.status == .connected }.count
    }

    // MARK: approvals inbox

    /// Everything waiting on you, oldest first — across Macs, sessions and chats.
    var pendingApprovals: [PendingApproval] {
        macs.flatMap { mac in (permissionsByMac[mac.id] ?? []).map { PendingApproval(macId: mac.id, request: $0) } }
            .sorted { $0.request.createdAt < $1.request.createdAt }
    }

    func session(for approval: PendingApproval) -> SessionSummary? {
        sessionsByMac[approval.macId]?.first { $0.id == approval.request.sessionId }
    }

    /// Opens the session an approval belongs to (switching Macs if it is on another one).
    func openSession(for approval: PendingApproval) {
        if approval.macId != activeMacId { switchTo(approval.macId) }
        let kind = session(for: approval)?.kind ?? .agent
        present(approval.request.sessionId, kind: kind)
    }

    // MARK: context window

    /// How full the model's context is in this session, when the agent has reported enough to say.
    func contextUsage(_ sessionId: String) -> ContextWindow.Usage? {
        guard let transcript = transcripts[sessionId], transcript.contextTokens > 0 else { return nil }
        let state = states[sessionId]
        let limit = ContextWindow.limit(model: state?.model ?? transcript.model, agent: state?.agent ?? .claude,
                                        observed: transcript.contextTokens)
        return ContextWindow.Usage(tokens: transcript.contextTokens, limit: limit)
    }

    /// Hands the conversation to the CLI's own `/compact`.
    func compact(_ sessionId: String) {
        prompt(sessionId, text: "/compact")
    }

    // MARK: rewind

    /// The transcript entry behind a row, when it is a prompt (rewind cuts at prompts).
    static func entryUUID(forItemId id: String) -> String? {
        guard id.hasPrefix("user:") else { return nil }
        let uuid = String(id.dropFirst("user:".count))
        return uuid.isEmpty ? nil : uuid
    }

    /// Takes the conversation back to just before a prompt: the Mac copies the transcript up to that
    /// point into a new session and resumes it. Nothing on disk is reverted — the turn review does that.
    func rewind(_ sessionId: String, toItemId itemId: String) {
        guard let uuid = AppModel.entryUUID(forItemId: itemId) else { return }
        rewindError = nil
        rewindingSession = sessionId
        sendMessage(.rewind(sessionId: sessionId, uuid: uuid), session: sessionId)
    }

    func handleRewound(sessionId: String, newSessionId: String, dropped: Int, error: String?) {
        rewindingSession = nil
        if let error {
            rewindError = error
            return
        }
        guard !newSessionId.isEmpty else { return }
        rewindNotice = RewindNotice(sessionId: newSessionId, dropped: dropped)
        present(newSessionId, kind: .agent)
    }

    // MARK: turn review

    /// The turns of a session that wrote files, newest first.
    func turnChanges(_ sessionId: String) -> [TurnChanges.Turn] {
        TurnChanges.reviewable(transcripts[sessionId]?.items ?? [])
    }

    func projectRoot(_ sessionId: String) -> String {
        states[sessionId]?.cwd ?? summary(for: sessionId)?.cwd ?? ""
    }

    /// Throws away the working-tree changes for the files a turn wrote (git `checkout --`).
    func revert(_ sessionId: String, paths: [String]) {
        let relative = TurnChanges.repoRelative(paths, cwd: projectRoot(sessionId))
        guard !relative.isEmpty else { return }
        runGit(sessionId, .discard(paths: relative))
    }

    // MARK: palette

    func requestPalette(_ sessionId: String) {
        sendMessage(.listPalette(sessionId: sessionId), session: sessionId)
    }

    func addSnippet(_ snippet: PromptSnippet) {
        snippets.append(snippet)
        PromptSnippet.save(snippets)
    }

    func removeSnippets(_ ids: Set<String>) {
        snippets.removeAll { ids.contains($0.id) }
        PromptSnippet.save(snippets)
    }

    // MARK: worktrees

    func requestWorktrees(_ sessionId: String) {
        worktreeErrors[sessionId] = nil
        sendMessage(.listWorktrees(sessionId: sessionId), session: sessionId)
    }

    func worktreeAction(_ sessionId: String, _ action: WorktreeAction) {
        worktreeBusy = true
        worktreeErrors[sessionId] = nil
        sendMessage(.worktreeAction(sessionId: sessionId, action: action), session: sessionId)
    }

    // MARK: task queue

    func requestTasks() {
        sendMessage(.listTasks)
    }

    func addTask(_ task: AgentTask) {
        tasks.append(task)   // optimistic; the Mac answers with the real queue
        sendMessage(.addTask(task: task))
    }

    func updateTask(_ task: AgentTask) {
        sendMessage(.updateTask(task: task))
    }

    func taskAction(_ id: String, _ action: TaskAction) {
        if action == .delete { tasks.removeAll { $0.id == id } }
        sendMessage(.taskAction(id: id, action: action))
    }

    func setTaskSettings(_ settings: TaskQueueSettings) {
        taskSettings = settings
        sendMessage(.setTaskSettings(settings: settings))
    }

    /// The task a session was started for, when it was.
    func task(forSession sessionId: String) -> AgentTask? {
        tasks.first { $0.sessionId == sessionId }
    }

    // MARK: background processes

    func requestProcesses() {
        sendMessage(.listProcesses)
    }

    /// Starts a command that keeps running on the Mac. Face ID-gated like an approval — it runs code there.
    func startProcess(_ sessionId: String?, command: String, label: String?, completion: @escaping (CommandRun?) -> Void) {
        let start = { [self] in
            let runId = UUID().uuidString.lowercased()
            let run = CommandRun(id: runId, sessionId: sessionId ?? "", command: command)
            commandRuns[runId] = run
            attachedProcesses.insert(runId)
            sendMessage(.startProcess(sessionId: sessionId, runId: runId, command: command, label: label), session: sessionId)
            requestProcesses()
            completion(run)
        }
        if requireBiometricsForApproval {
            Task { @MainActor in
                guard await Biometrics.authenticate(reason: "Run a command on the Mac") else { completion(nil); return }
                start()
            }
        } else {
            start()
        }
    }

    /// Follows (or stops following) a process's output. Attaching replays the buffered tail.
    @discardableResult
    func attachProcess(_ process: BackgroundProcess, attached: Bool) -> CommandRun? {
        if attached {
            let run = commandRuns[process.id] ?? CommandRun(id: process.id, sessionId: process.sessionId ?? "", command: process.command)
            run.output = ""            // the Mac replays what it has buffered
            run.done = !process.running
            run.exitCode = process.exitCode
            commandRuns[process.id] = run
            attachedProcesses.insert(process.id)
            sendMessage(.attachProcess(runId: process.id, attached: true), session: process.sessionId)
            return run
        }
        attachedProcesses.remove(process.id)
        sendMessage(.attachProcess(runId: process.id, attached: false), session: process.sessionId)
        return commandRuns[process.id]
    }

    func killProcess(_ process: BackgroundProcess) {
        sendMessage(.killProcess(runId: process.id), session: process.sessionId)
    }

    /// Processes worth a badge: still running.
    var runningProcessCount: Int { backgroundProcesses.filter(\.running).count }
}
