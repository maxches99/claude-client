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
}
