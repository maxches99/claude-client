import XCTest
@testable import ClaudeRemoteCore

/// Reading Sentry's answers and turning a crash into a task prompt.
final class CrashTests: XCTestCase {
    func testIssuesParseWithStringCountsAndFractionalDates() throws {
        let json = """
        [{"id":"4521","shortId":"IOS-APP-3F","title":"EXC_BAD_ACCESS: ChatView.send","culprit":"ChatView.send()","level":"fatal",
          "count":"12","userCount":4,"firstSeen":"2026-09-20T10:00:00.123Z","lastSeen":"2026-09-25T08:30:00Z",
          "permalink":"https://acme.sentry.io/issues/4521/","status":"unresolved"},
         {"title":"no id, skipped"}]
        """
        let issues = try SentryAPI.parseIssues(Data(json.utf8), sourceId: "src")
        XCTAssertEqual(issues.count, 1)
        let issue = issues[0]
        XCTAssertEqual(issue.id, "src:4521")
        XCTAssertEqual(issue.count, 12)
        XCTAssertEqual(issue.userCount, 4)
        XCTAssertNotNil(issue.firstSeen)
        XCTAssertNotNil(issue.lastSeen)
        XCTAssertEqual(issue.impactLabel, "12 events · 4 users")
    }

    func testAnErrorObjectIsReportedNotSwallowed() {
        let json = #"{"detail":"Invalid token"}"#
        XCTAssertThrowsError(try SentryAPI.parseIssues(Data(json.utf8), sourceId: "src")) { error in
            XCTAssertEqual("\(error)", "Invalid token")
        }
    }

    func testStackSummaryPutsTheCrashingFrameFirstAndKeepsAppFrames() throws {
        let json = """
        {"entries":[{"type":"exception","data":{"values":[
          {"type":"NSInvalidArgumentException","value":"index 3 beyond bounds",
           "stacktrace":{"frames":[
             {"function":"main","filename":"main.swift","lineNo":10,"inApp":true},
             {"function":"UIKit internal","package":"UIKitCore","inApp":false},
             {"function":"ChatView.send()","filename":"ChatView.swift","lineNo":628,"inApp":true}]}}]}}],
         "tags":[{"key":"release","value":"1.5.0 (42)"},{"key":"os","value":"iOS 26.4"},{"key":"user","value":"x"}]}
        """
        let stack = try XCTUnwrap(SentryAPI.stackSummary(Data(json.utf8)))
        let lines = stack.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "NSInvalidArgumentException: index 3 beyond bounds")
        XCTAssertEqual(lines[1], "  at ChatView.send() (ChatView.swift:628)", "the crashing frame comes first")
        XCTAssertEqual(lines[2], "  at main (main.swift:10)")
        XCTAssertFalse(stack.contains("UIKit internal"), "system frames are left out when the app has its own")
        XCTAssertTrue(stack.contains("release=1.5.0 (42)"))
        XCTAssertFalse(stack.contains("user=x"), "only a few useful tags go into the prompt")
    }

    func testFixPromptCarriesTheCrashAndTheStack() {
        let issue = CrashIssue(sourceId: "s", issueId: "1", title: "Crash in send", culprit: "ChatView.send()", count: 3, userCount: 1,
                               permalink: "https://sentry.io/1")
        let prompt = issue.fixPrompt(stack: "  at ChatView.send() (ChatView.swift:628)")
        XCTAssertTrue(prompt.contains("Crash: Crash in send"))
        XCTAssertTrue(prompt.contains("Where: ChatView.send()"))
        XCTAssertTrue(prompt.contains("ChatView.swift:628"))
        XCTAssertTrue(prompt.contains("https://sentry.io/1"))
    }

    func testTheTokenNeverGoesToAPhone() throws {
        let source = CrashSource(organization: "acme", project: "ios", cwd: "/tmp", hasToken: true, token: "sntrys_secret")
        let data = try ProtocolCoding.encoder.encode(ServerMessage.crashes(sources: [source.forPhone], items: [], error: nil))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("sntrys_secret"))
    }
}
