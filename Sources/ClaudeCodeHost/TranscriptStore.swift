#if os(macOS)
import Foundation
import ClaudeRemoteCore

/// Reads Claude Code's on-disk transcripts (`~/.claude/projects/<encoded cwd>/<session id>.jsonl`).
public final class TranscriptStore: @unchecked Sendable {
    public struct StoredSession: Sendable {
        public var id: String
        public var path: String
        public var cwd: String
        public var title: String
        public var updatedAt: Date
        public var size: Int
    }

    public let projectsDirectory: String
    private let lock = NSLock()
    private var cache: [String: (mtime: Date, size: Int, session: StoredSession)] = [:]

    public init(claudeHome: String = NSHomeDirectory() + "/.claude") {
        self.projectsDirectory = claudeHome + "/projects"
    }

    private static let uuidPattern = try! NSRegularExpression(pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", options: .caseInsensitive)

    private static func isSessionFileName(_ name: String) -> Bool {
        guard name.hasSuffix(".jsonl") else { return false }
        let base = String(name.dropLast(6))
        return uuidPattern.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)) != nil
    }

    // MARK: listing

    public func allSessions() -> [StoredSession] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDirectory) else { return [] }
        var result: [StoredSession] = []
        for dir in projectDirs where !dir.hasPrefix(".") {
            let dirPath = projectsDirectory + "/" + dir
            guard let files = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }
            for file in files where TranscriptStore.isSessionFileName(file) {
                let path = dirPath + "/" + file
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mtime = attrs[.modificationDate] as? Date,
                      let size = (attrs[.size] as? NSNumber)?.intValue, size > 0 else { continue }
                if let cached = lock.withLock({ cache[path] }), cached.mtime == mtime, cached.size == size {
                    result.append(cached.session)
                    continue
                }
                guard let session = summarize(path: path, id: String(file.dropLast(6)), mtime: mtime, size: size) else { continue }
                lock.withLock { cache[path] = (mtime, size, session) }
                result.append(session)
            }
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func session(id: String) -> StoredSession? {
        allSessions().first { $0.id == id }
    }

    public func projects() -> [ProjectInfo] {
        var byPath: [String: (Date, Int)] = [:]
        for s in allSessions() {
            let cur = byPath[s.cwd] ?? (.distantPast, 0)
            byPath[s.cwd] = (max(cur.0, s.updatedAt), cur.1 + 1)
        }
        return byPath
            .filter { FileManager.default.fileExists(atPath: $0.key) }
            .map { ProjectInfo(path: $0.key, lastUsed: $0.value.0, sessionCount: $0.value.1) }
            .sorted { $0.lastUsed > $1.lastUsed }
    }

    /// Reads the head of the file to find cwd and the first real user prompt.
    private func summarize(path: String, id: String, mtime: Date, size: Int) -> StoredSession? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 1 << 20)
        var cwd: String?
        var firstPrompt: String?
        var customTitle: String?
        var aiTitle: String?
        func scan(_ data: Data) {
            for line in data.split(separator: 0x0A) {
                // Cheap prefilter: only title entries and the first real prompt matter here.
                let isTitle = line.starts(with: Data("{\"type\":\"custom-title\"".utf8)) || line.starts(with: Data("{\"type\":\"ai-title\"".utf8))
                if !isTitle && cwd != nil && firstPrompt != nil { continue }
                guard let entry = try? JSONValue.parse(line) else { continue }
                if cwd == nil, let c = entry["cwd"]?.string { cwd = c }
                switch entry["type"]?.string {
                case "custom-title": customTitle = entry["customTitle"]?.string ?? customTitle
                case "ai-title": aiTitle = entry["aiTitle"]?.string ?? aiTitle
                case "user":
                    if firstPrompt == nil, entry["isMeta"]?.bool != true, entry["isSidechain"]?.bool != true,
                       let text = TranscriptStore.userText(entry), !text.isEmpty {
                        firstPrompt = String(text.split(separator: "\n").first ?? "").trimmingCharacters(in: .whitespaces)
                    }
                default: break
                }
            }
        }
        scan(head)
        // Titles can be (re)written late in the file; check the tail too.
        if size > head.count {
            let tailLength = min(64 * 1024, size - head.count)
            try? handle.seek(toOffset: UInt64(size - tailLength))
            if let tail = try? handle.readToEnd() {
                if let firstNewline = tail.firstIndex(of: 0x0A) { scan(tail[(firstNewline + 1)...]) }
            }
        }
        guard let cwd else { return nil }
        var title = customTitle ?? aiTitle ?? firstPrompt ?? "(empty session)"
        if title.count > 120 { title = String(title.prefix(120)) + "…" }
        return StoredSession(id: id, path: path, cwd: cwd, title: title, updatedAt: mtime, size: size)
    }

    static func userText(_ entry: JSONValue) -> String? {
        guard let content = entry["message"]?["content"] else { return nil }
        if let s = content.string { return Transcript.cleanUserText(s) }
        let texts = content.array?.compactMap { block -> String? in
            guard block["type"]?.string == "text", let t = block["text"]?.string else { return nil }
            let cleaned = Transcript.cleanUserText(t)
            return cleaned.isEmpty ? nil : cleaned
        } ?? []
        return texts.first
    }

    // MARK: history

    public struct History: Sendable {
        public var entries: [JSONValue]
        public var endOffset: UInt64
    }

    /// Conversation entries (user / assistant / compaction markers) and the byte offset where reading stopped.
    public func history(path: String, limit: Int = 600) -> History {
        guard let data = FileManager.default.contents(atPath: path) else { return History(entries: [], endOffset: 0) }
        var entries: [JSONValue] = []
        // Only complete lines count; a writer may be mid-line.
        var end = data.count
        if let lastNewline = data.lastIndex(of: 0x0A) { end = lastNewline + 1 } else { end = 0 }
        for line in data[0..<end].split(separator: 0x0A) {
            guard let entry = try? JSONValue.parse(line), TranscriptStore.isConversationEntry(entry) else { continue }
            entries.append(entry)
        }
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        return History(entries: entries, endOffset: UInt64(end))
    }

    static func isConversationEntry(_ entry: JSONValue) -> Bool {
        switch entry["type"]?.string {
        case "user", "assistant":
            return entry["isSidechain"]?.bool != true
        case "system":
            return entry["subtype"]?.string == "compact_boundary"
        default:
            return false
        }
    }
}

