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
            case .cwdMissing(let p): return "Directory does not exist: \(p)"
            case .spawnFailed(let why): return "Could not start claude: \(why)"
            }
        }
    }

    private final class Hosted {
        let process: CLIProcess
        var state: SessionState
        var pending: [String: (request: PermissionRequest, continuation: CheckedContinuation<JSONValue?, Never>)] = [:]
        var startedAt = Date()
        var title: String?
        var forkedFromPath: String?
        init(process: CLIProcess, state: SessionState) {
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

    private let cli: ClaudeCLI
    private let store: TranscriptStore
    private let registry: LiveSessionRegistry
    private let notifier: Notifier?
    private let log: @Sendable (String) -> Void
    private var subscribers: [UUID: Sender] = [:]
    private var hosted: [String: Hosted] = [:]
    private var watched: [String: Watched] = [:]
    private var cachedCliVersion: String?
    private var cachedLoggedIn: Bool?

    public init(cli: ClaudeCLI, store: TranscriptStore = TranscriptStore(), registry: LiveSessionRegistry = LiveSessionRegistry(),
                notifier: Notifier? = nil, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.cli = cli
        self.store = store
        self.registry = registry
        self.notifier = notifier
        self.log = log
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

    public func hostInfo(daemonVersion: String) -> HostInfo {
        if cachedCliVersion == nil { cachedCliVersion = cli.version() }
        if cachedLoggedIn == nil { cachedLoggedIn = cli.authStatus()?.loggedIn }
        return HostInfo(hostName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName, daemonVersion: daemonVersion,
                        cliVersion: cachedCliVersion, cliPath: cli.path, loggedIn: cachedLoggedIn)
    }

    public func refreshAuth() {
        cachedLoggedIn = cli.authStatus()?.loggedIn
    }

    public func listProjects() -> [ProjectInfo] {
        store.projects()
    }

    public func listSessions() -> [SessionSummary] {
        let stored = store.allSessions()
        let storedById = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [SessionSummary] = []
        var seen = Set<String>()

        for (id, h) in hosted {
            let s = storedById[id]
            result.append(SessionSummary(id: id, title: h.title ?? s?.title ?? "New session", cwd: h.state.cwd,
                                         updatedAt: s?.updatedAt ?? h.startedAt, origin: .host, status: h.state.status))
            seen.insert(id)
        }
        let ownPids = Set(hosted.values.map { $0.process.pid })
        for live in registry.liveSessions() where !seen.contains(live.sessionId) && !ownPids.contains(live.pid) {
            let s = storedById[live.sessionId]
            let status: SessionStatus = live.status == "busy" ? .running : .idle
            result.append(SessionSummary(id: live.sessionId, title: s?.title ?? live.name ?? "Desktop session", cwd: live.cwd,
                                         updatedAt: s?.updatedAt ?? live.updatedAt, origin: .desktop, status: status,
                                         desktopName: live.name, entrypoint: live.entrypoint))
            seen.insert(live.sessionId)
        }
        for s in stored where !seen.contains(s.id) {
            result.append(SessionSummary(id: s.id, title: s.title, cwd: s.cwd, updatedAt: s.updatedAt, origin: .stored, status: .unknown))
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
        let stored = store.session(id: sessionId)
        let ownPids = Set(hosted.values.map { $0.process.pid })
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
        guard let stored else { throw ManagerError.unknownSession(sessionId) }
        guard FileManager.default.fileExists(atPath: stored.cwd) else { throw ManagerError.cwdMissing(stored.cwd) }
        var config = CLIProcess.Config(cliPath: cli.path, cwd: stored.cwd)
        config.resume = sessionId
        let h = try spawn(sessionId: sessionId, config: config, origin: .host)
        h.title = stored.title
        let history = store.history(path: stored.path)
        reply(.history(sessionId: sessionId, entries: history.entries))
        reply(.state(state: h.state))
        broadcast(.sessions(items: listSessions()))
    }

    public func create(_ options: NewSessionOptions) throws -> SessionState {
        guard FileManager.default.fileExists(atPath: options.cwd) else { throw ManagerError.cwdMissing(options.cwd) }
        let sessionId = UUID().uuidString.lowercased()
        var config = CLIProcess.Config(cliPath: cli.path, cwd: options.cwd)
        config.sessionId = sessionId
        config.model = options.model
        config.permissionMode = options.permissionMode
        config.effort = options.effort
        let h = try spawn(sessionId: sessionId, config: config, origin: .host)
        broadcast(.sessions(items: listSessions()))
        return h.state
    }

    /// Continue a copy of `sessionId` under the daemon (safe even while the original is open in Desktop).
    public func fork(sessionId: String) throws -> SessionState {
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

    private func spawn(sessionId: String, config: CLIProcess.Config, origin: SessionOrigin) throws -> Hosted {
        let process = CLIProcess(config: config)
        let state = SessionState(id: sessionId, origin: origin, status: .idle, cwd: config.cwd, model: config.model, permissionMode: config.permissionMode)
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

    // MARK: driving

    public func prompt(sessionId: String, text: String, images: [InlineImage] = []) throws {
        guard let h = hosted[sessionId] else {
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
        try h.process.sendUser(text, images: images)
        if h.title == nil {
            h.title = String(text.split(separator: "\n").first ?? "").trimmingCharacters(in: .whitespaces)
            broadcast(.sessions(items: listSessions()))
        }
        update(h, status: .running)
    }

    public func resolvePermission(sessionId: String, requestId: String, allow: Bool, message: String?) {
        guard let h = hosted[sessionId], let entry = h.pending.removeValue(forKey: requestId) else { return }
        let response: JSONValue
        if allow {
            response = .object(["behavior": "allow", "updatedInput": entry.request.input])
        } else {
            response = .object(["behavior": "deny", "message": .string(message ?? "Denied from phone")])
        }
        entry.continuation.resume(returning: response)
        h.state.pendingPermissions.removeAll { $0.id == requestId }
        broadcast(.permissionResolved(sessionId: sessionId, requestId: requestId))
        update(h, status: h.pending.isEmpty ? .running : .awaitingPermission)
    }

    public func interrupt(sessionId: String) async throws {
        guard let h = hosted[sessionId] else { throw ManagerError.unknownSession(sessionId) }
        try await h.process.interrupt()
    }

    public func setModel(sessionId: String, model: String) async throws {
        guard let h = hosted[sessionId] else { throw ManagerError.unknownSession(sessionId) }
        try await h.process.setModel(model)
        h.state.model = model
        broadcast(.state(state: h.state))
    }

    public func setPermissionMode(sessionId: String, mode: String) async throws {
        guard let h = hosted[sessionId] else { throw ManagerError.unknownSession(sessionId) }
        try await h.process.setPermissionMode(mode)
        h.state.permissionMode = mode
        broadcast(.state(state: h.state))
    }

    public func close(sessionId: String) {
        if let h = hosted[sessionId] {
            for (_, entry) in h.pending { entry.continuation.resume(returning: nil) }
            h.pending.removeAll()
            h.process.terminate()
        }
        if let w = watched.removeValue(forKey: sessionId) {
            w.tail?.stop()
            w.poller?.cancel()
        }
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

    public func shutdown() {
        for id in Array(hosted.keys) { close(sessionId: id) }
        for id in Array(watched.keys) { close(sessionId: id) }
    }

    // MARK: CLI callbacks

    private func handleMessage(sessionId: String, message: JSONValue) {
        guard let h = hosted[sessionId] else { return }
        switch message["type"]?.string {
        case "system":
            if message["subtype"]?.string == "init" {
                if let m = message["model"]?.string { h.state.model = m }
                if let p = message["permissionMode"]?.string { h.state.permissionMode = p }
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
                    notifier.notify(.done, body: "\(name) · \(h.title ?? "turn complete")")
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
                h.pending[requestId] = (permission, continuation)
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
        guard let h = hosted[sessionId], let entry = h.pending.removeValue(forKey: requestId) else { return }
        entry.continuation.resume(returning: nil)
        h.state.pendingPermissions.removeAll { $0.id == requestId }
        broadcast(.permissionResolved(sessionId: sessionId, requestId: requestId))
        update(h, status: h.pending.isEmpty ? .running : .awaitingPermission)
    }

    private func handleExit(sessionId: String, status: Int32, stderr: String) {
        guard let h = hosted.removeValue(forKey: sessionId) else { return }
        for (_, entry) in h.pending { entry.continuation.resume(returning: nil) }
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

    // MARK: notifications

    private func notifyName(_ h: Hosted) -> String {
        (h.state.cwd as NSString).lastPathComponent
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
