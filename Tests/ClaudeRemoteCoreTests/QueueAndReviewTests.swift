import XCTest
@testable import ClaudeRemoteCore

/// The pieces the queue, the worktree screen, the turn review and the context meter are built on.
final class QueueAndReviewTests: XCTestCase {

    // MARK: worktrees

    func testWorktreeListParsesBranchesAndFlags() {
        let porcelain = """
        worktree /Users/me/repo
        HEAD 1234567890abcdef1234567890abcdef12345678
        branch refs/heads/main

        worktree /Users/me/repo-feature
        HEAD abcdefabcdefabcdefabcdefabcdefabcdefabcd
        branch refs/heads/feature/thing
        locked

        worktree /Users/me/repo-gone
        HEAD 0000000000000000000000000000000000000000
        detached
        prunable gitdir file points to non-existent location

        """
        let items = Worktree.parse(porcelain: porcelain)
        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(items[0].isMain, "the first record is the repository's own working tree")
        XCTAssertEqual(items[0].branch, "main")
        XCTAssertEqual(items[1].branch, "feature/thing")
        XCTAssertFalse(items[1].isMain)
        XCTAssertTrue(items[1].locked)
        XCTAssertNil(items[2].branch, "a detached worktree has no branch")
        XCTAssertEqual(items[2].head, "0000000")
        XCTAssertTrue(items[2].prunable)
        XCTAssertEqual(items[1].name, "repo-feature")
    }

    // MARK: turn review

    private func item(_ id: String, _ kind: TranscriptItem.Kind) -> TranscriptItem {
        TranscriptItem(id: id, kind: kind, timestamp: Date())
    }

    private func toolUse(_ id: String, _ name: String, _ input: [String: JSONValue]) -> TranscriptItem {
        item(id, .toolUse(id: id, name: name, input: .object(input), partialInput: "", streaming: false))
    }

