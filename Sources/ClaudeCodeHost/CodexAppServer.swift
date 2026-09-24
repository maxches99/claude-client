#if os(macOS)
import Foundation
import Network
import ClaudeRemoteCore

/// One `codex app-server` process speaking JSON-RPC over stdio — the channel the Codex desktop
/// app and IDE extension use. A single process hosts any number of threads:
///  * we send requests (`thread/start`, `turn/start`, …) and get responses by id;
///  * the server streams notifications (`item/started`, `item/agentMessage/delta`, `turn/completed`, …);
///  * the server sends us requests too (`item/commandExecution/requestApproval`, …) that we answer.
public final class CodexAppServer: @unchecked Sendable {
    public enum ServerError: Error, CustomStringConvertible {
        case notRunning
        case rpc(code: Int, message: String)
        case timeout(String)

        public var description: String {
            switch self {
            case .notRunning: return "Codex app-server is not running"
            case .rpc(_, let m): return m
            case .timeout(let method): return "Codex did not answer \(method) in time"
            }
        }
    }

    public let cliPath: String
    /// With a port, the server listens on `ws://127.0.0.1:port` instead of stdio and we connect as
    /// a WebSocket client — so the Codex app can share the same server (`CODEX_APP_SERVER_WS_URL`)
    /// and its threads become ours to follow and drive. A server already on the port is reused.
    public let listenPort: UInt16?
    private var channel: WebSocketChannel?
    private let wsQueue = DispatchQueue(label: "ccremote.codex.ws")
    /// True when we attached to a server someone else started (we never terminate that one).
    private(set) public var attachedToExisting = false
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let writeQueue = DispatchQueue(label: "ccremote.codex.stdin")
    private let lock = NSLock()
    private var buffer = Data()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var stderrTail: [String] = []
    private(set) public var isRunning = false

    /// Server → client notification (`method`, `params`).
    public var onNotification: (@Sendable (_ method: String, _ params: JSONValue) -> Void)?
    /// Server → client request; the returned value is sent as the JSON-RPC result. `nil` means the
    /// handler answers later itself (`respond` / `respondError`) — approvals wait for the phone.
    public var onRequest: (@Sendable (_ id: JSONValue, _ method: String, _ params: JSONValue) async -> JSONValue?)?
    public var onExit: (@Sendable (_ status: Int32, _ stderrTail: String) -> Void)?
    public var log: (@Sendable (String) -> Void)?

    public init(cliPath: String, listenPort: UInt16? = nil) {
        self.cliPath = cliPath
        self.listenPort = listenPort
    }

    public var pid: Int32 { process.processIdentifier }

    // MARK: lifecycle

