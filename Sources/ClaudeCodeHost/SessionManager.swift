#if os(macOS)
import Foundation
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
    private final class Hosted {
        let process: CLIProcess?          // Claude only
        var state: SessionState
        var pending: [String: PermissionRequest] = [:]
        /// Claude's `can_use_tool` waits on stdin for the answer; Codex approvals are answered through the backend.
        var waiters: [String: CheckedContinuation<JSONValue?, Never>] = [:]
        var startedAt = Date()
        var title: String?
        var forkedFromPath: String?
        /// History a Codex fork/resume came with, replayed to the next phone that opens it.
        var forkedHistory: [JSONValue]?
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
        init(state: SessionState, live: LiveSessionRegistry.LiveSession) {
            self.state = state
            self.live = live
        }
    }

    /// Chats run in their own scratch directory; that is also how a chat is recognised later
    /// (a session whose cwd is this directory), for both agents and across restarts.
    public static let chatDirectory = NSHomeDirectory() + "/Library/Application Support/ccremote/chats"

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

    private let cli: ClaudeCLI
    private let codex: CodexBackend?
    private let store: TranscriptStore
    private let registry: LiveSessionRegistry
    private let notifier: Notifier?
    private let log: @Sendable (String) -> Void
    private var subscribers: [UUID: Sender] = [:]
    private var hosted: [String: Hosted] = [:]
    private var watched: [String: Watched] = [:]
    private var watchedCodex: [String: WatchedCodex] = [:]
    /// Codex threads someone else has open right now, refreshed with the session list.
    private var codexOpenElsewhere: Set<String> = []
    private var cachedCliVersion: String?
    private var cachedLoggedIn: Bool?
    private var cachedCodexVersion: String?
    /// Codex threads on disk, as last fetched from the app-server (see `refreshSources`).
    private var codexThreads: [CodexBackend.ThreadInfo] = []
    /// Codex threads this daemon closed recently — `thread/list` picks them up with a delay.
    private var recentCodexThreads: [CodexBackend.ThreadInfo] = []

    public init(cli: ClaudeCLI, codex: CodexBackend? = nil, store: TranscriptStore = TranscriptStore(), registry: LiveSessionRegistry = LiveSessionRegistry(),
                notifier: Notifier? = nil, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.cli = cli
        self.codex = codex
        self.store = store
        self.registry = registry
        self.notifier = notifier
        self.log = log
        if let codex {
            Task { [weak self] in
                await codex.setEventHandler { [weak self] event in
                    guard let self else { return }
                    Task { await self.handleCodexEvent(event) }
                }
            }
        }
    }

    // MARK: subscribers

    public func subscribe(_ id: UUID, send: @escaping Sender) {
        subscribers[id] = send
    }

    public func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }

    private func broadcast(_ message: ServerMessage) {
        for send in subscribers.values { send(message) }
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
        return HostInfo(hostName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName, daemonVersion: daemonVersion,
                        cliVersion: cachedCliVersion, cliPath: cli.path, loggedIn: cachedLoggedIn, codex: codexInfo)
    }

    public var hasCodex: Bool { codex != nil }

    /// Fetches what `listSessions` cannot read synchronously (the Codex thread list). Call before
    /// answering an explicit list request; broadcasts reuse the last fetch.
    public func refreshSources() async {
        guard let codex else { return }
        codexOpenElsewhere = CodexCLI.threadsOpenElsewhere().subtracting(await codex.hostedThreadIds())
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

    private static func kind(cwd: String) -> SessionKind {
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
            let status: SessionStatus = live.status == "busy" ? .running : .idle
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
    public func open(sessionId: String, reply: Sender) async throws {
        if let h = hosted[sessionId] {
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
            let state = SessionState(id: sessionId, origin: .desktop, status: live.status == "busy" ? .running : .idle, cwd: live.cwd)
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
            if codexOpenElsewhere.contains(sessionId) || CodexCLI.threadsOpenElsewhere().contains(sessionId) {
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
    private func isCodexThread(_ id: String) -> Bool {
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

    private func spawn(sessionId: String, config: CLIProcess.Config, origin: SessionOrigin, kind: SessionKind = .agent) throws -> Hosted {
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

    public func prompt(sessionId: String, text: String, images: [InlineImage] = [], attachments: [Attachment]? = nil) async throws {
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
                // The inbox channel only carries text; images are supported on phone-hosted sessions.
                try PeerInbox.send(text: text, socketPath: socket, pid: w.live.pid, sessionsDirectory: registry.directory)
                w.state.status = .running
                broadcast(.state(state: w.state))
                return
            }
            throw ManagerError.unknownSession(sessionId)
        }
        if let process = h.process {
            try process.sendUser(text, images: images)
        } else if let codex {
            // Codex does not echo the prompt; show ours right away, then hand the turn over.
            let event = try await codex.prompt(threadId: sessionId, text: text, images: images, options: codexOptions(h))
            broadcast(.event(sessionId: sessionId, payload: event))
            h.forkedHistory?.append(event)
        }
        if h.title == nil {
            h.title = String(text.split(separator: "\n").first ?? "").trimmingCharacters(in: .whitespaces)
            broadcast(.sessions(items: listSessions()))
        }
        update(h, status: .running)
    }

    private func codexOptions(_ h: Hosted) -> CodexBackend.TurnOptions {
        CodexBackend.TurnOptions(model: h.state.model, effort: h.state.effort, approvalPolicy: h.state.permissionMode, sandbox: h.state.sandbox)
    }

    public func resolvePermission(sessionId: String, requestId: String, allow: Bool, message: String?, remember: Bool = false) async {
        guard let h = hosted[sessionId], let request = h.pending.removeValue(forKey: requestId) else { return }
        if let waiter = h.waiters.removeValue(forKey: requestId) {
            let response: JSONValue
            if allow {
                var fields: [String: JSONValue] = ["behavior": "allow", "updatedInput": request.input]
                // "Allow & remember": echo the CLI's suggested rule so matching calls are auto-approved later.
                if remember, let suggestions = request.suggestions, suggestions.array?.isEmpty == false {
                    fields["updatedPermissions"] = suggestions
                }
                response = .object(fields)
            } else {
                response = .object(["behavior": "deny", "message": .string(message ?? "Denied from phone")])
            }
            waiter.resume(returning: response)
        } else if let codex {
            await codex.decide(requestId: requestId, allow: allow)
        }
        h.state.pendingPermissions.removeAll { $0.id == requestId }
        broadcast(.permissionResolved(sessionId: sessionId, requestId: requestId))
        update(h, status: h.pending.isEmpty ? .running : .awaitingPermission)
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
    private static func readRollout(path: String) -> ([JSONValue], UInt64) {
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
            broadcast(.event(sessionId: sessionId, payload: event))
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
            for entry in history.entries { broadcast(.event(sessionId: sessionId, payload: entry)) }
            attachTail(to: w, sessionId: sessionId, path: stored.path, startOffset: history.endOffset)
        }
        let status: SessionStatus = live.status == "busy" ? .running : .idle
        if status != w.state.status {
            w.state.status = status
            broadcast(.state(state: w.state))
        }
    }

    private func attachTail(to w: Watched, sessionId: String, path: String, startOffset: UInt64) {
        w.tailing = true
        w.tail = TranscriptTail(path: path, startOffset: startOffset) { [weak self] entry in
            guard let self else { return }
            Task { await self.broadcast(.event(sessionId: sessionId, payload: entry)) }
        }
    }

    // MARK: files

    public enum FileError: Error, CustomStringConvertible {
        case notFound, notAnImage, tooLarge
        public var description: String {
            switch self {
            case .notFound: return "File not found"
            case .notAnImage: return "Only images can be fetched"
            case .tooLarge: return "File is larger than 12 MB"
            }
        }
    }

    /// Resolves a session's working directory across hosted/watched/stored sessions.
    private func cwdFor(_ sessionId: String) -> String? {
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
    public func gitDiff(sessionId: String) throws -> String {
        guard let cwd = cwdFor(sessionId) else { throw ManagerError.unknownSession(sessionId) }
        guard FileManager.default.fileExists(atPath: cwd) else { throw ManagerError.cwdMissing(cwd) }
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

    private func runGit(_ args: [String], timeout: TimeInterval = 15) -> (code: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-c", "core.pager=cat"] + args
        p.environment = ClaudeCLI.childEnvironment()
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

    /// Images only, capped in size — used for files a SendUserFile tool call points at.
    public func readImage(path: String) throws -> (mediaType: String, data: Data) {
        let expanded = (path as NSString).expandingTildeInPath
        let types = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp", "heic": "image/heic", "svg": "image/svg+xml"]
        guard let mediaType = types[(expanded as NSString).pathExtension.lowercased()] else { throw FileError.notAnImage }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: expanded), let size = (attrs[.size] as? NSNumber)?.intValue else { throw FileError.notFound }
        guard size <= 12 * 1024 * 1024 else { throw FileError.tooLarge }
        guard let data = FileManager.default.contents(atPath: expanded) else { throw FileError.notFound }
        return (mediaType, data)
    }

    public func shutdown() async {
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
        case "result":
            let isError = message["is_error"]?.bool == true
            if isError { h.state.lastError = message["result"]?.string }
            update(h, status: .idle)
            broadcast(.sessions(items: listSessions()))
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
        default:
            break
        }
        broadcast(.event(sessionId: sessionId, payload: message))
    }

    private func handleControlRequest(sessionId: String, requestId: String, request: JSONValue) async -> JSONValue? {
        switch request["subtype"]?.string {
        case "can_use_tool":
            guard let h = hosted[sessionId] else { return nil }
            let permission = PermissionRequest(
                id: requestId, sessionId: sessionId,
                toolName: request["tool_name"]?.string ?? "tool",
                input: request["input"] ?? .object([:]),
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
    }

    private func update(_ h: Hosted, status: SessionStatus) {
        h.state.status = status
        broadcast(.state(state: h.state))
    }

    // MARK: Codex callbacks

    private func handleCodexEvent(_ event: CodexBackend.Event) {
        switch event {
        case .event(let threadId, let payload):
            guard let h = hosted[threadId] else { return }
            // Keep the replayable history (full messages, results); deltas are transient.
            if payload["type"]?.string != "stream_event" { h.forkedHistory?.append(payload) }
            broadcast(.event(sessionId: threadId, payload: payload))
        case .turnStarted(let threadId):
            guard let h = hosted[threadId] else { return }
            if h.state.status != .awaitingPermission { update(h, status: .running) }
        case .turnCompleted(let threadId, let isError, let summary):
            guard let h = hosted[threadId] else { return }
            if isError { h.state.lastError = summary }
            update(h, status: .idle)
            broadcast(.sessions(items: listSessions()))
            if let notifier {
                let name = notifyName(h)
                if isError {
                    notifier.notify(.error, body: "\(name) · \(summary ?? "Turn failed")")
                } else {
                    let text = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
                    notifier.notify(.done, body: "\(name) · \(SessionManager.notifySnippet((text?.isEmpty == false ? text : h.title) ?? "turn complete"))")
                }
            }
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
            }
            if let notifier { notifier.notify(.error, body: "Codex · \(error)") }
            broadcast(.sessions(items: listSessions()))
        }
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
        guard let h = hosted[sessionId], h.pending[requestId] != nil else { return }
        let summary = ToolSummary.line(name: permission.toolName, input: permission.input)
        let body = "\(notifyName(h)) · \(permission.toolName)" + (summary.isEmpty ? "" : ": \(summary)")
        notifier.notify(.permission, body: body)
    }
}
#endif
