import Foundation
import ClaudeRemoteDaemon

/// The pre-app way of running ccremote: `scripts/install-launchagent.sh` wrote
/// `~/Library/LaunchAgents/dev.maxches.ccremote.plist` running `caffeinate -s ccremote --quiet …`.
/// Both can't own port 7811, so the app detects it, imports its flags into `config.json`, and
/// can unload it.
enum LegacyLaunchAgent {
    static let label = "dev.maxches.ccremote"
    static let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"

    struct Info: Equatable {
        /// Flags after the `ccremote` binary, e.g. `["--quiet", "--relay", "wss://…"]`.
        let flags: [String]
        /// The flags parsed on top of the saved config (so importing keeps anything already set).
        let config: DaemonConfig
        let isLoaded: Bool
    }

    static func detect() -> Info? {
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String],
              let binary = args.firstIndex(where: { ($0 as NSString).lastPathComponent == "ccremote" }) else { return nil }
        let flags = Array(args[(binary + 1)...])
        let config = (try? DaemonArguments.parse(flags, base: DaemonConfig.load()))?.config ?? DaemonConfig.load()
        return Info(flags: flags, config: config, isLoaded: isLoaded())
    }

    static func isLoaded() -> Bool {
        launchctl(["print", "gui/\(getuid())/\(label)"]) == 0
    }

    /// Unloads the agent and renames its plist to `.disabled` so it does not come back at login.
    static func disable() throws {
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        _ = launchctl(["unload", plistPath])
        let fm = FileManager.default
        if fm.fileExists(atPath: plistPath) {
            let disabled = plistPath + ".disabled"
            try? fm.removeItem(atPath: disabled)
            try fm.moveItem(atPath: plistPath, toPath: disabled)
        }
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
