import XCTest
@testable import ClaudeRemoteCore

/// Codex app-server notifications → stream-json → the same transcript rows a Claude session gets.
final class CodexTranslatorTests: XCTestCase {
    private func json(_ s: String) -> JSONValue { try! JSONValue.parse(s) }

    private func run(_ translator: inout CodexTranslator, _ transcript: inout Transcript, _ method: String, _ params: String) {
        for event in translator.translate(method: method, params: json(params)) { transcript.apply(event) }
    }

    func testAgentMessageStreamsThenSettles() {
        var tr = CodexTranslator()
        var t = Transcript()
        t.apply(tr.userEvent(text: "hi", images: []))
        run(&tr, &t, "turn/started", #"{"threadId":"th","turn":{"id":"turn1","status":"inProgress","items":[]}}"#)
        run(&tr, &t, "item/started", #"{"threadId":"th","turnId":"turn1","startedAtMs":1,"item":{"type":"userMessage","id":"u1","content":[{"type":"text","text":"hi"}]}}"#)
        XCTAssertEqual(t.items.count, 1, "Codex's echo of our own prompt is dropped")
        run(&tr, &t, "item/started", #"{"threadId":"th","turnId":"turn1","startedAtMs":1,"item":{"type":"agentMessage","id":"a1","text":""}}"#)
        run(&tr, &t, "item/agentMessage/delta", #"{"threadId":"th","turnId":"turn1","itemId":"a1","delta":"Hel"}"#)
        run(&tr, &t, "item/agentMessage/delta", #"{"threadId":"th","turnId":"turn1","itemId":"a1","delta":"lo"}"#)
        XCTAssertEqual(t.items.count, 2)
        guard case .assistantText(let text, let streaming) = t.items[1].kind else { return XCTFail("expected streamed text") }
        XCTAssertEqual(text, "Hello"); XCTAssertTrue(streaming); XCTAssertTrue(t.isStreaming)

        run(&tr, &t, "item/completed", #"{"threadId":"th","turnId":"turn1","completedAtMs":2,"item":{"type":"agentMessage","id":"a1","text":"Hello"}}"#)
        XCTAssertEqual(t.items.count, 2, "the full message replaces the streamed block")
        guard case .assistantText(let final, let still) = t.items[1].kind else { return XCTFail() }
        XCTAssertEqual(final, "Hello"); XCTAssertFalse(still); XCTAssertFalse(t.isStreaming)

        run(&tr, &t, "turn/completed", #"{"threadId":"th","turn":{"id":"turn1","status":"completed","items":[],"durationMs":1500}}"#)
        guard case .turnEnd(let summary, let isError) = t.items[2].kind else { return XCTFail("expected turn end") }
        XCTAssertEqual(summary, "1.5s"); XCTAssertFalse(isError)
    }

    func testCommandExecutionBecomesBashToolCall() {
        var tr = CodexTranslator()
        var t = Transcript()
        run(&tr, &t, "item/started", #"{"threadId":"th","turnId":"t","startedAtMs":1,"item":{"type":"commandExecution","id":"c1","command":"ls -la","cwd":"/tmp","status":"inProgress","commandActions":[]}}"#)
        guard case .toolUse(let id, let name, let input, _, let streaming) = t.items[0].kind else { return XCTFail() }
        XCTAssertEqual(id, "c1"); XCTAssertEqual(name, "Bash"); XCTAssertEqual(input["command"]?.string, "ls -la"); XCTAssertTrue(streaming)

        run(&tr, &t, "item/completed", #"{"threadId":"th","turnId":"t","completedAtMs":2,"item":{"type":"commandExecution","id":"c1","command":"ls -la","cwd":"/tmp","status":"failed","exitCode":2,"aggregatedOutput":"nope","commandActions":[]}}"#)
        XCTAssertEqual(t.items.count, 2)
        guard case .toolUse(_, _, _, _, let done) = t.items[0].kind else { return XCTFail() }
        XCTAssertFalse(done)
        guard case .toolResult(let toolUseId, let text, let isError, _) = t.items[1].kind else { return XCTFail() }
        XCTAssertEqual(toolUseId, "c1"); XCTAssertEqual(text, "nope\nexit code 2"); XCTAssertTrue(isError)
    }

    func testFileChangeBecomesOneEditPerFile() {
        var tr = CodexTranslator()
        var t = Transcript()
        run(&tr, &t, "item/completed", #"{"threadId":"th","turnId":"t","completedAtMs":2,"item":{"type":"fileChange","id":"f1","status":"completed","changes":[{"path":"/p/a.swift","kind":{"type":"update"},"diff":"@@ -1 +1 @@\n-a\n+b"},{"path":"/p/new.swift","kind":{"type":"add"},"diff":"+x"}]}}"#)
        XCTAssertEqual(t.items.count, 4)
        guard case .toolUse(let id0, let name0, let input0, _, _) = t.items[0].kind else { return XCTFail() }
        XCTAssertEqual(id0, "f1#0"); XCTAssertEqual(name0, "Edit"); XCTAssertEqual(input0["file_path"]?.string, "/p/a.swift"); XCTAssertEqual(input0["diff"]?.string, "@@ -1 +1 @@\n-a\n+b")
        guard case .toolUse(_, let name1, _, _, _) = t.items[1].kind else { return XCTFail() }
        XCTAssertEqual(name1, "Write")
        guard case .toolResult(let rid, let rtext, let rerr, _) = t.items[2].kind else { return XCTFail() }
        XCTAssertEqual(rid, "f1#0"); XCTAssertEqual(rtext, "Applied"); XCTAssertFalse(rerr)
    }

    func testReasoningSummaryStreamsAsThinking() {
        var tr = CodexTranslator()
        var t = Transcript()
        run(&tr, &t, "item/started", #"{"threadId":"th","turnId":"t","startedAtMs":1,"item":{"type":"reasoning","id":"r1","summary":[],"content":[]}}"#)
        XCTAssertEqual(t.items.count, 0, "no empty thinking row before the first delta")
        run(&tr, &t, "item/reasoning/summaryPartAdded", #"{"threadId":"th","turnId":"t","itemId":"r1","summaryIndex":0}"#)
        run(&tr, &t, "item/reasoning/summaryTextDelta", #"{"threadId":"th","turnId":"t","itemId":"r1","summaryIndex":0,"delta":"Think"}"#)
        run(&tr, &t, "item/reasoning/summaryPartAdded", #"{"threadId":"th","turnId":"t","itemId":"r1","summaryIndex":1}"#)
        run(&tr, &t, "item/reasoning/summaryTextDelta", #"{"threadId":"th","turnId":"t","itemId":"r1","summaryIndex":1,"delta":"more"}"#)
        guard case .thinking(let text, let streaming) = t.items[0].kind else { return XCTFail() }
        XCTAssertEqual(text, "Think\n\nmore"); XCTAssertTrue(streaming)
        run(&tr, &t, "item/completed", #"{"threadId":"th","turnId":"t","completedAtMs":2,"item":{"type":"reasoning","id":"r1","summary":["Think","more"],"content":[]}}"#)
        XCTAssertEqual(t.items.count, 1)
        guard case .thinking(let final, let still) = t.items[0].kind else { return XCTFail() }
        XCTAssertEqual(final, "Think\n\nmore"); XCTAssertFalse(still)
    }

    func testFailedTurnAndErrorNotification() {
        var tr = CodexTranslator()
        var t = Transcript()
        run(&tr, &t, "error", #"{"threadId":"th","turnId":"t","willRetry":true,"error":{"message":"rate limited"}}"#)
        guard case .note(let note) = t.items[0].kind else { return XCTFail() }
        XCTAssertEqual(note, "rate limited (retrying)")
        run(&tr, &t, "turn/completed", #"{"threadId":"th","turn":{"id":"t","status":"failed","items":[],"error":{"message":"boom"}}}"#)
        guard case .turnEnd(let summary, let isError) = t.items[1].kind else { return XCTFail() }
        XCTAssertTrue(isError); XCTAssertTrue(summary.contains("boom")); XCTAssertTrue(summary.contains("failed"))
    }

    func testHistoryReplaysStoredThread() {
        let thread = json(#"""
        {"id":"th","turns":[{"id":"t1","status":"completed","startedAt":1700000000,"items":[
            {"type":"userMessage","id":"u1","content":[{"type":"text","text":"do it"},{"type":"localImage","path":"/tmp/x.png"}]},
            {"type":"reasoning","id":"r1","summary":["plan"],"content":[]},
            {"type":"commandExecution","id":"c1","command":"make","cwd":"/p","status":"completed","exitCode":0,"aggregatedOutput":"ok","commandActions":[]},
            {"type":"mcpToolCall","id":"m1","server":"figma","tool":"get_node","arguments":{"id":"1"},"status":"completed","result":{"content":[{"type":"text","text":"node"}]}},
            {"type":"agentMessage","id":"a1","text":"Done."}
        ]}]}
        """#)
        var t = Transcript()
        t.apply(entries: CodexTranslator.history(thread: thread))
        let kinds = t.items.map { item -> String in
            switch item.kind {
            case .user(let text, _): return "user:\(text)"
            case .thinking(let text, _): return "think:\(text)"
            case .toolUse(_, let name, _, _, let streaming): return "tool:\(name):\(streaming ? "running" : "done")"
            case .toolResult(_, let text, _, _): return "result:\(text)"
            case .assistantText(let text, _): return "text:\(text)"
            default: return "?"
            }
        }
        XCTAssertEqual(kinds, ["user:do it\n[image: /tmp/x.png]", "think:plan", "tool:Bash:done", "result:ok",
                               "tool:mcp__figma__get_node:done", "result:node", "text:Done."])
    }
}

extension CodexTranslatorTests {
    func testShellWrapperIsUnwrapped() {
        XCTAssertEqual(CodexTranslator.unwrapShell("/bin/zsh -lc 'git log --oneline -3'"), "git log --oneline -3")
        XCTAssertEqual(CodexTranslator.unwrapShell(#"/bin/zsh -lc 'echo '\''hi'\'''"#), "echo 'hi'")
        XCTAssertEqual(CodexTranslator.unwrapShell(#"bash -lc "ls -la""#), "ls -la")
        XCTAssertEqual(CodexTranslator.unwrapShell("ls -la"), "ls -la")
    }
}

/// The other Codex source: a session file written by the Codex app, which we only read.
final class CodexRolloutTests: XCTestCase {
    private func json(_ s: String) -> JSONValue { try! JSONValue.parse(s) }

    func testRolloutBecomesTheSameRowsAsALiveSession() {
        let lines = [
            #"{"timestamp":"2026-09-19T14:00:58.823Z","type":"session_meta","payload":{"session_id":"th","cwd":"/p"}}"#,
            #"{"timestamp":"2026-09-19T14:01:00.000Z","type":"response_item","payload":{"type":"message","id":"m0","role":"developer","content":[{"type":"input_text","text":"<skills_instructions>…"}]}}"#,
            #"{"timestamp":"2026-09-19T14:01:01.000Z","type":"response_item","payload":{"type":"message","id":"m1","role":"user","content":[{"type":"input_text","text":"list the folder"}]}}"#,
            #"{"timestamp":"2026-09-19T14:01:02.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}"#,
            #"{"timestamp":"2026-09-19T14:01:03.000Z","type":"response_item","payload":{"type":"reasoning","id":"r1","summary":[{"type":"summary_text","text":"check the files"}]}}"#,
            #"{"timestamp":"2026-09-19T14:01:04.000Z","type":"response_item","payload":{"type":"custom_tool_call","id":"ctc1","call_id":"call_1","name":"exec","input":"const r = await tools.exec_command({\"cmd\":\"ls\"})"}}"#,
            #"{"timestamp":"2026-09-19T14:01:05.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","id":"ctco1","call_id":"call_1","output":[{"type":"input_text","text":"README.md\n"}]}}"#,
            #"{"timestamp":"2026-09-19T14:01:06.000Z","type":"response_item","payload":{"type":"message","id":"m2","role":"assistant","content":[{"type":"output_text","text":"One file: README.md."}]}}"#,
            #"{"timestamp":"2026-09-19T14:01:07.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","duration_ms":5000,"last_agent_message":"One file: README.md."}}"#,
        ].map(json)

        var t = Transcript()
        t.apply(entries: CodexRollout.history(lines: lines))
        let rows = t.items.map { item -> String in
            switch item.kind {
            case .user(let text, _): return "user:\(text)"
            case .thinking(let text, _): return "think:\(text)"
            case .toolUse(let id, let name, let input, _, let streaming):
                return "tool:\(name):\(id):\(input["input"]?.string?.contains("ls") == true):\(streaming ? "running" : "done")"
            case .toolResult(_, let text, let isError, _): return "result:\(text.trimmingCharacters(in: .newlines)):\(isError)"
            case .assistantText(let text, _): return "text:\(text)"
            case .turnEnd(let summary, _): return "turn:\(summary)"
            default: return "?"
            }
        }
        XCTAssertEqual(rows, ["user:list the folder", "think:check the files", "tool:exec:call_1:true:done",
                              "result:README.md:false", "text:One file: README.md.", "turn:5.0s"],
                       "developer instructions are skipped; tool call and its output pair up")
    }

    func testTurnBoundariesDriveTheRunningFlag() {
        var r = CodexRollout()
        XCTAssertFalse(r.isRunning)
        _ = r.apply(json(#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}"#))
        XCTAssertTrue(r.isRunning)
        let events = r.apply(json(#"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","duration_ms":1200,"last_agent_message":"done"}}"#))
        XCTAssertFalse(r.isRunning)
        XCTAssertEqual(events.first?["type"]?.string, "result")
        XCTAssertEqual(events.first?["result"]?.string, "done")
    }
}

extension CodexRolloutTests {
    func testCodexContextBlocksAreNotShownAsPrompts() {
        let context = #"{"timestamp":"t","type":"response_item","payload":{"type":"message","id":"m0","role":"user","content":[{"type":"input_text","text":"<environment_context>\n  <cwd>/p</cwd>\n</environment_context>"}]}}"#
        var r = CodexRollout()
        XCTAssertTrue(r.apply(try! JSONValue.parse(context)).isEmpty)

        let mixed = #"{"timestamp":"t","type":"response_item","payload":{"type":"message","id":"m1","role":"user","content":[{"type":"input_text","text":"<environment_context>\n  <cwd>/p</cwd>\n</environment_context>\nrun the tests"}]}}"#
        let events = r.apply(try! JSONValue.parse(mixed))
        XCTAssertEqual(events.first?["message"]?["content"]?[0]?["text"]?.string, "run the tests")

        let truncated = "<recommended_plugins>\nlist without a closing tag"
        XCTAssertEqual(CodexRollout.stripContextBlocks(truncated), "")
    }
}
