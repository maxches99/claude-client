import XCTest
@testable import ClaudeRemoteCore

final class TranscriptTests: XCTestCase {
    private func json(_ s: String) -> JSONValue { try! JSONValue.parse(s) }

    func testStreamedTextIsReplacedByFullBlockWithoutDuplicates() {
        var t = Transcript()
        t.apply(json(#"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_1"}}}"#))
        t.apply(json(#"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}"#))
        t.apply(json(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}}"#))
        t.apply(json(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}}"#))
        XCTAssertEqual(t.items.count, 1)
        guard case .assistantText(let text, let streaming) = t.items[0].kind else { return XCTFail("expected text") }
        XCTAssertEqual(text, "Hello")
        XCTAssertTrue(streaming)

        t.apply(json(#"{"type":"stream_event","event":{"type":"content_block_stop","index":0}}"#))
        t.apply(json(#"{"type":"assistant","message":{"id":"msg_1","role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":"Hello"}]}}"#))
        XCTAssertEqual(t.items.count, 1, "full block must replace the streamed one")
        guard case .assistantText(_, let stillStreaming) = t.items[0].kind else { return XCTFail() }
        XCTAssertFalse(stillStreaming)
        XCTAssertEqual(t.model, "claude-opus-5")
    }

    func testToolUseAndResultPairUp() {
        var t = Transcript()
        t.apply(json(#"{"type":"assistant","message":{"id":"m","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]}}"#))
        guard case .toolUse(let id, let name, let input, _, let streaming) = t.items[0].kind else { return XCTFail() }
        XCTAssertEqual(id, "toolu_1"); XCTAssertEqual(name, "Bash"); XCTAssertEqual(input["command"]?.string, "ls"); XCTAssertTrue(streaming)

        t.apply(json(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"a\nb"}],"is_error":false}]}}"#))
        XCTAssertEqual(t.items.count, 2)
        guard case .toolUse(_, _, _, _, let done) = t.items[0].kind else { return XCTFail() }
        XCTAssertFalse(done, "tool result should mark the call finished")
        guard case .toolResult(let toolUseId, let text, let isError, let images) = t.items[1].kind else { return XCTFail() }
        XCTAssertEqual(toolUseId, "toolu_1"); XCTAssertEqual(text, "a\nb"); XCTAssertFalse(isError); XCTAssertTrue(images.isEmpty)
    }

    func testHarnessBoilerplateIsStrippedFromUserTurns() {
        var t = Transcript()
        t.apply(json(#"{"type":"user","uuid":"u1","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>ignore me</system-reminder>"},{"type":"text","text":"real prompt"}]}}"#))
        XCTAssertEqual(t.items.count, 1)
        guard case .user(let text, _) = t.items[0].kind else { return XCTFail() }
        XCTAssertEqual(text, "real prompt")

        t.apply(json(#"{"type":"user","uuid":"u2","isMeta":true,"message":{"role":"user","content":"meta"}}"#))
        t.apply(json(#"{"type":"user","uuid":"u3","isSidechain":true,"message":{"role":"user","content":"subagent"}}"#))
        t.apply(json(#"{"type":"assistant","parent_tool_use_id":"toolu_x","message":{"id":"m2","content":[{"type":"text","text":"nested"}]}}"#))
        XCTAssertEqual(t.items.count, 1, "meta, sidechain and nested sub-agent turns are hidden")
    }

    func testImagesAreKeptInUserTurnsAndToolResults() {
        var t = Transcript()
        t.apply(json(#"{"type":"user","uuid":"u1","message":{"role":"user","content":[{"type":"text","text":"look"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}}]}}"#))
        guard case .user(let text, let images) = t.items[0].kind else { return XCTFail() }
        XCTAssertEqual(text, "look"); XCTAssertEqual(images, [InlineImage(mediaType: "image/png", base64: "AAAA")])

        t.apply(json(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_9","content":[{"type":"text","text":"Screenshot"},{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"BBBB"}}]}]}}"#))
        guard case .toolResult(_, let rtext, _, let rimages) = t.items[1].kind else { return XCTFail() }
        XCTAssertEqual(rtext, "Screenshot"); XCTAssertEqual(rimages.first?.base64, "BBBB")
    }

    func testResultRowSummarizesTurn() {
        var t = Transcript()
        t.apply(json(#"{"type":"result","subtype":"success","is_error":false,"duration_ms":1500,"num_turns":2,"total_cost_usd":0.5}"#))
        guard case .turnEnd(let summary, let isError) = t.items[0].kind else { return XCTFail() }
        XCTAssertEqual(summary, "1.5s · 2 turns · $0.500"); XCTAssertFalse(isError)
    }

    func testProtocolRoundTrip() throws {
        let messages: [ClientMessage] = [.hello(token: "t", client: "c"), .create(options: NewSessionOptions(cwd: "/tmp", model: "claude-opus-5")),
                                         .permission(sessionId: "s", requestId: "r", allow: false, message: nil), .listSessions]
        for m in messages {
            let text = try ProtocolCoding.encode(m)
            _ = try ProtocolCoding.decode(ClientMessage.self, from: text)
        }
        let request = PermissionRequest(id: "r", sessionId: "s", toolName: "Bash", input: ["command": "ls"], createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let encoded = try ProtocolCoding.encode(ServerMessage.permissionRequest(request: request))
        XCTAssertTrue(encoded.contains(#""permissionRequest":{"request":{"#))
        if case .permissionRequest(let decoded) = try ProtocolCoding.decode(ServerMessage.self, from: encoded) {
            XCTAssertEqual(decoded, request)
        } else { XCTFail() }
    }

    func testToolSummaries() {
        XCTAssertEqual(ToolSummary.line(name: "Bash", input: ["command": "git status"]), "git status")
        XCTAssertEqual(ToolSummary.displayName("mcp__Claude_Code_iOS_Simulator__control"), "control · Claude Code iOS Simulator")
        XCTAssertEqual(ToolSummary.displayName("Read"), "Read")
    }
}
