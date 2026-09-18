#if os(macOS)
import Foundation
import ClaudeRemoteCore

/// Sessions currently running on this Mac, from `~/.claude/sessions/<pid>.json`
/// (written by every interactive `claude` process, including Claude Desktop's).
public struct LiveSessionRegistry: Sendable {
    public struct LiveSession: Sendable {
        public var pid: Int32
        public var sessionId: String
        public var cwd: String
        public var name: String?
        public var status: String?      // "idle" | "busy"
        public var entrypoint: String?
        public var updatedAt: Date
        public var messagingSocketPath: String?
    }

    public let directory: String

    public init(claudeHome: String = NSHomeDirectory() + "/.claude") {
        self.directory = claudeHome + "/sessions"
    }

    public func liveSession(id: String) -> LiveSession? {
        liveSessions().first { $0.sessionId == id }
    }

    public func liveSessions() -> [LiveSession] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        var result: [LiveSession] = []
        for file in files where file.hasSuffix(".json") {
            guard let data = fm.contents(atPath: directory + "/" + file), let json = try? JSONValue.parse(data),
                  let pid = json["pid"]?.int, let sessionId = json["sessionId"]?.string, let cwd = json["cwd"]?.string else { continue }
            guard kill(pid_t(pid), 0) == 0 else { continue }   // stale registry entry
            let updated = json["updatedAt"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
            result.append(LiveSession(pid: Int32(pid), sessionId: sessionId, cwd: cwd, name: json["name"]?.string,
                                      status: json["status"]?.string, entrypoint: json["entrypoint"]?.string, updatedAt: updated,
                                      messagingSocketPath: json["messagingSocketPath"]?.string))
        }
        return result
    }
}
#endif
