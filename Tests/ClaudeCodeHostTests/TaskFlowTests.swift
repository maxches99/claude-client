import XCTest
@testable import ClaudeCodeHost
@testable import ClaudeRemoteCore

/// The git side of tasks, review, cloning and the digest clock, against real repositories.
final class TaskFlowTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "ccremote-flow-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    @discardableResult
    private func git(_ args: [String], in dir: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", dir] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeRepo(_ name: String) throws -> String {
        let dir = (root as NSString).appendingPathComponent(name)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        git(["init", "-q", "-b", "main"], in: dir)
        git(["config", "user.email", "test@example.com"], in: dir)
        git(["config", "user.name", "Test"], in: dir)
        try "one\ntwo\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        try "old\n".write(toFile: dir + "/old.txt", atomically: true, encoding: .utf8)
        git(["add", "."], in: dir)
        git(["commit", "-qm", "first"], in: dir)
        return dir
    }

    private func makeManager(workspace: String? = nil, taskStore: String? = nil) -> SessionManager {
        SessionManager(cli: ClaudeCLI(path: "/nonexistent/claude"), store: TranscriptStore(claudeHome: root + "/claude-home"),
                       taskStore: taskStore, workspaceRoot: workspace)
    }

    func testChangesCoverCommitsWorkingTreeUntrackedAndRenames() async throws {
        let repo = try makeRepo("repo")
        let base = git(["rev-parse", "HEAD"], in: repo)
        try "one\nTWO\nthree\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        git(["mv", "old.txt", "renamed.txt"], in: repo)
        git(["commit", "-qam", "second"], in: repo)
        try "fresh\nfile\n".write(toFile: repo + "/new.txt", atomically: true, encoding: .utf8)   // untracked

        let manager = makeManager()
        let result = manager.changes(in: repo, against: base)
        let byPath = Dictionary(uniqueKeysWithValues: result.files.map { ($0.path, $0) })
        XCTAssertEqual(byPath["a.txt"]?.status, "M")
        XCTAssertEqual(byPath["a.txt"]?.additions, 2)
        XCTAssertEqual(byPath["a.txt"]?.deletions, 1)
        XCTAssertEqual(byPath["new.txt"]?.status, "?", "an untracked file is part of the change")
        XCTAssertEqual(byPath["new.txt"]?.additions, 2)
        XCTAssertNotNil(byPath["renamed.txt"], "a rename is keyed by its new path: \(byPath.keys.sorted())")
        XCTAssertTrue(result.diff.contains("+three") && result.diff.contains("+fresh"))
        XCTAssertEqual(result.stat.files, 3)
        XCTAssertEqual(SessionManager.renamedPath("src/{old => new}/x.swift"), "src/new/x.swift")
        XCTAssertEqual(SessionManager.renamedPath("old.txt => renamed.txt"), "renamed.txt")
    }

    /// A worktree task that fails to start (no CLI here) still has its worktree; writing into it and
    /// asking for a pull request commits and pushes the branch — and stops, honestly, at GitHub.
    func testPullRequestCommitsAndPushesTheTaskBranch() async throws {
        let repo = try makeRepo("app")
        let bare = (root as NSString).appendingPathComponent("remote.git")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "init", "-q", "--bare", bare]
        try p.run(); p.waitUntilExit()
        git(["remote", "add", "origin", bare], in: repo)
        git(["push", "-q", "origin", "main"], in: repo)

        let manager = makeManager(taskStore: root + "/tasks.json")
        let task = AgentTask(title: "Uppercase the second line", prompt: "Make line two uppercase", cwd: repo, inWorktree: true, openPullRequest: true)
        await manager.addTask(task)
        let list = await manager.taskList().items
        let started = try XCTUnwrap(list.first)
        let worktree = try XCTUnwrap(started.worktreePath, "the worktree is made before the agent starts")
        XCTAssertEqual(started.baseCommit, git(["rev-parse", "HEAD"], in: repo))
        XCTAssertEqual(started.branch?.hasPrefix("task/"), true)

        // Nothing changed yet: no pull request.
        await manager.performTaskAction(id: task.id, action: .openPullRequest)
        var error = await manager.taskList().items.first?.error ?? ""
        XCTAssertTrue(error.contains("changed nothing"), error)

        try "one\nTWO\n".write(toFile: worktree + "/a.txt", atomically: true, encoding: .utf8)
        await manager.performTaskAction(id: task.id, action: .openPullRequest)
        error = await manager.taskList().items.first?.error ?? ""
        let branch = try XCTUnwrap(started.branch)
        XCTAssertEqual(git(["log", "-1", "--format=%s", branch], in: bare), "Uppercase the second line", "the branch reached the remote with the task's commit")
        XCTAssertTrue(git(["show", "\(branch):a.txt"], in: bare).contains("TWO"))
        XCTAssertFalse(error.isEmpty, "a local remote is not GitHub, so gh must fail — and say so")
    }

    func testCloningIntoTheWorkspaceMakesAProject() async throws {
        let source = try makeRepo("upstream-project")
        let workspace = (root as NSString).appendingPathComponent("work")
        let manager = makeManager(workspace: workspace)
        let path = try await manager.cloneRepository(source: "file://" + source)
        XCTAssertEqual(path, workspace + "/upstream-project")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/a.txt"))
        let again = try await manager.cloneRepository(source: "file://" + source)
        XCTAssertEqual(again, path, "cloning twice returns the existing checkout")
        let projects = await manager.listProjects()
        XCTAssertTrue(projects.contains { $0.path == path }, "a fresh clone is a project before any session ran in it")
    }

    func testClonePlans() {
        XCTAssertEqual(SessionManager.clonePlan("maxches99/claude-client")?.name, "claude-client")
        XCTAssertEqual(SessionManager.clonePlan("maxches99/claude-client")?.shorthand, "maxches99/claude-client")
        XCTAssertEqual(SessionManager.clonePlan("https://github.com/apple/swift-nio.git")?.shorthand, "apple/swift-nio")
        XCTAssertEqual(SessionManager.clonePlan("git@github.com:apple/swift-nio.git")?.name, "swift-nio")
        XCTAssertNil(SessionManager.clonePlan("rm -rf /"))
        XCTAssertNil(SessionManager.clonePlan("/etc/passwd"))
    }

    func testVerdictMapsBackAndFallsBackToTotals() {
        let parsed = DuelJudge.ParsedVerdict(winnerLabel: "B", scores: [
            "A": DuelScore(correctness: 9, completeness: 9, quality: 9, tests: 9),
            "B": DuelScore(correctness: 5, completeness: 5, quality: 5, tests: 5),
        ], summary: "")
        let mapped = SessionManager.resolveVerdict(parsed, labels: ["A": "codex-task", "B": "claude-task"])
        XCTAssertEqual(mapped.winner, "claude-task", "the judge's pick stands even if its numbers disagree")
        XCTAssertEqual(mapped.scores["codex-task"]?.correctness, 9)
        let offScript = DuelJudge.ParsedVerdict(winnerLabel: "Solution A", scores: parsed.scores, summary: "")
        XCTAssertEqual(SessionManager.resolveVerdict(offScript, labels: ["A": "x", "B": "y"]).winner, "x", "an unknown winner label falls back to the higher total")
        let tie = DuelJudge.ParsedVerdict(winnerLabel: nil, scores: parsed.scores, summary: "")
        XCTAssertNil(SessionManager.resolveVerdict(tie, labels: ["A": "x", "B": "y"]).winner)
    }

    func testDigestIsDueOncePerDayAfterItsTime() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let at = { (h: Int, m: Int) in cal.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: h, minute: m))! }
        var schedule = DigestSchedule(minutes: 9 * 60, lastSentAt: nil)
        XCTAssertNil(SessionManager.digestDue(schedule: schedule, now: at(8, 59), calendar: cal))
        XCTAssertEqual(SessionManager.digestDue(schedule: schedule, now: at(9, 0), calendar: cal), at(9, 0))
        schedule.lastSentAt = at(9, 1)
        XCTAssertNil(SessionManager.digestDue(schedule: schedule, now: at(10, 0), calendar: cal), "one digest a day")
        XCTAssertNil(SessionManager.digestDue(schedule: DigestSchedule(minutes: 9 * 60), now: at(22, 0), calendar: cal),
                     "a Mac asleep all day does not send the morning digest at night")
        XCTAssertNil(SessionManager.digestDue(schedule: DigestSchedule(minutes: nil), now: at(9, 30), calendar: cal))
    }

    func testTelegramFormBodyKeepsAmpersandsAndCyrillic() {
        let body = Notifier.formEncode(["text": "a &amp; b = c + d · Привет", "chat_id": "42"])
        XCTAssertEqual(body, "chat_id=42&text=a%20%26amp%3B%20b%20%3D%20c%20%2B%20d%20%C2%B7%20%D0%9F%D1%80%D0%B8%D0%B2%D0%B5%D1%82")
    }
}
