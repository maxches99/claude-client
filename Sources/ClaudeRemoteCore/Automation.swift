import Foundation

// MARK: - GitHub issues → tasks

/// An open issue of the project's GitHub repository (`gh issue list`), to start a task from.
public struct GitHubIssue: Codable, Equatable, Identifiable, Sendable {
    public var number: Int
    public var title: String
    public var body: String
    public var url: String
    public var labels: [String]
    public var author: String?
    public var updatedAt: Date?
    public var id: Int { number }

    public init(number: Int, title: String, body: String = "", url: String, labels: [String] = [], author: String? = nil, updatedAt: Date? = nil) {
        self.number = number
        self.title = title
        self.body = body
        self.url = url
        self.labels = labels
        self.author = author
        self.updatedAt = updatedAt
    }

    /// What the agent is told: the issue as written, and that the change should close it.
    public var taskPrompt: String {
        var text = "Resolve GitHub issue #\(number): \(title)"
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { text += "\n\n" + (trimmed.count > 6000 ? String(trimmed.prefix(6000)) + "…" : trimmed) }
        text += "\n\n(\(url))"
        return text
    }
}

/// The issue a task works on; its pull request says `Fixes #number`.
public struct IssueRef: Codable, Equatable, Sendable {
    public var number: Int
    public var title: String
    public var url: String

    public init(number: Int, title: String, url: String) {
        self.number = number
        self.title = title
        self.url = url
    }
}

// MARK: - CI repair

/// Where a task's pull request stands with CI, as last seen by the host.
public struct TaskCI: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case pending, passing, failing
        /// A repair task is working on the failure.
        case repairing
        /// A repair is committed in the worktree and waits for "Push the fix".
        case fixReady
        /// Repairs ran out (see `attempts`); it needs a person now.
        case gaveUp
    }

    public var state: State
    /// The failing checks' names, when failing.
    public var failing: [String]
    /// The head commit the state is about (a new push resets the watch).
    public var headSha: String?
    public var attempts: Int
    /// The repair task working on it, when there is one.
    public var repairTaskId: String?
    public var checkedAt: Date

    public init(state: State, failing: [String] = [], headSha: String? = nil, attempts: Int = 0, repairTaskId: String? = nil, checkedAt: Date = Date()) {
        self.state = state
        self.failing = failing
        self.headSha = headSha
        self.attempts = attempts
        self.repairTaskId = repairTaskId
        self.checkedAt = checkedAt
    }

    public static let maxAttempts = 3

    public var label: String {
        switch state {
        case .pending: return "CI running"
        case .passing: return "CI passing"
        case .failing: return failing.isEmpty ? "CI failing" : "CI failing: " + failing.prefix(3).joined(separator: ", ")
        case .repairing: return "Fixing CI…"
        case .fixReady: return "CI fix ready to push"
        case .gaveUp: return "CI still failing after \(attempts) tries"
        }
    }

    /// The prompt for a repair: the failing checks and the end of their log.
    public static func repairPrompt(pullRequest: String, failing: [String], log: String) -> String {
        var text = "CI failed on the pull request \(pullRequest)"
        if !failing.isEmpty { text += " — failing checks: " + failing.joined(separator: ", ") }
        text += ".\n\nFix the cause in this working tree and make the checks pass. Do not push and do not open a pull request; the change is reviewed first."
        let tail = log.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            let cut = tail.count > 12_000 ? "…\n" + String(tail.suffix(12_000)) : tail
            text += "\n\nThe end of the failing log:\n\n```\n" + cut + "\n```"
        }
        return text
    }
}

// MARK: - Model duels

/// One side of a duel: an agent with a model and settings. A classic duel is Claude against Codex;
/// with contestants it can be two models (or two reasoning levels) of the same agent.
public struct DuelContestant: Codable, Equatable, Sendable {
    public var agent: AgentKind
    public var model: String?
    /// Codex reasoning effort.
    public var effort: String?
    /// Claude permission mode / Codex approval policy.
    public var mode: String?
    /// What the duel screen calls this side ("Opus", "GPT-5 high").
    public var label: String

    public init(agent: AgentKind, model: String? = nil, effort: String? = nil, mode: String? = nil, label: String) {
        self.agent = agent
        self.model = model
        self.effort = effort
        self.mode = mode
        self.label = label
    }
}

// MARK: - Prompt templates

