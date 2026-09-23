#if os(macOS) || os(Linux)
import Foundation

/// Where ccremote keeps its own files, per platform.
public enum HostPaths {
    /// macOS: `~/Library/Application Support/ccremote`; Linux: `$XDG_CONFIG_HOME/ccremote` (default `~/.config/ccremote`).
    /// `CCREMOTE_SUPPORT_DIR` overrides both, so a second daemon (a development build) gets its own
    /// token, hook socket, task queue and config and cannot take over the running one's.
    public static let supportDirectory: String = {
        if let dir = ProcessInfo.processInfo.environment["CCREMOTE_SUPPORT_DIR"], !dir.isEmpty {
            return (dir as NSString).expandingTildeInPath
        }
        #if os(macOS)
        return NSHomeDirectory() + "/Library/Application Support/ccremote"
        #else
        let env = ProcessInfo.processInfo.environment
        let base = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/.config"
        return base + "/ccremote"
        #endif
    }()

    /// The login shell commands from the phone run in (`-lc`): zsh on the Mac, bash on Linux, where
    /// zsh usually isn't installed.
    public static var shell: String {
        #if os(macOS)
        return "/bin/zsh"
        #else
        return FileManager.default.isExecutableFile(atPath: "/bin/bash") ? "/bin/bash" : "/bin/sh"
        #endif
    }

    /// The name phones see for this machine when no `--name` is configured.
    public static var machineName: String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        let name = ProcessInfo.processInfo.hostName
        return name.isEmpty ? "Linux" : name
        #endif
    }
}
#endif
