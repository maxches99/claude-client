import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// MARK: - Plan check

/// How a finished task measured up to the plan it wrote before starting.
public struct PlanCheck: Codable, Equatable, Sendable {
    public struct Step: Codable, Equatable, Sendable {
        public enum Status: String, Codable, Sendable { case done, partial, missing }
        public var text: String
        public var status: Status
        public var note: String?

        public init(text: String, status: Status, note: String? = nil) {
            self.text = text
            self.status = status
            self.note = note
        }
    }

    public var steps: [Step]
    /// Changes the plan never mentioned.
    public var extras: [String]
    public var summary: String

    public init(steps: [Step], extras: [String] = [], summary: String = "") {
        self.steps = steps
        self.extras = extras
        self.summary = summary
    }

    public var doneCount: Int { steps.filter { $0.status == .done }.count }
}

/// Briefs and answers for the short tool-less chats that look at a task afterwards: did it follow its
/// plan, and why did it fail.
public enum TaskReview {
    /// What the task's prompt gets in front when "Plan first" is on.
    public static let planPreamble = """
    Before changing anything, write your plan as a numbered list under a line that says exactly "Plan:" \
    (one step per line, short). Then carry it out.

    """

    /// The numbered steps under "Plan:" in the agent's first reply.
    public static func extractPlan(_ text: String) -> [String]? {
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("plan:") }) else { return nil }
        var steps: [String] = []
        for line in lines[(start + 1)...] {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { if steps.isEmpty { continue } else { break } }
            guard let r = t.range(of: #"^(\d+[.)]|[-*•])\s+"#, options: .regularExpression) else { if steps.isEmpty { continue } else { break } }
            steps.append(String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces))
        }
        return steps.isEmpty ? nil : steps
    }

    public static func planBrief(task: String, plan: [String], diff: String, summary: String) -> String {
        var fence = "```"
        while diff.contains(fence) { fence += "`" }
        let numbered = plan.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let cut = diff.count > 60_000 ? String(diff.prefix(60_000)) + "\n… (cut)" : diff
        return """
        A coding task was done after its author wrote a plan. Check the change against the plan.

        Task:
        \(task)

        Plan:
        \(numbered)

        The author's summary (context only):
        \(summary.prefix(2000))

        The change:
        \(fence)diff
        \(cut)
        \(fence)

        For every plan step say whether the change does it: "done", "partial" or "missing", with a short note \
        when it is not plainly done. List changes the plan did not mention as "extras". Answer with one fenced \
        JSON block, nothing after it:
        ```json
        {"steps": [{"step": 1, "status": "done", "note": ""}], "extras": ["…"], "summary": "one or two sentences"}
        ```
        """
    }

    public static func parsePlanCheck(_ reply: String, plan: [String]) -> PlanCheck? {
        guard let json = lastJSON(reply) else { return nil }
        var steps: [PlanCheck.Step] = []
        for item in json["steps"]?.array ?? [] {
            let n = (item["step"]?.int ?? (steps.count + 1)) - 1
            let status = PlanCheck.Step.Status(rawValue: item["status"]?.string?.lowercased() ?? "") ?? .missing
            let note = item["note"]?.string.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            steps.append(PlanCheck.Step(text: plan.indices.contains(n) ? plan[n] : (item["text"]?.string ?? "Step \(n + 1)"), status: status, note: note))
        }
        // A step the reviewer skipped counts as not shown.
        for (i, text) in plan.enumerated() where !steps.contains(where: { $0.text == text }) && steps.count <= i {
            steps.append(PlanCheck.Step(text: text, status: .missing, note: "not assessed"))
        }
        return PlanCheck(steps: steps, extras: (json["extras"]?.array ?? []).compactMap(\.string), summary: json["summary"]?.string ?? "")
    }

    public static func postmortemBrief(task: String, error: String, transcriptTail: String, ciLog: String?) -> String {
        var text = """
        A coding task failed. Write a short post-mortem for the person who set it: what the agent tried, \
        where it got stuck and why, and what a human needs to do or decide to unblock it. At most eight \
        short lines, plain text, no preamble.

        Task:
        \(task)

        How it ended:
        \(error.prefix(2000))

        The end of the session:
        \(transcriptTail.suffix(12_000))
        """
        if let ciLog, !ciLog.isEmpty { text += "\n\nThe failing CI log (end):\n\(ciLog.suffix(8000))" }
        return text
    }

    public static func lastJSON(_ reply: String) -> JSONValue? {
        if let r = reply.range(of: #"```json\s*\n([\s\S]*?)\n```"#, options: [.regularExpression, .backwards]) {
            let block = String(reply[r]).replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
            if let v = try? JSONValue.parse(Data(block.utf8)) { return v }
        }
        guard let open = reply.firstIndex(of: "{"), let close = reply.lastIndex(of: "}"), open < close else { return nil }
        return try? JSONValue.parse(Data(reply[open...close].utf8))
    }
}