/// A prompt with `{placeholders}`, from the project's `.ccremote.json` (`"templates"`) or the host's own
/// `templates.json`; the phone asks for each field and fills them in.
public struct PromptTemplate: Codable, Equatable, Identifiable, Sendable {
    public enum Scope: String, Codable, Sendable { case project, host }

    public var name: String
    public var prompt: String
    public var description: String?
    public var scope: Scope
    public var id: String { scope.rawValue + ":" + name }

    public init(name: String, prompt: String, description: String? = nil, scope: Scope) {
        self.name = name
        self.prompt = prompt
        self.description = description
        self.scope = scope
    }

    /// The placeholders in order of first appearance: `{screen name}` → "screen name". `{{` escapes.
    public var fields: [String] {
        var out: [String] = []
        var seen = Set<String>()
        let chars = Array(prompt)
        var i = 0
        while i < chars.count {
            if chars[i] == "{", i + 1 < chars.count, chars[i + 1] == "{" { i += 2; continue }
            if chars[i] == "{", let close = chars[(i + 1)...].firstIndex(of: "}") {
                let name = String(chars[(i + 1)..<close]).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !name.contains("{"), seen.insert(name).inserted { out.append(name) }
                i = close + 1
                continue
            }
            i += 1
        }
        return out
    }

    /// The prompt with each `{field}` replaced; unknown or empty fields stay as they are.
    public func filled(_ values: [String: String]) -> String {
        var result = prompt
        for field in fields {
            guard let value = values[field]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { continue }
            result = result.replacingOccurrences(of: "{\(field)}", with: value)
        }
        return result.replacingOccurrences(of: "{{", with: "{").replacingOccurrences(of: "}}", with: "}")
    }

    /// `"templates": [{"name": …, "prompt": …, "description": …}]` from a JSON object.
    public static func parse(_ json: JSONValue?, scope: Scope) -> [PromptTemplate] {
        (json?.array ?? []).compactMap { item in
            guard let name = item["name"]?.string?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  let prompt = item["prompt"]?.string, !prompt.isEmpty else { return nil }
            return PromptTemplate(name: name, prompt: prompt, description: item["description"]?.string, scope: scope)
        }
    }
}

// MARK: - Audit

/// One thing an agent did on the machine, with what makes it worth a second look.
public struct AuditEvent: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case command, write, delete, fetch, tool

        public var systemImage: String {
            switch self {
            case .command: return "terminal"
            case .write: return "pencil.line"
            case .delete: return "trash"
            case .fetch: return "globe"
            case .tool: return "puzzlepiece.extension"
            }
        }
    }

    public var id: String
    public var date: Date
    public var sessionId: String
    public var sessionTitle: String
    public var agent: AgentKind
    public var cwd: String
    public var kind: Kind
    /// The command, the path, the URL or query, or the tool's name.
    public var detail: String
    /// Why it stands out ("outside the project", "sudo", …); empty for the ordinary.
    public var flags: [String]

    public init(id: String, date: Date, sessionId: String, sessionTitle: String, agent: AgentKind, cwd: String, kind: Kind, detail: String, flags: [String]) {
        self.id = id
        self.date = date
        self.sessionId = sessionId
        self.sessionTitle = sessionTitle
        self.agent = agent
        self.cwd = cwd
        self.kind = kind
        self.detail = detail
        self.flags = flags
    }

    public var isFlagged: Bool { !flags.isEmpty }
}

public struct AuditReport: Codable, Equatable, Sendable {
    public var since: Date
    public var events: [AuditEvent]
    /// Events were left out past the limit.
    public var truncated: Bool

    public init(since: Date, events: [AuditEvent], truncated: Bool = false) {
        self.since = since
        self.events = events
        self.truncated = truncated
    }
}

