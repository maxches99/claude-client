import Foundation

/// "Allow everything here for half an hour": a time-limited grant the host applies to permission
/// requests before they reach a phone. Scoped to one session or to a project folder (and everything
/// under it), optionally narrowed to one tool or a Bash command prefix.
public struct TrustGrant: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    /// One session, or nil for every session under `cwd`.
    public var sessionId: String?
    /// The project folder for a project-wide grant (also kept for a session grant, for display).
    public var cwd: String?
    /// nil = any tool; "Edit" = that tool; "Bash(git *)" = Bash commands starting with "git ".
    public var tool: String?
    public var createdAt: Date
    public var expiresAt: Date
    /// Who granted it (device label), for the list and the approval log.
    public var by: String?

    public init(id: String = UUID().uuidString.lowercased(), sessionId: String?, cwd: String?, tool: String?,
                createdAt: Date = Date(), expiresAt: Date, by: String? = nil) {
        self.id = id
        self.sessionId = sessionId
        self.cwd = cwd
        self.tool = tool
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.by = by
    }

    /// Tools that ask the person something rather than for permission — never answered by a grant.
    public static let needsAnswer: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    public func isExpired(now: Date = Date()) -> Bool { expiresAt <= now }

    /// Whether this grant answers a request from `sessionId` (running in `sessionCwd`) for `toolName`.
    public func covers(sessionId: String, sessionCwd: String?, toolName: String, input: JSONValue, now: Date = Date()) -> Bool {
        guard !isExpired(now: now), !Self.needsAnswer.contains(toolName) else { return false }
        if let own = self.sessionId {
            guard own == sessionId else { return false }
        } else {
            guard let cwd, let sessionCwd, Self.isWithin(sessionCwd, cwd) else { return false }
        }
        return Self.toolMatches(tool, toolName: toolName, input: input)
    }

    static func isWithin(_ path: String, _ folder: String) -> Bool {
        let folder = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        return path == folder || path.hasPrefix(folder + "/")
    }

    static func toolMatches(_ pattern: String?, toolName: String, input: JSONValue) -> Bool {
        guard let pattern, !pattern.isEmpty else { return true }
        guard let open = pattern.firstIndex(of: "("), pattern.hasSuffix(")") else { return pattern == toolName }
        guard String(pattern[..<open]) == toolName else { return false }
        let rule = String(pattern[pattern.index(after: open)..<pattern.index(before: pattern.endIndex)])
        let subject = input["command"]?.string ?? input["file_path"]?.string ?? input["url"]?.string ?? ""
        if rule.hasSuffix("*") {
            let prefix = rule.dropLast().trimmingCharacters(in: .whitespaces)
            // A chained command could smuggle anything past a prefix: only plain ones match.
            if toolName == "Bash", subject.contains(where: { ";&|`$\n".contains($0) }) { return false }
            return subject == prefix || subject.hasPrefix(prefix + " ") || (rule.hasSuffix(" *") ? false : subject.hasPrefix(prefix))
        }
        return subject == rule
    }

    /// "Bash(git *)" for a Bash request (its first word), else the tool's name.
    public static func suggestedTool(toolName: String, input: JSONValue) -> String {
        if toolName == "Bash", let command = input["command"]?.string,
           let first = command.split(separator: " ").first, !first.isEmpty {
            return "Bash(\(first) *)"
        }
        return toolName
    }

    /// "everything", "Edit", "git commands".
    public var toolLabel: String {
        guard let tool, !tool.isEmpty else { return "everything" }
        if tool.hasPrefix("Bash("), tool.hasSuffix(" *)") { return "`\(tool.dropFirst(5).dropLast(3))` commands" }
        return tool
    }
}
