#if os(macOS)
import Foundation
import ClaudeRemoteCore

extension SessionManager {
    public struct Rewound: Sendable {
        public let newSessionId: String
        /// How many transcript entries were left behind.
        public let dropped: Int
    }

    /// Continues the conversation from just before `uuid`: the transcript is copied up to that entry
    /// into a new session, which is then resumed under the daemon. The original session and its
    /// transcript are untouched, and so are the files on disk — reverting those is the turn review's
    /// job, deliberately separate, because a rewind is about what the agent *knows*.
    public func rewind(sessionId: String, uuid: String) async throws -> Rewound {
        guard !isCodexThread(sessionId) else { throw ManagerError.spawnFailed("Codex threads cannot be rewound yet.") }
        guard let stored = store.session(id: sessionId) else { throw ManagerError.unknownSession(sessionId) }
        guard FileManager.default.fileExists(atPath: stored.cwd) else { throw ManagerError.cwdMissing(stored.cwd) }
        let newId = UUID().uuidString.lowercased()
        let cut = try SessionManager.writeRewound(from: stored.path, upTo: uuid, newSessionId: newId)
        var config = CLIProcess.Config(cliPath: try claudePath(), cwd: stored.cwd)
        config.resume = newId
        if let h = hosted[sessionId] {
            config.model = h.state.model
            config.permissionMode = h.state.permissionMode
        }
        let h = try spawn(sessionId: newId, config: config, origin: .host, kind: SessionManager.kind(cwd: stored.cwd))
        h.title = stored.title
        log("[\(sessionId.prefix(8))] rewound into \(newId.prefix(8)) (\(cut.dropped) entries dropped)")
        broadcast(.sessions(items: listSessions()))
        return Rewound(newSessionId: newId, dropped: cut.dropped)
    }

    /// Copies `path` into a sibling transcript for `newSessionId`, keeping the entries before the one
    /// with `uuid` (that entry — the prompt being taken back — goes too). Every kept entry's
    /// `sessionId` is rewritten so the CLI resumes it as its own session.
    static func writeRewound(from path: String, upTo uuid: String, newSessionId: String) throws -> (path: String, dropped: Int) {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw ManagerError.unknownSession(uuid)
        }
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        var cutIndex: Int?
        for (i, line) in lines.enumerated() {
            guard let entry = try? JSONValue.parse(line) else { continue }
            if entry["uuid"]?.string == uuid { cutIndex = i; break }
        }
        guard let cutIndex else { throw ManagerError.spawnFailed("That message is no longer in the transcript on the Mac.") }
        var out = Data()
        var kept = 0
        for line in lines[0..<cutIndex] {
            guard let entry = try? JSONValue.parse(line), var fields = entry.object else { continue }
            // Trailing bookkeeping entries point at messages that are about to be dropped.
            if let type = fields["type"]?.string, type == "last-prompt" || type == "queue-operation" { continue }
            fields["sessionId"] = .string(newSessionId)
            out.append(Data(JSONValue.object(fields).serializedString().utf8))
            out.append(0x0A)
            kept += 1
        }
        guard kept > 0 else { throw ManagerError.spawnFailed("Nothing is left before that message.") }
        let directory = (path as NSString).deletingLastPathComponent
        let destination = (directory as NSString).appendingPathComponent("\(newSessionId).jsonl")
        try out.write(to: URL(fileURLWithPath: destination))
        return (destination, lines.count - cutIndex)
    }
}
#endif
