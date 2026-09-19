#if os(macOS)
import Foundation

/// Locates and describes the `codex` binary on this Mac.
public struct CodexCLI: Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    /// Search order: explicit env override, the usual CLI install locations, then the binary the
    /// Codex desktop app bundles (it runs the very same `codex app-server` we do).
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> CodexCLI? {
        let fm = FileManager.default
        if let override = environment["CCREMOTE_CODEX_PATH"], fm.isExecutableFile(atPath: override) {
            return CodexCLI(path: override)
        }
        let home = NSHomeDirectory()
        var candidates = [home + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex", home + "/.npm-global/bin/codex"]
        for app in ["/Applications/Codex.app", home + "/Applications/Codex.app", "/Applications/ChatGPT.app", home + "/Applications/ChatGPT.app"] {
            candidates.append(app + "/Contents/Resources/codex")
        }
        return candidates.first(where: fm.isExecutableFile(atPath:)).map(CodexCLI.init(path:))
    }

    /// `codex-cli 0.150.0-alpha.8` → `0.150.0-alpha.8`.
    public func version() -> String? {
        run(["--version"]).flatMap { $0.split(separator: " ").last.map(String.init) }
    }

    /// Cheap login check: the CLI and the desktop app share `~/.codex/auth.json`.
    public static func hasCredentials(codexHome: String = NSHomeDirectory() + "/.codex") -> Bool {
        FileManager.default.fileExists(atPath: codexHome + "/auth.json")
    }

    /// Threads someone has open right now — the Codex app, another CLI, or our own app-server.
    ///
    /// Codex keeps one `<thread id>.lock` per open thread and holds a `flock` on it; the file is
    /// removed when the thread is closed. A stale file would still be lock-free, so we test the
    /// lock itself (taken and released immediately) rather than trusting the file's existence.
    public static func threadsOpenElsewhere(codexHome: String = NSHomeDirectory() + "/.codex") -> Set<String> {
        let directory = codexHome + "/thread-writer-locks"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        var open: Set<String> = []
        for name in names where name.hasSuffix(".lock") {
            let fd = Darwin.open(directory + "/" + name, O_RDONLY)
            guard fd >= 0 else { continue }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                flock(fd, LOCK_UN)          // nobody holds it: the thread is closed
            } else if errno == EWOULDBLOCK {
                open.insert(String(name.dropLast(5)))
            }
            Darwin.close(fd)
        }
        return open
    }

    /// Queues a message for a thread owned by another process (the Codex app picks it up).
    /// The only way to write into a session we do not host — like `PeerInbox` for Claude.
    public func queue(threadId: String, message: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["queue", "--thread", threadId, "--message", message]
        p.environment = ClaudeCLI.childEnvironment()
        p.standardInput = FileHandle.nullDevice
        let err = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        try p.run()
        let output = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let text = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw QueueError.failed(text.isEmpty ? "codex queue exited with status \(p.terminationStatus)" : text)
        }
    }

    public enum QueueError: Error, CustomStringConvertible {
        case failed(String)
        public var description: String {
            switch self { case .failed(let why): return why }
        }
    }

    private func run(_ args: [String], timeout: TimeInterval = 20) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.environment = ClaudeCLI.childEnvironment()
        let out = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        var data = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return nil
        }
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
