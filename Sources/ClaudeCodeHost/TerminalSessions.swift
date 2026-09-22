#if os(macOS) || os(Linux)
import Foundation
import ClaudeRemoteCore
import CPTY
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// The libc calls, by names the types below (which have `write` / `close` methods of their own) can reach.
private func systemWrite(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int { write(fd, buffer, count) }
private func systemClose(_ fd: Int32) { _ = close(fd) }

/// A login shell running in a pseudo-terminal on the Mac, and the tail of what it printed — so a
/// phone that comes back sees the screen, not a blank one.
final class TerminalRun: @unchecked Sendable {
    var info: TerminalInfo
    let master: Int32
    let pid: pid_t
    var listeners: Set<UUID> = []
    private(set) var tail: [UInt8] = []
    private var readSource: DispatchSourceRead?
    private let writeQueue = DispatchQueue(label: "ccremote.terminal.write")
    static let tailLimit = 256 * 1024

    init(info: TerminalInfo, master: Int32, pid: pid_t) {
        self.info = info
        self.master = master
        self.pid = pid
    }

    func remember(_ bytes: [UInt8]) {
        tail += bytes
        if tail.count > TerminalRun.tailLimit { tail.removeFirst(tail.count - TerminalRun.tailLimit) }
    }

    /// Reads the master side until the shell goes away; `output` gets each chunk.
    func startReading(queue: DispatchQueue, output: @escaping @Sendable ([UInt8]) -> Void, closed: @escaping @Sendable () -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        let fd = master
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                output(Array(buffer.prefix(n)))
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                // EIO once the last process holding the slave side has exited.
                source.cancel()
                closed()
            }
        }
        source.resume()
        readSource = source
    }

    func write(_ bytes: [UInt8]) {
        let fd = master
        writeQueue.async {
            var offset = 0
            while offset < bytes.count {
                let n = bytes[offset...].withUnsafeBytes { systemWrite(fd, $0.baseAddress, $0.count) }
                if n > 0 { offset += n } else if errno != EINTR && errno != EAGAIN { return }
            }
        }
    }

    func stopReading() {
        readSource?.cancel()
        readSource = nil
    }
}

extension SessionManager {
    static let maxTerminals = 4

    /// Starts a login shell in a new pseudo-terminal, in the session's project (or the home folder).
    public func openTerminal(sessionId: String?, terminalId: String, cols: Int, rows: Int, phone: UUID) throws {
        guard terminals[terminalId] == nil else {
            attachTerminal(terminalId: terminalId, phone: phone, attached: true)
            return
        }
        guard terminals.values.filter({ $0.info.running }).count < SessionManager.maxTerminals else {
            throw GitError.refused("\(SessionManager.maxTerminals) terminals are already open on the Mac — close one first.")
        }
        let cwd = sessionId.flatMap { cwdFor($0) }.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? NSHomeDirectory()
        var env = ClaudeCLI.childEnvironment()
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["NO_COLOR"] = nil
        env["TERM_PROGRAM"] = "ClaudeRemote"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        let shell = env["SHELL"].flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil } ?? "/bin/zsh"
        // A leading dash makes it a login shell, so the user's profile is read — the same shell they get in Terminal.
        let argv0 = "-" + (shell as NSString).lastPathComponent
        let size = (cols: UInt16(clamping: max(20, cols)), rows: UInt16(clamping: max(5, rows)))

