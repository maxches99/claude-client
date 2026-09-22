import Foundation

/// A job queued for the Mac: a prompt, where to run it, and what became of it. The daemon starts a
/// session per task — one at a time, or several in parallel — so a list of chores typed on the phone
/// works itself off without anyone watching.
public struct AgentTask: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Waiting for a slot in the queue.
        case queued
        /// Waiting for its scheduled time.
        case scheduled
        case running
        case done
        case failed
        case cancelled

        public var label: String {
            switch self {
            case .queued: return "Queued"
            case .scheduled: return "Scheduled"
            case .running: return "Running"
            case .done: return "Done"
            case .failed: return "Failed"
            case .cancelled: return "Cancelled"
            }
        }

        public var isFinished: Bool { self == .done || self == .failed || self == .cancelled }
    }

    public var id: String
    public var title: String
    public var prompt: String
    public var cwd: String
    public var agent: AgentKind
    public var model: String?
    /// Claude: permission mode. Codex: approval policy. A task runs unattended, so the phone
    /// usually picks one that does not stop to ask.
    public var permissionMode: String?
    public var status: Status
    /// The session the daemon created for this task, once it started.
    public var sessionId: String?
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    /// The agent's last reply, trimmed — what the list shows when the task is done.
    public var resultSummary: String?
    public var error: String?
    /// When a scheduled task runs next (nil = as soon as a slot frees up).
    public var runAt: Date?
    /// Minutes since local midnight for a task that repeats every day.
    public var dailyAtMinutes: Int?
    /// Run in a fresh git worktree of `cwd` instead of the working tree, so parallel tasks don't collide.
    public var inWorktree: Bool
    /// The worktree the daemon made for it (so the phone can offer to remove it afterwards).
    public var worktreePath: String?

    public init(id: String = UUID().uuidString.lowercased(), title: String, prompt: String, cwd: String, agent: AgentKind = .claude,
                model: String? = nil, permissionMode: String? = nil, status: Status = .queued, sessionId: String? = nil,
                createdAt: Date = Date(), startedAt: Date? = nil, finishedAt: Date? = nil, resultSummary: String? = nil,
                error: String? = nil, runAt: Date? = nil, dailyAtMinutes: Int? = nil, inWorktree: Bool = false, worktreePath: String? = nil) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.cwd = cwd
        self.agent = agent
        self.model = model
        self.permissionMode = permissionMode
        self.status = status
        self.sessionId = sessionId
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.resultSummary = resultSummary
        self.error = error
        self.runAt = runAt
        self.dailyAtMinutes = dailyAtMinutes
        self.inWorktree = inWorktree
        self.worktreePath = worktreePath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        prompt = try c.decode(String.self, forKey: .prompt)
        cwd = try c.decode(String.self, forKey: .cwd)
        agent = try c.decodeIfPresent(AgentKind.self, forKey: .agent) ?? .claude
        model = try c.decodeIfPresent(String.self, forKey: .model)
        permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .queued
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        resultSummary = try c.decodeIfPresent(String.self, forKey: .resultSummary)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        runAt = try c.decodeIfPresent(Date.self, forKey: .runAt)
        dailyAtMinutes = try c.decodeIfPresent(Int.self, forKey: .dailyAtMinutes)
        inWorktree = try c.decodeIfPresent(Bool.self, forKey: .inWorktree) ?? false
        worktreePath = try c.decodeIfPresent(String.self, forKey: .worktreePath)
    }

    public var projectName: String { (cwd as NSString).lastPathComponent }
    public var repeats: Bool { dailyAtMinutes != nil }

    /// "09:30" for a daily task.
    public var dailyLabel: String? {
        guard let m = dailyAtMinutes else { return nil }
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    /// A title from the first line of the prompt when none was typed.
    public static func title(fromPrompt prompt: String) -> String {
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Task" }
        return trimmed.count > 80 ? String(trimmed.prefix(80)) + "…" : trimmed
    }
}

/// How the daemon works off the queue.
public struct TaskQueueSettings: Codable, Equatable, Sendable {
    /// How many tasks may run at once. 1 = strictly one after another.
    public var maxParallel: Int
    /// Nothing new is started while paused (running tasks finish).
    public var paused: Bool

    public init(maxParallel: Int = 1, paused: Bool = false) {
        self.maxParallel = maxParallel
        self.paused = paused
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxParallel = try c.decodeIfPresent(Int.self, forKey: .maxParallel) ?? 1
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
    }
}

/// Something the phone does to a task that already exists.
public enum TaskAction: String, Codable, Sendable {
    /// Jump the queue (and ignore a schedule) — start it now.
    case runNow
    /// Stop a running task (its session stays, interrupted) or drop it from the queue.
    case cancel
    /// Put a finished task back at the end of the queue.
    case retry
    case delete
}
