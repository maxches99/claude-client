#if os(macOS)
import Foundation

/// Installs the daemon's `PermissionRequest` hook into `~/.claude/settings.json`, so permission
/// prompts of sessions the daemon does not host — Claude Desktop, a terminal — are offered to the
/// phone before the Mac shows its own dialog. The hook is a `curl` over the daemon's Unix socket
/// (see `HookServer`); when the daemon is not running the command exits quietly and the CLI prompts
/// as usual. Sessions pick hooks up at start, so ones already open keep prompting on the Mac.
public enum ClaudeHooks {
    public static let settingsPath = NSHomeDirectory() + "/.claude/settings.json"
    /// Where the daemon listens; `$HOME`-relative in the command so the settings file stays portable.
    public static let socketName = "hook.sock"
    static let marker = "ccremote/" + socketName

    public static func socketPath(supportDirectory: String) -> String {
        (supportDirectory as NSString).appendingPathComponent(socketName)
    }

    /// The shell line the CLI runs. `Expect:` is cleared so curl does not wait for a `100 Continue`
    /// on larger tool inputs; `exit 0` keeps a missing daemon from surfacing as a hook error.
    public static var command: String {
        let sock = "$HOME/Library/Application Support/" + marker
        return "S=\"\(sock)\"; [ -S \"$S\" ] && curl -s --max-time 595 -H 'Expect:' -H 'Content-Type: application/json' "
            + "--unix-socket \"$S\" --data-binary @- http://ccremote/permission-request; exit 0"
    }

    public enum HookError: Error, CustomStringConvertible {
        case malformed(String)
        public var description: String {
            switch self {
            case .malformed(let why): return "~/.claude/settings.json could not be read: \(why)"
            }
        }
    }

    /// True when our hook is in the settings file right now.
    public static func isInstalled(path: String = settingsPath) -> Bool {
        guard let settings = try? read(path: path) else { return false }
        return entries(in: settings).contains(where: isOurs)
    }

    public static func install(path: String = settingsPath) throws {
        var settings = try read(path: path)
        var list = entries(in: settings).filter { !isOurs($0) }
        list.append([
            "hooks": [[
                "type": "command",
                "command": command,
                "timeout": 600,
            ]],
        ])
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        hooks["PermissionRequest"] = list
        settings["hooks"] = hooks
        try write(settings, path: path)
    }

    public static func uninstall(path: String = settingsPath) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        var settings = try read(path: path)
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        let list = entries(in: settings).filter { !isOurs($0) }
        if list.isEmpty { hooks["PermissionRequest"] = nil } else { hooks["PermissionRequest"] = list }
        if hooks.isEmpty { settings["hooks"] = nil } else { settings["hooks"] = hooks }
        try write(settings, path: path)
    }

    // MARK: file

    private static func read(path: String) throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return [:] }
        let parsed: Any
        do { parsed = try JSONSerialization.jsonObject(with: data) } catch { throw HookError.malformed(error.localizedDescription) }
        guard let object = parsed as? [String: Any] else { throw HookError.malformed("top level is not an object") }
        return object
    }

    private static func write(_ settings: [String: Any], path: String) throws {
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func entries(in settings: [String: Any]) -> [[String: Any]] {
        ((settings["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]]) ?? []
    }

    /// A matcher group is ours when any of its commands talks to our socket.
    private static func isOurs(_ entry: [String: Any]) -> Bool {
        for hook in entry["hooks"] as? [[String: Any]] ?? [] {
            if let command = hook["command"] as? String, command.contains(marker) { return true }
        }
        return false
    }
}
#endif
