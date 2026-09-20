import XCTest
@testable import ClaudeRemoteCore

final class InteractionTests: XCTestCase {
    private let questionInput: JSONValue = [
        "heading": "Before I build the deck",
        "questions": [
            ["question": "Which library?", "header": "Library", "multiSelect": false,
             "options": [["label": "date-fns", "description": "small"], ["label": "moment", "description": "old"]]],
            ["question": "Which platforms?", "header": "Targets", "multiSelect": true,
             "options": [["label": "iOS"], ["label": "macOS"], ["label": "watchOS"]]],
        ],
    ]

    func testParsesQuestions() {
        let qs = AskUserQuestion.questions(in: questionInput)
        XCTAssertEqual(qs.count, 2)
        XCTAssertEqual(qs[0].header, "Library")
        XCTAssertEqual(qs[0].options.map(\.label), ["date-fns", "moment"])
        XCTAssertFalse(qs[0].multiSelect)
        XCTAssertTrue(qs[1].multiSelect)
        XCTAssertEqual(AskUserQuestion.heading(in: questionInput), "Before I build the deck")
        XCTAssertEqual(AskUserQuestion.questions(in: ["command": "ls"]).count, 0)
    }

    func testAnsweredInputKeepsQuestionsAndJoinsMultiSelect() {
        let out = AskUserQuestion.answeredInput(questionInput,
                                                answers: ["Which library?": ["date-fns"], "Which platforms?": ["iOS", "watchOS"]],
                                                notes: ["Which library?": "  keep it small ", "Which platforms?": "   "])
        XCTAssertEqual(out["questions"]?.array?.count, 2)
        XCTAssertEqual(out["answers"]?["Which library?"]?.string, "date-fns")
        XCTAssertEqual(out["answers"]?["Which platforms?"]?.string, "iOS, watchOS")
        XCTAssertEqual(out["annotations"]?["Which library?"]?["notes"]?.string, "keep it small")
        XCTAssertNil(out["annotations"]?["Which platforms?"])
    }

    func testTypedAnswerIsPassedAsIs() {
        let out = AskUserQuestion.answeredInput(questionInput, answers: ["Which library?": ["something else"], "Which platforms?": []])
        XCTAssertEqual(out["answers"]?["Which library?"]?.string, "something else")
        XCTAssertNil(out["answers"]?["Which platforms?"])
        XCTAssertNil(out["annotations"])
    }

    func testPlanHelpers() {
        let input: JSONValue = ["plan": "# Plan\n\n1. do it", "planFilePath": "/tmp/plan.md"]
        XCTAssertEqual(PlanReview.plan(in: input), "# Plan\n\n1. do it")
        XCTAssertEqual(PlanReview.planFilePath(in: input), "/tmp/plan.md")
        XCTAssertNil(PlanReview.plan(in: ["planFilePath": "/tmp/plan.md"]))
        let suggestions: JSONValue = [["type": "setMode", "mode": "acceptEdits", "destination": "session"]]
        XCTAssertEqual(PlanReview.suggestedMode(in: suggestions), "acceptEdits")
        XCTAssertNil(PlanReview.suggestedMode(in: [["type": "addRules"]]))
        XCTAssertNil(PlanReview.suggestedMode(in: nil))
    }

    func testRequestKinds() {
        let q = PermissionRequest(id: "1", sessionId: "s", toolName: "AskUserQuestion", input: [:])
        let p = PermissionRequest(id: "2", sessionId: "s", toolName: "ExitPlanMode", input: [:])
        let b = PermissionRequest(id: "3", sessionId: "s", toolName: "Bash", input: [:])
        XCTAssertTrue(q.isQuestion); XCTAssertFalse(q.runsCode)
        XCTAssertTrue(p.isPlanReview); XCTAssertFalse(p.runsCode)
        XCTAssertTrue(b.runsCode)
    }

