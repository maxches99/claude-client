import XCTest
@testable import ClaudeRemoteCore

/// When a repeating task runs next, how its schedule reads, and that old task JSON still decodes.
final class TaskScheduleTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US")
        return c
    }()

    /// Friday 2026-09-25 12:00 UTC.
    private var fridayNoon: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 12))! }

    func testWeekdayTaskSkipsTheWeekend() {
        var task = AgentTask(title: "Deps", prompt: "update", cwd: "/tmp")
        task.dailyAtMinutes = 9 * 60
        task.repeatWeekdays = [2, 3, 4, 5, 6]
        let next = task.nextRun(after: fridayNoon, calendar: calendar)!
        let parts = calendar.dateComponents([.day, .hour, .weekday], from: next)
        XCTAssertEqual(parts.weekday, 2, "Friday 09:00 has passed, so the next run is Monday")
        XCTAssertEqual(parts.day, 28)
        XCTAssertEqual(parts.hour, 9)
    }

    func testWeekdayTaskRunsLaterTodayWhenTodayMatches() {
        var task = AgentTask(title: "Report", prompt: "report", cwd: "/tmp")
        task.dailyAtMinutes = 18 * 60
        task.repeatWeekdays = [6]
        let next = task.nextRun(after: fridayNoon, calendar: calendar)!
        XCTAssertEqual(calendar.dateComponents([.day, .hour], from: next), DateComponents(day: 25, hour: 18))
    }

    func testIntervalTaskRunsAfterItsIntervalWithAFloor() {
        var task = AgentTask(title: "Poll", prompt: "poll", cwd: "/tmp")
        task.repeatEveryMinutes = 120
        XCTAssertEqual(task.nextRun(after: fridayNoon, calendar: calendar)!.timeIntervalSince(fridayNoon), 7200)
        task.repeatEveryMinutes = 1
        XCTAssertEqual(task.nextRun(after: fridayNoon, calendar: calendar)!.timeIntervalSince(fridayNoon), 15 * 60,
                       "an interval shorter than 15 minutes is raised to 15")
        XCTAssertTrue(task.repeats)
    }

    func testOneOffTaskHasNoNextRun() {
        let task = AgentTask(title: "Once", prompt: "once", cwd: "/tmp")
        XCTAssertNil(task.nextRun(after: fridayNoon, calendar: calendar))
        XCTAssertNil(task.scheduleLabel(calendar: calendar))
        XCTAssertFalse(task.repeats)
    }

    func testScheduleLabels() {
        var task = AgentTask(title: "T", prompt: "p", cwd: "/tmp")
        task.dailyAtMinutes = 9 * 60 + 30
        XCTAssertEqual(task.scheduleLabel(calendar: calendar), "Daily 09:30")
        task.repeatWeekdays = [2, 3, 4, 5, 6]
        XCTAssertEqual(task.scheduleLabel(calendar: calendar), "Weekdays 09:30")
        task.repeatWeekdays = [5, 2]
        XCTAssertEqual(task.scheduleLabel(calendar: calendar), "Mon, Thu 09:30")
        task.repeatWeekdays = Array(1...7)
        XCTAssertEqual(task.scheduleLabel(calendar: calendar), "Daily 09:30", "all seven days is every day")
        task.dailyAtMinutes = nil
        task.repeatEveryMinutes = 180
        XCTAssertEqual(task.scheduleLabel(calendar: calendar), "Every 3 h")
    }

    func testRunHistoryKeepsTheNewest() {
        var task = AgentTask(title: "T", prompt: "p", cwd: "/tmp")
        for i in 0..<(AgentTask.runHistoryLimit + 5) {
            task.record(TaskRun(startedAt: nil, finishedAt: Date(timeIntervalSince1970: Double(i)), outcome: .done))
        }
        XCTAssertEqual(task.runs?.count, AgentTask.runHistoryLimit)
        XCTAssertEqual(task.runs?.last?.finishedAt, Date(timeIntervalSince1970: Double(AgentTask.runHistoryLimit + 4)))
    }

    func testTaskFromAnOlderHostDecodesWithoutTheNewFields() throws {
        let json = #"{"id":"a","title":"Nightly","prompt":"p","cwd":"/tmp","status":"scheduled","dailyAtMinutes":420}"#
        let task = try ProtocolCoding.decoder.decode(AgentTask.self, from: Data(json.utf8))
        XCTAssertFalse(task.paused)
        XCTAssertNil(task.repeatWeekdays)
        XCTAssertNil(task.runs)
        XCTAssertTrue(task.repeats)
    }

    func testNewFieldsRoundTrip() throws {
        var task = AgentTask(title: "T", prompt: "p", cwd: "/tmp", repeatWeekdays: [2, 4], paused: true)
        task.dailyAtMinutes = 60
        task.record(TaskRun(startedAt: nil, finishedAt: Date(timeIntervalSince1970: 1_000), outcome: .noChanges,
                            pullRequestURL: "https://example.com/pr/1", diffStat: DiffStat(files: 0, insertions: 0, deletions: 0)))
        let back = try ProtocolCoding.decoder.decode(AgentTask.self, from: ProtocolCoding.encoder.encode(task))
        XCTAssertEqual(back.repeatWeekdays, [2, 4])
        XCTAssertTrue(back.paused)
        XCTAssertEqual(back.runs, task.runs)
    }
}
