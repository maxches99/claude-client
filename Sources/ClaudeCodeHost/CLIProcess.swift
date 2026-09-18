#if os(macOS)
import Foundation
import ClaudeRemoteCore

/// One `claude` process speaking `--input-format stream-json --output-format stream-json`.
///
/// This is the same channel Claude Desktop and the Agent SDK use:
///  * user turns are written to stdin as `{"type":"user", ...}` lines;
///  * every stdout line is a JSON message (`assistant`, `user`, `stream_event`, `result`, `system`, ...);
///  * both sides can send `control_request` frames and answer with `control_response`;
///    the CLI asks us `can_use_tool` when a tool needs permission.
public final class CLIProcess: @unchecked Sendable {
    public struct Config: Sendable {
        public var cliPath: String
        public var cwd: String
        public var sessionId: String?      // for new sessions: pin the id up front
        public var resume: String?         // resume an existing transcript
        public var forkSession = false
        public var model: String?
        public var permissionMode: String?
        public var effort: String?
        public var extraArgs: [String] = []

        public init(cliPath: String, cwd: String) {
            self.cliPath = cliPath
            self.cwd = cwd
        }
    }

    public enum ProcessError: Error, CustomStringConvertible {
        case notRunning
        case controlError(String)
        case timeout

        public var description: String {
            switch self {
            case .notRunning: return "CLI process is not running"
            case .controlError(let m): return m
            case .timeout: return "CLI did not answer in time"
            }
        }
    }

    public let config: Config
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let writeQueue = DispatchQueue(label: "ccremote.cli.stdin")
    private let lock = NSLock()
    private var buffer = Data()
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var stderrTail: [String] = []
    private(set) public var isRunning = false

    /// Every stdout message except control traffic.
    public var onMessage: (@Sendable (JSONValue) -> Void)?
    /// CLI → host control requests (`can_use_tool`, `hook_callback`, ...). Return nil to stay silent.
    public var onControlRequest: (@Sendable (_ requestId: String, _ request: JSONValue) async -> JSONValue?)?
    /// CLI cancelled an outstanding control request (e.g. the turn was interrupted).
    public var onControlCancel: (@Sendable (_ requestId: String) -> Void)?
    public var onExit: (@Sendable (_ status: Int32, _ stderrTail: String) -> Void)?
    public var log: (@Sendable (String) -> Void)?

    public init(config: Config) {
        self.config = config
    }

    public var pid: Int32 { process.processIdentifier }

    // MARK: lifecycle

    public func start() throws {
        var args = ["--output-format", "stream-json", "--verbose", "--input-format", "stream-json",
                    "--permission-prompt-tool", "stdio", "--include-partial-messages", "--replay-user-messages",
                    "--setting-sources=user,project,local", "-p"]
        if let sessionId = config.sessionId { args += ["--session-id", sessionId] }
        if let resume = config.resume { args += ["--resume=\(resume)"] }
        if config.forkSession { args.append("--fork-session") }
        if let model = config.model { args += ["--model", model] }
        if let mode = config.permissionMode { args += ["--permission-mode", mode] }
        if let effort = config.effort { args += ["--effort", effort] }
        args += config.extraArgs

        process.executableURL = URL(fileURLWithPath: config.cliPath)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: config.cwd)
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
            for c in pendingNow { c.resume(throwing: ProcessError.notRunning) }
            self.onExit?(p.terminationStatus, tail)
        }
        try process.run()
        isRunning = true
        log?("started pid \(process.processIdentifier): \(args.joined(separator: " "))")
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

    public func send(_ value: JSONValue) throws {
        guard isRunning else { throw ProcessError.notRunning }
        var data = try value.serialized()
        data.append(0x0A)
        writeQueue.async { [stdinPipe] in
            stdinPipe.fileHandleForWriting.write(data)
        }
    }

    public func sendUserText(_ text: String) throws {
        try send(.object([
            "type": "user",
            "session_id": "",
            "parent_tool_use_id": .null,
            "message": .object(["role": "user", "content": .array([.object(["type": "text", "text": .string(text)])])]),
        ]))
    }

    /// Host → CLI control request; resolves with the `response` object of the `control_response`.
    @discardableResult
    public func control(_ subtype: String, _ fields: [String: JSONValue] = [:], timeout: TimeInterval = 60) async throws -> JSONValue {
        guard isRunning else { throw ProcessError.notRunning }
        let requestId = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(13).description
        var request = fields
        request["subtype"] = .string(subtype)
        let frame = JSONValue.object(["type": "control_request", "request_id": .string(requestId), "request": .object(request)])
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { pending[requestId] = continuation }
            do {
                try send(frame)
            } catch {
                lock.withLock { pending[requestId] = nil }
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let c = self.lock.withLock({ self.pending.removeValue(forKey: requestId) }) else { return }
                c.resume(throwing: ProcessError.timeout)
            }
        }
    }

    public func initialize() async throws -> JSONValue { try await control("initialize") }
    public func interrupt() async throws { try await control("interrupt") }
    public func setModel(_ model: String) async throws { try await control("set_model", ["model": .string(model)]) }
    public func setPermissionMode(_ mode: String) async throws { try await control("set_permission_mode", ["mode": .string(mode)]) }

    public func respond(requestId: String, response: JSONValue) {
        try? send(.object(["type": "control_response", "response": .object(["subtype": "success", "request_id": .string(requestId), "response": response])]))
    }

    public func respondError(requestId: String, error: String) {
        try? send(.object(["type": "control_response", "response": .object(["subtype": "error", "request_id": .string(requestId), "error": .string(error)])]))
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
        switch value["type"]?.string {
        case "control_response":
            guard let response = value["response"], let id = response["request_id"]?.string else { return }
            guard let continuation = lock.withLock({ pending.removeValue(forKey: id) }) else { return }
            if response["subtype"]?.string == "error" {
                continuation.resume(throwing: ProcessError.controlError(response["error"]?.string ?? "control error"))
            } else {
                continuation.resume(returning: response["response"] ?? .null)
            }
        case "control_request":
            guard let id = value["request_id"]?.string, let request = value["request"] else { return }
            Task { [weak self] in
                guard let self else { return }
                if let handler = self.onControlRequest, let reply = await handler(id, request) {
                    self.respond(requestId: id, response: reply)
                } else if self.onControlRequest == nil {
                    self.respondError(requestId: id, error: "unsupported control request")
                }
            }
        case "control_cancel_request":
            if let id = value["request_id"]?.string { onControlCancel?(id) }
        default:
            onMessage?(value)
        }
    }
}
#endif
