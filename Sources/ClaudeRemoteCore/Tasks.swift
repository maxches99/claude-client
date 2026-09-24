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
    /// Commit the worktree started from — what "the task's changes" are measured against.
    public var baseCommit: String?
    /// The worktree's branch.
    public var branch: String?
    /// Commit, push and open a draft pull request when the task succeeds (worktree tasks only).
    public var openPullRequest: Bool
    public var pullRequestURL: String?
    /// The duel this task is one side of.
    public var duelId: String?
    /// Size of the change once finished (worktree tasks).
    public var diffStat: DiffStat?
    /// The project's tests, run in the worktree after the task (duels).
    public var check: TaskCheck?
    /// Codex reasoning effort for the task's session.
    public var effort: String?
    /// What a duel calls this side ("Opus", "GPT-5 high"); nil = the agent's name.
    public var label: String?
    /// The GitHub issue the task resolves; its pull request says `Fixes #…`.
    public var issue: IssueRef?
    /// Watch the pull request's CI and start a repair when it fails.
    public var fixCI: Bool
    /// The pull request's CI as the host last saw it.
    public var ci: TaskCI?
    /// A CI repair: the task whose pull request it fixes (it runs in that task's worktree).
    public var repairOf: String?

    public init(id: String = UUID().uuidString.lowercased(), title: String, prompt: String, cwd: String, agent: AgentKind = .claude,
                model: String? = nil, permissionMode: String? = nil, status: Status = .queued, sessionId: String? = nil,
                createdAt: Date = Date(), startedAt: Date? = nil, finishedAt: Date? = nil, resultSummary: String? = nil,
                error: String? = nil, runAt: Date? = nil, dailyAtMinutes: Int? = nil, inWorktree: Bool = false, worktreePath: String? = nil,
                openPullRequest: Bool = false, duelId: String? = nil, effort: String? = nil, label: String? = nil,
                issue: IssueRef? = nil, fixCI: Bool = false, repairOf: String? = nil) {
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
        self.openPullRequest = openPullRequest
        self.duelId = duelId
        self.effort = effort
        self.label = label
        self.issue = issue
        self.fixCI = fixCI
        self.repairOf = repairOf
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
        baseCommit = try c.decodeIfPresent(String.self, forKey: .baseCommit)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        openPullRequest = try c.decodeIfPresent(Bool.self, forKey: .openPullRequest) ?? false
        pullRequestURL = try c.decodeIfPresent(String.self, forKey: .pullRequestURL)
        duelId = try c.decodeIfPresent(String.self, forKey: .duelId)
        diffStat = try c.decodeIfPresent(DiffStat.self, forKey: .diffStat)
        check = try c.decodeIfPresent(TaskCheck.self, forKey: .check)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        issue = try c.decodeIfPresent(IssueRef.self, forKey: .issue)
        fixCI = try c.decodeIfPresent(Bool.self, forKey: .fixCI) ?? false
        ci = try c.decodeIfPresent(TaskCI.self, forKey: .ci)
        repairOf = try c.decodeIfPresent(String.self, forKey: .repairOf)
    }

    /// The name a duel screen or notification uses for this task's side.
    public var sideLabel: String { label ?? agent.label }

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

/// How big a change is: `git diff --shortstat`.
public struct DiffStat: Codable, Equatable, Sendable {
    public var files: Int
    public var insertions: Int
    public var deletions: Int

    public init(files: Int, insertions: Int, deletions: Int) {
        self.files = files
        self.insertions = insertions
        self.deletions = deletions
    }

    /// Parses " 3 files changed, 40 insertions(+), 2 deletions(-)".
    public static func parse(shortstat: String) -> DiffStat {
        func number(before word: String) -> Int {
            guard let range = shortstat.range(of: word) else { return 0 }
            let head = shortstat[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            return Int(head.split(separator: " ").last ?? "") ?? 0
        }
        return DiffStat(files: number(before: "file"), insertions: number(before: "insertion"), deletions: number(before: "deletion"))
    }

    public var label: String { "\(files) file\(files == 1 ? "" : "s") · +\(insertions) −\(deletions)" }
}

/// A command run against a task's result — the project's tests, for a duel.
public struct TaskCheck: Codable, Equatable, Sendable {
    public var command: String
    public var exitCode: Int32?
    /// The end of the output.
    public var outputTail: String
    public var timedOut: Bool