// MARK: - People on a host

/// Someone with their own pairing on a host. The owner sees everything; a member sees only the sessions,
/// chats and tasks they started, and works in their own folder of the workspace.
public struct HostUser: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var isOwner: Bool
    public var createdAt: Date
    public var lastSeenAt: Date?
    /// The member signed in their own Claude account (their token), so their limits are their own.
    public var ownClaudeLogin: Bool

    public init(id: String, name: String, isOwner: Bool, createdAt: Date = Date(), lastSeenAt: Date? = nil, ownClaudeLogin: Bool = false) {
        self.id = id
        self.name = name
        self.isOwner = isOwner
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.ownClaudeLogin = ownClaudeLogin
    }
}

// MARK: - Handing a session over

/// A session packed to continue somewhere else — another host of yours, or someone else's: its
/// transcript, and its repository's state (the remote, the branch's own commits as a git bundle, and the
/// uncommitted changes as a patch).
public struct SessionPackage: Codable, Equatable, Sendable {
    public static let fileExtension = "ccsession"

    public var version: Int
    public var agent: AgentKind
    public var title: String
    public var sessionId: String
    /// Where it ran; the transcript's paths are rewritten to wherever it lands.
    public var cwd: String
    public var remoteURL: String?
    public var branch: String?
    /// The commit the bundle's history starts from (on the remote).
    public var baseCommit: String?
    /// gzip-free, base64: the transcript file as it is on disk (JSONL).
    public var transcript: String
    public var gitBundle: String?
    public var patch: String?
    public var createdAt: Date
    public var from: String

    public init(version: Int = 1, agent: AgentKind, title: String, sessionId: String, cwd: String, remoteURL: String?, branch: String?,
                baseCommit: String?, transcript: String, gitBundle: String?, patch: String?, createdAt: Date = Date(), from: String) {
        self.version = version
        self.agent = agent
        self.title = title
        self.sessionId = sessionId
        self.cwd = cwd
        self.remoteURL = remoteURL
        self.branch = branch
        self.baseCommit = baseCommit
        self.transcript = transcript
        self.gitBundle = gitBundle
        self.patch = patch
        self.createdAt = createdAt
        self.from = from
    }

    /// The transcript without its inline images (screenshots run to megabytes each and are not needed to
    /// carry on); each becomes a short note.
    public static func strippingImages(_ jsonl: Data) -> Data {
        func strip(_ v: JSONValue) -> JSONValue {
            switch v {
            case .object(let o):
                if o["type"]?.string == "image", o["source"]?["type"]?.string == "base64" {
                    return .object(["type": .string("text"), "text": .string("[image left out when the session was handed over]")])
                }
                return .object(o.mapValues(strip))
            case .array(let a): return .array(a.map(strip))
            default: return v
            }
        }
        var out = Data()
        for line in jsonl.split(separator: 0x0A, omittingEmptySubsequences: true) {
            // Only lines with an image are rewritten; the rest go through byte for byte.
            if line.range(of: Data("\"base64\"".utf8)) != nil, let value = try? JSONValue.parse(Data(line)),
               let rewritten = try? strip(value).serialized() {
                out.append(rewritten)
            } else {
                out.append(line)
            }
            out.append(0x0A)
        }
        return out
    }