    public func start() throws {
        if let port = listenPort {
            try startShared(port: port)
            return
        }
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["app-server"]
        process.environment = ClaudeCLI.childEnvironment()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.consume(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self.lock.withLock {
                self.stderrTail.append(text)
                if self.stderrTail.count > 50 { self.stderrTail.removeFirst(self.stderrTail.count - 50) }
            }
            // Refused requests dump a whole HTML page into the error; the first lines say what happened.
            let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.log?("stderr: \(line.count > 400 ? line.prefix(400) + "…" : line)")
        }
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.isRunning = false
            self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
            self.stderrPipe.fileHandleForReading.readabilityHandler = nil
            let tail = self.lock.withLock { self.stderrTail.joined() }
            let pendingNow = self.lock.withLock { () -> [CheckedContinuation<JSONValue, Error>] in
                let values = Array(self.pending.values)
                self.pending.removeAll()
                return values
            }
            for c in pendingNow { c.resume(throwing: ServerError.notRunning) }
            self.onExit?(p.terminationStatus, tail)
        }
        try process.run()
        isRunning = true
        log?("started pid \(process.processIdentifier): codex app-server")
    }

    public func terminate() {
        guard isRunning else { return }
        if listenPort != nil {
            channel?.close()
            channel = nil
            isRunning = false
            // A shared server outlives us on purpose (the Codex app may be on it) unless we spawned it.
            if !attachedToExisting, process.isRunning { process.terminate() }
            return
        }
        writeQueue.async { [stdinPipe] in
            try? stdinPipe.fileHandleForWriting.close()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [process] in
            if process.isRunning { process.terminate() }
        }
    }

    // MARK: shared (WebSocket) mode

    /// Spawns `codex app-server --listen ws://127.0.0.1:port` unless something already answers
    /// there, then connects. Blocks briefly (≤ 8 s) until the socket is up.
    private func startShared(port: UInt16) throws {
        if !CodexAppServer.portIsOpen(port) {
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = ["app-server", "--listen", "ws://127.0.0.1:\(port)"]
            process.environment = ClaudeCLI.childEnvironment()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard let self, !data.isEmpty else { handle.readabilityHandler = nil; return }
                self.log?("app-server: \(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard let self, !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                self.lock.withLock {
                    self.stderrTail.append(text)
                    if self.stderrTail.count > 50 { self.stderrTail.removeFirst(self.stderrTail.count - 50) }
                }
                self.log?("stderr: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            process.terminationHandler = { [weak self] p in
                guard let self else { return }
                self.log?("shared app-server exited (\(p.terminationStatus))")
                self.connectionLost(reason: "app-server exited (\(p.terminationStatus))")
            }
            try process.run()
            log?("started pid \(process.processIdentifier): codex app-server --listen ws://127.0.0.1:\(port)")
            let deadline = Date().addingTimeInterval(8)
            while !CodexAppServer.portIsOpen(port), Date() < deadline { Thread.sleep(forTimeInterval: 0.15) }
        } else {
            attachedToExisting = true
            log?("attaching to the codex app-server already on 127.0.0.1:\(port)")
        }
        let url = URL(string: "ws://127.0.0.1:\(port)")!
        let connection = NWConnection(to: .url(url), using: WebSocketChannel.parameters(tls: .none))
        let channel = WebSocketChannel(connection: connection, queue: wsQueue)
        let gate = ConnectGate()
        channel.onState = { [weak self] state in
            switch state {
            case .ready:
                gate.finish(nil)
            case .failed(let error):
                gate.finish(error)
                self?.connectionLost(reason: "\(error)")
            case .cancelled:
                gate.finish(ServerError.notRunning)
                self?.connectionLost(reason: "connection closed")
            default: break
            }
        }
        channel.onText = { [weak self] text in
            guard let value = try? JSONValue.parse(text) else { return }
            self?.dispatch(value)
        }
        self.channel = channel
        channel.start()
        if let failure = gate.wait(seconds: 10) {
            channel.close()
            self.channel = nil
            throw failure
        }
        isRunning = true
    }

    /// First state outcome of a connection attempt, awaited synchronously.
    private final class ConnectGate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var done = false
        private var error: Error?
        func finish(_ error: Error?) {
            lock.withLock {
                guard !done else { return }
                done = true
                self.error = error
                semaphore.signal()
            }
        }
        /// nil = connected; an error otherwise (including a timeout).
        func wait(seconds: TimeInterval) -> Error? {
            if semaphore.wait(timeout: .now() + seconds) == .timedOut { return ServerError.timeout("connect") }
            return lock.withLock { error }
        }
    }

    private func connectionLost(reason: String) {
        guard isRunning else { return }
        isRunning = false
        let pendingNow = lock.withLock { () -> [CheckedContinuation<JSONValue, Error>] in
            let values = Array(pending.values)
            pending.removeAll()
            return values
        }
        for c in pendingNow { c.resume(throwing: ServerError.notRunning) }
        onExit?(-1, reason)
    }

    /// A TCP connect probe: something is listening on 127.0.0.1:port.
    static func portIsOpen(_ port: UInt16) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }

    // MARK: sending

    private func send(_ value: JSONValue) throws {
        guard isRunning else { throw ServerError.notRunning }
        if let channel {
            channel.send(text: String(decoding: try value.serialized(), as: UTF8.self))
            return
        }
        var data = try value.serialized()
        data.append(0x0A)
        writeQueue.async { [stdinPipe] in
            stdinPipe.fileHandleForWriting.write(data)
        }
    }

    public func notify(_ method: String, _ params: JSONValue = .object([:])) throws {
        try send(.object(["method": .string(method), "params": params]))
    }

    /// Sends a request and resolves with its `result`.
    public func request(_ method: String, _ params: JSONValue = .object([:]), timeout: TimeInterval = 60) async throws -> JSONValue {
        guard isRunning else { throw ServerError.notRunning }
        let id = lock.withLock { () -> Int in
            let id = nextId
            nextId += 1
            return id
        }
        let frame = JSONValue.object(["id": .number(Double(id)), "method": .string(method), "params": params])
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { pending[id] = continuation }
            do {
                try send(frame)
            } catch {
                lock.withLock { pending[id] = nil }
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let c = self.lock.withLock({ self.pending.removeValue(forKey: id) }) else { return }
                c.resume(throwing: ServerError.timeout(method))
            }
        }
    }

    /// `initialize` handshake; must precede everything else.
    public func initialize(clientName: String, clientVersion: String) async throws -> JSONValue {
        let result = try await request("initialize", .object([
            "clientInfo": .object(["name": .string(clientName), "title": "ClaudeRemote", "version": .string(clientVersion)]),
            "capabilities": .object(["optOutNotificationMethods": .array([
                "fuzzyFileSearch/sessionUpdated", "fuzzyFileSearch/sessionCompleted", "account/rateLimits/updated",
            ])]),
        ]))
        try notify("initialized")
        return result
    }

    public func respond(id: JSONValue, result: JSONValue) {
        try? send(.object(["id": id, "result": result]))
    }

    public func respondError(id: JSONValue, code: Int = -32601, message: String) {
        try? send(.object(["id": id, "error": .object(["code": .number(Double(code)), "message": .string(message)])]))
    }

    // MARK: receiving

    private func consume(_ data: Data) {
        var lines: [Data] = []
        lock.withLock {
            buffer.append(data)
            while let nl = buffer.firstIndex(of: 0x0A) {
                lines.append(buffer.subdata(in: buffer.startIndex..<nl))
                buffer.removeSubrange(buffer.startIndex...nl)
            }
        }
        for line in lines where !line.isEmpty {
            guard let value = try? JSONValue.parse(line) else {
                log?("unparseable line: \(String(decoding: line.prefix(200), as: UTF8.self))")
                continue
            }
            dispatch(value)
        }
    }

    private func dispatch(_ value: JSONValue) {
        let method = value["method"]?.string
        let id = value["id"]
        switch (method, id) {
        case (let method?, let id?):
            // Server → client request.
            Task { [weak self] in
                guard let self else { return }
                guard let handler = self.onRequest else {
                    self.respondError(id: id, message: "unsupported request \(method)")
                    return
                }
                if let reply = await handler(id, method, value["params"] ?? .object([:])) {
                    self.respond(id: id, result: reply)
                }
            }
        case (let method?, nil):
            onNotification?(method, value["params"] ?? .object([:]))
        case (nil, let id?):
            guard let key = id.int, let continuation = lock.withLock({ pending.removeValue(forKey: key) }) else { return }
            if let error = value["error"] {
                continuation.resume(throwing: ServerError.rpc(code: error["code"]?.int ?? 0, message: error["message"]?.string ?? "Codex error"))
            } else {
                continuation.resume(returning: value["result"] ?? .null)
            }
        default:
            break
        }
    }
}
#endif
