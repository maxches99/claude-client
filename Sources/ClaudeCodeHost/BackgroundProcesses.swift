#if os(macOS)
import Foundation
import ClaudeRemoteCore

/// A command running on the Mac on its own: the process, what we know about it, and the tail of its
/// output kept for whoever attaches next. Unlike a one-shot `runCommand`, nothing about it depends on
/// the phone staying connected.
final class BackgroundRun {
    let process: Process
    var info: BackgroundProcess
    /// The last of the output, so a phone attaching later sees where things stand.
    private(set) var buffer = ""
    /// Phones currently watching the output live.
    var listeners: Set<UUID> = []

    static let bufferLimit = 256 * 1024

    init(process: Process, info: BackgroundProcess) {
        self.process = process
        self.info = info
    }

    func append(_ chunk: String) {
        buffer += chunk
        if buffer.count > BackgroundRun.bufferLimit {
            buffer = String(buffer.suffix(BackgroundRun.bufferLimit))
        }
        info.outputBytes += chunk.utf8.count
    }

    var tail: String { buffer }
}

extension SessionManager {
    /// Starts a command that keeps running after the phone leaves. Its output is buffered and
    /// streamed to every attached phone as ordinary `commandOutput` frames.
    public func startProcess(sessionId: String?, runId: String, command: String, label: String?, phone: UUID) throws {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitError.refused("The command is empty.") }
        guard processes[runId] == nil else { throw GitError.refused("That process is already running.") }
        let cwd = sessionId.flatMap { cwdFor($0) } ?? NSHomeDirectory()
        guard FileManager.default.fileExists(atPath: cwd) else { throw ManagerError.cwdMissing(cwd) }
        guard processes.values.filter({ $0.info.running }).count < 8 else {
            throw GitError.refused("Too many background processes are already running on the Mac.")
        }

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

        let info = BackgroundProcess(id: runId, command: trimmed, label: label, cwd: cwd, sessionId: sessionId)
        let run = BackgroundRun(process: p, info: info)
        run.listeners.insert(phone)

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { await self?.processOutput(runId: runId, chunk: text, done: false, exitCode: nil) }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            let code = proc.terminationReason == .uncaughtSignal ? -Int32(proc.terminationStatus) : proc.terminationStatus
            Task {
                if !rest.isEmpty { await self?.processOutput(runId: runId, chunk: String(decoding: rest, as: UTF8.self), done: false, exitCode: nil) }
                await self?.processOutput(runId: runId, chunk: "", done: true, exitCode: code)
            }
        }
        try p.run()
        processes[runId] = run
        log("background: \(label ?? "run") · \(trimmed.prefix(80))")
        broadcastProcesses()
    }

    /// Start or stop following a process. Attaching replays the buffered tail first, so the screen
    /// shows what already happened.
    public func attachProcess(runId: String, phone: UUID, attached: Bool) {
        guard let run = processes[runId] else { return }
        if attached {
            run.listeners.insert(phone)
            let tail = run.tail
            if !tail.isEmpty { subscribers[phone]?(.commandOutput(sessionId: run.info.sessionId ?? "", runId: runId, chunk: tail, done: false, exitCode: nil)) }
            if !run.info.running {
                subscribers[phone]?(.commandOutput(sessionId: run.info.sessionId ?? "", runId: runId, chunk: "", done: true, exitCode: run.info.exitCode))
            }
        } else {
            run.listeners.remove(phone)
        }
    }

    public func killProcess(runId: String) {
        guard let run = processes[runId], run.info.running else { return }
        run.process.terminate()
        log("background: terminated \(run.info.displayName.prefix(60))")
    }

    public func listProcesses() -> [BackgroundProcess] {
        processes.values.map(\.info).sorted { a, b in
            if a.running != b.running { return a.running }
            return a.startedAt > b.startedAt
        }
    }

    func detachAllProcesses(phone: UUID) {
        for run in processes.values { run.listeners.remove(phone) }
    }

    func broadcastProcesses() {
        broadcast(.processes(items: listProcesses()))
    }

    private func processOutput(runId: String, chunk: String, done: Bool, exitCode: Int32?) {
        guard let run = processes[runId] else { return }
        if !chunk.isEmpty { run.append(chunk) }
        let sessionId = run.info.sessionId ?? ""
        for phone in run.listeners {
            subscribers[phone]?(.commandOutput(sessionId: sessionId, runId: runId, chunk: chunk, done: done, exitCode: exitCode))
        }
        guard done else { return }
        run.info.running = false
        run.info.finishedAt = Date()
        run.info.exitCode = exitCode
        if let notifier, exitCode != 0, exitCode != -15 {
            notifier.notify(.error, body: "\(run.info.displayName) exited with \(exitCode.map(String.init) ?? "?")")
        }
        pruneFinishedProcesses()
        broadcastProcesses()
    }

    /// Finished runs stay around so their output can still be read — but not forever.
    private func pruneFinishedProcesses() {
        let finished = processes.values.filter { !$0.info.running }.sorted { ($0.info.finishedAt ?? .distantPast) > ($1.info.finishedAt ?? .distantPast) }
        let cutoff = Date().addingTimeInterval(-3600)
        for (i, run) in finished.enumerated() where i >= 8 || (run.info.finishedAt ?? .distantPast) < cutoff {
            processes[run.info.id] = nil
        }
    }

    /// Stops everything still running (daemon shutdown).
    func terminateAllProcesses() {
        for run in processes.values where run.info.running { run.process.terminate() }
    }
}
#endif