    /// `/old/path` → `/new/path` wherever it appears as a JSON string value in the transcript.
    public static func rewrite(transcript: String, from old: String, to new: String) -> String {
        guard old != new else { return transcript }
        let escapedOld = old.replacingOccurrences(of: "/", with: "\\/")
        let escapedNew = new.replacingOccurrences(of: "/", with: "\\/")
        return transcript.replacingOccurrences(of: "\"" + old, with: "\"" + new)
            .replacingOccurrences(of: "\"" + escapedOld, with: "\"" + escapedNew)
            .replacingOccurrences(of: " " + old + "/", with: " " + new + "/")
    }
}

// MARK: - Editing a file

public enum FileHash {
    /// Lowercase hex SHA-256 — how the phone says which version of a file it edited.
    public static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Review comments on a task's pull request

/// A comment someone left on a task's pull request (a line comment, a review, or a conversation comment).
public struct PRComment: Codable, Equatable, Sendable {
    public var id: String
    public var author: String
    public var body: String
    public var path: String?
    public var line: Int?
    public var createdAt: Date?

    public init(id: String, author: String, body: String, path: String? = nil, line: Int? = nil, createdAt: Date? = nil) {
        self.id = id
        self.author = author
        self.body = body
        self.path = path
        self.line = line
        self.createdAt = createdAt
    }
}

/// Where answering review comments on a task's pull request stands.
public struct TaskReviews: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case watching
        /// A follow-up task is working on the comments.
        case addressing
        /// Its change is committed and waits for "Push the fix".
        case fixReady
    }

    public var state: State
    /// Comments already handed to the agent (or there before the watch began).
    public var seen: [String]
    public var lastCount: Int
    public var followUpTaskId: String?

    public init(state: State = .watching, seen: [String] = [], lastCount: Int = 0, followUpTaskId: String? = nil) {
        self.state = state
        self.seen = seen
        self.lastCount = lastCount
        self.followUpTaskId = followUpTaskId
    }

    public var label: String {
        switch state {
        case .watching: return "Watching review comments"
        case .addressing: return "Addressing \(lastCount) review comment\(lastCount == 1 ? "" : "s")…"
        case .fixReady: return "Changes for \(lastCount) review comment\(lastCount == 1 ? "" : "s") ready to push"
        }
    }

    public static func prompt(pullRequest: String, comments: [PRComment]) -> String {
        var text = "Reviewers left comments on the pull request \(pullRequest). Address each one in this working tree. "
            + "Do not push and do not reply on GitHub; the change is reviewed first. If a comment asks for something you think is wrong, "
            + "leave the code as it is and say why in your final message.\n"
        for (i, c) in comments.enumerated() {
            var head = "\n\(i + 1). @\(c.author)"
            if let path = c.path { head += " on `\(path)`" + (c.line.map { " line \($0)" } ?? "") }
            text += head + ":\n" + c.body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(3000) + "\n"
        }
        return text
    }

    /// `gh api …/pulls/N/comments`, `…/issues/N/comments` and `gh pr view --json reviews` → comments,
    /// leaving out empty bodies and the host's own account.
    public static func parse(lineComments: JSONValue?, issueComments: JSONValue?, reviews: JSONValue?, me: String?) -> [PRComment] {
        let iso = ISO8601DateFormatter()
        var out: [PRComment] = []
        func add(_ id: String, _ author: String?, _ body: String?, path: String? = nil, line: Int? = nil, at: String?) {
            guard let body = body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty, let author, author != me else { return }
            out.append(PRComment(id: id, author: author, body: body, path: path, line: line, createdAt: at.flatMap { iso.date(from: $0) }))
        }
        for c in lineComments?.array ?? [] {
            add("line-\(c["id"]?.int ?? 0)", c["user"]?["login"]?.string, c["body"]?.string, path: c["path"]?.string,
                line: c["line"]?.int ?? c["original_line"]?.int, at: c["created_at"]?.string)
        }
        for c in issueComments?.array ?? [] {
            add("issue-\(c["id"]?.int ?? 0)", c["user"]?["login"]?.string, c["body"]?.string, at: c["created_at"]?.string)
        }
        for r in reviews?["reviews"]?.array ?? [] {
            add("review-\(r["id"]?.string ?? "")", r["author"]?["login"]?.string, r["body"]?.string, at: r["submittedAt"]?.string)
        }
        return out.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }
}
