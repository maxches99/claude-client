#if os(macOS) || os(Linux)
import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
import ClaudeRemoteCore

/// Owns CLI processes and transcript watchers; fans events out to connected phones.
public actor SessionManager {
    public typealias Sender = @Sendable (ServerMessage) -> Void

    public enum ManagerError: Error, CustomStringConvertible {
        case unknownSession(String)
        case notDrivable(String)
        case cwdMissing(String)
        case spawnFailed(String)

        public var description: String {
            switch self {
            case .unknownSession(let id): return "Unknown session \(id)"
            case .notDrivable(let why): return why
            case .cwdMissing(let p): return p.isEmpty ? "No project directory was given" : "Directory does not exist: \(p)"
            case .spawnFailed(let why): return "Could not start claude: \(why)"
            }
        }
    }

    /// A session the daemon drives: a `claude` process of our own, or a thread in the shared Codex app-server.
    final class Hosted {
        let process: CLIProcess?          // Claude only
        var state: SessionState
        var pending: [String: PermissionRequest] = [:]
        /// Claude's `can_use_tool` waits on stdin for the answer; Codex approvals are answered through the backend.
        var waiters: [String: CheckedContinuation<JSONValue?, Never>] = [:]
        var startedAt = Date()
        /// Last prompt, event or phone open — what the idle reaper measures from.
        var lastActivity = Date()
        var title: String?
        var forkedFromPath: String?
        // What the Live Activity push shows: the tool running right now, whether the model is thinking,
        // and when the turn began — cheap to track from the stream, no transcript needed.
        var lastTool: (name: String, line: String)?
        var thinking = false
        var turnStartedAt: Date?
        var lastActivityPush = Date.distantPast
        var activityPushTimer: Task<Void, Never>?
        /// History a Codex fork/resume came with, replayed to the next phone that opens it.
        var forkedHistory: [JSONValue]?
        /// Prompts sent while a turn was running; the first goes out when the turn ends.
        var queue: [(prompt: QueuedPrompt, images: [InlineImage], attachments: [Attachment]?)] = []
        /// Tool inputs as the CLI sent them, where the phone-facing request was enriched (a plan read
        /// from disk); the reply echoes the original.
        var originalInputs: [String: JSONValue] = [:]
        var agent: AgentKind { state.agent }
        init(process: CLIProcess?, state: SessionState) {
            self.process = process
            self.state = state
        }
    }

    private final class Watched {
        var tail: TranscriptTail?
        var state: SessionState
        var live: LiveSessionRegistry.LiveSession
        var poller: DispatchSourceTimer?
        var tailing = false     // transcript file found and being followed
        var transcriptPath: String?
        /// Sub-agent files being followed, by path; they appear while the session runs.
        var subagentTails: [String: TranscriptTail] = [:]
        init(state: SessionState, live: LiveSessionRegistry.LiveSession) {
            self.state = state
            self.live = live
        }
    }

    /// Chats run in their own scratch directory; that is also how a chat is recognised later
    /// (a session whose cwd is this directory), for both agents and across restarts.
    public static let chatDirectory = HostPaths.supportDirectory + "/chats"

    /// Replaces the coding-agent system prompt in a chat session.
    static let chatSystemPrompt = """
        You are a helpful assistant answering questions in a chat on someone's phone. \
        Answer directly and concisely; no preamble, no task planning. You have no tools and no \
        codebase to work on here — if something genuinely needs files or commands, say so and \
        suggest opening a normal session instead.
        """

    /// A Codex thread open in the Codex app (or another client): we cannot drive it, but its state
    /// on disk is readable, so it is polled and mirrored to the phone.
    private final class WatchedCodex {
        var state: SessionState
        var tail: TranscriptTail?
        /// Watches for the session being closed in the Codex app.
        var poller: DispatchSourceTimer?
        /// History replayed to a phone that opens this session later.
        var history: [JSONValue] = []
        var translator = CodexRollout()
        var title: String?
        init(state: SessionState) { self.state = state }
    }

    let cli: ClaudeCLI
    let codex: CodexBackend?
    let store: TranscriptStore
    private let registry: LiveSessionRegistry
    let notifier: Notifier?
    private let livePusher: LiveActivityPusher?
    private let approvalLog: String?
    let log: @Sendable (String) -> Void
    var subscribers: [UUID: Sender] = [:]
    /// Live Activity push tokens per session, per phone. Kept while the phone is away — that's the point.
    private var activityTokens: [String: [UUID: (token: String, approvalNeedsApp: Bool)]] = [:]
    var hosted: [String: Hosted] = [:]
    private var watched: [String: Watched] = [:]
    private var watchedCodex: [String: WatchedCodex] = [:]
    /// Codex threads someone else has open right now, refreshed with the session list.
    private var codexOpenElsewhere: Set<String> = []
    private var cachedCliVersion: String?
    private var cachedLoggedIn: Bool?
    private var cachedCodexVersion: String?
    /// Codex threads on disk, as last fetched from the app-server (see `refreshSources`).
    var codexThreads: [CodexBackend.ThreadInfo] = []
    /// Codex threads this daemon closed recently — `thread/list` picks them up with a delay.
    private var recentCodexThreads: [CodexBackend.ThreadInfo] = []
    /// Permission prompts of sessions we do not host (Desktop / terminal), handed to us by the CLI's
    /// `PermissionRequest` hook and parked until a phone answers or the hook gives up.
    private struct HookWaiter {
        let request: PermissionRequest
        let originalInput: JSONValue
        let continuation: CheckedContinuation<JSONValue?, Never>
    }
    private var hookWaiters: [String: HookWaiter] = [:]

    /// Close hosted chats idle this long (their process stays resident otherwise — 250 MB each on a
    /// hub). `nil` = keep them until closed. Reopening resumes from the transcript.
    private var idleTimeout: TimeInterval?
    private var idleReaper: DispatchSourceTimer?

    // MARK: queue & processes (logic in SessionManagerTasks.swift / BackgroundProcesses.swift)

    /// Commands left running on the Mac, by run id — they outlive the phone that started them.
    var processes: [String: BackgroundRun] = [:]
    /// Shells in pseudo-terminals, by terminal id (TerminalSessions.swift).
    var terminals: [String: TerminalRun] = [:]
    /// Where share links are published (SessionManagerShare.swift); nil without a relay.
    var shareConfig: ShareConfig?
    /// The task queue, oldest first, and how it is worked off.
    var tasks: [AgentTask] = []
    var taskSettings = TaskQueueSettings()
    /// Wakes the queue for scheduled tasks.
    var taskTimer: Task<Void, Never>?
    /// `tasks.json` in the support directory, when the daemon gave us one.
    let taskStorePath: String?

    public init(cli: ClaudeCLI, codex: CodexBackend? = nil, store: TranscriptStore = TranscriptStore(), registry: LiveSessionRegistry = LiveSessionRegistry(),
                notifier: Notifier? = nil, livePusher: LiveActivityPusher? = nil, approvalLog: String? = nil, taskStore: String? = nil,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.approvalLog = approvalLog
        self.taskStorePath = taskStore
        self.cli = cli
        self.codex = codex
        self.store = store
        self.registry = registry
        self.notifier = notifier
        self.livePusher = livePusher
        self.log = log
        if let codex {
            Task { [weak self] in
                await codex.setEventHandler { [weak self] event in
                    guard let self else { return }
                    Task { await self.handleCodexEvent(event) }
                }
            }
        }
        Task { [weak self] in
            await self?.loadTasks()
            await self?.startTaskTimer()
        }
    }

    // MARK: idle chats

    public func setIdleTimeout(_ timeout: TimeInterval?) {
        idleTimeout = timeout
        idleReaper?.cancel()
        idleReaper = nil
        guard let timeout, timeout > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.reapIdleChats() }
        }
        timer.resume()
        idleReaper = timer
    }

    private func reapIdleChats() async {
        guard let idleTimeout else { return }
        let now = Date()
        let stale = hosted.filter { _, h in
            h.state.kind == .chat && h.state.status == .idle && now.timeIntervalSince(h.lastActivity) > idleTimeout
        }
        for (id, h) in stale {
            log("[\(id.prefix(8))] chat idle for \(Int(now.timeIntervalSince(h.lastActivity) / 60)) min — closing (reopen resumes it)")
            await close(sessionId: id)
        }
    }

    // MARK: subscribers

    public func subscribe(_ id: UUID, send: @escaping Sender) {
        subscribers[id] = send
    }

    public func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
        detachAllProcesses(phone: id)
        detachAllTerminals(phone: id)
        // Nobody left to answer: let the Mac show its own prompt instead of holding the CLI.
        if subscribers.isEmpty { cancelHookPermissions(reason: "no phone connected") }
    }

    public var hasSubscribers: Bool { !subscribers.isEmpty }

    func broadcast(_ message: ServerMessage) {
        for send in subscribers.values { send(message) }
    }

    /// Recent durable events per session, numbered, so a phone that reconnects can catch up.
    private var eventLog: [String: [(seq: Int, payload: JSONValue)]] = [:]
    private var eventSeq: [String: Int] = [:]
    private static let eventLogLimit = 400

    /// Sends a session event to every phone, numbering and remembering it unless it is a partial
    /// stream delta (those are superseded by the full message that follows).
    private func emit(sessionId: String, payload: JSONValue) {
        guard payload["type"]?.string != "stream_event" else {
            broadcast(.event(sessionId: sessionId, payload: payload))
            return
        }
        let seq = (eventSeq[sessionId] ?? 0) + 1
        eventSeq[sessionId] = seq
        var log = eventLog[sessionId] ?? []
        log.append((seq, payload))
        if log.count > SessionManager.eventLogLimit { log.removeFirst(log.count - SessionManager.eventLogLimit) }
        eventLog[sessionId] = log
        broadcast(.event(sessionId: sessionId, payload: payload, seq: seq))
    }

    /// Everything after `since`, if the log still reaches back that far (nil otherwise = resend history).
    private func catchUp(sessionId: String, since: Int) -> [JSONValue]? {
        let current = eventSeq[sessionId] ?? 0
        if since == current { return [] }
        guard since < current, let log = eventLog[sessionId], let first = log.first, first.seq <= since + 1 else { return nil }
        return log.filter { $0.seq > since }.map(\.payload)
    }

    // MARK: info

    public func hostInfo(daemonVersion: String) async -> HostInfo {
        if cachedCliVersion == nil { cachedCliVersion = cli.version() }
        if cachedLoggedIn == nil { cachedLoggedIn = cli.authStatus()?.loggedIn }
        var codexInfo: CodexInfo?
        if let codex {
            if cachedCodexVersion == nil { cachedCodexVersion = codex.cli.version() }
            codexInfo = CodexInfo(path: codex.cli.path, version: cachedCodexVersion, loggedIn: await codex.loggedIn)
        }
        return HostInfo(hostName: HostPaths.machineName, daemonVersion: daemonVersion,
                        cliVersion: cachedCliVersion, cliPath: cli.path, loggedIn: cachedLoggedIn, codex: codexInfo, livePush: livePusher != nil,
                        canShare: shareConfig != nil)
    }

    public var hasCodex: Bool { codex != nil }

    public func warmUpCodex() async { await codex?.warmUp() }

    /// Codex threads open in the Codex app on the shared app-server — followed and driven by
    /// resuming them there (see `CodexBackend.threadsLoadedElsewhere`).
    private var codexLoadedElsewhere: Set<String> = []

    /// Fetches what `listSessions` cannot read synchronously (the Codex thread list). Call before
    /// answering an explicit list request; broadcasts reuse the last fetch.
    public func refreshSources() async {
        guard let codex else { return }
        codexLoadedElsewhere = await codex.threadsLoadedElsewhere()
        // On a shared server every loaded thread's lock is held by that one process, so the lock
        // files say nothing about who has it open; `thread/loaded/list` does.
        let hosted = await codex.hostedThreadIds()
        codexOpenElsewhere = codex.isShared ? codexLoadedElsewhere : CodexCLI.threadsOpenElsewhere().subtracting(hosted)
        do {
            codexThreads = try await codex.listThreads()
        } catch {
            log("codex thread list failed: \(error)")
        }
    }

    /// Models an agent can run here. Claude's list is fixed; Codex advertises its own.
    public func listModels(agent: AgentKind) async throws -> [ModelOption] {
        switch agent {
        case .claude:
            return [ModelOption(id: "claude-opus-5", label: "Opus 5", isDefault: true),
                    ModelOption(id: "claude-sonnet-5", label: "Sonnet 5"),
                    ModelOption(id: "claude-haiku-4-5", label: "Haiku 4.5")]
        case .codex:
            guard let codex else { throw CodexBackend.BackendError.notInstalled }
            return try await codex.listModels()
        }
    }

    public func refreshAuth() {
        cachedLoggedIn = cli.authStatus()?.loggedIn
    }

    public func listProjects() -> [ProjectInfo] {
        store.projects().filter { $0.path != SessionManager.chatDirectory }
    }

    static func kind(cwd: String) -> SessionKind {
        cwd == chatDirectory ? .chat : .agent
    }

    public func listSessions() -> [SessionSummary] {
        let stored = store.allSessions()
        let storedById = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [SessionSummary] = []
        var seen = Set<String>()

        let codexById = Dictionary(codexThreads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, h) in hosted {
            let s = storedById[id]
            let title = h.title ?? s?.title ?? codexById[id]?.title ?? (h.state.kind == .chat ? "New chat" : "New session")
            result.append(SessionSummary(id: id, title: title, cwd: h.state.cwd, updatedAt: s?.updatedAt ?? codexById[id]?.updatedAt ?? h.startedAt,
                                         origin: .host, status: h.state.status, agent: h.agent, kind: h.state.kind))
            seen.insert(id)
        }
        let ownPids = Set(hosted.values.compactMap { $0.process?.pid })
        for live in registry.liveSessions() where !seen.contains(live.sessionId) && !ownPids.contains(live.pid) {
            let s = storedById[live.sessionId]
            let status: SessionStatus = hasHookPermission(sessionId: live.sessionId) ? .awaitingPermission : (live.status == "busy" ? .running : .idle)
            result.append(SessionSummary(id: live.sessionId, title: s?.title ?? live.name ?? "Desktop session", cwd: live.cwd,
                                         updatedAt: s?.updatedAt ?? live.updatedAt, origin: .desktop, status: status,
                                         desktopName: live.name, entrypoint: live.entrypoint))
            seen.insert(live.sessionId)
        }
        for (id, w) in watchedCodex where !seen.contains(id) {
            let t = codexById[id]
            result.append(SessionSummary(id: id, title: w.title ?? t?.title ?? "Codex session", cwd: w.state.cwd,
                                         updatedAt: t?.updatedAt ?? Date(), origin: .desktop, status: w.state.status,
                                         entrypoint: "codex-app", agent: .codex, kind: SessionManager.kind(cwd: w.state.cwd)))
            seen.insert(id)
        }
        for s in stored where !seen.contains(s.id) {
            result.append(SessionSummary(id: s.id, title: s.title, cwd: s.cwd, updatedAt: s.updatedAt, origin: .stored, status: .unknown,
                                         kind: SessionManager.kind(cwd: s.cwd)))
        }
        for t in codexThreads + recentCodexThreads where !seen.contains(t.id) {
            // Open in the Codex app → it belongs there; we can follow it but not drive it.
            let elsewhere = codexOpenElsewhere.contains(t.id)
            result.append(SessionSummary(id: t.id, title: t.title, cwd: t.cwd, updatedAt: t.updatedAt,
                                         origin: elsewhere ? .desktop : .stored, status: elsewhere ? .idle : .unknown,
                                         entrypoint: elsewhere ? "codex-app" : nil, agent: .codex, kind: SessionManager.kind(cwd: t.cwd)))
            seen.insert(t.id)
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: open / create

    /// Attach the caller to a session. Sends `history` + `state` to `reply`; subsequent traffic is broadcast.
    public func open(sessionId: String, since: Int? = nil, reply: Sender) async throws {
        // A reconnecting phone that still holds the transcript only needs the gap.
        if let since, let state = hosted[sessionId]?.state ?? watched[sessionId]?.state ?? watchedCodex[sessionId]?.state,
           let missed = catchUp(sessionId: sessionId, since: since) {
            reply(.catchUp(sessionId: sessionId, entries: missed, lastSeq: eventSeq[sessionId] ?? since))
            reply(.state(state: state))
            return
        }
        if let h = hosted[sessionId] {
            h.lastActivity = Date()
            sendHistory(sessionId: sessionId, to: reply)
            reply(.state(state: h.state))
            return
        }
        if let w = watched[sessionId] {
            sendHistory(sessionId: sessionId, to: reply)
            reply(.state(state: w.state))
            return
        }
        if let w = watchedCodex[sessionId] {
            reply(.history(sessionId: sessionId, entries: w.history))
            reply(.state(state: w.state))
            return
        }
        let stored = store.session(id: sessionId)
        let ownPids = Set(hosted.values.compactMap { $0.process?.pid })
        if let live = registry.liveSessions().first(where: { $0.sessionId == sessionId && !ownPids.contains($0.pid) }) {
            // Open in Claude Desktop / a terminal: follow the transcript instead of starting a second process.
            // Prompts are delivered through the process's messaging inbox (see PeerInbox).
            var state = SessionState(id: sessionId, origin: .desktop, status: live.status == "busy" ? .running : .idle, cwd: live.cwd)
            state.pendingPermissions = hookWaiters.values.map(\.request).filter { $0.sessionId == sessionId }.sorted { $0.createdAt < $1.createdAt }
            if !state.pendingPermissions.isEmpty { state.status = .awaitingPermission }
            let w = Watched(state: state, live: live)
            watched[sessionId] = w
            if let stored {
                let history = store.history(path: stored.path)
                reply(.history(sessionId: sessionId, entries: history.entries))
                attachTail(to: w, sessionId: sessionId, path: stored.path, startOffset: history.endOffset)
            } else {
                // Freshly started session: no transcript yet. The poller attaches the tail once it appears.
                reply(.history(sessionId: sessionId, entries: []))
            }
            startStatusPolling(sessionId: sessionId)
            reply(.state(state: state))
            return
        }
        guard let stored else {
            // Not a Claude transcript — a Codex thread on disk, if Codex is around.
            guard let codex, isCodexThread(sessionId) else { throw ManagerError.unknownSession(sessionId) }
            var loadedElsewhere = codex.isShared && codexLoadedElsewhere.contains(sessionId)
            if codex.isShared, !loadedElsewhere { loadedElsewhere = await codex.threadsLoadedElsewhere().contains(sessionId) }
            if loadedElsewhere {
                // Open in the Codex app on the shared server: resuming subscribes us to it live.
                let started = try await codex.resume(threadId: sessionId)
                let h = adoptCodex(started)
                h.title = codexThreads.first { $0.id == sessionId }?.title
                reply(.history(sessionId: sessionId, entries: started.history))
                reply(.state(state: h.state))
                broadcast(.sessions(items: listSessions()))
                return
            }
            if !codex.isShared, codexOpenElsewhere.contains(sessionId) || CodexCLI.threadsOpenElsewhere().contains(sessionId) {
                try await watchCodex(sessionId: sessionId, reply: reply)
                return
            }
            let isChat = codexThreads.first { $0.id == sessionId }?.cwd == SessionManager.chatDirectory
            let options = isChat ? CodexBackend.TurnOptions(effort: "low", approvalPolicy: CodexApprovalPolicy.never.rawValue,
                                                            sandbox: CodexSandboxMode.readOnly.rawValue) : CodexBackend.TurnOptions()
            let started = try await codex.resume(threadId: sessionId, options: options,
                                                 instructions: isChat ? SessionManager.chatSystemPrompt : nil)
            let h = adoptCodex(started)
            reply(.history(sessionId: sessionId, entries: started.history))
            reply(.state(state: h.state))
            broadcast(.sessions(items: listSessions()))
            return
        }
        guard FileManager.default.fileExists(atPath: stored.cwd) else { throw ManagerError.cwdMissing(stored.cwd) }
        var config = CLIProcess.Config(cliPath: cli.path, cwd: stored.cwd)
        config.resume = sessionId
        let kind = SessionManager.kind(cwd: stored.cwd)
        if kind == .chat {
            config.tools = ""
            config.systemPrompt = SessionManager.chatSystemPrompt
            config.settingSources = ""
        }
        let h = try spawn(sessionId: sessionId, config: config, origin: .host, kind: kind)
        h.title = stored.title
        let history = store.history(path: stored.path)
        reply(.history(sessionId: sessionId, entries: history.entries))
        reply(.state(state: h.state))
        broadcast(.sessions(items: listSessions()))
    }

    /// Hosted or listed as Codex — or, before the thread list has arrived, shaped like a Codex id:
    /// Codex thread ids are UUIDv7 (time-ordered, `01a0…`), Claude session ids random UUIDv4.
    func isCodexThread(_ id: String) -> Bool {
        if let h = hosted[id] { return h.agent == .codex }
        if codexThreads.contains(where: { $0.id == id }) || recentCodexThreads.contains(where: { $0.id == id }) { return true }
        return store.session(id: id) == nil && id.count == 36 && id.dropFirst(14).first == "7"
    }

    public func create(_ options: NewSessionOptions) async throws -> SessionState {
        let isChat = options.kind == .chat
        let cwd = isChat ? SessionManager.chatDirectory : options.cwd
        if isChat {
            try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        }
        guard FileManager.default.fileExists(atPath: cwd) else { throw ManagerError.cwdMissing(cwd) }
        if options.agent == .codex {
            guard let codex else { throw CodexBackend.BackendError.notInstalled }
            // A chat is a thread with no way to touch the machine: read-only sandbox, nothing to approve.
            let turnOptions = CodexBackend.TurnOptions(
                model: options.model, effort: options.effort ?? (isChat ? "low" : nil),
                approvalPolicy: isChat ? CodexApprovalPolicy.never.rawValue : options.permissionMode,
                sandbox: isChat ? CodexSandboxMode.readOnly.rawValue : options.sandbox)
            let started = try await codex.start(cwd: cwd, options: turnOptions,
                                                instructions: isChat ? SessionManager.chatSystemPrompt : nil)
            let h = adoptCodex(started, kind: options.kind)
            broadcast(.sessions(items: listSessions()))
            return h.state
        }
        let sessionId = UUID().uuidString.lowercased()
        var config = CLIProcess.Config(cliPath: cli.path, cwd: cwd)
        config.sessionId = sessionId
        config.model = options.model ?? (isChat ? "claude-sonnet-5" : nil)
        config.effort = options.effort
        if isChat {
            config.tools = ""                  // no tools at all → nothing can ask for permission
            config.systemPrompt = SessionManager.chatSystemPrompt
            config.settingSources = ""         // no CLAUDE.md, no project settings
        } else {
            config.permissionMode = options.permissionMode
        }
        let h = try spawn(sessionId: sessionId, config: config, origin: .host, kind: options.kind)
        broadcast(.sessions(items: listSessions()))
        return h.state
    }

    /// Continue a copy of `sessionId` under the daemon (safe even while the original is open in Desktop).
    public func fork(sessionId: String) async throws -> SessionState {
        if let codex, isCodexThread(sessionId) {
            let started = try await codex.fork(threadId: sessionId)
            let h = adoptCodex(started)
            h.title = h.title ?? hosted[sessionId]?.title ?? codexThreads.first { $0.id == sessionId }?.title
            h.forkedHistory = started.history
            broadcast(.sessions(items: listSessions()))
            return h.state
        }
        guard let stored = store.session(id: sessionId) else { throw ManagerError.unknownSession(sessionId) }
        guard FileManager.default.fileExists(atPath: stored.cwd) else { throw ManagerError.cwdMissing(stored.cwd) }
        let newId = UUID().uuidString.lowercased()
        var config = CLIProcess.Config(cliPath: cli.path, cwd: stored.cwd)
        config.resume = sessionId
        config.forkSession = true
        config.sessionId = newId
        let h = try spawn(sessionId: newId, config: config, origin: .host)
        h.title = stored.title
        h.forkedFromPath = stored.path
        broadcast(.sessions(items: listSessions()))
        return h.state
    }

    private func sendHistory(sessionId: String, to reply: Sender) {
        if let h = hosted[sessionId], h.agent == .codex {
            reply(.history(sessionId: sessionId, entries: h.forkedHistory ?? []))
            return
        }
        if let h = hosted[sessionId], let source = h.forkedFromPath, store.session(id: sessionId) == nil {
            // The fork's own transcript is not on disk yet; the original has the same history.
            reply(.history(sessionId: sessionId, entries: store.history(path: source).entries))
            return
        }
        if let stored = store.session(id: sessionId) {
            reply(.history(sessionId: sessionId, entries: store.history(path: stored.path).entries))
        } else {
            reply(.history(sessionId: sessionId, entries: []))
        }
    }

    func spawn(sessionId: String, config: CLIProcess.Config, origin: SessionOrigin, kind: SessionKind = .agent) throws -> Hosted {
        let process = CLIProcess(config: config)
        let state = SessionState(id: sessionId, origin: origin, status: .idle, cwd: config.cwd, model: config.model,
                                 permissionMode: config.permissionMode, kind: kind)
        let h = Hosted(process: process, state: state)
        let log = self.log
        process.log = { line in log("[\(sessionId.prefix(8))] \(line)") }
        process.onMessage = { [weak self] message in
            guard let self else { return }
            Task { await self.handleMessage(sessionId: sessionId, message: message) }
        }
        process.onControlRequest = { [weak self] requestId, request in
            guard let self else { return nil }
            return await self.handleControlRequest(sessionId: sessionId, requestId: requestId, request: request)
        }
        process.onControlCancel = { [weak self] requestId in
            guard let self else { return }
            Task { await self.cancelPermission(sessionId: sessionId, requestId: requestId) }
        }
        process.onExit = { [weak self] status, stderr in
            guard let self else { return }
            Task { await self.handleExit(sessionId: sessionId, status: status, stderr: stderr) }
        }
        do {
            try process.start()
        } catch {
            throw ManagerError.spawnFailed(error.localizedDescription)
        }
        hosted[sessionId] = h
        Task {
            do {
                _ = try await process.initialize()
            } catch {
                log("[\(sessionId.prefix(8))] initialize failed: \(error)")
            }
        }
        return h
    }

    /// Registers a thread the Codex backend just started / resumed / forked.
    private func adoptCodex(_ started: CodexBackend.Started, kind: SessionKind? = nil) -> Hosted {
        let state = SessionState(id: started.id, origin: .host, status: .idle, cwd: started.cwd, model: started.model,
                                 permissionMode: started.approvalPolicy, agent: .codex,
                                 kind: kind ?? SessionManager.kind(cwd: started.cwd), effort: started.effort, sandbox: started.sandbox)
        let h = Hosted(process: nil, state: state)
        h.title = started.title
        h.forkedHistory = started.history
        hosted[started.id] = h
        return h
    }

    // MARK: driving

    public func prompt(sessionId: String, text: String, images: [InlineImage] = [], attachments: [Attachment]? = nil, resumed: Bool = false) async throws {
        var text = text
        var images = images
        if let attachments, !attachments.isEmpty {
            // Only a session with a live CLI process here can take inline image blocks. Watched desktop /
            // Codex sessions are driven over a text-only channel, so their images are staged to disk too.
            let inlineCapable = hosted[sessionId] != nil
            let staged = try stageAttachments(attachments, sessionId: sessionId, stageImages: !inlineCapable)
            images += staged.images
            if !staged.text.isEmpty { text += (text.isEmpty ? "" : "\n\n") + staged.text }
        }
        guard let h = hosted[sessionId] else {
            if !resumed, watched[sessionId] == nil, watchedCodex[sessionId] == nil,
               store.session(id: sessionId) != nil || isCodexThread(sessionId) {
                // Not attached any more — the idle reaper closed this chat (or the phone kept a
                // stored session on screen). Bring it back the way `open` does and continue;
                // phones still hold the history, so only the fresh state goes out.
                let senders = Array(subscribers.values)
                try await open(sessionId: sessionId) { message in
                    if case .state = message { for send in senders { send(message) } }
                }
                try await prompt(sessionId: sessionId, text: text, images: images, resumed: true)
                return
            }
            if watchedCodex[sessionId] != nil {
                guard let codexCLI = codex?.cli else { throw ManagerError.unknownSession(sessionId) }
                guard images.isEmpty else {
                    throw ManagerError.notDrivable("Images can only be sent to sessions hosted on the phone.")
                }
                // We cannot drive another process's thread; Codex has a queue for exactly this.
                try codexCLI.queue(threadId: sessionId, message: text)
                return
            }
            if let w = watched[sessionId] {
                guard let socket = w.live.messagingSocketPath else {
                    throw ManagerError.notDrivable("This session has no messaging inbox; fork it to continue from the phone.")
                }
                #if os(macOS)
                // The inbox channel only carries text; images are supported on phone-hosted sessions.
                try PeerInbox.send(text: text, socketPath: socket, pid: w.live.pid, sessionsDirectory: registry.directory)
                w.state.status = .running
                broadcast(.state(state: w.state))
                return
                #else
                _ = socket
                throw ManagerError.notDrivable("Writing into sessions of another process is not supported on this platform; fork it to continue from the phone.")
                #endif
            }
            throw ManagerError.unknownSession(sessionId)
        }
        h.lastActivity = Date()
        if h.state.status == .running || h.state.status == .awaitingPermission {
            // Mid-turn: park it. Sending now would either interleave with the running turn (Claude)
            // or be refused (Codex); the queue goes out in order as turns end.
            let queued = QueuedPrompt(text: text, attachmentCount: images.count)
            h.queue.append((queued, images, nil))
            h.state.queued.append(queued)
            broadcast(.state(state: h.state))
            return
        }
        if let process = h.process {
            try process.sendUser(text, images: images)
        } else if let codex {
            // Codex does not echo the prompt; show ours right away, then hand the turn over.
            let event = try await codex.prompt(threadId: sessionId, text: text, images: images, options: codexOptions(h))
            emit(sessionId: sessionId, payload: event)
            h.forkedHistory?.append(event)
        }
        if h.title == nil {
            h.title = String(text.split(separator: "\n").first ?? "").trimmingCharacters(in: .whitespaces)
            broadcast(.sessions(items: listSessions()))
        }
        h.turnStartedAt = Date()
        h.lastTool = nil
        h.thinking = false
        update(h, status: .running)
    }

    private func codexOptions(_ h: Hosted) -> CodexBackend.TurnOptions {
        CodexBackend.TurnOptions(model: h.state.model, effort: h.state.effort, approvalPolicy: h.state.permissionMode, sandbox: h.state.sandbox)
    }

    /// Pull a prompt back out of the queue before it is sent.
    public func dequeue(sessionId: String, promptId: String) {
        guard let h = hosted[sessionId] else { return }
        h.queue.removeAll { $0.prompt.id == promptId }
        h.state.queued.removeAll { $0.id == promptId }
        broadcast(.state(state: h.state))
    }

    /// The turn ended: send the next queued prompt, if any. Runs after the idle state went out so
    /// the phone sees the turn boundary.
    private func flushQueue(sessionId: String) {
        guard let h = hosted[sessionId], h.state.status == .idle, !h.queue.isEmpty else { return }
        let next = h.queue.removeFirst()
        h.state.queued.removeAll { $0.id == next.prompt.id }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.prompt(sessionId: sessionId, text: next.prompt.text, images: next.images, attachments: next.attachments)
            } catch {
                await self.queueFailed(sessionId: sessionId, error: "\(error)")
            }
        }
    }

    private func queueFailed(sessionId: String, error: String) {
        guard let h = hosted[sessionId] else { return }
        h.state.lastError = "Queued prompt failed: \(error)"
        broadcast(.state(state: h.state))
    }

    /// The reply for a `can_use_tool` / hook decision. `updatedInput` (a question's answers) wins over
    /// the input as requested; "remember" echoes the CLI's suggested rule so matching calls are
    /// auto-approved later.
    private static func decision(allow: Bool, input: JSONValue, updatedInput: JSONValue?, suggestions: JSONValue?, remember: Bool,
                                 message: String?, echoInput: Bool) -> JSONValue {
        guard allow else { return .object(["behavior": "deny", "message": .string(message ?? "Denied from phone")]) }
        var fields: [String: JSONValue] = ["behavior": "allow"]
        if let updatedInput { fields["updatedInput"] = updatedInput } else if echoInput { fields["updatedInput"] = input }
        if remember, let suggestions, suggestions.array?.isEmpty == false { fields["updatedPermissions"] = suggestions }
        return .object(fields)
    }

    public static func approvalLogPath(supportDirectory: String) -> String { supportDirectory + "/approvals.jsonl" }

    /// One line per decision made from a phone: when, who, which session and tool, what was decided.
    private func recordApproval(_ request: PermissionRequest, allow: Bool, remember: Bool, by device: String?, source: String) {
        guard let approvalLog else { return }
        let summary = ToolSummary.line(name: request.toolName, input: request.input)
        let entry: JSONValue = .object([
            "at": .string(ISO8601DateFormatter().string(from: Date())),
            "device": .string(device ?? "phone"),
            "session": .string(request.sessionId),
            "project": .string(((cwdFor(request.sessionId) ?? "") as NSString).lastPathComponent),
            "tool": .string(request.toolName),
            "summary": .string(String(summary.prefix(300))),
            "decision": .string(allow ? (remember ? "allow+remember" : "allow") : "deny"),
            "source": .string(source),
        ])
        let line = entry.serializedString() + "\n"
        if let handle = FileHandle(forWritingAtPath: approvalLog) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            handle.write(Data(line.utf8))
        } else {
            FileManager.default.createFile(atPath: approvalLog, contents: Data(line.utf8), attributes: [.posixPermissions: 0o600])
        }
    }

    public func resolvePermission(sessionId: String, requestId: String, allow: Bool, message: String?, remember: Bool = false,
                                  updatedInput: JSONValue? = nil, by device: String? = nil) async {
        if let waiter = hookWaiters[requestId] {
            recordApproval(waiter.request, allow: allow, remember: remember, by: device, source: "hook")
            resolveHookPermission(requestId: requestId, allow: allow, message: message, remember: remember, updatedInput: updatedInput)
            return
        }
        guard let h = hosted[sessionId], let request = h.pending.removeValue(forKey: requestId) else { return }
        recordApproval(request, allow: allow, remember: remember, by: device, source: h.agent == .codex ? "codex" : "claude")
        let original = h.originalInputs.removeValue(forKey: requestId) ?? request.input
        if let waiter = h.waiters.removeValue(forKey: requestId) {
            waiter.resume(returning: SessionManager.decision(allow: allow, input: original, updatedInput: updatedInput, suggestions: request.suggestions,
                                                             remember: remember, message: message, echoInput: true))
        } else if let codex {
            await codex.decide(requestId: requestId, allow: allow)
        }
        h.state.pendingPermissions.removeAll { $0.id == requestId }
        broadcast(.permissionResolved(sessionId: sessionId, requestId: requestId))
        update(h, status: h.pending.isEmpty ? .running : .awaitingPermission)
    }

    // MARK: permissions of sessions we do not host (PermissionRequest hook)

    /// The CLI of a Desktop / terminal session is about to show a permission prompt and asks us
    /// first (through the `PermissionRequest` hook). Parks the request for a phone to answer and
    /// returns the hook decision, or nil to let the Mac prompt as usual — at once when no phone is
    /// connected or the session is one of ours (its `can_use_tool` already reaches the phone).
    public func requestHookPermission(requestId: String, sessionId: String, toolName: String, input: JSONValue, suggestions: JSONValue?,
                                      cwd: String?) async -> JSONValue? {
        guard hosted[sessionId] == nil, !subscribers.isEmpty else { return nil }
        let shown = SessionManager.enrichedInput(toolName: toolName, input: input)
        let request = PermissionRequest(id: requestId, sessionId: sessionId, toolName: toolName, input: shown,
                                        title: nil, description: nil, displayName: nil, decisionReason: nil, toolUseId: nil, suggestions: suggestions)
        log("[\(sessionId.prefix(8))] hook permission: \(toolName)")
        let response: JSONValue? = await withCheckedContinuation { continuation in
            hookWaiters[requestId] = HookWaiter(request: request, originalInput: input, continuation: continuation)
            if let w = watched[sessionId] {
                w.state.pendingPermissions.append(request)
                w.state.status = .awaitingPermission
                broadcast(.state(state: w.state))
            }
            broadcast(.permissionRequest(request: request))
            broadcast(.sessions(items: listSessions()))
            schedulePermissionNotification(sessionId: sessionId, requestId: requestId, permission: request)
        }
        return response
    }

    /// The hook gave up waiting (its connection closed): forget the request; the Mac prompts.
    public func cancelHookPermission(requestId: String) {
        guard let waiter = hookWaiters.removeValue(forKey: requestId) else { return }
        waiter.continuation.resume(returning: nil)
        finishHookPermission(waiter.request)
    }

    private func cancelHookPermissions(reason: String) {
        guard !hookWaiters.isEmpty else { return }
        log("hook permissions released (\(reason))")
        for id in Array(hookWaiters.keys) { cancelHookPermission(requestId: id) }
    }

    private func resolveHookPermission(requestId: String, allow: Bool, message: String?, remember: Bool, updatedInput: JSONValue?) {
        guard let waiter = hookWaiters.removeValue(forKey: requestId) else { return }
        // Only an explicit new input (answers) travels back; the hook path rejects an "updated" input
        // that merely repeats the original for tools that need user interaction.
        waiter.continuation.resume(returning: SessionManager.decision(allow: allow, input: waiter.originalInput, updatedInput: updatedInput,
                                                                      suggestions: waiter.request.suggestions, remember: remember,
                                                                      message: message, echoInput: false))
        log("[\(waiter.request.sessionId.prefix(8))] hook permission \(allow ? "allowed" : "denied") from phone: \(waiter.request.toolName)")
        finishHookPermission(waiter.request)
    }

    private func finishHookPermission(_ request: PermissionRequest) {
        if let w = watched[request.sessionId] {
            w.state.pendingPermissions.removeAll { $0.id == request.id }
            if w.state.pendingPermissions.isEmpty, w.state.status == .awaitingPermission {
                w.state.status = w.live.status == "busy" ? .running : .idle
            }
            broadcast(.state(state: w.state))
        }
        broadcast(.permissionResolved(sessionId: request.sessionId, requestId: request.id))
        broadcast(.sessions(items: listSessions()))
    }

    func hasHookPermission(sessionId: String) -> Bool {
        hookWaiters.values.contains { $0.request.sessionId == sessionId }
    }

    /// What the phone should see for a tool input: ExitPlanMode's plan is read from the plan file when
    /// the CLI did not inline it.
    private static func enrichedInput(toolName: String, input: JSONValue) -> JSONValue {
        guard toolName == PlanReview.toolName, PlanReview.plan(in: input) == nil,
              let path = PlanReview.planFilePath(in: input),
              let data = FileManager.default.contents(atPath: (path as NSString).expandingTildeInPath),
              let text = String(data: data.prefix(400_000), encoding: .utf8), !text.isEmpty else { return input }
        var fields = input.object ?? [:]
        fields["plan"] = .string(text)
        return .object(fields)
    }

    public func interrupt(sessionId: String) async throws {
        guard let h = hosted[sessionId] else { throw ManagerError.unknownSession(sessionId) }
        if let process = h.process {
            try await process.interrupt()
        } else if let codex {
            try await codex.interrupt(threadId: sessionId)
        }
    }

    public func setModel(sessionId: String, model: String) async throws {
        guard let h = hosted[sessionId] else { throw ManagerError.unknownSession(sessionId) }
        try await h.process?.setModel(model)     // Codex takes the model with the next turn
        h.state.model = model
        broadcast(.state(state: h.state))
    }

    public func setPermissionMode(sessionId: String, mode: String) async throws {
        guard let h = hosted[sessionId] else { throw ManagerError.unknownSession(sessionId) }
        try await h.process?.setPermissionMode(mode)
        h.state.permissionMode = mode
        broadcast(.state(state: h.state))
    }

    public func setEffort(sessionId: String, effort: String) throws {
        guard let h = hosted[sessionId] else { throw ManagerError.unknownSession(sessionId) }
        guard h.agent == .codex else { throw ManagerError.notDrivable("Effort can only be changed on Codex sessions") }
        h.state.effort = effort
        broadcast(.state(state: h.state))
    }

    public func setSandbox(sessionId: String, mode: String) throws {
        guard let h = hosted[sessionId] else { throw ManagerError.unknownSession(sessionId) }
        guard h.agent == .codex else { throw ManagerError.notDrivable("Sandbox applies to Codex sessions only") }
        h.state.sandbox = mode
        broadcast(.state(state: h.state))
    }

    public func close(sessionId: String) async {
        if let h = hosted[sessionId] {
            for (_, waiter) in h.waiters { waiter.resume(returning: nil) }
            h.waiters.removeAll()
            h.pending.removeAll()
            if let process = h.process {
                process.terminate()
            } else if let codex {
                await codex.close(threadId: sessionId)
                hosted[sessionId] = nil
                recentCodexThreads.removeAll { $0.id == sessionId }
                recentCodexThreads.insert(CodexBackend.ThreadInfo(id: sessionId, title: h.title ?? "Codex thread", cwd: h.state.cwd, updatedAt: Date(), path: nil), at: 0)
                if recentCodexThreads.count > 20 { recentCodexThreads.removeLast() }
                h.state.status = .exited
                h.state.pendingPermissions.removeAll()
                broadcast(.state(state: h.state))
                broadcast(.sessions(items: listSessions()))
            }
        }
        if let w = watched.removeValue(forKey: sessionId) {
            w.tail?.stop()
            w.subagentTails.values.forEach { $0.stop() }
            w.poller?.cancel()
        }
        stopWatchingCodex(sessionId: sessionId)
    }

    // MARK: Codex sessions open in the Codex app

    /// Follows a Codex thread we do not own: `thread/read` sees what the other process has written,
    /// so polling it and sending what changed mirrors the session onto the phone.
    private func watchCodex(sessionId: String, reply: Sender) async throws {
        guard let codex else { throw ManagerError.unknownSession(sessionId) }
        let info = codexThreads.first { $0.id == sessionId }
        var path = info?.path
        var cwd = info?.cwd ?? ""
        if path == nil {
            let thread = try await codex.read(threadId: sessionId)
            path = thread["path"]?.string
            cwd = thread["cwd"]?.string ?? cwd
        }
        guard let rolloutPath = path, FileManager.default.fileExists(atPath: rolloutPath) else {
            throw ManagerError.notDrivable("This Codex session is open in the Codex app and its session file could not be found.")
        }
        let state = SessionState(id: sessionId, origin: .desktop, status: .idle, cwd: cwd, agent: .codex,
                                 kind: SessionManager.kind(cwd: cwd))
        let w = WatchedCodex(state: state)
        w.title = info?.title
        let (lines, endOffset) = SessionManager.readRollout(path: rolloutPath)
        w.history = lines.flatMap { w.translator.apply($0) }
        watchedCodex[sessionId] = w
        reply(.history(sessionId: sessionId, entries: w.history))
        reply(.state(state: state))
        // Codex appends to the rollout as the turn runs, so tailing it mirrors the session live.
        w.tail = TranscriptTail(path: rolloutPath, startOffset: endOffset, accepts: { _ in true }) { [weak self] line in
            guard let self else { return }
            Task { await self.receiveRollout(sessionId: sessionId, line: line) }
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.checkCodexStillOpen(sessionId: sessionId) }
        }
        timer.resume()
        w.poller = timer
        broadcast(.sessions(items: listSessions()))
    }

    /// Whole rollout file plus the offset to keep tailing from.
    static func readRollout(path: String) -> ([JSONValue], UInt64) {
        guard let data = FileManager.default.contents(atPath: path) else { return ([], 0) }
        var lines: [JSONValue] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            if let value = try? JSONValue.parse(Data(line)) { lines.append(value) }
        }
        return (lines, UInt64(data.count))
    }

    private func receiveRollout(sessionId: String, line: JSONValue) {
        guard let w = watchedCodex[sessionId] else { return }
        let events = w.translator.apply(line)
        for event in events {
            w.history.append(event)
            emit(sessionId: sessionId, payload: event)
        }
        let status: SessionStatus = w.translator.isRunning ? .running : .idle
        if status != w.state.status {
            w.state.status = status
            broadcast(.state(state: w.state))
            broadcast(.sessions(items: listSessions()))
        }
    }

    /// Closed in the Codex app: it becomes an ordinary stored thread the phone can resume.
    private func checkCodexStillOpen(sessionId: String) {
        guard let w = watchedCodex[sessionId], !CodexCLI.threadsOpenElsewhere().contains(sessionId) else { return }
        stopWatchingCodex(sessionId: sessionId)
        w.state.status = .idle
        w.state.origin = .stored
        broadcast(.state(state: w.state))
        broadcast(.sessions(items: listSessions()))
    }

    private func stopWatchingCodex(sessionId: String) {
        guard let w = watchedCodex.removeValue(forKey: sessionId) else { return }
        w.tail?.stop()
        w.tail = nil
        w.poller?.cancel()
        w.poller = nil
        codexOpenElsewhere.remove(sessionId)
    }

    /// Mirrors the registry's busy/idle flag for a watched session and notices when it exits.
    private func startStatusPolling(sessionId: String) {
        guard let w = watched[sessionId] else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.pollWatched(sessionId: sessionId) }
        }
        timer.resume()
        w.poller = timer
    }

    private func pollWatched(sessionId: String) {
        guard let w = watched[sessionId] else { return }
        guard let live = registry.liveSession(id: sessionId) else {
            w.tail?.stop()
            w.subagentTails.values.forEach { $0.stop() }
            w.poller?.cancel()
            watched[sessionId] = nil
            w.state.status = .exited
            broadcast(.state(state: w.state))
            broadcast(.sessions(items: listSessions()))
            return
        }
        w.live = live
        // Attach the transcript tail as soon as the file shows up (new sessions write it on first turn).
        if !w.tailing, let stored = store.session(id: sessionId) {
            let history = store.history(path: stored.path)
            for entry in history.entries { emit(sessionId: sessionId, payload: entry) }
            attachTail(to: w, sessionId: sessionId, path: stored.path, startOffset: history.endOffset)
        }
        if w.tailing { attachSubagentTails(to: w, sessionId: sessionId) }
        let status: SessionStatus = hasHookPermission(sessionId: sessionId) ? .awaitingPermission : (live.status == "busy" ? .running : .idle)
        if status != w.state.status {
            w.state.status = status
            broadcast(.state(state: w.state))
        }
    }

    private func attachTail(to w: Watched, sessionId: String, path: String, startOffset: UInt64) {
        w.tailing = true
        w.transcriptPath = path
        w.tail = TranscriptTail(path: path, startOffset: startOffset) { [weak self] entry in
            guard let self else { return }
            Task { await self.emit(sessionId: sessionId, payload: entry) }
        }
        attachSubagentTails(to: w, sessionId: sessionId, fromStart: false)
    }

    /// Follows sub-agent files as they appear next to a watched transcript. Files already sent with
    /// the history are followed from their end; ones that show up later are read from the start.
    private func attachSubagentTails(to w: Watched, sessionId: String, fromStart: Bool = true) {
        guard let path = w.transcriptPath else { return }
        for (file, parent) in TranscriptStore.subagentFiles(transcriptPath: path) where w.subagentTails[file] == nil {
            let size = (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? NSNumber)?.uint64Value ?? 0
            w.subagentTails[file] = TranscriptTail(path: file, startOffset: fromStart ? 0 : size, accepts: { _ in true }) { [weak self] entry in
                guard let self, let tagged = TranscriptStore.tagSubagent(entry, parent: parent) else { return }
                Task { await self.emit(sessionId: sessionId, payload: tagged) }
            }
        }
    }

    // MARK: files

    public enum FileError: Error, CustomStringConvertible {
        case notFound, tooLarge
        public var description: String {
            switch self {
            case .notFound: return "File not found"
            case .tooLarge: return "File is larger than 12 MB"
            }
        }
    }

    /// Resolves a session's working directory across hosted/watched/stored sessions.
    func cwdFor(_ sessionId: String) -> String? {
        if let h = hosted[sessionId] { return h.state.cwd }
        if let w = watched[sessionId] { return w.state.cwd }
        if let w = watchedCodex[sessionId] { return w.state.cwd }
        return store.session(id: sessionId)?.cwd
    }

    /// Splits attachments: image files become inline images (direct vision); every other file is written
    /// under `<cwd>/.ccremote-attachments/` and returned as a prompt-appended path reference so the agent
    /// can open it with its tools. A `.gitignore` in that folder keeps staged files out of the repo.
    private func stageAttachments(_ attachments: [Attachment], sessionId: String, stageImages: Bool) throws -> (text: String, images: [InlineImage]) {
        var inlineImages: [InlineImage] = []
        var savedPaths: [String] = []
        var stageDir: String?
        for att in attachments {
            if att.isImage && !stageImages {
                inlineImages.append(InlineImage(mediaType: att.mediaType, base64: att.base64))
                continue
            }
            guard let data = Data(base64Encoded: att.base64) else { continue }
            guard let cwd = cwdFor(sessionId) else { throw ManagerError.unknownSession(sessionId) }
            let dir = stageDir ?? (cwd as NSString).appendingPathComponent(".ccremote-attachments")
            if stageDir == nil {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try? "*\n".write(toFile: (dir as NSString).appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
                stageDir = dir
            }
            let safe = SessionManager.safeFilename(att.filename)
            let stamp = SessionManager.stageStamp()
            var dest = (dir as NSString).appendingPathComponent("\(stamp)-\(safe)")
            var n = 1
            while FileManager.default.fileExists(atPath: dest) {
                dest = (dir as NSString).appendingPathComponent("\(stamp)-\(n)-\(safe)"); n += 1
            }
            try data.write(to: URL(fileURLWithPath: dest))
            savedPaths.append(".ccremote-attachments/" + (dest as NSString).lastPathComponent)
        }
        var refText = ""
        if !savedPaths.isEmpty {
            refText = "[Attached \(savedPaths.count == 1 ? "file" : "files"):\n" + savedPaths.map { "- \($0)" }.joined(separator: "\n") + "]"
        }
        return (refText, inlineImages)
    }

    private static func safeFilename(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent.replacingOccurrences(of: "/", with: "_")
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "file" : trimmed
    }

    private static func stageStamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date())
    }

    /// Fuzzy-search files under the session's cwd for the composer's "@" mention picker. Runs the walk
    /// off the actor so a large tree does not stall other messages. Empty query returns a shallow page.
    public func listFiles(sessionId: String, query: String) async -> [String] {
        guard let cwd = cwdFor(sessionId) else { return [] }
        return await Task.detached(priority: .utility) { SessionManager.walkFiles(cwd: cwd, query: query) }.value
    }

    private static let fileWalkSkipDirs: Set<String> = [
        ".git", ".build", "node_modules", "DerivedData", "DerivedDataWatch", ".swiftpm",
        "Pods", ".next", "dist", "build", ".venv", "venv", "__pycache__", ".gradle", "target",
    ]

    /// Returns up to 40 file paths (relative to `cwd`) matching `query` (case-insensitive substring on
    /// the relative path). Filename matches and shallower paths rank first. Bounded so it never hangs.
    private static func walkFiles(cwd: String, query: String) -> [String] {
        let root = URL(fileURLWithPath: cwd, isDirectory: true)
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                     options: [.skipsHiddenFiles], errorHandler: nil) else { return [] }
        let q = query.lowercased()
        var matches: [(path: String, score: Int)] = []
        var scanned = 0
        for case let url as URL in en {
            scanned += 1
            if scanned > 20_000 { break }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let name = url.lastPathComponent
            if isDir {
                if fileWalkSkipDirs.contains(name) { en.skipDescendants() }
                continue
            }
            var rel = url.path
            if rel.hasPrefix(cwd) { rel.removeFirst(cwd.count) }
            if rel.hasPrefix("/") { rel.removeFirst() }
            if rel.isEmpty { continue }
            if !q.isEmpty && !rel.lowercased().contains(q) { continue }
            let nameMiss = (q.isEmpty || name.lowercased().contains(q)) ? 0 : 500
            matches.append((rel, nameMiss + rel.count))
            if matches.count >= 400 { break }
        }
        matches.sort { $0.score != $1.score ? $0.score < $1.score : $0.path < $1.path }
        return Array(matches.prefix(40)).map(\.path)
    }

    /// The session repo's uncommitted changes (status + diff), for reviewing before approving.
    /// The `/usage` data (session cost + plan rate-limit windows). Rate limits are account-global, so if
    /// this session has no live Claude process (e.g. a desktop session) any hosted one answers.
    public func usage(sessionId: String) async throws -> JSONValue {
        if let process = hosted[sessionId]?.process ?? hosted.values.first(where: { $0.process != nil })?.process {
            return try await process.getUsage()
        }
        // No live Claude process here (e.g. viewing a desktop session) — spawn a short-lived one just to
        // read the account's plan limits, then tear it down. Rate limits are account-global.
        let resolved = cwdFor(sessionId) ?? NSHomeDirectory()
        let cwd = FileManager.default.fileExists(atPath: resolved) ? resolved : NSHomeDirectory()
        var config = CLIProcess.Config(cliPath: cli.path, cwd: cwd)
        config.sessionId = UUID().uuidString.lowercased()
        let probe = CLIProcess(config: config)
        probe.log = { [weak self] line in self?.log("[usage] \(line)") }
        try probe.start()
        defer { probe.terminate() }
        _ = try await probe.initialize()
        return try await probe.getUsage()
    }

    public func gitDiff(sessionId: String, path: String? = nil, staged: Bool = false) throws -> String {
        let cwd = try gitCwd(sessionId)
        if let path {
            // One file: the index side, the working-tree side, or the whole file when git doesn't know it yet.
            let tracked = runGit(["-C", cwd, "ls-files", "--error-unmatch", "--", path]).code == 0
            if !tracked {
                let full = (cwd as NSString).appendingPathComponent(path)
                guard let data = FileManager.default.contents(atPath: full) else { return "" }
                guard let text = String(data: data.prefix(200_000), encoding: .utf8) else { return "(binary file, \(data.count) bytes)" }
                return "--- /dev/null\n+++ b/\(path)\n" + text.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }.joined(separator: "\n")
            }
            let args = staged ? ["diff", "--cached", "--", path] : ["diff", "--", path]
            let r = runGit(["-C", cwd] + args)
            if r.code != 0 { return "git failed: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))" }
            return String(r.out.prefix(200_000))
        }
        let status = runGit(["-C", cwd, "status", "--short", "--branch"])
        if status.code != 0 {
            return status.err.contains("not a git repository") ? "Not a git repository." : "git failed: \(status.err.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        let stat = runGit(["-C", cwd, "diff", "--stat"]).out
        let diff = runGit(["-C", cwd, "diff"]).out
        var out = "# Status\n" + (status.out.isEmpty ? "clean" : status.out)
        if !stat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out += "\n# Changes\n" + stat }
        if !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out += "\n# Diff\n" + diff }
        return String(out.prefix(120_000))
    }

    func gitCwd(_ sessionId: String) throws -> String {
        guard let cwd = cwdFor(sessionId) else { throw ManagerError.unknownSession(sessionId) }
        guard FileManager.default.fileExists(atPath: cwd) else { throw ManagerError.cwdMissing(cwd) }
        return cwd
    }

    public enum GitError: Error, CustomStringConvertible {
        case notARepository
        case failed(String)
        case refused(String)

        public var description: String {
            switch self {
            case .notARepository: return "Not a git repository."
            case .failed(let why): return why
            case .refused(let why): return why
            }
        }
    }

    // MARK: git status / actions

    /// Branch, upstream sync counts, the changed files and the local branch list — what the phone's
    /// Git screen shows. Parsed from `status --porcelain=v2 --branch`, which is stable across git versions.
    public func gitStatus(sessionId: String) throws -> GitStatus {
        let cwd = try gitCwd(sessionId)
        let r = runGit(["-C", cwd, "status", "--porcelain=v2", "--branch", "--untracked-files=all"])
        if r.code != 0 {
            if r.err.contains("not a git repository") { throw GitError.notARepository }
            throw GitError.failed(r.err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var status = GitStatus.parse(porcelain: r.out)
        let branches = runGit(["-C", cwd, "for-each-ref", "--format=%(refname:short)", "--sort=-committerdate", "refs/heads/"])
        if branches.code == 0 {
            status.branches = branches.out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        }
        let last = runGit(["-C", cwd, "log", "-1", "--format=%h %s"])
        if last.code == 0 { let subject = last.out.trimmingCharacters(in: .whitespacesAndNewlines)
            status.lastCommit = subject.isEmpty ? nil : subject
        }
        return status
    }

    /// Runs one git action in the repo and returns git's output. Refuses to act on a session whose
    /// agent is mid-turn on the repo, to keep the phone from racing the agent's own edits.
    public func gitAction(sessionId: String, action: GitAction) throws -> String {
        let cwd = try gitCwd(sessionId)
        if let h = hosted[sessionId], h.state.status == .running {
            throw GitError.refused("The agent is working in this repo — wait for the turn to finish.")
        }
        let args: [String]
        var timeout: TimeInterval = 20
        switch action {
        case .stage(let paths):
            args = paths.isEmpty ? ["add", "-A"] : ["add", "-A", "--"] + paths
        case .unstage(let paths):
            args = paths.isEmpty ? ["reset", "-q"] : ["reset", "-q", "--"] + paths
        case .discard(let paths):
            // Tracked changes go back to the index; untracked files are removed. Two steps, so run the
            // first here and fall through to the second below.
            let checkout = runGit(["-C", cwd, "checkout", "-q", "--"] + (paths.isEmpty ? ["."] : paths))
            if checkout.code != 0, !checkout.err.contains("did not match any file") {
                throw GitError.failed(checkout.err.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            args = paths.isEmpty ? ["clean", "-fdq"] : ["clean", "-fdq", "--"] + paths
        case .commit(let message, let all):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw GitError.refused("Commit message is empty.") }
            args = (all ? ["commit", "-a"] : ["commit"]) + ["-m", trimmed]
        case .push(let setUpstream):
            timeout = 90
            if setUpstream, let branch = try? gitStatus(sessionId: sessionId).branch {
                args = ["push", "-u", "origin", branch]
            } else {
                args = ["push"]
            }
        case .pull:
            timeout = 90
            args = ["pull", "--ff-only"]
        case .fetch:
            timeout = 60
            args = ["fetch", "--prune"]
        case .checkout(let branch):
            args = ["checkout", "-q", branch]
        case .createBranch(let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw GitError.refused("Branch name is empty.") }
            args = ["checkout", "-q", "-b", trimmed]
        case .createPullRequest(let title, let body, let draft):
            return try createPullRequest(cwd: cwd, sessionId: sessionId, title: title, body: body, draft: draft)
        }
        let r = runGit(["-C", cwd] + args, timeout: timeout)
        let output = (r.out + (r.err.isEmpty ? "" : "\n" + r.err)).trimmingCharacters(in: .whitespacesAndNewlines)
        if r.code != 0 { throw GitError.failed(output.isEmpty ? "git exited with status \(r.code)" : output) }
        log("[\(sessionId.prefix(8))] git \(action.label)")
        return output
    }

    // MARK: pull requests (gh)

    /// `gh` wherever Homebrew or the installer put it; nil when GitHub's CLI is not installed.
    static func locateGh() -> String? {
        for p in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"] where FileManager.default.isExecutableFile(atPath: p) { return p }
        let path = ClaudeCLI.childEnvironment()["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let p = "\(dir)/gh"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    private func runGh(_ args: [String], cwd: String, timeout: TimeInterval = 40) throws -> (code: Int32, out: String, err: String) {
        guard let gh = SessionManager.locateGh() else { throw GitError.refused("GitHub CLI (gh) is not installed on the Mac.") }
        return runTool(gh, args, cwd: cwd, timeout: timeout)
    }

    /// The pull request for the current branch, with its checks. Nil when the branch has none.
    public func pullRequest(sessionId: String) throws -> PullRequestInfo? {
        let cwd = try gitCwd(sessionId)
        let fields = "number,title,url,state,isDraft,reviewDecision,mergeable,baseRefName,statusCheckRollup"
        let r = try runGh(["pr", "view", "--json", fields], cwd: cwd)
        if r.code != 0 {
            let err = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
            if err.contains("no pull requests found") || err.contains("no open pull requests") { return nil }
            throw GitError.failed(err.isEmpty ? "gh exited with status \(r.code)" : err)
        }
        guard let json = try? JSONValue.parse(Data(r.out.utf8)), let number = json["number"]?.int else { return nil }
        let checks = (json["statusCheckRollup"]?.array ?? []).compactMap { c -> CheckRun? in
            // Check runs carry name/status/conclusion; legacy commit statuses context/state.
            let name = c["name"]?.string ?? c["context"]?.string ?? "check"
            if let state = c["state"]?.string, c["status"]?.string == nil {
                let done = state != "PENDING" && state != "EXPECTED"
                return CheckRun(name: name, status: done ? "COMPLETED" : "PENDING", conclusion: done ? state : nil, url: c["targetUrl"]?.string)
            }
            return CheckRun(name: name, status: c["status"]?.string ?? "PENDING", conclusion: c["conclusion"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                            url: c["detailsUrl"]?.string)
        }
        return PullRequestInfo(number: number, title: json["title"]?.string ?? "", url: json["url"]?.string ?? "",
                               state: json["state"]?.string ?? "OPEN", isDraft: json["isDraft"]?.bool ?? false,
                               reviewDecision: json["reviewDecision"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                               mergeable: json["mergeable"]?.string, baseBranch: json["baseRefName"]?.string, checks: checks)
    }

    private func createPullRequest(cwd: String, sessionId: String, title: String, body: String, draft: Bool) throws -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitError.refused("The pull request needs a title.") }
        let status = try gitStatus(sessionId: sessionId)
        guard let branch = status.branch else { throw GitError.refused("Not on a branch.") }
        var output = ""
        if status.upstream == nil {
            let push = runGit(["-C", cwd, "push", "-u", "origin", branch], timeout: 90)
            if push.code != 0 { throw GitError.failed(push.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
            output += "Pushed \(branch) to origin.\n"
        }
        var args = ["pr", "create", "--title", trimmed, "--body", body]
        if draft { args.append("--draft") }
        let r = try runGh(args, cwd: cwd, timeout: 90)
        let text = (r.out + (r.err.isEmpty ? "" : "\n" + r.err)).trimmingCharacters(in: .whitespacesAndNewlines)
        if r.code != 0 { throw GitError.failed(text.isEmpty ? "gh exited with status \(r.code)" : text) }
        log("[\(sessionId.prefix(8))] gh pr create")
        return output + text
    }

    // MARK: rename / search across sessions

    /// Titles a session. Claude keeps titles as `custom-title` lines in the transcript (the same
    /// entry `/rename` writes); Codex threads are named through the app-server.
    public func renameSession(sessionId: String, title: String) async throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitError.refused("The title is empty.") }
        if let codex, isCodexThread(sessionId) {
            try await codex.rename(threadId: sessionId, name: trimmed)
            hosted[sessionId]?.title = trimmed
            watchedCodex[sessionId]?.title = trimmed
            await codex.invalidateThreadList()
            await refreshSources()
            broadcast(.sessions(items: listSessions()))
            return
        }
        guard let stored = store.session(id: sessionId) else { throw ManagerError.unknownSession(sessionId) }
        // `type` first: the store recognises title lines by their prefix, like the CLI writes them.
        let titleJSON = JSONValue.string(trimmed).serializedString()
        let line = Data(("{\"type\":\"custom-title\",\"customTitle\":\(titleJSON),\"sessionId\":\"\(sessionId)\"}\n").utf8)
        guard let handle = FileHandle(forWritingAtPath: stored.path) else { throw ManagerError.unknownSession(sessionId) }
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        handle.write(line)
        hosted[sessionId]?.title = trimmed
        log("[\(sessionId.prefix(8))] renamed")
        broadcast(.sessions(items: listSessions()))
    }

    /// Transcripts mentioning `query` (case-insensitive), newest first, with the line it appears on.
    /// A `grep -l` pass over the transcript folders finds the files; the snippet comes from the first hit.
    public func searchSessions(query: String) async -> [SessionSearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        let stored = store.allSessions()
        let byPath = Dictionary(stored.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let codexById = Dictionary(codexThreads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let roots = [NSHomeDirectory() + "/.claude/projects", NSHomeDirectory() + "/.codex/sessions"]
        return await Task.detached(priority: .utility) { [self] in
            let r = self.runTool("/usr/bin/grep", ["-rlIiF", "--include=*.jsonl", "--exclude-dir=subagents", "-e", q] + roots, timeout: 30)
            var hits: [SessionSearchHit] = []
            for file in r.out.split(separator: "\n").map(String.init).prefix(60) {
                let name = (file as NSString).lastPathComponent
                let isCodex = file.contains("/.codex/")
                let sessionId: String
                if isCodex {
                    // rollout-<timestamp>-<uuid>.jsonl
                    guard let uuid = name.dropLast(6).split(separator: "-").suffix(5).joined(separator: "-") as String?, uuid.count == 36 else { continue }
                    sessionId = uuid
                } else {
                    sessionId = String(name.dropLast(6))
                }
                let snippet = SessionManager.snippet(inFile: file, query: q)
                let mtime = (try? FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date) ?? .distantPast
                if isCodex {
                    let t = codexById[sessionId]
                    hits.append(SessionSearchHit(sessionId: sessionId, title: t?.title ?? "Codex session", cwd: t?.cwd ?? "", snippet: snippet,
                                                 updatedAt: t?.updatedAt ?? mtime, agent: .codex))
                } else if let s = byPath[file] {
                    hits.append(SessionSearchHit(sessionId: sessionId, title: s.title, cwd: s.cwd, snippet: snippet, updatedAt: s.updatedAt))
                }
            }
            return hits.sorted { $0.updatedAt > $1.updatedAt }
        }.value
    }

    /// ±90 characters around the first occurrence in the file, JSON escapes undone.
    nonisolated static func snippet(inFile path: String, query: String) -> String {
        let r = FileHandle(forReadingAtPath: path)
        defer { try? r?.close() }
        guard let data = r?.readData(ofLength: 8 * 1024 * 1024), let text = String(data: data, encoding: .utf8),
              let range = text.range(of: query, options: [.caseInsensitive]) else { return "" }
        let start = text.index(range.lowerBound, offsetBy: -90, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 90, limitedBy: text.endIndex) ?? text.endIndex
        var s = String(text[start..<end])
        s = s.replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\\\"", with: "\"")
        // Cut at the JSON field boundaries around the match when they fall inside the window.
        if let q = s.range(of: "\",\"", options: .backwards, range: s.startIndex..<(s.range(of: query, options: .caseInsensitive)?.lowerBound ?? s.endIndex)) {
            s = String(s[q.upperBound...])
            if let colon = s.firstIndex(of: ":"), s.distance(from: s.startIndex, to: colon) < 24 { s = String(s[s.index(after: colon)...]) }
        }
        if let q = s.range(of: "\",\"", range: (s.range(of: query, options: .caseInsensitive)?.upperBound ?? s.startIndex)..<s.endIndex) {
            s = String(s[..<q.lowerBound])
        }
        return "…" + s.trimmingCharacters(in: CharacterSet(charactersIn: "\" {}[]")) + "…"
    }

    // MARK: project browser

    public enum ProjectError: Error, CustomStringConvertible {
        case outsideProject, notADirectory(String)
        public var description: String {
            switch self {
            case .outsideProject: return "That path is outside the project."
            case .notADirectory(let p): return "Not a directory: \(p)"
            }
        }
    }

    /// A project directory listing (folders first). `path` is relative to the cwd and may not
    /// escape it; hidden files are included except `.git` and build output.
    public func listDirectory(sessionId: String, path: String?) throws -> (path: String, entries: [DirectoryEntry]) {
        guard let cwd = cwdFor(sessionId) else { throw ManagerError.unknownSession(sessionId) }
        let rel = (path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let full = rel.isEmpty ? cwd : (cwd as NSString).appendingPathComponent(rel)
        let resolved = (full as NSString).standardizingPath
        let root = (cwd as NSString).standardizingPath
        guard resolved == root || resolved.hasPrefix(root + "/") else { throw ProjectError.outsideProject }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue else { throw ProjectError.notADirectory(rel) }
        let names = try FileManager.default.contentsOfDirectory(atPath: resolved)
        var entries: [DirectoryEntry] = []
        for name in names where name != ".git" && name != ".DS_Store" {
            let p = (resolved as NSString).appendingPathComponent(name)
            let attrs = (try? FileManager.default.attributesOfItem(atPath: p)) ?? [:]
            let type = attrs[.type] as? FileAttributeType
            var dir = type == .typeDirectory
            if type == .typeSymbolicLink {
                var flag: ObjCBool = false
                if FileManager.default.fileExists(atPath: p, isDirectory: &flag) { dir = flag.boolValue }
            }
            entries.append(DirectoryEntry(name: name, isDirectory: dir, size: dir ? nil : (attrs[.size] as? NSNumber)?.intValue,
                                          modifiedAt: attrs[.modificationDate] as? Date))
        }
        entries.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return (rel, entries)
    }

    /// Searches file contents: `git grep` inside a repository (respects .gitignore), plain `grep`
    /// elsewhere. Case-insensitive fixed string; at most 200 matches.
    public func searchProject(sessionId: String, query: String) async throws -> (matches: [SearchMatch], truncated: Bool) {
        guard let cwd = cwdFor(sessionId) else { throw ManagerError.unknownSession(sessionId) }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return ([], false) }
        let limit = 200
        return await Task.detached(priority: .utility) { [self] in
            let inRepo = self.runGit(["-C", cwd, "rev-parse", "--is-inside-work-tree"]).code == 0
            let r: (code: Int32, out: String, err: String)
            if inRepo {
                r = self.runGit(["-C", cwd, "grep", "-n", "-I", "-i", "-F", "--no-color", "-e", q, "--", ".",
                                 ":!*.lock", ":!*.min.js", ":!*.map"], timeout: 20)
            } else {
                let excludes = SessionManager.fileWalkSkipDirs.map { "--exclude-dir=\($0)" }
                r = self.runTool("/usr/bin/grep", ["-rnIiF", "--no-messages"] + excludes + ["-e", q, "."], cwd: cwd, timeout: 20)
            }
            var matches: [SearchMatch] = []
            var truncated = false
            for line in r.out.split(separator: "\n") {
                // path:line:text
                guard let c1 = line.firstIndex(of: ":") else { continue }
                let rest = line[line.index(after: c1)...]
                guard let c2 = rest.firstIndex(of: ":"), let n = Int(rest[..<c2]) else { continue }
                var path = String(line[..<c1])
                if path.hasPrefix("./") { path.removeFirst(2) }
                let text = String(rest[rest.index(after: c2)...]).trimmingCharacters(in: .whitespaces)
                matches.append(SearchMatch(path: path, line: n, text: String(text.prefix(200))))
                if matches.count >= limit { truncated = true; break }
            }
            return (matches, truncated)
        }.value
    }

    // MARK: quick commands

    /// Commands from `.ccremote.json` in the project, or a guess from its build files.
    public func projectCommands(sessionId: String) -> [ProjectCommand] {
        guard let cwd = cwdFor(sessionId) else { return [] }
        let fm = FileManager.default
        let configPath = (cwd as NSString).appendingPathComponent(".ccremote.json")
        if let data = fm.contents(atPath: configPath), let json = try? JSONValue.parse(data), let list = json["commands"]?.array {
            let items = list.compactMap { c -> ProjectCommand? in
                guard let command = c["command"]?.string, !command.isEmpty else { return nil }
                return ProjectCommand(id: "repo:" + command, name: c["name"]?.string ?? command, command: command, source: "repo")
            }
            if !items.isEmpty { return items }
        }
        func has(_ name: String) -> Bool { fm.fileExists(atPath: (cwd as NSString).appendingPathComponent(name)) }
        var items: [ProjectCommand] = []
        func add(_ name: String, _ command: String) { items.append(ProjectCommand(id: "default:" + command, name: name, command: command)) }
        if has("Package.swift") { add("Build", "swift build"); add("Test", "swift test") }
        if has("Tuist.swift") || has("Project.swift") { add("Generate project (Tuist)", "tuist generate --no-open") }
        if has("package.json") {
            add("Install", "npm install"); add("Test", "npm test"); add("Build", "npm run build")
        }
        if has("Cargo.toml") { add("Build", "cargo build"); add("Test", "cargo test") }
        if has("go.mod") { add("Build", "go build ./..."); add("Test", "go test ./...") }
        if has("pyproject.toml") || has("pytest.ini") || has("setup.py") { add("Test", "pytest") }
        if has("Makefile") { add("make", "make"); add("make test", "make test") }
        if has("Gemfile") { add("Test", "bundle exec rspec") }
        if has("mix.exs") { add("Test", "mix test") }
        add("Git status", "git status --short --branch")
        return items
    }

    private var commandRuns: [String: Process] = [:]

    /// Runs a shell command in the project directory, streaming stdout/stderr through `output`
    /// (called off the actor, in order) until `done`. Output is capped at 2 MB; the run can be
    /// cancelled with `cancelCommand`.
    public func runCommand(sessionId: String, runId: String, command: String, output: @escaping @Sendable (String, Bool, Int32?) -> Void) throws {
        guard let cwd = cwdFor(sessionId) else { throw ManagerError.unknownSession(sessionId) }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitError.refused("The command is empty.") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", trimmed]
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ClaudeCLI.childEnvironment()
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let counter = CommandOutputCounter()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            if counter.add(data.count) <= 2 * 1024 * 1024 { output(text, false, nil) }
            else if !counter.warned { counter.warned = true; output("\n… output truncated (2 MB)\n", false, nil) }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            if !rest.isEmpty, counter.add(rest.count) <= 2 * 1024 * 1024 { output(String(decoding: rest, as: UTF8.self), false, nil) }
            output("", true, proc.terminationReason == .uncaughtSignal ? -Int32(proc.terminationStatus) : proc.terminationStatus)
            Task { await self?.commandFinished(runId: runId) }
        }
        try p.run()
        commandRuns[runId] = p
        log("[\(sessionId.prefix(8))] run: \(trimmed.prefix(80))")
    }

    public func cancelCommand(runId: String) {
        commandRuns[runId]?.terminate()
    }

    private func commandFinished(runId: String) { commandRuns[runId] = nil }

    final class CommandOutputCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var total = 0
        var warned = false
        func add(_ n: Int) -> Int { lock.withLock { total += n; return total } }
    }

    /// Runs any tool in `cwd` and captures its output; the base for git and gh.
    nonisolated func runTool(_ executable: String, _ args: [String], cwd: String? = nil, timeout: TimeInterval = 15) -> (code: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ClaudeCLI.childEnvironment()
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GH_PROMPT_DISABLED"] = "1"
        env["NO_COLOR"] = "1"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        do { try p.run() } catch { return (-1, "", "cannot run \((executable as NSString).lastPathComponent): \(error.localizedDescription)") }
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        let q = DispatchQueue(label: "ccremote.tool", attributes: .concurrent)
        group.enter(); q.async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); q.async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        if group.wait(timeout: .now() + timeout) == .timedOut { p.terminate() }
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }

    nonisolated func runGit(_ args: [String], timeout: TimeInterval = 15) -> (code: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-c", "core.pager=cat"] + args
        var env = ClaudeCLI.childEnvironment()
        env["GIT_TERMINAL_PROMPT"] = "0"   // fail fast instead of waiting for a password nobody can type
        env["GIT_EDITOR"] = "true"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        do { try p.run() } catch { return (-1, "", "cannot run git: \(error.localizedDescription)") }
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        let q = DispatchQueue(label: "ccremote.git", attributes: .concurrent)
        group.enter(); q.async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); q.async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        if group.wait(timeout: .now() + timeout) == .timedOut { p.terminate() }
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }

    /// Any file the agent handed the user (SendUserFile), capped in size. The media type comes from the
    /// extension so the phone knows whether to render it (image, Markdown, text, PDF) or just offer it to save.
    public func readFile(path: String) throws -> (mediaType: String, data: Data) {
        let expanded = (path as NSString).expandingTildeInPath
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: expanded), let size = (attrs[.size] as? NSNumber)?.intValue else { throw FileError.notFound }
        guard size <= 12 * 1024 * 1024 else { throw FileError.tooLarge }
        guard let data = FileManager.default.contents(atPath: expanded) else { throw FileError.notFound }
        return (SessionManager.mediaType(forExtension: (expanded as NSString).pathExtension), data)
    }

    static func mediaType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "svg": return "image/svg+xml"
        case "md", "markdown": return "text/markdown"
        case "pdf": return "application/pdf"
        case "json": return "application/json"
        case "html", "htm": return "text/html"
        case "csv": return "text/csv"
        case "txt", "log", "swift", "py", "js", "ts", "rb", "go", "rs", "sh", "yml", "yaml", "toml", "xml", "diff", "patch", "c", "h", "m", "cpp", "java", "kt", "sql", "css":
            return "text/plain"
        default:
            #if canImport(UniformTypeIdentifiers)
            if let uti = UTType(filenameExtension: ext), let mime = uti.preferredMIMEType { return mime }
            #endif
            return "application/octet-stream"
        }
    }

    public func shutdown() async {
        taskTimer?.cancel()
        terminateAllProcesses()
        terminateAllTerminals()
        for id in Array(hosted.keys) { await close(sessionId: id) }
        for id in Array(watched.keys) { await close(sessionId: id) }
        for id in Array(watchedCodex.keys) { stopWatchingCodex(sessionId: id) }
        await codex?.shutdown()
    }

    // MARK: CLI callbacks

    private func handleMessage(sessionId: String, message: JSONValue) {
        guard let h = hosted[sessionId] else { return }
        switch message["type"]?.string {
        case "system":
            if message["subtype"]?.string == "init" {
                if let m = message["model"]?.string { h.state.model = m }
                if let p = message["permissionMode"]?.string { h.state.permissionMode = p }
                if let cmds = message["slash_commands"]?.array?.compactMap(\.string), !cmds.isEmpty { h.state.slashCommands = cmds }
                broadcast(.state(state: h.state))
            }
        case "assistant":
            // Track the running tool / thinking for the Live Activity; a text block means the turn is
            // back to prose, a tool_use names what runs next.
            for block in message["message"]?["content"]?.array ?? [] {
                switch block["type"]?.string {
                case "tool_use":
                    let name = block["name"]?.string ?? "tool"
                    h.lastTool = (name, ToolSummary.line(name: name, input: block["input"] ?? .object([:])))
                    h.thinking = false
                case "thinking": h.thinking = true
                case "text": h.thinking = false
                default: break
                }
            }
            if h.state.status == .running { pushActivity(sessionId, h, throttled: true) }
        case "user":
            // A tool result closes the running tool.
            if message["message"]?["content"]?.array?.contains(where: { $0["type"]?.string == "tool_result" }) == true { h.lastTool = nil }
        case "result":
            let isError = message["is_error"]?.bool == true
            if isError { h.state.lastError = message["result"]?.string }
            h.lastTool = nil
            h.thinking = false
            update(h, status: .idle)
            broadcast(.sessions(items: listSessions()))
            flushQueue(sessionId: sessionId)
            if let notifier {
                let name = notifyName(h)
                if isError {
                    notifier.notify(.error, body: "\(name) · \(message["result"]?.string ?? "Turn failed")")
                } else {
                    // Put Claude's final answer in the "done" push (truncated) so it's useful at a glance.
                    let answer = message["result"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let summary = (answer?.isEmpty == false ? answer : h.title) ?? "turn complete"
                    notifier.notify(.done, body: "\(name) · \(SessionManager.notifySnippet(summary))")
                }
            }
            taskTurnFinished(sessionId: sessionId, isError: isError, summary: message["result"]?.string)
        default:
            break
        }
        emit(sessionId: sessionId, payload: message)
    }

    private func handleControlRequest(sessionId: String, requestId: String, request: JSONValue) async -> JSONValue? {
        switch request["subtype"]?.string {
        case "can_use_tool":
            guard let h = hosted[sessionId] else { return nil }
            let toolName = request["tool_name"]?.string ?? "tool"
            let input = request["input"] ?? .object([:])
            let shown = SessionManager.enrichedInput(toolName: toolName, input: input)
            if shown != input { h.originalInputs[requestId] = input }
            let permission = PermissionRequest(
                id: requestId, sessionId: sessionId,
                toolName: toolName,
                input: shown,
                title: request["title"]?.string,
                description: request["description"]?.string,
                displayName: request["display_name"]?.string,
                decisionReason: request["decision_reason"]?.string,
                toolUseId: request["tool_use_id"]?.string,
                suggestions: request["permission_suggestions"])
            schedulePermissionNotification(sessionId: sessionId, requestId: requestId, permission: permission)
            let response: JSONValue? = await withCheckedContinuation { continuation in
                h.pending[requestId] = permission
                h.waiters[requestId] = continuation
                h.state.pendingPermissions.append(permission)
                update(h, status: .awaitingPermission)
                broadcast(.permissionRequest(request: permission))
            }
            return response
        case "elicitation":
            return .object(["action": "decline"])
        case "request_user_dialog":
            return nil
        default:
            log("[\(sessionId.prefix(8))] unsupported control request: \(request["subtype"]?.string ?? "?")")
            return .object([:])
        }
    }

    private func cancelPermission(sessionId: String, requestId: String) {
        guard let h = hosted[sessionId], h.pending.removeValue(forKey: requestId) != nil else { return }
        h.waiters.removeValue(forKey: requestId)?.resume(returning: nil)
        h.state.pendingPermissions.removeAll { $0.id == requestId }
        broadcast(.permissionResolved(sessionId: sessionId, requestId: requestId))
        update(h, status: h.pending.isEmpty ? .running : .awaitingPermission)
    }

    private func handleExit(sessionId: String, status: Int32, stderr: String) {
        guard let h = hosted.removeValue(forKey: sessionId) else { return }
        for (_, waiter) in h.waiters { waiter.resume(returning: nil) }
        h.waiters.removeAll()
        h.pending.removeAll()
        h.queue.removeAll()
        h.state.queued.removeAll()
        h.state.pendingPermissions.removeAll()
        h.state.status = .exited
        if status != 0 {
            let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            h.state.lastError = "claude exited with status \(status)" + (tail.isEmpty ? "" : ": \(tail.suffix(400))")
        }
        log("[\(sessionId.prefix(8))] exited (\(status))")
        if status != 0, let notifier { notifier.notify(.error, body: "\(notifyName(h)) · \(h.state.lastError ?? "session exited")") }
        broadcast(.state(state: h.state))
        broadcast(.sessions(items: listSessions()))
        pushActivity(sessionId, h, throttled: false)
        activityTokens[sessionId] = nil
        if status != 0 { taskTurnFinished(sessionId: sessionId, isError: true, summary: h.state.lastError) }
    }

    private func update(_ h: Hosted, status: SessionStatus) {
        h.lastActivity = Date()
        h.state.status = status
        broadcast(.state(state: h.state))
        pushActivity(h.state.id, h, throttled: false)
    }

    // MARK: Codex callbacks

    private func handleCodexEvent(_ event: CodexBackend.Event) {
        switch event {
        case .event(let threadId, let payload):
            guard let h = hosted[threadId] else { return }
            // Keep the replayable history (full messages, results); deltas are transient.
            if payload["type"]?.string != "stream_event" { h.forkedHistory?.append(payload) }
            emit(sessionId: threadId, payload: payload)
        case .turnStarted(let threadId):
            guard let h = hosted[threadId] else { return }
            if h.turnStartedAt == nil { h.turnStartedAt = Date() }
            if h.state.status != .awaitingPermission { update(h, status: .running) }
        case .turnCompleted(let threadId, let isError, let summary):
            guard let h = hosted[threadId] else { return }
            if isError { h.state.lastError = summary }
            h.lastTool = nil
            h.thinking = false
            update(h, status: .idle)
            broadcast(.sessions(items: listSessions()))
            flushQueue(sessionId: threadId)
            if let notifier {
                let name = notifyName(h)
                if isError {
                    notifier.notify(.error, body: "\(name) · \(summary ?? "Turn failed")")
                } else {
                    let text = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
                    notifier.notify(.done, body: "\(name) · \(SessionManager.notifySnippet((text?.isEmpty == false ? text : h.title) ?? "turn complete"))")
                }
            }
            taskTurnFinished(sessionId: threadId, isError: isError, summary: summary)
        case .approval(let threadId, let request):
            guard let h = hosted[threadId] else {
                Task { await codex?.decide(requestId: request.id, allow: false) }
                return
            }
            h.pending[request.id] = request
            h.state.pendingPermissions.append(request)
            update(h, status: .awaitingPermission)
            broadcast(.permissionRequest(request: request))
            schedulePermissionNotification(sessionId: threadId, requestId: request.id, permission: request)
        case .approvalResolved(let threadId, let requestId):
            cancelPermission(sessionId: threadId, requestId: requestId)
        case .exited(let error):
            for (id, h) in hosted where h.agent == .codex {
                hosted[id] = nil
                h.pending.removeAll()
                h.state.pendingPermissions.removeAll()
                h.state.status = .exited
                h.state.lastError = error
                broadcast(.state(state: h.state))
                pushActivity(id, h, throttled: false)
                activityTokens[id] = nil
            }
            if let notifier { notifier.notify(.error, body: "Codex · \(error)") }
            broadcast(.sessions(items: listSessions()))
        }
    }

    // MARK: Live Activity push

    /// A phone started (token) or ended (nil) a Live Activity for a session. Tokens outlive the phone's
    /// connection on purpose: the push is what reaches a backgrounded app.
    public func registerLiveActivity(sessionId: String, phone: UUID, token: String?, approvalNeedsApp: Bool) {
        if let token {
            activityTokens[sessionId, default: [:]][phone] = (token, approvalNeedsApp)
            if let h = hosted[sessionId] { pushActivity(sessionId, h, throttled: false) }
        } else {
            activityTokens[sessionId]?[phone] = nil
        }
    }

    /// What the activity shows for a hosted session right now.
    public func activityState(sessionId: String, approvalNeedsApp: Bool) -> SessionActivityState? {
        guard let h = hosted[sessionId] else { return nil }
        return activityState(h, approvalNeedsApp: approvalNeedsApp)
    }

    private func activityState(_ h: Hosted, approvalNeedsApp: Bool) -> SessionActivityState {
        let pending = h.state.pendingPermissions.first
        return SessionActivityState.make(status: h.state.status, pending: pending, lastTool: h.lastTool, thinking: h.thinking,
                                         turnStartedAt: h.turnStartedAt, lastError: h.state.status == .idle ? nil : h.state.lastError,
                                         approvalNeedsApp: approvalNeedsApp)
    }

    /// Pushes the session's activity state to every registered phone. Working-state churn (a tool per
    /// second) is coalesced to one push every couple of seconds; approvals and endings go out at once.
    private func pushActivity(_ sessionId: String, _ h: Hosted, throttled: Bool) {
        guard let livePusher, let phones = activityTokens[sessionId], !phones.isEmpty else { return }
        if throttled {
            let elapsed = Date().timeIntervalSince(h.lastActivityPush)
            if elapsed < 2 {
                guard h.activityPushTimer == nil else { return }
                h.activityPushTimer = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64((2 - elapsed) * 1_000_000_000))
                    await self?.flushActivityPush(sessionId)
                }
                return
            }
        }
        h.activityPushTimer?.cancel()
        h.activityPushTimer = nil
        h.lastActivityPush = Date()
        for (_, phone) in phones {
            let state = activityState(h, approvalNeedsApp: phone.approvalNeedsApp)
            switch state.phase {
            case .needsApproval:
                livePusher.push(token: phone.token, event: .update, state: state,
                                alert: ("\(notifyName(h)) needs approval", "\(state.pendingTool ?? "Tool"): \(state.detail)"))
            case .stopped:
                livePusher.push(token: phone.token, event: .end, state: state, dismissAfter: 5 * 60)
            case .done, .failed:
                // Leave the result on the lock screen for a while, then let it go.
                livePusher.push(token: phone.token, event: .end, state: state, dismissAfter: 15 * 60)
            case .working:
                livePusher.push(token: phone.token, event: .update, state: state, priority: 5)
            }
        }
    }

    private func flushActivityPush(_ sessionId: String) {
        guard let h = hosted[sessionId] else { return }
        h.activityPushTimer = nil
        pushActivity(sessionId, h, throttled: false)
    }

    // MARK: notifications

    private func notifyName(_ h: Hosted) -> String {
        (h.state.cwd as NSString).lastPathComponent
    }

    /// Collapse whitespace and cap length so a long final answer stays a readable push.
    static func notifySnippet(_ text: String, limit: Int = 280) -> String {
        let collapsed = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }

    /// Notify about a permission only if it's still unanswered after a short grace period —
    /// so approving from the app immediately doesn't also fire a push.
    private func schedulePermissionNotification(sessionId: String, requestId: String, permission: PermissionRequest) {
        guard let notifier else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self else { return }
            await self.firePermissionNotificationIfPending(sessionId: sessionId, requestId: requestId, permission: permission, notifier: notifier)
        }
    }

    private func firePermissionNotificationIfPending(sessionId: String, requestId: String, permission: PermissionRequest, notifier: Notifier) {
        let name: String
        if let h = hosted[sessionId], h.pending[requestId] != nil {
            name = notifyName(h)
        } else if let waiter = hookWaiters[requestId] {
            name = ((cwdFor(waiter.request.sessionId) ?? "") as NSString).lastPathComponent
        } else {
            return
        }
        let summary = ToolSummary.line(name: permission.toolName, input: permission.input)
        let body = "\(name) · \(permission.toolName)" + (summary.isEmpty ? "" : ": \(summary)")
        notifier.notify(.permission, body: body)
    }
}
#endif
