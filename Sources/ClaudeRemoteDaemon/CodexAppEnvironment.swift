#if os(macOS)
import Foundation

/// Points the Codex desktop app at the daemon's shared app-server. The app reads
/// `CODEX_APP_SERVER_WS_URL` from its environment; for a GUI app that is launchd's user
/// environment, set with `launchctl setenv` — it applies to apps launched afterwards.
public enum CodexAppEnvironment {
    public static let variable = "CODEX_APP_SERVER_WS_URL"

    public static func url(port: UInt16) -> String { "ws://127.0.0.1:\(port)" }

    /// What launchd currently hands new apps, if anything.
    public static func current() -> String? {
        let r = run(["getenv", variable])
        let value = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.code == 0 && !value.isEmpty ? value : nil
    }

    @discardableResult
    public static func set(port: UInt16) -> String? {
        let r = run(["setenv", variable, url(port: port)])
        return r.code == 0 ? nil : r.err
    }

    @discardableResult
    public static func clear() -> String? {
        let r = run(["unsetenv", variable])
        return r.code == 0 ? nil : r.err
    }

    private static func run(_ args: [String]) -> (code: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return (-1, "", error.localizedDescription) }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }
}
#endif
