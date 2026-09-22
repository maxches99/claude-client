import Foundation

/// "While you were away": what happened on a Mac since a moment the phone names — per session, what
/// the agent did (prompts it got, files it wrote, commands it ran, what went wrong, its last word),
/// plus the queue's finished tasks and the background processes that stopped.
public struct DigestItem: Codable, Equatable, Identifiable, Sendable {
    public var sessionId: String
    public var title: String
    public var cwd: String
    public var agent: AgentKind
    public var kind: SessionKind
    public var status: SessionStatus
    public var updatedAt: Date
    /// Prompts the session received in the window.
    public var prompts: Int
    /// Files the agent wrote, relative to the project where possible — the first few.
    public var files: [String]
    /// How many distinct files it wrote in total.
    public var fileCount: Int
    public var commands: Int
    /// Failed tool calls and failed turns.
    public var errors: Int
    /// The agent's latest reply, trimmed.
    public var lastReply: String?
    /// It is stopped on a question or an approval right now.
    public var waiting: Bool

    public var id: String { sessionId }
    public var projectName: String { (cwd as NSString).lastPathComponent }

    public init(sessionId: String, title: String, cwd: String, agent: AgentKind = .claude, kind: SessionKind = .agent,
                status: SessionStatus, updatedAt: Date, prompts: Int = 0, files: [String] = [], fileCount: Int = 0,
                commands: Int = 0, errors: Int = 0, lastReply: String? = nil, waiting: Bool = false) {
        self.sessionId = sessionId
        self.title = title
        self.cwd = cwd
        self.agent = agent
        self.kind = kind
        self.status = status
        self.updatedAt = updatedAt
        self.prompts = prompts
        self.files = files
        self.fileCount = fileCount
        self.commands = commands
        self.errors = errors
        self.lastReply = lastReply
        self.waiting = waiting
    }

    /// Anything worth a line in the digest (a session that was merely touched is not).
    public var isEventful: Bool { prompts > 0 || fileCount > 0 || commands > 0 || errors > 0 || waiting || lastReply != nil }
}

public struct DigestReport: Codable, Equatable, Sendable {
    public var since: Date
    public var generatedAt: Date
    public var sessions: [DigestItem]
    /// Tasks of the queue that finished (or failed) in the window.
    public var tasks: [AgentTask]
    /// Background processes that stopped in the window.
    public var processes: [BackgroundProcess]

    public init(since: Date, generatedAt: Date = Date(), sessions: [DigestItem] = [], tasks: [AgentTask] = [], processes: [BackgroundProcess] = []) {
        self.since = since
        self.generatedAt = generatedAt
        self.sessions = sessions
        self.tasks = tasks
        self.processes = processes
    }

    public var isEmpty: Bool { sessions.isEmpty && tasks.isEmpty && processes.isEmpty }
    public var waitingCount: Int { sessions.filter(\.waiting).count }
    public var errorCount: Int { sessions.reduce(0) { $0 + ($1.errors > 0 ? 1 : 0) } + tasks.filter { $0.status == .failed }.count }
}

/// Folds transcript entries into one session's digest line. The entries are the raw stream-json /
/// transcript shape (`user` / `assistant` / `result`), so the same code reads Claude transcripts on
/// disk and Codex rollouts translated into that shape.
public enum DigestBuilder {
    public static let fileSample = 6

    public static func summarize(entries: [JSONValue], since: Date, cwd: String) -> (prompts: Int, files: [String], fileCount: Int, commands: Int, errors: Int, lastReply: String?) {
        var prompts = 0, commands = 0, errors = 0
        var files: [String] = []
        var seen = Set<String>()
        var lastReply: String?
        let root = (cwd as NSString).standardizingPath
        for entry in entries {
            guard entry["isSidechain"]?.bool != true, entry["parent_tool_use_id"]?.string == nil else { continue }
            guard let stamp = entry["timestamp"]?.string.flatMap(Transcript.parseDate), stamp > since else { continue }
            switch entry["type"]?.string {
            case "user":
                if entry["isMeta"]?.bool == true { continue }
                let content = entry["message"]?["content"]
                if let text = content?.string, !Transcript.cleanUserText(text).isEmpty { prompts += 1; continue }
                var counted = false
                for block in content?.array ?? [] {
                    switch block["type"]?.string {
                    case "text":
                        if !counted, let text = block["text"]?.string, !Transcript.cleanUserText(text).isEmpty { prompts += 1; counted = true }
                    case "tool_result":
                        if block["is_error"]?.bool == true { errors += 1 }
                    default: break
                    }
                }
            case "assistant":
                for block in entry["message"]?["content"]?.array ?? [] {
                    switch block["type"]?.string {
                    case "text":
                        if let text = block["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { lastReply = text }
                    case "tool_use":
                        let name = block["name"]?.string ?? ""
                        let input = block["input"] ?? .object([:])
                        if TurnChanges.writingTools.contains(name) {
                            let path = input["file_path"]?.string ?? input["notebook_path"]?.string ?? ""
                            guard !path.isEmpty, seen.insert(path).inserted else { continue }
                            let full = (path as NSString).standardizingPath
                            files.append(full.hasPrefix(root + "/") ? String(full.dropFirst(root.count + 1)) : path)
                        } else if name == "Bash" {
                            commands += 1
                        }
                    default: break
                    }
                }
            case "result":
                if entry["is_error"]?.bool == true { errors += 1 }
            default:
                break
            }
        }
        let reply = lastReply.map { $0.count > 280 ? String($0.prefix(280)) + "…" : $0 }
        return (prompts, Array(files.prefix(fileSample)), files.count, commands, errors, reply)
    }
}
