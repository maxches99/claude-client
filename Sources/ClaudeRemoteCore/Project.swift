import Foundation

/// One row of a directory listing under the session's project.
public struct DirectoryEntry: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var isDirectory: Bool
    public var size: Int?
    public var modifiedAt: Date?
    public var id: String { name }

    public init(name: String, isDirectory: Bool, size: Int? = nil, modifiedAt: Date? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

/// A line matching a project search (`git grep` / `grep -rn`).
public struct SearchMatch: Codable, Equatable, Identifiable, Sendable {
    /// Relative to the project root.
    public var path: String
    public var line: Int
    public var text: String
    public var id: String { "\(path):\(line)" }

    public init(path: String, line: Int, text: String) {
        self.path = path
        self.line = line
        self.text = text
    }
}

/// A shell command the phone can run in the project without the agent: from `.ccremote.json`
/// (`{"commands": [{"name": "Tests", "command": "swift test"}]}`) or guessed from what the project
/// looks like (a Package.swift, a package.json, …).
public struct ProjectCommand: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var command: String
    /// `repo` when it comes from `.ccremote.json`, `default` when guessed.
    public var source: String

    public init(id: String = UUID().uuidString.lowercased(), name: String, command: String, source: String = "default") {
        self.id = id
        self.name = name
        self.command = command
        self.source = source
    }
}

/// One CI check on a pull request, as `gh pr view` reports it.
public struct CheckRun: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    /// `COMPLETED`, `IN_PROGRESS`, `QUEUED`, `PENDING`… (GitHub's check status).
    public var status: String
    /// `SUCCESS`, `FAILURE`, `NEUTRAL`, `SKIPPED`, `CANCELLED`… once completed.
    public var conclusion: String?
    public var url: String?
    public var id: String { name }

    public init(name: String, status: String, conclusion: String? = nil, url: String? = nil) {
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.url = url
    }

    public var isDone: Bool { status == "COMPLETED" || conclusion != nil }
    public var isSuccess: Bool { ["SUCCESS", "NEUTRAL", "SKIPPED"].contains(conclusion ?? "") }
}

/// The pull request for the session's current branch.
public struct PullRequestInfo: Codable, Equatable, Sendable {
    public var number: Int
    public var title: String
    public var url: String
    /// `OPEN`, `MERGED`, `CLOSED`.
    public var state: String
    public var isDraft: Bool
    /// `APPROVED`, `CHANGES_REQUESTED`, `REVIEW_REQUIRED`, or empty.
    public var reviewDecision: String?
    /// `MERGEABLE`, `CONFLICTING`, `UNKNOWN`.
    public var mergeable: String?
    public var baseBranch: String?
    public var checks: [CheckRun]

    public init(number: Int, title: String, url: String, state: String, isDraft: Bool = false, reviewDecision: String? = nil,
                mergeable: String? = nil, baseBranch: String? = nil, checks: [CheckRun] = []) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.reviewDecision = reviewDecision
        self.mergeable = mergeable
        self.baseBranch = baseBranch
        self.checks = checks
    }

    public enum CIState: Equatable, Sendable { case none, pending, success, failure }

    /// The checks folded into one light: red if anything failed, yellow while anything runs.
    public var ciState: CIState {
        guard !checks.isEmpty else { return .none }
        if checks.contains(where: { $0.isDone && !$0.isSuccess }) { return .failure }
        if checks.contains(where: { !$0.isDone }) { return .pending }
        return .success
    }
}

/// A transcript that mentions a search query, with the line it was found on.
public struct SessionSearchHit: Codable, Equatable, Identifiable, Sendable {
    public var sessionId: String
    public var title: String
    public var cwd: String
    public var snippet: String
    public var updatedAt: Date
    public var agent: AgentKind
    public var id: String { sessionId }

    public init(sessionId: String, title: String, cwd: String, snippet: String, updatedAt: Date, agent: AgentKind = .claude) {
        self.sessionId = sessionId
        self.title = title
        self.cwd = cwd
        self.snippet = snippet
        self.updatedAt = updatedAt
        self.agent = agent
    }
}