    public init(command: String, exitCode: Int32?, outputTail: String, timedOut: Bool = false) {
        self.command = command
        self.exitCode = exitCode
        self.outputTail = outputTail
        self.timedOut = timedOut
    }

    public var passed: Bool { exitCode == 0 && !timedOut }
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
    /// Commit, push and open a draft pull request for a finished worktree task.
    case openPullRequest
    /// Push a CI repair that is committed and waiting (`TaskCI.State.fixReady`) to the pull request.
    case pushFix
    /// Stop (or start) watching the pull request's CI.
    case toggleFixCI
}

/// The same prompt given to Claude and to Codex, each in its own worktree, and a judge's verdict on
/// which did it better — the project's tests, the size of the change and a blind review of both diffs.
public struct Duel: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// The two tasks are queued or running.
        case running
        /// Both finished; diffs, tests and the judge are being gathered.
        case judging
        case decided
        case failed

        public var label: String {
            switch self {
            case .running: return "Running"
            case .judging: return "Judging"
            case .decided: return "Decided"
            case .failed: return "Failed"
            }
        }
    }

    public var id: String
    public var title: String
    public var prompt: String
    public var cwd: String
    /// One task per contestant.
    public var taskIds: [String]
    public var judge: AgentKind
    public var status: Status
    public var verdict: DuelVerdict?
    public var error: String?
    /// The task whose result was kept (the other worktree is gone).
    public var keptTaskId: String?
    public var createdAt: Date
    public var decidedAt: Date?
    /// The blind labels the judge saw ("A" → task id), so the verdict maps back to the agents.
    public var blindLabels: [String: String]?

    public init(id: String = UUID().uuidString.lowercased(), title: String, prompt: String, cwd: String, taskIds: [String],
                judge: AgentKind = .claude, status: Status = .running, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.cwd = cwd
        self.taskIds = taskIds
        self.judge = judge
        self.status = status
        self.createdAt = createdAt
    }

    public var projectName: String { (cwd as NSString).lastPathComponent }
}

public struct DuelScore: Codable, Equatable, Sendable {
    /// 0…10 each.
    public var correctness: Double
    public var completeness: Double
    public var quality: Double
    public var tests: Double
    public var notes: String

    public init(correctness: Double, completeness: Double, quality: Double, tests: Double, notes: String = "") {
        self.correctness = correctness
        self.completeness = completeness
        self.quality = quality
        self.tests = tests
        self.notes = notes
    }

    /// Correctness counts double: a tidy change that does the wrong thing loses.
    public var total: Double { ((correctness * 2 + completeness + quality + tests) / 5 * 10).rounded() / 10 }
}

public struct DuelVerdict: Codable, Equatable, Sendable {
    /// The winning task, nil for a tie.
    public var winnerTaskId: String?
    /// Task id → score.
    public var scores: [String: DuelScore]
    public var summary: String
    /// The chat the judge ran in, to read its full reasoning.
    public var judgeSessionId: String?

    public init(winnerTaskId: String?, scores: [String: DuelScore], summary: String, judgeSessionId: String? = nil) {
        self.winnerTaskId = winnerTaskId
        self.scores = scores
        self.summary = summary
        self.judgeSessionId = judgeSessionId
    }
}

/// What the phone does with a duel.
public enum DuelAction: Codable, Equatable, Sendable {
    /// Keep one side: the other worktree and its branch are removed.
    case keep(taskId: String)
    /// Ask the judge again (after a failure, or with a different judge).
    case rejudge(judge: AgentKind)
    /// Remove the duel, its tasks and both worktrees.
    case delete
}
