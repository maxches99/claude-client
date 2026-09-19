#if os(macOS)
import Foundation
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

    public init(cliPath: String) {
        self.cliPath = cliPath
    }

    public var pid: Int32 { process.processIdentifier }

    // MARK: lifecycle

    public func start() throws {
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
            self.log?("stderr: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
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
        writeQueue.async { [stdinPipe] in
            try? stdinPipe.fileHandleForWriting.close()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [process] in
            if process.isRunning { process.terminate() }
        }
    }

    // MARK: sending

    private func send(_ value: JSONValue) throws {
        guard isRunning else { throw ServerError.notRunning }
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
