#if os(macOS)
import Foundation
import Network
import ClaudeRemoteCore
import ClaudeCodeHost

/// A tiny HTTP server on a Unix socket for Claude Code's hooks. The `PermissionRequest` hook
/// (`ClaudeHooks`) POSTs the hook input here and waits; the reply is the hook's stdout — a decision
/// made on the phone, or nothing, which lets the CLI prompt on the Mac as usual.
///
/// One request per connection, HTTP/1.1 without keep-alive: enough for `curl`, and simple enough
/// to parse by hand. A closed connection (the CLI timed the hook out, or the turn was aborted)
/// withdraws the request from the phone.
final class HookServer: @unchecked Sendable {
    private let path: String
    private let manager: SessionManager
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "ccremote.hooks")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private let lock = NSLock()

    /// Give up before curl's own `--max-time` so the hook's stdout is ours, not a timeout.
    static let maxWait: TimeInterval = 580

    init(path: String, manager: SessionManager, log: @escaping @Sendable (String) -> Void) {
        self.path = path
        self.manager = manager
        self.log = log
    }

    func start() {
        // A stale socket file from a previous run refuses the bind.
        unlink(path)
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.unix(path: path)
        params.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: params)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    chmod(self.path, 0o600)   // only this user may talk to the daemon through it
                    self.log("hooks: listening on \(self.path)")
                case .failed(let error): self.log("hooks: listener failed: \(error)")
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] nw in self?.accept(nw) }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            log("hooks: cannot listen on \(path): \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        let open: [Connection] = lock.withLock { Array(connections.values) }
        for c in open { c.cancel() }
        unlink(path)
    }

    private func accept(_ nw: NWConnection) {
        let connection = Connection(nw, server: self)
        lock.withLock { connections[ObjectIdentifier(connection)] = connection }
        connection.start(on: queue)
    }

    fileprivate func finished(_ connection: Connection) {
        _ = lock.withLock { connections.removeValue(forKey: ObjectIdentifier(connection)) }
    }

    // MARK: routing

    /// Handles one parsed request and returns the response body (empty = no decision).
    fileprivate func handle(path: String, body: Data, onStarted: (String?) -> Void) async -> Data {
        guard path == "/permission-request" else { return Data() }
        guard let input = try? JSONValue.parse(body) else {
            log("hooks: unreadable hook input (\(body.count) bytes)")
            return Data()
        }
        guard let sessionId = input["session_id"]?.string, let toolName = input["tool_name"]?.string else { return Data() }
        let requestId = "hook-" + UUID().uuidString.lowercased()
        onStarted(requestId)
        let decision = await withTaskGroup(of: JSONValue?.self) { group -> JSONValue? in
            group.addTask { [manager] in
                await manager.requestHookPermission(requestId: requestId, sessionId: sessionId, toolName: toolName,
                                                    input: input["tool_input"] ?? .object([:]),
                                                    suggestions: input["permission_suggestions"], cwd: input["cwd"]?.string)
            }
            group.addTask { [manager] in
                try? await Task.sleep(nanoseconds: UInt64(HookServer.maxWait * 1_000_000_000))
                await manager.cancelHookPermission(requestId: requestId)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let decision else { return Data() }
        let reply: JSONValue = .object(["hookSpecificOutput": .object(["hookEventName": "PermissionRequest", "decision": decision])])
        return (try? reply.serialized()) ?? Data()
    }

    fileprivate func withdraw(requestId: String) {
        Task { await manager.cancelHookPermission(requestId: requestId) }
    }

    // MARK: one connection

    fileprivate final class Connection: @unchecked Sendable {
        private let nw: NWConnection
        private unowned let server: HookServer
        private var buffer = Data()
        private var requestId: String?
        private var answered = false

        init(_ nw: NWConnection, server: HookServer) {
            self.nw = nw
            self.server = server
        }

        func start(on queue: DispatchQueue) {
            nw.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled: self?.closed()
                default: break
                }
            }
            nw.start(queue: queue)
            read()
        }

        func cancel() { nw.cancel() }

        private func read() {
            nw.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data { self.buffer.append(data) }
                if let request = self.parse() {
                    self.serve(request)
                    return
                }
                if error != nil || isComplete { self.nw.cancel(); return }
                if self.buffer.count > 8 << 20 { self.nw.cancel(); return }   // nobody's hook input is that big
                self.read()
            }
        }

        /// Head + full body present → (path, body).
        private func parse() -> (path: String, body: Data)? {
            guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let head = String(decoding: buffer[..<headEnd.lowerBound], as: UTF8.self)
            let lines = head.components(separatedBy: "\r\n")
            let requestLine = lines.first?.split(separator: " ") ?? []
            let path = requestLine.count > 1 ? String(requestLine[1]) : "/"
            var length = 0
            for line in lines.dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                if parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                    length = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }
            let bodyStart = headEnd.upperBound
            guard buffer.count - bodyStart >= length else { return nil }
            return (path, buffer[bodyStart..<(bodyStart + length)])
        }

        private func serve(_ request: (path: String, body: Data)) {
            Task { [weak self] in
                guard let self else { return }
                let body = await self.server.handle(path: request.path, body: request.body) { id in self.requestId = id }
                self.answered = true
                var head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                if body.isEmpty { head = head.replacingOccurrences(of: "Content-Type: application/json\r\n", with: "") }
                self.nw.send(content: Data(head.utf8) + body, completion: .contentProcessed { [weak self] _ in
                    self?.nw.cancel()
                })
            }
        }

        private func closed() {
            if !answered, let requestId { server.withdraw(requestId: requestId) }
            server.finished(self)
        }
    }
}
#endif
