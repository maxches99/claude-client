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
    /// Minutes since local midnight for a task that repeats every day (or on `repeatWeekdays`).
    public var dailyAtMinutes: Int?
    /// With `dailyAtMinutes`: the days it runs on, as `Calendar` weekdays (1 = Sunday … 7 = Saturday).
    /// Nil or empty = every day.
    public var repeatWeekdays: [Int]?
    /// Runs again this many minutes after each run finishes (instead of at a time of day).
    public var repeatEveryMinutes: Int?
    /// A repeating task that is kept but not run until resumed.
    public var paused: Bool
    /// The last runs of a repeating task, newest last.
    public var runs: [TaskRun]?
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
    /// Take a Simulator screenshot before and after (the project's `"preview"` command).
    public var wantsPreview: Bool
    public var preview: TaskPreview?
    /// The working tree before a task that ran in it (not in a worktree), to put back in one tap.
    public var snapshot: TaskSnapshot?
    /// Ask for a plan first, and check the result against it afterwards.
    public var planFirst: Bool
    public var plan: [String]?
    public var planCheck: PlanCheck?
    /// Why it failed, in a few lines, written by a short review after the failure.
    public var postmortem: String?
    /// The person on the host who set it (nil = the owner).
    public var ownerId: String?
    /// Answer new review comments on its pull request with a follow-up change.
    public var answerReviews: Bool
    public var reviews: TaskReviews?
    /// A follow-up for review comments (with `repairOf`), not a CI repair.
    public var isReviewFollowUp: Bool

    /// How many runs a repeating task remembers.
    public static let runHistoryLimit = 20

    public init(id: String = UUID().uuidString.lowercased(), title: String, prompt: String, cwd: String, agent: AgentKind = .claude,
                model: String? = nil, permissionMode: String? = nil, status: Status = .queued, sessionId: String? = nil,
                createdAt: Date = Date(), startedAt: Date? = nil, finishedAt: Date? = nil, resultSummary: String? = nil,
                error: String? = nil, runAt: Date? = nil, dailyAtMinutes: Int? = nil, inWorktree: Bool = false, worktreePath: String? = nil,
                openPullRequest: Bool = false, duelId: String? = nil, effort: String? = nil, label: String? = nil,
                issue: IssueRef? = nil, fixCI: Bool = false, repairOf: String? = nil, wantsPreview: Bool = false, planFirst: Bool = false, answerReviews: Bool = false, isReviewFollowUp: Bool = false,
                repeatWeekdays: [Int]? = nil, repeatEveryMinutes: Int? = nil, paused: Bool = false) {
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
        self.wantsPreview = wantsPreview
        self.planFirst = planFirst
        self.answerReviews = answerReviews
        self.isReviewFollowUp = isReviewFollowUp
        self.repeatWeekdays = repeatWeekdays
        self.repeatEveryMinutes = repeatEveryMinutes
        self.paused = paused
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
        wantsPreview = try c.decodeIfPresent(Bool.self, forKey: .wantsPreview) ?? false
        preview = try c.decodeIfPresent(TaskPreview.self, forKey: .preview)
        snapshot = try c.decodeIfPresent(TaskSnapshot.self, forKey: .snapshot)
        planFirst = try c.decodeIfPresent(Bool.self, forKey: .planFirst) ?? false
        plan = try c.decodeIfPresent([String].self, forKey: .plan)
        planCheck = try c.decodeIfPresent(PlanCheck.self, forKey: .planCheck)
        postmortem = try c.decodeIfPresent(String.self, forKey: .postmortem)
        ownerId = try c.decodeIfPresent(String.self, forKey: .ownerId)
        answerReviews = try c.decodeIfPresent(Bool.self, forKey: .answerReviews) ?? false
        reviews = try c.decodeIfPresent(TaskReviews.self, forKey: .reviews)
        isReviewFollowUp = try c.decodeIfPresent(Bool.self, forKey: .isReviewFollowUp) ?? false
        repeatWeekdays = try c.decodeIfPresent([Int].self, forKey: .repeatWeekdays)
        repeatEveryMinutes = try c.decodeIfPresent(Int.self, forKey: .repeatEveryMinutes)
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        runs = try c.decodeIfPresent([TaskRun].self, forKey: .runs)
    }

    /// The name a duel screen or notification uses for this task's side.
    public var sideLabel: String { label ?? agent.label }

    public var projectName: String { (cwd as NSString).lastPathComponent }
    public var repeats: Bool { dailyAtMinutes != nil || repeatEveryMinutes != nil }

    /// "09:30" for a daily task.
    public var dailyLabel: String? {
        guard let m = dailyAtMinutes else { return nil }
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    /// The days a time-of-day task runs on, sorted; nil = every day.
    public var weekdays: [Int]? {
        guard let days = repeatWeekdays.map({ Array(Set($0.filter { (1...7).contains($0) })).sorted() }), !days.isEmpty, days.count < 7 else { return nil }
        return days
    }

    /// "Daily 09:30", "Weekdays 09:30", "Mon, Thu 18:00", "Every 2 h" — nil for a one-off task.
    public func scheduleLabel(calendar: Calendar = .current) -> String? {
        if let every = repeatEveryMinutes {
            if every % 60 == 0 { return every == 60 ? "Every hour" : "Every \(every / 60) h" }
            return "Every \(every) min"
        }
        guard let time = dailyLabel else { return nil }
        guard let days = weekdays else { return "Daily \(time)" }
        if days == [2, 3, 4, 5, 6] { return "Weekdays \(time)" }
        if days == [1, 7] { return "Weekends \(time)" }
        let symbols = calendar.shortWeekdaySymbols
        return days.map { symbols[$0 - 1] }.joined(separator: ", ") + " " + time
    }

    /// When a repeating task runs next after `now`: the next matching time of day (on its weekdays),
    /// or `repeatEveryMinutes` from now. Nil for a one-off task.
    public func nextRun(after now: Date = Date(), calendar: Calendar = .current) -> Date? {
        if let every = repeatEveryMinutes {
            return now.addingTimeInterval(TimeInterval(max(15, every) * 60))
        }
        guard let minutes = dailyAtMinutes else { return nil }
        return AgentTask.nextTime(minutes: minutes, weekdays: weekdays, after: now, calendar: calendar)
    }

    /// The next moment `minutes` past local midnight, today or later, on one of `weekdays` (nil = any day).
    public static func nextTime(minutes: Int, weekdays: [Int]?, after now: Date, calendar: Calendar = .current) -> Date {
        let clamped = min(max(0, minutes), 24 * 60 - 1)
        let startOfToday = calendar.startOfDay(for: now)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday),
                  let at = calendar.date(bySettingHour: clamped / 60, minute: clamped % 60, second: 0, of: day) else { continue }
            guard at > now else { continue }
            if let weekdays, !weekdays.contains(calendar.component(.weekday, from: at)) { continue }
            return at
        }
        return now.addingTimeInterval(86_400)
    }

    /// Adds a finished run to the history, keeping the newest `runHistoryLimit`.
    public mutating func record(_ run: TaskRun) {
        var list = runs ?? []
        list.append(run)
        runs = Array(list.suffix(AgentTask.runHistoryLimit))
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
    /// Put the working tree back as it was before the task (its snapshot).
    case restoreSnapshot
    /// Stop (or start) answering review comments on the pull request.
    case toggleAnswerReviews
    /// Keep a repeating task but stop running it (protocol 11).
    case pause
    case resume
    /// Leave out the next run of a repeating task; the one after goes ahead (protocol 11).
    case skipNext
}

/// One run of a repeating task, kept on it as history.
public struct TaskRun: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case done
        case failed
        /// Finished without changing anything (a worktree task with an empty diff) — no pull request.
        case noChanges
    }

    public var startedAt: Date?
    public var finishedAt: Date
    public var outcome: Outcome
    public var summary: String?
    public var sessionId: String?
    public var pullRequestURL: String?
    public var diffStat: DiffStat?

    public init(startedAt: Date?, finishedAt: Date, outcome: Outcome, summary: String? = nil, sessionId: String? = nil,
                pullRequestURL: String? = nil, diffStat: DiffStat? = nil) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.summary = summary
        self.sessionId = sessionId
        self.pullRequestURL = pullRequestURL
        self.diffStat = diffStat
    }
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