        var master: Int32 = -1
        var pid: pid_t = 0
        let status = SessionManager.withCStrings([argv0]) { argv in
            SessionManager.withCStrings(env.map { "\($0.key)=\($0.value)" }) { envp in
                ccr_pty_spawn(shell, argv, envp, cwd, size.cols, size.rows, &master, &pid)
            }
        }
        guard status == 0 else { throw GitError.refused("Could not start a terminal: \(String(cString: strerror(status)))") }
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)

        let info = TerminalInfo(id: terminalId, cwd: cwd, sessionId: sessionId, cols: Int(size.cols), rows: Int(size.rows))
        let run = TerminalRun(info: info, master: master, pid: pid)
        run.listeners.insert(phone)
        terminals[terminalId] = run
        run.startReading(queue: DispatchQueue(label: "ccremote.terminal.\(terminalId.prefix(8))"), output: { [weak self] bytes in
            Task { await self?.terminalOutput(terminalId: terminalId, bytes: bytes) }
        }, closed: { [weak self] in
            Task { await self?.terminalClosedOutput(terminalId: terminalId) }
        })
        // Reap the shell when it exits (a blocking wait on its own thread; at most a handful exist).
        Thread.detachNewThread { [weak self] in
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) < 0 && errno == EINTR {}
            let code: Int32 = (raw & 0x7F) == 0 ? (raw >> 8) & 0xFF : -(raw & 0x7F)
            Task { await self?.terminalProcessExited(terminalId: terminalId, exitCode: code) }
        }
        log("terminal \(terminalId.prefix(8)) opened in \(cwd) (\(size.cols)×\(size.rows), pid \(pid))")
        broadcast(.terminals(items: listTerminals()))
    }

    public func attachTerminal(terminalId: String, phone: UUID, attached: Bool) {
        guard let run = terminals[terminalId] else {
            if attached { subscribers[phone]?(.terminalExited(terminalId: terminalId, exitCode: nil)) }
            return
        }
        if attached {
            run.listeners.insert(phone)
            // Replay what the shell has shown so far onto a cleared screen.
            let replay = Array("\u{1B}[H\u{1B}[2J".utf8) + run.tail
            subscribers[phone]?(.terminalOutput(terminalId: terminalId, dataBase64: Data(replay).base64EncodedString()))
            if !run.info.running { subscribers[phone]?(.terminalExited(terminalId: terminalId, exitCode: run.info.exitCode)) }
        } else {
            run.listeners.remove(phone)
        }
    }

    public func terminalInput(terminalId: String, data: [UInt8]) {
        guard let run = terminals[terminalId], run.info.running, !data.isEmpty else { return }
        run.write(data)
    }

    public func resizeTerminal(terminalId: String, cols: Int, rows: Int) {
        guard let run = terminals[terminalId], run.info.running else { return }
        let c = UInt16(clamping: max(20, cols)), r = UInt16(clamping: max(5, rows))
        guard Int(c) != run.info.cols || Int(r) != run.info.rows else { return }
        _ = ccr_pty_resize(run.master, c, r)
        run.info.cols = Int(c)
        run.info.rows = Int(r)
    }

    public func closeTerminal(terminalId: String) {
        guard let run = terminals[terminalId] else { return }
        if run.info.running {
            kill(run.pid, SIGHUP)
        } else {
            forgetTerminal(terminalId)
        }
    }

    public func listTerminals() -> [TerminalInfo] {
        terminals.values.map(\.info).sorted { $0.startedAt < $1.startedAt }
    }

    func detachAllTerminals(phone: UUID) {
        for run in terminals.values { run.listeners.remove(phone) }
    }

    func terminateAllTerminals() {
        for run in terminals.values where run.info.running { kill(run.pid, SIGHUP) }
    }

    private func terminalOutput(terminalId: String, bytes: [UInt8]) {
        guard let run = terminals[terminalId] else { return }
        run.remember(bytes)
        if let title = SessionManager.terminalTitle(in: bytes) { run.info.title = title }
        let encoded = Data(bytes).base64EncodedString()
        for phone in run.listeners { subscribers[phone]?(.terminalOutput(terminalId: terminalId, dataBase64: encoded)) }
    }

    private func terminalClosedOutput(terminalId: String) {
        terminals[terminalId]?.stopReading()
    }

    private func terminalProcessExited(terminalId: String, exitCode: Int32) {
        guard let run = terminals[terminalId] else { return }
        run.info.running = false
        run.info.exitCode = exitCode
        for phone in run.listeners { subscribers[phone]?(.terminalExited(terminalId: terminalId, exitCode: exitCode)) }
        log("terminal \(terminalId.prefix(8)) exited (\(exitCode))")
        forgetTerminal(terminalId)
    }

    private func forgetTerminal(_ terminalId: String) {
        guard let run = terminals.removeValue(forKey: terminalId) else { return }
        run.stopReading()
        systemClose(run.master)
        broadcast(.terminals(items: listTerminals()))
    }

    /// The window title a shell sets with OSC 0 / 2 (zsh and bash prompts often do).
    static func terminalTitle(in bytes: [UInt8]) -> String? {
        guard let start = bytes.lastIndex(of: 0x5D), start > 0, bytes[start - 1] == 0x1B,
              start + 2 < bytes.count, bytes[start + 1] == 0x30 || bytes[start + 1] == 0x32, bytes[start + 2] == 0x3B else { return nil }
        let body = bytes[(start + 3)...]
        guard let end = body.firstIndex(where: { $0 == 0x07 || $0 == 0x1B }) else { return nil }
        let title = String(decoding: body[..<end], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : String(title.prefix(80))
    }

    /// Hands C a NULL-terminated `char *[]` for the duration of `body`.
    static func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { for p in pointers { free(p) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
#endif