    func testTurnsCollectWrittenFilesPerPrompt() {
        let items: [TranscriptItem] = [
            item("user:1", .user(text: "first", images: [])),
            toolUse("t1", "Read", ["file_path": .string("/repo/README.md")]),
            toolUse("t2", "Edit", ["file_path": .string("/repo/a.swift")]),
            toolUse("t3", "Bash", ["command": .string("swift build")]),
            toolUse("t4", "Write", ["file_path": .string("/repo/a.swift")]),
            item("turn:1", .turnEnd(summary: "done", isError: false)),
            item("user:2", .user(text: "second", images: [])),
            toolUse("t5", "NotebookEdit", ["notebook_path": .string("/repo/nb.ipynb")]),
        ]
        let turns = TurnChanges.turns(items)
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].paths, ["/repo/a.swift"], "a file written twice in one turn is listed once, and reads don't count")
        XCTAssertEqual(turns[0].commands, ["swift build"])
        XCTAssertFalse(turns[0].isCurrent, "a turn that ended is not the running one")
        XCTAssertEqual(turns[1].paths, ["/repo/nb.ipynb"])
        XCTAssertTrue(turns[1].isCurrent, "the last turn has no result yet")
    }

    func testReviewableSkipsTurnsThatWroteNothingAndIsNewestFirst() {
        let items: [TranscriptItem] = [
            item("user:1", .user(text: "just a question", images: [])),
            item("turn:1", .turnEnd(summary: "", isError: false)),
            item("user:2", .user(text: "now fix it", images: [])),
            toolUse("t1", "Edit", ["file_path": .string("/repo/b.swift")]),
        ]
        let reviewable = TurnChanges.reviewable(items)
        XCTAssertEqual(reviewable.count, 1)
        XCTAssertEqual(reviewable.first?.prompt, "now fix it")
    }

    func testRepoRelativeDropsPathsOutsideTheProject() {
        let paths = ["/repo/src/a.swift", "/elsewhere/b.swift", "/repo/README.md"]
        XCTAssertEqual(TurnChanges.repoRelative(paths, cwd: "/repo"), ["src/a.swift", "README.md"])
        XCTAssertEqual(TurnChanges.repoRelative(["/repo"], cwd: "/repo"), [], "the root itself is not a file in the repo")
    }

    // MARK: context window

    func testContextWindowLimitsAndThresholds() {
        XCTAssertEqual(ContextWindow.limit(model: "claude-sonnet-5"), 200_000)
        XCTAssertEqual(ContextWindow.limit(model: "claude-sonnet-5[1m]"), 1_000_000)
        XCTAssertEqual(ContextWindow.limit(model: nil), 200_000)
        XCTAssertEqual(ContextWindow.limit(model: "gpt-5-codex", agent: .codex), 272_000)

        let usage = ContextWindow.Usage(tokens: 150_000, limit: 200_000)
        XCTAssertEqual(usage.percentLabel, "75%")
        XCTAssertTrue(usage.isTight)
        XCTAssertFalse(usage.isCritical)
        XCTAssertEqual(usage.label, "150k / 200k")
        XCTAssertTrue(ContextWindow.Usage(tokens: 195_000, limit: 200_000).isCritical)

        // A watched session reports the plain model id even on the 1M window, so a count that cannot
        // fit in 200k tells us which window it really is — instead of pinning the meter at 100%.
        XCTAssertEqual(ContextWindow.limit(model: "claude-opus-5-20260401", observed: 340_000), 1_000_000)
        XCTAssertEqual(ContextWindow.limit(model: "claude-opus-5-20260401", observed: 120_000), 200_000)
    }

    /// The meter reads the latest assistant message's input tokens, and a compaction resets it.
    func testTranscriptTracksContextTokens() throws {
        var transcript = Transcript()
        transcript.apply(try JSONValue.parse(#"""
        {"type":"assistant","uuid":"a1","message":{"id":"m1","model":"claude-sonnet-5","content":[{"type":"text","text":"hi"}],
         "usage":{"input_tokens":1200,"cache_read_input_tokens":98000,"cache_creation_input_tokens":800,"output_tokens":40}}}
        """#))
        XCTAssertEqual(transcript.contextTokens, 100_000)
        transcript.apply(try JSONValue.parse(#"{"type":"system","subtype":"compact_boundary","uuid":"c1"}"#))
        XCTAssertEqual(transcript.contextTokens, 0, "after a compaction the window starts over")
    }

    // MARK: tasks

    func testTaskTitleFallsBackToTheFirstLineOfThePrompt() {
        XCTAssertEqual(AgentTask.title(fromPrompt: "Run the tests\nand fix what fails"), "Run the tests")
        XCTAssertEqual(AgentTask.title(fromPrompt: "   "), "Task")
        XCTAssertEqual(AgentTask.title(fromPrompt: String(repeating: "x", count: 100)).count, 81, "long titles are cut with an ellipsis")
    }

    func testTaskDailyLabelAndDecodingDefaults() throws {
        var task = AgentTask(title: "Nightly", prompt: "run tests", cwd: "/repo")
        task.dailyAtMinutes = 9 * 60 + 5
        XCTAssertEqual(task.dailyLabel, "09:05")
        XCTAssertTrue(task.repeats)

        // A task written by an older build has none of the newer fields.
        let sparse = try ProtocolCoding.decoder.decode(AgentTask.self, from: Data(#"{"id":"1","title":"t","prompt":"p","cwd":"/x"}"#.utf8))
        XCTAssertEqual(sparse.status, .queued)
        XCTAssertEqual(sparse.agent, .claude)
        XCTAssertFalse(sparse.inWorktree)
    }

    // MARK: protocol

    func testNewMessagesRoundTrip() throws {
        func client(_ m: ClientMessage) throws -> ClientMessage {
            try ProtocolCoding.decode(ClientMessage.self, from: ProtocolCoding.encode(m))
        }
        func server(_ m: ServerMessage) throws -> ServerMessage {
            try ProtocolCoding.decode(ServerMessage.self, from: ProtocolCoding.encode(m))
        }
        _ = try client(.rewind(sessionId: "s", uuid: "u"))
        _ = try client(.listPalette(sessionId: "s"))
        _ = try client(.worktreeAction(sessionId: "s", action: .add(name: "fix", branch: "fix", base: nil)))
        _ = try client(.startProcess(sessionId: "s", runId: "r", command: "npm run dev", label: "Dev server"))
        _ = try client(.attachProcess(runId: "r", attached: true))
        _ = try client(.setTaskSettings(settings: TaskQueueSettings(maxParallel: 2, paused: true)))

        // Dates travel as milliseconds, so they come back rounded — compare the fields that matter.
        let task = AgentTask(title: "Tests", prompt: "swift test", cwd: "/repo", model: "claude-sonnet-5",
                             permissionMode: "acceptEdits", dailyAtMinutes: 7 * 60, inWorktree: true)
        guard case .addTask(let back) = try client(.addTask(task: task)) else { return XCTFail("not addTask") }
        XCTAssertEqual(back.id, task.id)
        XCTAssertEqual(back.prompt, task.prompt)
        XCTAssertEqual(back.model, task.model)
        XCTAssertEqual(back.permissionMode, task.permissionMode)
        XCTAssertEqual(back.dailyAtMinutes, task.dailyAtMinutes)
        XCTAssertTrue(back.inWorktree)

        guard case .tasks(let items, let settings) = try server(.tasks(items: [task], settings: TaskQueueSettings(maxParallel: 3, paused: false))) else {
            return XCTFail("not tasks")
        }
        XCTAssertEqual(items.first?.id, task.id)
        XCTAssertEqual(settings.maxParallel, 3)

        let process = BackgroundProcess(id: "r", command: "npm run dev", label: "Dev", cwd: "/repo", sessionId: "s")
        guard case .processes(let running) = try server(.processes(items: [process])) else { return XCTFail("not processes") }
        XCTAssertEqual(running.first?.id, process.id)
        XCTAssertEqual(running.first?.label, "Dev")
        XCTAssertEqual(running.first?.running, true)

        let palette = PaletteItem(kind: .skill, name: "code-review", detail: "Review the diff", scope: .project)
        guard case .palette(_, let paletteItems) = try server(.palette(sessionId: "s", items: [palette])) else { return XCTFail("not palette") }
        XCTAssertEqual(paletteItems.first?.insert, "/code-review ")

        _ = try server(.worktrees(sessionId: "s", items: [Worktree(path: "/repo", branch: "main", isMain: true)], error: nil))
        _ = try server(.rewound(sessionId: "s", newSessionId: "s2", dropped: 4, error: nil))
    }
}