/// Reads tool calls out of transcript entries (the same shape `DigestBuilder` reads) and marks the ones
/// worth a look: anything outside the project, privilege, destruction, the network, secrets.
public enum AuditBuilder {
    public static func events(entries: [JSONValue], since: Date, sessionId: String, title: String, agent: AgentKind, cwd: String) -> [AuditEvent] {
        var out: [AuditEvent] = []
        let root = (cwd as NSString).standardizingPath
        for entry in entries where entry["type"]?.string == "assistant" {
            guard let stamp = entry["timestamp"]?.string.flatMap(Transcript.parseDate), stamp > since else { continue }
            for block in entry["message"]?["content"]?.array ?? [] where block["type"]?.string == "tool_use" {
                let name = block["name"]?.string ?? ""
                let input = block["input"] ?? .object([:])
                let id = block["id"]?.string ?? UUID().uuidString
                var kind = AuditEvent.Kind.tool
                var detail = name
                var flags: [String] = []
                if name == "Bash" {
                    kind = .command
                    detail = input["command"]?.string ?? ""
                    flags = commandFlags(detail)
                } else if TurnChanges.writingTools.contains(name) || name == "Delete" {
                    kind = name == "Delete" ? .delete : .write
                    detail = input["file_path"]?.string ?? input["notebook_path"]?.string ?? ""
                    flags = pathFlags(detail, root: root)
                } else if name == "WebFetch" || name == "WebSearch" {
                    kind = .fetch
                    detail = input["url"]?.string ?? input["query"]?.string ?? ""
                } else if name.hasPrefix("mcp__") {
                    kind = .tool
                    detail = name.replacingOccurrences(of: "mcp__", with: "").replacingOccurrences(of: "__", with: " · ")
                } else {
                    continue   // reading, searching, planning: nothing happens to the machine
                }
                guard !detail.isEmpty else { continue }
                out.append(AuditEvent(id: sessionId + ":" + id, date: stamp, sessionId: sessionId, sessionTitle: title, agent: agent,
                                      cwd: cwd, kind: kind, detail: String(detail.prefix(2000)), flags: flags))
            }
        }
        return out
    }