    func testQueuedPromptDecodesWhenMissing() throws {
        let state = SessionState(id: "s", origin: .host, status: .idle, cwd: "/x")
        let json = try ProtocolCoding.encode(state).replacingOccurrences(of: "\"queued\":[],", with: "").replacingOccurrences(of: ",\"queued\":[]", with: "")
        let decoded = try ProtocolCoding.decode(SessionState.self, from: json)
        XCTAssertEqual(decoded.queued, [])
        let msg = ClientMessage.permission(sessionId: "s", requestId: "r", allow: true, message: nil, updatedInput: ["answers": ["q": "a"]])
        let round = try ProtocolCoding.decode(ClientMessage.self, from: try ProtocolCoding.encode(msg))
        if case .permission(_, _, _, _, _, let updated) = round {
            XCTAssertEqual(updated?["answers"]?["q"]?.string, "a")
        } else {
            XCTFail("wrong case")
        }
    }
}

final class DiffQuoteTests: XCTestCase {
    private let diff = """
    diff --git a/Sources/App.swift b/Sources/App.swift
    index 111..222 100644
    --- a/Sources/App.swift
    +++ b/Sources/App.swift
    @@ -10,4 +10,5 @@ struct App {
         let a = 1
    -    let b = 2
    +    let b = 3
    +    let c = 4
         let d = 5
    @@ -30,2 +31,2 @@
    -old
    +new
    """

    func testTracksFilesAndLineNumbers() {
        let lines = DiffLines(diff).lines
        let content = lines.filter(\.isContent)
        XCTAssertEqual(content.count, 7)
        XCTAssertEqual(content[0].kind, .context); XCTAssertEqual(content[0].newLine, 10); XCTAssertEqual(content[0].oldLine, 10)
        XCTAssertEqual(content[1].kind, .removed); XCTAssertEqual(content[1].oldLine, 11); XCTAssertNil(content[1].newLine)
        XCTAssertEqual(content[2].kind, .added); XCTAssertEqual(content[2].newLine, 11)
        XCTAssertEqual(content[3].kind, .added); XCTAssertEqual(content[3].newLine, 12)
        XCTAssertEqual(content[4].kind, .context); XCTAssertEqual(content[4].newLine, 13); XCTAssertEqual(content[4].oldLine, 12)
        XCTAssertEqual(content[5].oldLine, 30)
        XCTAssertEqual(content[6].newLine, 31)
        XCTAssertTrue(content.allSatisfy { $0.file == "Sources/App.swift" })
        XCTAssertTrue(lines.filter { !$0.isContent }.allSatisfy { $0.newLine == nil && $0.oldLine == nil })
    }

    func testQuoteNamesFileAndRange() {
        let parsed = DiffLines(diff)
        let ids = Set(parsed.lines.filter(\.isContent).prefix(4).map(\.id))
        let quote = parsed.quote(ids: ids)!
        XCTAssertTrue(quote.hasPrefix("`Sources/App.swift` lines 10–12:\n```diff\n"), quote)
        XCTAssertTrue(quote.contains("-    let b = 2\n+    let b = 3"))
        XCTAssertTrue(quote.hasSuffix("```"))
        XCTAssertNil(parsed.quote(ids: []))
        // Meta lines never make it into a quote.
        XCTAssertNil(parsed.quote(ids: [0, 1, 2, 3]))
    }

    func testRemovedOnlySelectionIsMarked() {
        let parsed = DiffLines(diff)
        let removed = parsed.lines.first { $0.kind == .removed }!
        XCTAssertEqual(parsed.quote(ids: [removed.id])?.split(separator: "\n").first, "`Sources/App.swift` line 11 (removed):")
    }

    func testUntrackedFileAndStatusSections() {
        let text = "# Status\n?? new.txt\n# Diff\n--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1,2 @@\n+hello\n+world"
        let parsed = DiffLines(text)
        let added = parsed.lines.filter { $0.kind == .added }
        XCTAssertEqual(added.map(\.newLine), [1, 2])
        XCTAssertEqual(added.first?.file, "new.txt")
        XCTAssertEqual(parsed.quote(ids: Set(added.map(\.id)))?.split(separator: "\n").first, "`new.txt` lines 1–2:")
    }
}

