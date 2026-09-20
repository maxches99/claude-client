import XCTest
@testable import ClaudeRemoteCore

final class TranscriptLayoutTests: XCTestCase {
    private func json(_ s: String) -> JSONValue { try! JSONValue.parse(s) }

    private func transcript() -> Transcript {
        var t = Transcript()
        t.apply(json(#"{"type":"user","uuid":"u1","timestamp":"2026-09-19T10:00:00.000Z","message":{"role":"user","content":"fix the build"}}"#))
        t.apply(json(#"{"type":"assistant","timestamp":"2026-09-19T10:00:01.000Z","message":{"id":"m1","content":[{"type":"thinking","thinking":"hmm"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"swift build"}}]}}"#))
        t.apply(json(#"{"type":"user","timestamp":"2026-09-19T10:00:31.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok","is_error":false}]}}"#))
        t.apply(json(#"{"type":"assistant","timestamp":"2026-09-19T10:00:32.000Z","message":{"id":"m2","content":[{"type":"tool_use","id":"toolu_2","name":"Read","input":{"file_path":"/tmp/a.swift"}}]}}"#))
        t.apply(json(#"{"type":"user","timestamp":"2026-09-19T10:00:40.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_2","content":"boom","is_error":true}]}}"#))
        t.apply(json(#"{"type":"assistant","timestamp":"2026-09-19T10:00:45.000Z","message":{"id":"m3","content":[{"type":"text","text":"Done."}]}}"#))
        t.apply(json(#"{"type":"result","uuid":"r1","timestamp":"2026-09-19T10:00:45.500Z","is_error":false,"duration_ms":44500}"#))
        return t
    }

    func testStepsBetweenProseFoldIntoOneFinishedGroup() {
        let blocks = TranscriptLayout.blocks(for: transcript().items, sessionRunning: false)
        XCTAssertEqual(blocks.count, 3)
        guard case .user = blocks[0], case .activity(let group) = blocks[1], case .assistant = blocks[2] else { return XCTFail("\(blocks)") }
        XCTAssertFalse(group.isLive)
        XCTAssertEqual(group.steps.count, 3, "thinking + two tool calls; results are folded into their calls")
        XCTAssertEqual(group.toolCount, 2)
        XCTAssertTrue(group.hasThinking)
        XCTAssertEqual(group.duration ?? 0, 44, accuracy: 0.01, "first step at :01, closed by the text at :45")

        guard case .tool(let bash) = group.steps[1] else { return XCTFail() }
        XCTAssertEqual(bash.name, "Bash"); XCTAssertEqual(bash.resultText, "ok"); XCTAssertFalse(bash.running); XCTAssertFalse(bash.isError)
        guard case .tool(let read) = group.steps[2] else { return XCTFail() }
        XCTAssertEqual(read.resultText, "boom"); XCTAssertTrue(read.isError)
    }

    func testTrailingGroupIsLiveOnlyWhileTheSessionRuns() {
        var t = Transcript()
        t.apply(json(#"{"type":"user","uuid":"u1","message":{"role":"user","content":"go"}}"#))
        t.apply(json(#"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"toolu_1","name":"Grep","input":{"pattern":"x"}}]}}"#))

        let live = TranscriptLayout.blocks(for: t.items, sessionRunning: true)
        guard case .activity(let running)? = live.last else { return XCTFail() }
        XCTAssertTrue(running.isLive)
        // The live status now names the command being run, not just the tool.
        XCTAssertEqual(running.liveStatus, "Grep: x")

        let stopped = TranscriptLayout.blocks(for: t.items, sessionRunning: false)
        guard case .activity(let idle)? = stopped.last else { return XCTFail() }
        XCTAssertFalse(idle.isLive)
    }

    func testLateResultReachesAClosedGroupAndOrphansAreKept() {
        var t = Transcript()
        t.apply(json(#"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]}}"#))
        t.apply(json(#"{"type":"assistant","message":{"id":"m2","content":[{"type":"text","text":"meanwhile"}]}}"#))
        t.apply(json(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"a b","is_error":false}]}}"#))
        t.apply(json(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_unknown","content":"??","is_error":false}]}}"#))

        let blocks = TranscriptLayout.blocks(for: t.items, sessionRunning: false)
        XCTAssertEqual(blocks.count, 3)
        guard case .activity(let first) = blocks[0], case .tool(let bash) = first.steps[0] else { return XCTFail("\(blocks)") }
        XCTAssertEqual(bash.resultText, "a b", "a result arriving after the group closed still pairs with its call")
        guard case .activity(let last) = blocks[2], case .orphanResult(_, let text, _, _) = last.steps[0] else { return XCTFail("\(blocks)") }
        XCTAssertEqual(text, "??")
    }

    func testFailedTurnShowsAnErrorRowAndSuccessfulOnesShowNothing() {
        var t = Transcript()
        t.apply(json(#"{"type":"user","uuid":"u1","message":{"role":"user","content":"go"}}"#))
        t.apply(json(#"{"type":"result","uuid":"r1","is_error":false,"duration_ms":10}"#))
        t.apply(json(#"{"type":"result","uuid":"r2","is_error":true,"subtype":"error_during_execution","result":"rate limited"}"#))
        let blocks = TranscriptLayout.blocks(for: t.items, sessionRunning: false)
        XCTAssertEqual(blocks.count, 2)
        guard case .turnError = blocks[1] else { return XCTFail("\(blocks)") }
    }

    func testFinishedGroupTitlesReadLikeTheDesktopTranscript() {
        let blocks = TranscriptLayout.blocks(for: transcript().items, sessionRunning: false)
        guard case .activity(let group) = blocks[1] else { return XCTFail("\(blocks)") }
        XCTAssertEqual(group.title, "Ran a command, read a file")

        func step(_ name: String, _ input: String) -> ToolStep {
            ToolStep(id: name, toolUseId: name, name: name, input: json(input), partialInput: "", running: false,
                     resultText: "", isError: false, resultImages: [], startedAt: nil)
        }
        XCTAssertEqual(ActivitySummary.finished([step("Bash", #"{"command":"ls"}"#), step("Bash", #"{"command":"pwd"}"#)]), "Ran 2 commands")
        XCTAssertEqual(ActivitySummary.finished([step("Bash", #"{"command":"ls","description":"list the sources."}"#)]), "List the sources",
                       "a lone described command reads as its description")
        XCTAssertEqual(ActivitySummary.finished([
            step("Bash", "{}"), step("Edit", #"{"file_path":"/a.swift"}"#), step("Grep", "{}"),
            step("Bash", #"{"command":"cat /Users/me/.claude/projects/x/memory/notes.md"}"#), step("Bash", "{}"),
        ]), "Recalled a memory, ran 2 commands, edited a file, searched the codebase",
                       "phrases come in a fixed order, and `cat` of a memory file counts as recalling it")
        XCTAssertEqual(ActivitySummary.finished([step("mcp__Figma__get_metadata", "{}")]), "Used get_metadata")
    }

    func testLiveGroupTitleNamesTheCurrentStep() {
        var t = Transcript()
        t.apply(json(#"{"type":"user","uuid":"u1","message":{"role":"user","content":"go"}}"#))
        t.apply(json(#"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]}}"#))
        guard case .activity(let running)? = TranscriptLayout.blocks(for: t.items, sessionRunning: true).last else { return XCTFail() }
        XCTAssertEqual(running.title, "Running a command")
        XCTAssertEqual(running.phase, "Running tools…")

        t.apply(json(#"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"toolu_2","name":"Read","input":{"file_path":"/a"}}]}}"#))
        guard case .activity(let two)? = TranscriptLayout.blocks(for: t.items, sessionRunning: true).last else { return XCTFail() }
        XCTAssertEqual(two.title, "Running 2 tools".replacingOccurrences(of: "tools", with: "commands"),
                       "parallel calls are counted by the first one's kind")

        t.apply(json(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"}]}}"#))
        t.apply(json(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_2","content":"ok"}]}}"#))
        t.apply(json(#"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m2"}}}"#))
        t.apply(json(#"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}}"#))
        guard case .activity(let thinking)? = TranscriptLayout.blocks(for: t.items, sessionRunning: true).last else { return XCTFail() }
        XCTAssertEqual(thinking.title, "Thinking…")
        XCTAssertEqual(thinking.phase, "Thinking…")

        t.apply(json(#"{"type":"stream_event","event":{"type":"content_block_stop","index":0}}"#))
        guard case .activity(let idle)? = TranscriptLayout.blocks(for: t.items, sessionRunning: true).last else { return XCTFail() }
        XCTAssertEqual(idle.title, "Ran a command, read a file", "between steps the live row shows what is done so far")
        XCTAssertEqual(idle.phase, "Working…")
    }

    func testTurnClockAndTokensResetOnEachPrompt() {
        var t = Transcript()
        t.apply(json(#"{"type":"user","uuid":"u1","timestamp":"2026-09-19T10:00:00.000Z","message":{"role":"user","content":"go"}}"#))
        XCTAssertEqual(t.turnStartedAt, Transcript.parseDate("2026-09-19T10:00:00.000Z"))
        t.apply(json(#"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m1"}}}"#))
        t.apply(json(#"{"type":"stream_event","event":{"type":"message_delta","delta":{},"usage":{"output_tokens":120}}}"#))
        XCTAssertEqual(t.turnOutputTokens, 120)
        // The full message repeats the final count for the same id — not double-counted.
        t.apply(json(#"{"type":"assistant","message":{"id":"m1","usage":{"output_tokens":150},"content":[{"type":"text","text":"a"}]}}"#))
        t.apply(json(#"{"type":"assistant","message":{"id":"m1","usage":{"output_tokens":150},"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}"#))
        XCTAssertEqual(t.turnOutputTokens, 150)
        t.apply(json(#"{"type":"assistant","message":{"id":"m2","usage":{"output_tokens":50},"content":[{"type":"text","text":"b"}]}}"#))
        XCTAssertEqual(t.turnOutputTokens, 200)
        // Tool results are user messages too, but not prompts.
        t.apply(json(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#))
        XCTAssertEqual(t.turnOutputTokens, 200)
        t.apply(json(#"{"type":"user","uuid":"u2","message":{"role":"user","content":"again"}}"#))
        XCTAssertEqual(t.turnOutputTokens, 0)
    }
}