/// Follows a transcript file that another process (Claude Desktop, a terminal) is writing.
public final class TranscriptTail: @unchecked Sendable {
    private let path: String
    private var offset: UInt64
    private var partial = Data()
    private let timer: DispatchSourceTimer
    private let onEntry: @Sendable (JSONValue) -> Void
    private let accepts: @Sendable (JSONValue) -> Bool

    /// `accepts` decides which lines are passed on; the default keeps Claude conversation entries,
    /// while a Codex rollout takes every line and translates it itself.
    public init(path: String, startOffset: UInt64, interval: TimeInterval = 0.5, queue: DispatchQueue = DispatchQueue(label: "ccremote.tail"),
                accepts: (@Sendable (JSONValue) -> Bool)? = nil,
                onEntry: @escaping @Sendable (JSONValue) -> Void) {
        self.path = path
        self.offset = startOffset
        self.onEntry = onEntry
        self.accepts = accepts ?? { TranscriptStore.isConversationEntry($0) }
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
    }

    deinit { timer.cancel() }

    public func stop() { timer.cancel() }

    private func poll() {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > offset else { return }
        try? handle.seek(toOffset: offset)
        guard let chunk = try? handle.readToEnd() else { return }
        offset += UInt64(chunk.count)
        partial.append(chunk)
        while let nl = partial.firstIndex(of: 0x0A) {
            let line = partial.subdata(in: partial.startIndex..<nl)
            partial.removeSubrange(partial.startIndex...nl)
            guard !line.isEmpty, let entry = try? JSONValue.parse(line), accepts(entry) else { continue }
            onEntry(entry)
        }
    }
}
#endif
