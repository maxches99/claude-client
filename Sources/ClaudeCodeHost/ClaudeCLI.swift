#if os(macOS)
import Foundation

/// Locates and describes the `claude` binary on this Mac.
public struct ClaudeCLI: Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    /// A Mac with Codex and no Claude CLI: the daemon still runs, Claude sessions are refused.
    public static let missing = ClaudeCLI(path: "")
    public var isInstalled: Bool { !path.isEmpty }

    /// Search order: explicit env override, the binary bundled with Claude Desktop
    /// (newest version), then the usual CLI install locations.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> ClaudeCLI? {
        let fm = FileManager.default
        // `none` runs the daemon with Codex alone even where Claude is installed.
        if environment["CCREMOTE_CLAUDE_PATH"] == "none" { return nil }
        if let override = environment["CCREMOTE_CLAUDE_PATH"], fm.isExecutableFile(atPath: override) {
            return ClaudeCLI(path: override)
        }
        let home = NSHomeDirectory()
        let desktopRoot = home + "/Library/Application Support/Claude/claude-code"
        if let versions = try? fm.contentsOfDirectory(atPath: desktopRoot) {
            let sorted = versions.filter { !$0.hasPrefix(".") }.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            for v in sorted {
                let candidate = "\(desktopRoot)/\(v)/claude.app/Contents/MacOS/claude"
                if fm.isExecutableFile(atPath: candidate) { return ClaudeCLI(path: candidate) }
            }
        }
        for candidate in [home + "/.claude/local/claude", home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"] {
            if fm.isExecutableFile(atPath: candidate) { return ClaudeCLI(path: candidate) }
        }
        return nil
    }

    /// Environment for child processes: inherit the shell, but drop variables a parent
    /// Claude Code session would leave behind (they make the CLI think it is nested).
    public static func childEnvironment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base.filter { key, _ in !key.hasPrefix("CLAUDE") && key != "BAGGAGE" && key != "AI_AGENT" }
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        return env
    }

    public func version() -> String? {
        run(["--version"]).flatMap { $0.split(separator: " ").first.map(String.init) }
    }

    public struct AuthStatus: Decodable, Sendable {
        public var loggedIn: Bool
        public var authMethod: String?
        public var email: String?
        public var subscriptionType: String?
    }

    public func authStatus() -> AuthStatus? {
        guard let out = run(["auth", "status"]), let data = out.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AuthStatus.self, from: data)
    }

    /// Runs a short CLI query. stdin is /dev/null: a child that inherits the terminal gets
    /// stopped by SIGTTIN when the daemon runs in a terminal, and we'd wait forever.
    private func run(_ args: [String], timeout: TimeInterval = 20) -> String? {
        guard isInstalled else { return nil }
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
        let reader = DispatchQueue(label: "ccremote.cli.query")
        let done = DispatchSemaphore(value: 0)
        reader.async {
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