final class SubagentTranscriptTests: XCTestCase {
    func testSubagentMessagesNestUnderParentToolUse() {
        var t = Transcript()
        t.apply(["type": "assistant", "uuid": "a1", "message": ["id": "m1", "content": [["type": "tool_use", "id": "tu1", "name": "Agent", "input": ["description": "Scan"]]]]])
        t.apply(["type": "assistant", "uuid": "s1", "parent_tool_use_id": "tu1", "message": ["id": "m2", "content": [["type": "tool_use", "id": "tu2", "name": "Read", "input": ["file_path": "/x"]]]]])
        t.apply(["type": "user", "uuid": "s2", "parent_tool_use_id": "tu1", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "tu2", "content": "ok"]]]])
        t.apply(["type": "assistant", "uuid": "s3", "parent_tool_use_id": "tu1", "message": ["id": "m3", "content": [["type": "text", "text": "done"]]]])
        XCTAssertEqual(t.items.count, 1)
        let sub = try! XCTUnwrap(t.subagents["tu1"])
        XCTAssertEqual(sub.items.count, 3)
        XCTAssertTrue(sub.subagents.isEmpty)
        let blocks = TranscriptLayout.blocks(for: sub.items, sessionRunning: false)
        XCTAssertEqual(blocks.count, 2)
    }

    func testSidechainWithoutParentIsStillDropped() {
        var t = Transcript()
        t.apply(["type": "assistant", "uuid": "x", "isSidechain": true, "message": ["id": "m", "content": [["type": "text", "text": "hidden"]]]])
        XCTAssertTrue(t.items.isEmpty)
        XCTAssertTrue(t.subagents.isEmpty)
    }
}

final class PullRequestTests: XCTestCase {
    func testCIStateFolding() {
        var pr = PullRequestInfo(number: 1, title: "t", url: "u", state: "OPEN")
        XCTAssertEqual(pr.ciState, .none)
        pr.checks = [CheckRun(name: "build", status: "COMPLETED", conclusion: "SUCCESS"), CheckRun(name: "lint", status: "IN_PROGRESS")]
        XCTAssertEqual(pr.ciState, .pending)
        pr.checks[1] = CheckRun(name: "lint", status: "COMPLETED", conclusion: "FAILURE")
        XCTAssertEqual(pr.ciState, .failure)
        pr.checks[1] = CheckRun(name: "lint", status: "COMPLETED", conclusion: "SKIPPED")
        XCTAssertEqual(pr.ciState, .success)
    }
}

final class E2ELinkTests: XCTestCase {
    func testHandshakeAndSealedRoundTrip() throws {
        let phone = E2ELink(token: "secret-token", role: .initiator)
        let mac = E2ELink(token: "secret-token", role: .responder)
        XCTAssertTrue(try mac.accept(phone.handshakeMessage()))
        XCTAssertTrue(try phone.accept(mac.handshakeMessage()))
        XCTAssertTrue(phone.isEstablished && mac.isEstablished)
        let sealed = try phone.seal("{\"hello\":1}")
        XCTAssertTrue(E2ELink.isSealed(sealed))
        XCTAssertFalse(sealed.contains("hello"))
        XCTAssertEqual(try mac.open(sealed), "{\"hello\":1}")
        let back = try mac.seal("{\"welcome\":2}")
        XCTAssertEqual(try phone.open(back), "{\"welcome\":2}")
        // Replaying a frame fails: the counter moved on.
        XCTAssertThrowsError(try mac.open(sealed))
    }

    func testWrongTokenCannotOpen() throws {
        let phone = E2ELink(token: "right", role: .initiator)
        let relay = E2ELink(token: "wrong", role: .responder)
        _ = try relay.accept(phone.handshakeMessage())
        _ = try phone.accept(relay.handshakeMessage())
        XCTAssertThrowsError(try relay.open(try phone.seal("{}")))
    }

    func testNonHandshakeFramesAreNotConsumed() throws {
        let link = E2ELink(token: "t", role: .responder)
        XCTAssertFalse(try link.accept("{\"hello\":{\"token\":\"t\"}}"))
        XCTAssertFalse(link.isEstablished)
        XCTAssertThrowsError(try link.seal("x"))
    }
}
