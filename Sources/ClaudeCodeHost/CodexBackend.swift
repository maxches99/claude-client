#if os(macOS) || os(Linux)
import Foundation
import ClaudeRemoteCore

/// Codex threads hosted by the daemon. Owns one lazily started `codex app-server`, keeps a
/// translator per thread, and turns the server's approval requests into `PermissionRequest`s
/// that the SessionManager shows on the phone — the same path Claude's `can_use_tool` takes.
public actor CodexBackend {
    public enum BackendError: Error, CustomStringConvertible {
        case notInstalled
        case startFailed(String)

        public var description: String {
            switch self {
            case .notInstalled: return "Codex is not installed on this Mac"
            case .startFailed(let why): return "Could not start codex app-server: \(why)"
            }
        }
    }

    /// A thread as listed by `thread/list`.
    public struct ThreadInfo: Sendable {
        public var id: String
        public var title: String
        public var cwd: String
        public var updatedAt: Date
        /// Codex's own session file (`~/.codex/sessions/…/rollout-*.jsonl`), read to follow a
        /// thread another process owns.
        public var path: String?
    }

    /// What a started / resumed / forked thread looks like right after the RPC.
    public struct Started: Sendable {
        public var id: String
        public var cwd: String
        public var model: String?
        public var effort: String?
        public var approvalPolicy: String?
        public var sandbox: String?
        public var title: String?
        public var history: [JSONValue]
    }

    /// The per-turn knobs Codex takes on `turn/start` (there is no `set_model` — they ride along with every turn).
    public struct TurnOptions: Sendable {
        public var model: String?
        public var effort: String?
        public var approvalPolicy: String?
        public var sandbox: String?
        public init(model: String? = nil, effort: String? = nil, approvalPolicy: String? = nil, sandbox: String? = nil) {
            self.model = model
            self.effort = effort
            self.approvalPolicy = approvalPolicy
            self.sandbox = sandbox
        }
    }

    public enum Event: Sendable {
        /// A stream-json shaped event for the phone.
        case event(threadId: String, payload: JSONValue)
        case turnStarted(threadId: String)
        case turnCompleted(threadId: String, isError: Bool, summary: String?)
        /// The server waits for a decision; answer with `decide`.
        case approval(threadId: String, request: PermissionRequest)
        /// The server stopped waiting (turn interrupted, answered elsewhere).
        case approvalResolved(threadId: String, requestId: String)
        /// The app-server died; every hosted thread is gone with it.
        case exited(error: String)
    }

    private struct PendingApproval {
        let rpcId: JSONValue
        let method: String
        let params: JSONValue
    }

    public let cli: CodexCLI
    private let log: @Sendable (String) -> Void
    private var server: CodexAppServer?
    private var initialized = false
    /// In-flight start, so concurrent callers share one process instead of each spawning their own.
    private var starting: Task<CodexAppServer, Error>?
    private var translators: [String: CodexTranslator] = [:]
    private var turnIds: [String: String] = [:]
    private var pendingApprovals: [String: PendingApproval] = [:]
    /// File changes seen at `item/started`, so a `fileChange/requestApproval` can name the files.
    private var fileChanges: [String: JSONValue] = [:]
    private var threadCache: (at: Date, items: [ThreadInfo])?
    private var modelCache: [ModelOption]?
    private(set) public var loggedIn: Bool?
    private let tempDirectory = NSTemporaryDirectory() + "ccremote-codex-images"

    public var onEvent: (@Sendable (Event) -> Void)?

    /// Port of the shared app-server (`ws://127.0.0.1:port`), nil for a private stdio one.
    public nonisolated let listenPort: UInt16?
    public nonisolated var isShared: Bool { listenPort != nil }

    public init(cli: CodexCLI, listenPort: UInt16? = nil, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.listenPort = listenPort
        self.cli = cli
        self.log = log
        self.loggedIn = CodexCLI.hasCredentials()
    }

    public func setEventHandler(_ handler: @escaping @Sendable (Event) -> Void) {
        onEvent = handler
    }

    // MARK: process

    private func ensureRunning() async throws -> CodexAppServer {
        if let server, server.isRunning, initialized { return server }
        if let starting { return try await starting.value }
        let task = Task { try await startServer() }
        starting = task
        defer { starting = nil }
        return try await task.value
    }

    private func startServer() async throws -> CodexAppServer {
        let server = CodexAppServer(cliPath: cli.path, listenPort: listenPort)
        let log = self.log
        server.log = { line in log("[codex] \(line)") }
        server.onNotification = { [weak self] method, params in
            guard let self else { return }
            Task { await self.handleNotification(method: method, params: params) }
        }
        server.onRequest = { [weak self] id, method, params in
            guard let self else { return nil }
            return await self.handleRequest(id: id, method: method, params: params)
        }
        server.onExit = { [weak self] status, stderr in
            guard let self else { return }
            Task { await self.handleExit(status: status, stderr: stderr) }
        }
        do {
            try server.start()
        } catch {
            throw BackendError.startFailed(error.localizedDescription)
        }
        self.server = server
        initialized = false
        do {
            _ = try await server.initialize(clientName: "ccremote", clientVersion: "1")
        } catch {
            server.terminate()
            self.server = nil
            throw BackendError.startFailed("\(error)")
        }
        initialized = true
        refreshAccountInBackground()
        return server
    }

    private func handleExit(status: Int32, stderr: String) {
        guard server != nil else { return }
        server = nil
        initialized = false
        let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let error = "codex app-server exited with status \(status)" + (tail.isEmpty ? "" : ": \(tail.suffix(400))")
        log("[codex] \(error)")
        translators.removeAll()
        turnIds.removeAll()
        pendingApprovals.removeAll()
        threadCache = nil
        onEvent?(.exited(error: error))
    }

    public func shutdown() {
        server?.terminate()
        server = nil
        initialized = false
    }

    // MARK: info

    /// Refines the cheap auth.json check with `account/read` once the server is up.
    private func refreshAccountInBackground() {
        Task { [weak self] in
            guard let self, let server = await self.server else { return }
            if let result = try? await server.request("account/read", .object([:]), timeout: 15) {
                await self.setLoggedIn(!(result["account"]?.isNull ?? true))
            }
        }
    }

    private func setLoggedIn(_ value: Bool) {
        loggedIn = value
    }

    public func listModels() async throws -> [ModelOption] {
        if let modelCache { return modelCache }
        let server = try await ensureRunning()
        let result = try await server.request("model/list", .object([:]), timeout: 30)
        let models = (result["data"]?.array ?? []).filter { $0["hidden"]?.bool != true }.map { m in
            ModelOption(id: m["model"]?.string ?? m["id"]?.string ?? "",
                        label: m["displayName"]?.string ?? m["model"]?.string ?? "",
                        description: m["description"]?.string,
                        isDefault: m["isDefault"]?.bool ?? false,
                        efforts: (m["supportedReasoningEfforts"]?.array ?? []).compactMap { $0["reasoningEffort"]?.string },
                        defaultEffort: m["defaultReasoningEffort"]?.string)
        }.filter { !$0.id.isEmpty }
        modelCache = models
        return models
    }

    /// Threads on disk (newest first), cached for a few seconds because the session list is rebuilt often.
    public func listThreads(limit: Int = 100, maxAge: TimeInterval = 5) async throws -> [ThreadInfo] {
        if let threadCache, Date().timeIntervalSince(threadCache.at) < maxAge { return threadCache.items }
        let server = try await ensureRunning()
        let result = try await server.request("thread/list", .object([
            "limit": .number(Double(limit)), "sortKey": "updated_at", "sortDirection": "desc", "archived": false,
        ]), timeout: 30)
        let items = (result["data"]?.array ?? []).compactMap(Self.threadInfo)
        threadCache = (Date(), items)
        return items
    }

    /// A thread as it is on disk, including its turns — works for threads another process owns
    /// (the Codex app), which is how a session open there is followed live.
    public func read(threadId: String) async throws -> JSONValue {
        let server = try await ensureRunning()
        let result = try await server.request("thread/read", .object(["threadId": .string(threadId), "includeTurns": .bool(true)]), timeout: 60)
        return result["thread"] ?? .object([:])
    }

    /// Threads this daemon hosts — excluded when looking for sessions open elsewhere.
    public func hostedThreadIds() -> Set<String> {
        Set(translators.keys)
    }

    /// Threads loaded in the shared app-server by another client (the Codex app): on a shared
    /// server `thread/resume` on one of these subscribes us to its live traffic — approvals included —
    /// so the phone can follow and drive a session open in the app. Empty for a private server.
    public func threadsLoadedElsewhere() async -> Set<String> {
        guard isShared, let server, server.isRunning, initialized else { return [] }
        guard let result = try? await server.request("thread/loaded/list", .object([:]), timeout: 10) else { return [] }
        let ids = (result["data"]?.array ?? []).compactMap(\.string)
        return Set(ids).subtracting(hostedThreadIds())
    }

    public func rename(threadId: String, name: String) async throws {
        let server = try await ensureRunning()
        _ = try await server.request("thread/name/set", .object(["threadId": .string(threadId), "name": .string(name)]), timeout: 30)
    }

    /// Starts the server ahead of use — in shared mode the Codex app needs it up to connect.
    public func warmUp() async {
        _ = try? await ensureRunning()
    }

    /// The cached list, if any — for callers that must not block.
    public func cachedThreads() -> [ThreadInfo] {
        threadCache?.items ?? []
    }

    public func invalidateThreadList() {
        threadCache = nil
    }

    private static func threadInfo(_ thread: JSONValue) -> ThreadInfo? {
        guard let id = thread["id"]?.string else { return nil }
        let name = thread["name"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let preview = thread["preview"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let title = name ?? preview.map { String($0.split(separator: "\n").first ?? "").trimmingCharacters(in: .whitespaces) } ?? "Codex thread"
        let updated = (thread["updatedAt"]?.double ?? thread["createdAt"]?.double ?? 0)
        return ThreadInfo(id: id, title: title, cwd: thread["cwd"]?.string ?? "", updatedAt: Date(timeIntervalSince1970: updated),
                          path: thread["path"]?.string)
    }

    // MARK: threads

    /// `instructions` replaces Codex's own agent prompt (chat sessions).
    public func start(cwd: String, options: TurnOptions, instructions: String? = nil) async throws -> Started {
        let server = try await ensureRunning()
        var params: [String: JSONValue] = ["cwd": .string(cwd)]
        if let m = options.model { params["model"] = .string(m) }
        if let p = options.approvalPolicy { params["approvalPolicy"] = .string(p) }
        if let s = options.sandbox { params["sandbox"] = .string(s) }
        if let instructions { params["baseInstructions"] = .string(instructions) }
        let result = try await server.request("thread/start", .object(params), timeout: 60)
        return try register(result, fallbackCwd: cwd, effort: options.effort)
    }

    /// `instructions` / `options` re-apply what the thread was started with — a resumed chat must
    /// stay tool-less, `thread/resume` does not remember it.
    public func resume(threadId: String, options: TurnOptions = TurnOptions(), instructions: String? = nil) async throws -> Started {
        let server = try await ensureRunning()
        var params: [String: JSONValue] = ["threadId": .string(threadId)]
        if let p = options.approvalPolicy { params["approvalPolicy"] = .string(p) }
        if let s = options.sandbox { params["sandbox"] = .string(s) }
        if let instructions { params["baseInstructions"] = .string(instructions) }
        let result = try await server.request("thread/resume", .object(params), timeout: 120)
        return try register(result, fallbackCwd: "", effort: options.effort)
    }

    public func fork(threadId: String) async throws -> Started {
        let server = try await ensureRunning()
        let result = try await server.request("thread/fork", .object(["threadId": .string(threadId)]), timeout: 120)
        return try register(result, fallbackCwd: "", effort: nil)
    }

    private func register(_ result: JSONValue, fallbackCwd: String, effort: String?) throws -> Started {
        guard let thread = result["thread"], let id = thread["id"]?.string else {
            throw BackendError.startFailed("thread/start returned no thread")
        }
        translators[id] = CodexTranslator()
        threadCache = nil
        let sandbox = result["sandbox"]?["type"]?.string.map(Self.sandboxMode) ?? result["sandbox"]?.string
        let policy = result["approvalPolicy"]?.string
        // Unnamed threads are titled by their first prompt, like the Codex app does.
        var firstPrompt: String?
        for turn in thread["turns"]?.array ?? [] where firstPrompt == nil {
            for item in turn["items"]?.array ?? [] where item["type"]?.string == "userMessage" {
                let texts: [JSONValue] = item["content"]?.array ?? []
                if let text = texts.first(where: { $0["type"]?.string == "text" })?["text"]?.string {
                    firstPrompt = String(text.split(separator: "\n").first ?? "").trimmingCharacters(in: .whitespaces)
                    break
                }
            }
        }
        return Started(id: id, cwd: result["cwd"]?.string ?? thread["cwd"]?.string ?? fallbackCwd,
                       model: result["model"]?.string, effort: effort ?? result["reasoningEffort"]?.string,
                       approvalPolicy: policy, sandbox: sandbox,
                       title: thread["name"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? firstPrompt.flatMap { $0.isEmpty ? nil : $0 },
                       history: CodexTranslator.history(thread: thread))
    }

    /// `SandboxPolicy.type` (camelCase) → `SandboxMode` (kebab-case) as `thread/start` takes it.
    private static func sandboxMode(_ policyType: String) -> String {
        switch policyType {
        case "readOnly": return "read-only"
        case "workspaceWrite": return "workspace-write"
        case "dangerFullAccess": return "danger-full-access"
        default: return policyType
        }
    }

    /// Sends a user turn. Returns the `user` event to show on the phone (Codex does not replay it).
    public func prompt(threadId: String, text: String, images: [InlineImage], options: TurnOptions) async throws -> JSONValue {
        let server = try await ensureRunning()
        var input: [JSONValue] = []
        if !text.isEmpty { input.append(.object(["type": "text", "text": .string(text)])) }
        for image in images {
            input.append(.object(["type": "localImage", "path": .string(try writeTempImage(image))]))
        }
        if input.isEmpty { input.append(.object(["type": "text", "text": ""])) }
        var params: [String: JSONValue] = ["threadId": .string(threadId), "input": .array(input)]
        if let m = options.model { params["model"] = .string(m) }
        if let e = options.effort { params["effort"] = .string(e) }
        if let p = options.approvalPolicy { params["approvalPolicy"] = .string(p) }
        if let s = options.sandbox { params["sandboxPolicy"] = Self.sandboxPolicy(s) }
        let event = translators[threadId, default: CodexTranslator()].userEvent(text: text, images: images)
        let result = try await server.request("turn/start", .object(params), timeout: 60)
        if let turnId = result["turn"]?["id"]?.string { turnIds[threadId] = turnId }
        return event
    }

    /// `SandboxMode` → the `SandboxPolicy` object `turn/start` wants.
    private static func sandboxPolicy(_ mode: String) -> JSONValue {
        switch mode {
        case "read-only": return .object(["type": "readOnly"])
        case "danger-full-access": return .object(["type": "dangerFullAccess"])
        default: return .object(["type": "workspaceWrite"])
        }
    }

    public func interrupt(threadId: String) async throws {
        let server = try await ensureRunning()
        guard let turnId = turnIds[threadId] else { return }
        _ = try await server.request("turn/interrupt", .object(["threadId": .string(threadId), "turnId": .string(turnId)]), timeout: 30)
    }

    /// Forgets a thread on our side; it stays on disk and can be resumed later.
    public func close(threadId: String) async {
        for (requestId, pending) in pendingApprovals where pending.params["threadId"]?.string == threadId {
            pendingApprovals[requestId] = nil
            server?.respond(id: pending.rpcId, result: Self.reply(for: pending, allow: false))
        }
        translators[threadId] = nil
        turnIds[threadId] = nil
        if let server, server.isRunning {
            _ = try? await server.request("thread/unsubscribe", .object(["threadId": .string(threadId)]), timeout: 10)
        }
    }

    // MARK: approvals

    /// Answers a pending approval. `allow == nil` = cancelled (treated as decline).
    public func decide(requestId: String, allow: Bool?) {
        guard let pending = pendingApprovals.removeValue(forKey: requestId) else { return }
        server?.respond(id: pending.rpcId, result: Self.reply(for: pending, allow: allow ?? false))
    }

    private static func reply(for pending: PendingApproval, allow: Bool) -> JSONValue {
        switch pending.method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            return .object(["decision": allow ? "accept" : "decline"])
        case "item/permissions/requestApproval":
            return .object(["permissions": allow ? (pending.params["permissions"] ?? .object([:])) : .object([:]), "scope": "turn"])
        default:
            return .object([:])
        }
    }

    private func handleRequest(id: JSONValue, method: String, params: JSONValue) async -> JSONValue? {
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval":
            guard let threadId = params["threadId"]?.string else { return .object(["decision": "decline"]) }
            let requestId = Self.requestKey(id)
            pendingApprovals[requestId] = PendingApproval(rpcId: id, method: method, params: params)
            let changes = params["itemId"]?.string.flatMap { fileChanges[$0] }
            onEvent?(.approval(threadId: threadId, request: Self.permissionRequest(id: requestId, threadId: threadId, method: method, params: params, changes: changes)))
            return nil   // answered later through `decide`
        case "item/tool/requestUserInput":
            return .object(["answers": .object([:])])
        case "mcpServer/elicitation/request":
            return .object(["action": "decline"])
        case "execCommandApproval", "applyPatchApproval":
            return .object(["decision": "denied"])
        default:
            log("[codex] unsupported server request: \(method)")
            server?.respondError(id: id, message: "unsupported request \(method)")
            return nil
        }
    }

    private static func requestKey(_ id: JSONValue) -> String {
        if let s = id.string { return "codex:\(s)" }
        if let n = id.int { return "codex:\(n)" }
        return "codex:\(id.serializedString())"
    }

    /// Shapes a Codex approval like a Claude tool permission so the phone renders it with the same rows.
    private static func permissionRequest(id: String, threadId: String, method: String, params: JSONValue, changes: JSONValue?) -> PermissionRequest {
        switch method {
        case "item/commandExecution/requestApproval":
            var input: [String: JSONValue] = ["command": .string(CodexTranslator.unwrapShell(params["command"]?.string ?? ""))]
            if let cwd = params["cwd"]?.string { input["cwd"] = .string(cwd) }
            return PermissionRequest(id: id, sessionId: threadId, toolName: "Bash", input: .object(input),
                                     description: params["reason"]?.string, toolUseId: params["itemId"]?.string)
        case "item/fileChange/requestApproval":
            var input: [String: JSONValue] = [:]
            let paths = (changes?.array ?? []).compactMap { $0["path"]?.string }
            if !paths.isEmpty { input["file_path"] = .string(paths.map(ToolSummary.shortPath).joined(separator: ", ")) }
            let diff = (changes?.array ?? []).compactMap { $0["diff"]?.string }.joined(separator: "\n")
            if !diff.isEmpty { input["diff"] = .string(String(diff.prefix(20_000))) }
            if let root = params["grantRoot"]?.string { input["grant_root"] = .string(root) }
            return PermissionRequest(id: id, sessionId: threadId, toolName: "Edit", input: .object(input),
                                     title: paths.isEmpty ? (params["reason"]?.string ?? "Apply file changes") : nil, description: params["reason"]?.string,
                                     displayName: paths.count > 1 ? "Edit \(paths.count) files" : "Edit", toolUseId: params["itemId"]?.string)
        default:
            return PermissionRequest(id: id, sessionId: threadId, toolName: "Permissions", input: params["permissions"] ?? .object([:]),
                                     title: params["reason"]?.string, description: params["reason"]?.string,
                                     displayName: "Extra permissions", toolUseId: params["itemId"]?.string)
        }
    }

    // MARK: notifications

    private func handleNotification(method: String, params: JSONValue) {
        if method == "serverRequest/resolved", let threadId = params["threadId"]?.string, let id = params["requestId"] {
            let key = Self.requestKey(id)
            if pendingApprovals.removeValue(forKey: key) != nil {
                onEvent?(.approvalResolved(threadId: threadId, requestId: key))
            }
            return
        }
        guard let threadId = params["threadId"]?.string ?? params["thread"]?["id"]?.string, translators[threadId] != nil else { return }
        if method == "turn/started", let turnId = params["turn"]?["id"]?.string { turnIds[threadId] = turnId }
        if method == "item/started", let item = params["item"], item["type"]?.string == "fileChange", let itemId = item["id"]?.string {
            fileChanges[itemId] = item["changes"]
        }
        if method == "item/completed", let itemId = params["item"]?["id"]?.string { fileChanges[itemId] = nil }
        let events = translators[threadId]!.translate(method: method, params: params)
        for event in events { onEvent?(.event(threadId: threadId, payload: event)) }
        switch method {
        case "turn/started":
            onEvent?(.turnStarted(threadId: threadId))
        case "turn/completed":
            turnIds[threadId] = nil
            threadCache = nil
            let result = events.first { $0["type"]?.string == "result" }
            onEvent?(.turnCompleted(threadId: threadId, isError: result?["is_error"]?.bool ?? false, summary: result?["result"]?.string))
        default:
            break
        }
    }

    // MARK: images

    /// Codex takes images by path; phone photos land in a temp dir the process can read.
    private func writeTempImage(_ image: InlineImage) throws -> String {
        try FileManager.default.createDirectory(atPath: tempDirectory, withIntermediateDirectories: true)
        let ext = image.mediaType.split(separator: "/").last.map(String.init) ?? "jpg"
        let path = "\(tempDirectory)/\(UUID().uuidString.lowercased()).\(ext == "jpeg" ? "jpg" : ext)"
        guard let data = Data(base64Encoded: image.base64) else { throw BackendError.startFailed("bad image data") }
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }
}
#endif
