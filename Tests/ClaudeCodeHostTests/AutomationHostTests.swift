import XCTest
import ClaudeRemoteCore
@testable import ClaudeCodeHost

final class AutomationHostTests: XCTestCase {
    func testCIReading() throws {
        let json = try JSONValue.parse(Data(#"""
        {"state":"OPEN","headRefOid":"abc","statusCheckRollup":[
          {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://github.com/o/r/actions/runs/123/job/9"},
          {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},
          {"__typename":"StatusContext","context":"deploy","state":"PENDING"}]}
        """#.utf8))
        let reading = SessionManager.readCI(json)
        XCTAssertTrue(reading.open)
        XCTAssertEqual(reading.head, "abc")
        XCTAssertEqual(reading.state, .failing)
        XCTAssertEqual(reading.failing.map(\.name), ["build"])
        XCTAssertEqual(reading.failing.first?.url.flatMap(SessionManager.actionsRunId), "123")

        let green = try JSONValue.parse(Data(#"{"state":"MERGED","headRefOid":"d","statusCheckRollup":[{"__typename":"CheckRun","name":"b","status":"COMPLETED","conclusion":"SUCCESS"}]}"#.utf8))
        let g = SessionManager.readCI(green)
        XCTAssertFalse(g.open)
        XCTAssertEqual(g.state, .passing)
        let running = try JSONValue.parse(Data(#"{"state":"OPEN","headRefOid":"d","statusCheckRollup":[{"__typename":"CheckRun","name":"b","status":"IN_PROGRESS"}]}"#.utf8))
        XCTAssertEqual(SessionManager.readCI(running).state, .pending)
    }

    func testIssueParsing() {
        let json = #"[{"number":7,"title":"T","body":"B","url":"https://github.com/o/r/issues/7","labels":[{"name":"bug"}],"author":{"login":"max"},"updatedAt":"2026-09-20T10:00:00Z"}]"#
        let issues = SessionManager.parseIssues(json)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].labels, ["bug"])
        XCTAssertEqual(issues[0].author, "max")
        XCTAssertNotNil(issues[0].updatedAt)
    }

    func testTemplatesFromProjectAndHost() async throws {
        let root = NSTemporaryDirectory() + "tpl-\(UUID().uuidString)"
        let project = root + "/proj", support = root + "/support"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try #"{"commands":[],"templates":[{"name":"Screen","prompt":"Add {name}"}]}"#.write(toFile: project + "/.ccremote.json", atomically: true, encoding: .utf8)
        try #"[{"name":"Review","prompt":"Review {area}"}]"#.write(toFile: support + "/templates.json", atomically: true, encoding: .utf8)
        let manager = SessionManager(cli: .missing, taskStore: support + "/tasks.json")
        let templates = await manager.templates(cwd: project)
        XCTAssertEqual(templates.map(\.name), ["Screen", "Review"])
        XCTAssertEqual(templates.map(\.scope), [.project, .host])
    }

    func testModelDuelMakesTwoLabelledSides() async throws {
        let repo = NSTemporaryDirectory() + "duel-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: repo) }
        for args in [["init", "-q"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"]] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = ["-C", repo] + args
            try p.run(); p.waitUntilExit()
        }
        // Claude "installed" at a path that never runs: the tasks are created paused, nothing starts.
        let manager = SessionManager(cli: ClaudeCLI(path: "/usr/bin/true"))
        await manager.setTaskSettings(TaskQueueSettings(maxParallel: 1, paused: true))
        let duel = try await manager.startDuel(title: "T", prompt: "p", cwd: repo, claudeMode: nil, codexPolicy: nil, judge: .claude,
                                               contestants: [DuelContestant(agent: .claude, model: "claude-opus-5", label: "Opus"),
                                                             DuelContestant(agent: .claude, model: "claude-opus-5", label: "Opus")])
        let tasks = await manager.taskList().items.filter { $0.duelId == duel.id }
        XCTAssertEqual(tasks.map(\.sideLabel), ["Opus A", "Opus B"])
        XCTAssertEqual(tasks.map(\.model), ["claude-opus-5", "claude-opus-5"])
        XCTAssertTrue(tasks.allSatisfy { $0.inWorktree })
    }
}
