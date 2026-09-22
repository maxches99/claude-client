#if os(macOS)
import Foundation
import ClaudeRemoteCore

extension SessionManager {
    /// What happened since `since`: every session touched in the window with what its agent did,
    /// the queue's tasks that finished, and the background processes that stopped.
    public func digest(since: Date) -> DigestReport {
        let codexById = Dictionary(codexThreads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var items: [DigestItem] = []
        for summary in listSessions() where summary.updatedAt > since {
            var item = DigestItem(sessionId: summary.id, title: summary.title, cwd: summary.cwd, agent: summary.agent,
                                  kind: summary.kind, status: summary.status, updatedAt: summary.updatedAt)
            let entries: [JSONValue]
            if summary.agent == .codex {
                entries = codexById[summary.id]?.path.map { SessionManager.digestEntries(rollout: $0) } ?? []
            } else {
                entries = store.session(id: summary.id).map { SessionManager.digestEntries(transcript: $0.path) } ?? []
            }
            let facts = DigestBuilder.summarize(entries: entries, since: since, cwd: summary.cwd)
            item.prompts = facts.prompts
            item.files = facts.files
            item.fileCount = facts.fileCount
            item.commands = facts.commands
            item.errors = facts.errors
            item.lastReply = facts.lastReply
            item.waiting = summary.status == .awaitingPermission || hasHookPermission(sessionId: summary.id)
                || !(hosted[summary.id]?.pending.isEmpty ?? true)
            // A chat that was only looked at is not news.
            if summary.kind == .chat && item.prompts == 0 && !item.waiting { continue }
            if item.isEventful { items.append(item) }
        }
        items.sort { a, b in
            if a.waiting != b.waiting { return a.waiting }
            if (a.errors > 0) != (b.errors > 0) { return a.errors > 0 }
            return a.updatedAt > b.updatedAt
        }
        let finishedTasks = tasks.filter { ($0.finishedAt ?? .distantPast) > since }
            .sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
        let stopped = processes.values.map(\.info).filter { !$0.running && ($0.finishedAt ?? .distantPast) > since }
            .sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
        return DigestReport(since: since, sessions: Array(items.prefix(40)), tasks: finishedTasks, processes: stopped)
    }

    /// The tail of a Claude transcript — what happened lately is at the end, and a long session's
    /// file can run to tens of megabytes.
    static func digestEntries(transcript path: String, tailBytes: Int = 4 * 1024 * 1024) -> [JSONValue] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        var data = (try? handle.readToEnd()) ?? Data()
        if start > 0, let newline = data.firstIndex(of: 0x0A) { data = data[(newline + 1)...] }
        return data.split(separator: 0x0A).compactMap { try? JSONValue.parse(Data($0)) }
    }

    /// A Codex rollout, translated into the same entry shape as a Claude transcript.
    static func digestEntries(rollout path: String) -> [JSONValue] {
        var translator = CodexRollout()
        return SessionManager.readRollout(path: path).0.flatMap { translator.apply($0) }
    }
}
#endif
