import XCTest
@testable import ClaudeCodeHost
@testable import ClaudeRemoteCore

/// The queue itself, driven through a SessionManager with no real CLI behind it: what starts, what
/// waits, what is written down, and what a restart makes of a task that was running.
final class TaskQueueTests: XCTestCase {
    private var directory: String!
    private var storePath: String { (directory as NSString).appendingPathComponent("tasks.json") }

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "ccremote-queue-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: directory)
    }

    /// A manager whose `claude` does not exist: a task that starts fails immediately, which is
    /// exactly the transition we want to watch without launching an agent.
    private func makeManager() -> SessionManager {
        SessionManager(cli: ClaudeCLI(path: "/nonexistent/claude"),
                       store: TranscriptStore(claudeHome: directory + "/claude-home"),
                       taskStore: storePath)
    }

    func testAQueuedTaskRunsAndRecordsWhyItFailed() async throws {
        let manager = makeManager()
        await manager.addTask(AgentTask(title: "Tests", prompt: "swift test", cwd: directory))
        let tasks = await manager.taskList().items
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].status, .failed, "there is no CLI to run, so the task fails instead of hanging in 'running'")
        XCTAssertNotNil(tasks[0].error)
        XCTAssertNotNil(tasks[0].finishedAt)
    }

    func testAScheduledTaskWaitsForItsTime() async throws {
        let manager = makeManager()
        var task = AgentTask(title: "Nightly", prompt: "run tests", cwd: directory)
        task.runAt = Date().addingTimeInterval(3600)
        await manager.addTask(task)
        let stored = await manager.taskList().items
        XCTAssertEqual(stored.first?.status, .scheduled, "an hour from now is not now")
        XCTAssertNil(stored.first?.sessionId)
    }

    func testARepeatingTaskThatCannotStartIsArmedAgainWithTheFailureInItsHistory() async throws {
        let manager = makeManager()
        var task = AgentTask(title: "Nightly", prompt: "run tests", cwd: directory + "/missing")
        task.repeatEveryMinutes = 60
        task.runAt = Date().addingTimeInterval(-1)
        await manager.addTask(task)
        let items = await manager.taskList().items
        let stored = try XCTUnwrap(items.first)
        XCTAssertEqual(stored.status, .scheduled, "one failed run does not end the schedule")
        XCTAssertEqual(stored.runs?.count, 1)
        XCTAssertEqual(stored.runs?.first?.outcome, .failed)
        XCTAssertGreaterThan(stored.runAt ?? .distantPast, Date().addingTimeInterval(50 * 60))
    }

    func testPausingSkippingAndResumingARepeatingTask() async throws {
        let manager = makeManager()
        var task = AgentTask(title: "Daily", prompt: "p", cwd: directory)
        task.dailyAtMinutes = 3 * 60
        await manager.addTask(task)
        let firstList = await manager.taskList().items
        let first = try XCTUnwrap(firstList.first?.runAt)

        await manager.performTaskAction(id: task.id, action: .skipNext)
        let skippedList = await manager.taskList().items
        let skipped = try XCTUnwrap(skippedList.first?.runAt)
        XCTAssertEqual(skipped.timeIntervalSince(first), 86_400, accuracy: 3_700, "the run after the skipped one is a day later")

        await manager.performTaskAction(id: task.id, action: .pause)
        let pausedList = await manager.taskList().items
        XCTAssertEqual(pausedList.first?.paused, true)
        await manager.performTaskAction(id: task.id, action: .resume)
        let resumedList = await manager.taskList().items
        let resumed = try XCTUnwrap(resumedList.first)
        XCTAssertFalse(resumed.paused)
        XCTAssertEqual(resumed.status, .scheduled)
    }

    func testAPausedRepeatingTaskDoesNotStartWhenDue() async throws {
        let manager = makeManager()
        var task = AgentTask(title: "Poll", prompt: "p", cwd: directory, repeatEveryMinutes: 60, paused: true)
        task.runAt = Date().addingTimeInterval(-60)
        await manager.addTask(task)
        let items = await manager.taskList().items
        let stored = try XCTUnwrap(items.first)
        XCTAssertEqual(stored.status, .scheduled)
        XCTAssertNil(stored.runs, "nothing ran")
    }

    func testPausedQueueStartsNothing() async throws {
        let manager = makeManager()
        await manager.setTaskSettings(TaskQueueSettings(maxParallel: 1, paused: true))
        await manager.addTask(AgentTask(title: "Later", prompt: "do it", cwd: directory))
        let stored = await manager.taskList().items
        XCTAssertEqual(stored.first?.status, .queued, "paused means queued, not started")
    }

    func testCancelAndDeleteTakeTasksOutOfTheQueue() async throws {
        let manager = makeManager()
        await manager.setTaskSettings(TaskQueueSettings(maxParallel: 1, paused: true))
        let task = AgentTask(title: "One", prompt: "a", cwd: directory)
        await manager.addTask(task)
        await manager.performTaskAction(id: task.id, action: .cancel)
        var stored = await manager.taskList().items
        XCTAssertEqual(stored.first?.status, .cancelled)

        await manager.performTaskAction(id: task.id, action: .retry)
        stored = await manager.taskList().items
        XCTAssertEqual(stored.first?.status, .queued, "a retry puts it back in line")

        await manager.performTaskAction(id: task.id, action: .delete)
        stored = await manager.taskList().items
        XCTAssertTrue(stored.isEmpty)
    }

    /// The queue lives in tasks.json, and a task that was running when the Mac app stopped is not
    /// left claiming to be running forever.
    func testQueueSurvivesARestartAndClearsStaleRunningTasks() async throws {
        let stale = AgentTask(title: "Interrupted", prompt: "long job", cwd: directory, status: .running,
                              sessionId: "session-1", startedAt: Date())
        let settings = TaskQueueSettings(maxParallel: 3, paused: true)
        struct Stored: Encodable { var tasks: [AgentTask]; var settings: TaskQueueSettings }
        let data = try ProtocolCoding.encoder.encode(Stored(tasks: [stale], settings: settings))
        try data.write(to: URL(fileURLWithPath: storePath))

        let manager = makeManager()
        // The manager loads its queue in a detached task at init.
        try await Task.sleep(nanoseconds: 300_000_000)
        let list = await manager.taskList()
        XCTAssertEqual(list.settings.maxParallel, 3)
        XCTAssertTrue(list.settings.paused)
        XCTAssertEqual(list.items.first?.status, .failed)
        XCTAssertEqual(list.items.first?.error, "The Mac app restarted while this task was running.")
    }
}