    private static let commandRules: [(pattern: String, flag: String)] = [
        (#"(^|[;&|]\s*)sudo\b"#, "sudo"),
        (#"\brm\s+(-[a-zA-Z]*[rf][a-zA-Z]*\s+)+"#, "recursive delete"),
        (#"\b(curl|wget)\b[^|]*\|\s*(ba|z)?sh\b"#, "pipes a download into a shell"),
        (#"\b(curl|wget|scp|rsync|ssh|nc|ncat|ftp)\b"#, "network"),
        (#"\bgit\s+push\b[^\n]*(--force|-f\b)"#, "force push"),
        (#"\bgit\s+(reset\s+--hard|clean\s+-[a-z]*f)"#, "discards git work"),
        (#"\bchmod\s+(-R\s+)?[0-7]*7[0-7]{0,2}\b"#, "world-writable"),
        (#"\b(security\s+find-|keychain|\.ssh/|id_rsa|id_ed25519|\.aws/credentials|\.netrc)"#, "touches credentials"),
        (#"\b(launchctl\s+(load|unload|bootstrap|bootout|kickstart|enable|disable)|crontab\s+(-e|-r|\S+\.)|systemctl\s+(start|stop|restart|enable|disable|mask|daemon-reload)|defaults\s+write)\b"#, "changes system settings"),
        (#"\b(npm|pnpm|yarn)\s+(i|install|add)\s+-g\b|\bbrew\s+install\b|\bpip3?\s+install\b"#, "installs software"),
        (#"(^|\s)(>|>>)\s*/(etc|usr|System|Library)/"#, "writes system files"),
    ]

    /// `cat > file <<'EOF' … EOF`: what is written is data, not something that runs.
    private static let heredoc = try! NSRegularExpression(pattern: #"<<-?\s*['"]?(\w+)['"]?[^\n]*\n[\s\S]*?\n\s*\1\s*(\n|$)"#)

    public static func commandFlags(_ command: String) -> [String] {
        var flags: [String] = []
        let ns = command as NSString
        let command = heredoc.stringByReplacingMatches(in: command, range: NSRange(location: 0, length: ns.length), withTemplate: "<<$1\n")
        for rule in commandRules where command.range(of: rule.pattern, options: .regularExpression) != nil {
            if !flags.contains(rule.flag) { flags.append(rule.flag) }
        }
        // "pipes a download into a shell" already says "network".
        if flags.contains("pipes a download into a shell") { flags.removeAll { $0 == "network" } }
        return flags
    }

    public static func pathFlags(_ path: String, root: String) -> [String] {
        let full = (path as NSString).standardizingPath
        var flags: [String] = []
        let inProject = full == root || full.hasPrefix(root + "/")
        let scratch = full.hasPrefix("/tmp/") || full.hasPrefix("/private/tmp/") || full.hasPrefix("/var/folders/")
        if !inProject && !scratch { flags.append("outside the project") }
        let name = (full as NSString).lastPathComponent.lowercased()
        if name.hasPrefix(".env") || full.contains("/.ssh/") || name.hasSuffix(".pem") || name.hasSuffix(".key") || full.contains("/.aws/") {
            flags.append("secrets")
        }
        if full.contains("/.github/workflows/") { flags.append("CI configuration") }
        return flags
    }
}

// MARK: - Relay setup

/// Everything a Mac needs to join the relay: shown as a QR / link by a Mac that has it, and sent by the
/// phone to one that doesn't (`ccremote://relay?url=…&secret=…`).
public struct RelaySetup: Codable, Equatable, Sendable {
    public var url: String
    public var secret: String

    public init(url: String, secret: String) {
        self.url = url
        self.secret = secret
    }

    public var link: String {
        var c = URLComponents()
        c.scheme = "ccremote"
        c.host = "relay"
        c.queryItems = [URLQueryItem(name: "url", value: url), URLQueryItem(name: "secret", value: secret)]
        return c.string ?? "ccremote://relay"
    }

    public static func parse(_ text: String) -> RelaySetup? {
        guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == "ccremote", c.host == "relay" else { return nil }
        let items = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard let url = items["url"], url.hasPrefix("ws://") || url.hasPrefix("wss://"), let secret = items["secret"], !secret.isEmpty else { return nil }
        return RelaySetup(url: url, secret: secret)
    }
}

/// How phones reach the host through the relay, so a phone keeps its route current by itself.
public struct RelayRoute: Codable, Equatable, Sendable {
    public var url: String
    public var room: String

    public init(url: String, room: String) {
        self.url = url
        self.room = room
    }
}

// MARK: - GitHub on the host

public struct GitHubAccount: Codable, Equatable, Sendable {
    public var ghInstalled: Bool
    /// The logged-in GitHub user, nil when gh is not logged in.
    public var login: String?
    public var gitName: String?
    public var gitEmail: String?

    public init(ghInstalled: Bool, login: String? = nil, gitName: String? = nil, gitEmail: String? = nil) {
        self.ghInstalled = ghInstalled
        self.login = login
        self.gitName = gitName
        self.gitEmail = gitEmail
    }

    public var ready: Bool { login != nil && !(gitName ?? "").isEmpty && !(gitEmail ?? "").isEmpty }
}

/// A `gh auth login --web` in progress: the code to type at `url` in a browser on any device.
public struct GitHubLoginState: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case starting, waiting, done, failed }
    public var status: Status
    public var code: String?
    public var url: String?
    public var message: String?

    public init(status: Status, code: String? = nil, url: String? = nil, message: String? = nil) {
        self.status = status
        self.code = code
        self.url = url
        self.message = message
    }

    /// `! First copy your one-time code: ABCD-1234` → `ABCD-1234`.
    public static func oneTimeCode(in text: String) -> String? {
        guard let r = text.range(of: #"[A-Z0-9]{4}-[A-Z0-9]{4}"#, options: .regularExpression) else { return nil }
        return String(text[r])
    }
}

// MARK: - Host updates

public struct HostUpdate: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case upToDate, available, updating, failed
        /// This host cannot update itself (a build from source, a CLI install).
        case unsupported
    }

    public var state: State
    public var current: String
    public var latest: String?
    public var notesURL: String?
    public var message: String?

    public init(state: State, current: String, latest: String? = nil, notesURL: String? = nil, message: String? = nil) {
        self.state = state
        self.current = current
        self.latest = latest
        self.notesURL = notesURL
        self.message = message
    }

    /// `v1.2.10` > `1.2.9`; a pre-release tail is ignored.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            let core = v.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: "-").first.map(String.init) ?? ""
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

// MARK: - Voice approvals

/// A spoken answer to "allow this?" — yes / no in English or Russian, nil when it was neither.
public enum VoiceAnswer {
    private static let yes: Set<String> = ["yes", "yeah", "yep", "yup", "allow", "approve", "approved", "ok", "okay", "sure", "go",
                                           "да", "ага", "угу", "разреши", "разрешаю", "разрешить", "давай", "можно", "одобряю", "ок", "окей", "конечно"]
    private static let no: Set<String> = ["no", "nope", "deny", "denied", "stop", "don't", "dont", "cancel", "reject",
                                          "нет", "неа", "запрети", "запрещаю", "отказ", "стоп", "отмена", "отклонить", "нельзя"]

    public static func parse(_ text: String) -> Bool? {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        let joined = words.joined(separator: " ")
        // "не надо", "не разрешаю": a negation wins over the verb after it.
        if joined.contains("не надо") || joined.contains("не разреша") || joined.contains("don't allow") { return false }
        for word in words {
            if no.contains(word) { return false }
            if yes.contains(word) { return true }
        }
        return nil
    }
}
