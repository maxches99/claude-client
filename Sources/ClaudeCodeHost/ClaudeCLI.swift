#if os(macOS) || os(Linux)
import Foundation

/// Locates and describes the `claude` binary on this Mac.
public struct ClaudeCLI: Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    /// Search order: explicit env override, the binary bundled with Claude Desktop
    /// (newest version), then the usual CLI install locations.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> ClaudeCLI? {
        let fm = FileManager.default
        if let override = environment["CCREMOTE_CLAUDE_PATH"], fm.isExecutableFile(atPath: override) {
            return ClaudeCLI(path: override)
        }
        let home = NSHomeDirectory()
        #if os(macOS)
        let desktopRoot = home + "/Library/Application Support/Claude/claude-code"
        if let versions = try? fm.contentsOfDirectory(atPath: desktopRoot) {
            let sorted = versions.filter { !$0.hasPrefix(".") }.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            for v in sorted {
                let candidate = "\(desktopRoot)/\(v)/claude.app/Contents/MacOS/claude"
                if fm.isExecutableFile(atPath: candidate) { return ClaudeCLI(path: candidate) }
            }
        }
        #endif
        let fixed = [home + "/.claude/local/claude", home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "/usr/bin/claude"]
        for candidate in fixed + pathCandidates(named: "claude", environment: environment) {
            if fm.isExecutableFile(atPath: candidate) { return ClaudeCLI(path: candidate) }
        }
        return nil
    }

    /// `<dir>/<name>` for every directory on `$PATH` (a systemd unit's PATH is short, so the
    /// fixed spots above still come first).
    static func pathCandidates(named name: String, environment: [String: String]) -> [String] {
        (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/" + name }
    }

    /// Environment for child processes: inherit the shell, but drop variables a parent
    /// Claude Code session would leave behind (they make the CLI think it is nested).
    public static func childEnvironment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        // Keep the headless-auth variables (a Linux hub logs in with `claude setup-token`).
        let keep: Set<String> = ["CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CONFIG_DIR"]
        var env = base.filter { key, _ in keep.contains(key) || (!key.hasPrefix("CLAUDE") && key != "BAGGAGE" && key != "AI_AGENT") }
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
