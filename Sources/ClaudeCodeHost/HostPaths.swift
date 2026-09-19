#if os(macOS) || os(Linux)
import Foundation

/// Where ccremote keeps its own files, per platform.
public enum HostPaths {
    /// macOS: `~/Library/Application Support/ccremote`; Linux: `$XDG_CONFIG_HOME/ccremote` (default `~/.config/ccremote`).
    public static let supportDirectory: String = {
        #if os(macOS)
        return NSHomeDirectory() + "/Library/Application Support/ccremote"
        #else
        let env = ProcessInfo.processInfo.environment
        let base = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/.config"
        return base + "/ccremote"
        #endif
    }()

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
