import XCTest
@testable import ClaudeRemoteCore

final class DuelAndDigestTests: XCTestCase {
    // MARK: the judge

    private func contestant(_ id: String, diff: String, passed: Bool?) -> DuelJudge.Contestant {
        DuelJudge.Contestant(taskId: id, summary: "Did the thing\nin two lines", diff: diff,
                             diffStat: DiffStat(files: 1, insertions: 3, deletions: 1),
                             check: passed.map { TaskCheck(command: "swift test", exitCode: $0 ? 0 : 1, outputTail: $0 ? "" : "FAIL: testX") },
                             failed: false)
    }

    func testBriefIsBlindAndCarriesTheEvidence() {
        let brief = DuelJudge.brief(task: "Fix the parser", contestants: [contestant("claude-task", diff: "+a", passed: true),
                                                                          contestant("codex-task", diff: "+b", passed: false)],
                                    labels: ["A", "B"])
        XCTAssertTrue(brief.contains("## Solution A") && brief.contains("## Solution B"))
        XCTAssertFalse(brief.lowercased().contains("claude-task") || brief.lowercased().contains("codex-task"), "the judge must not learn who wrote what")
        XCTAssertFalse(brief.contains("Claude") || brief.contains("Codex"), "no agent names in the brief")
        XCTAssertTrue(brief.contains("Tests (`swift test`): passed"))
        XCTAssertTrue(brief.contains("failed (exit 1)") && brief.contains("FAIL: testX"), "a failing run shows its output")
        XCTAssertTrue(brief.contains("Fix the parser"))
    }

    func testBriefCutsHugeDiffsAndPicksASafeFence() {
        let huge = String(repeating: "+line with ``` inside\n", count: 5000)
        let brief = DuelJudge.brief(task: "t", contestants: [contestant("a", diff: huge, passed: nil), contestant("b", diff: "", passed: nil)], labels: ["A", "B"])
        XCTAssertTrue(brief.contains("diff cut here"))
        XCTAssertTrue(brief.contains("````diff"), "a diff containing ``` gets a longer fence")
        XCTAssertTrue(brief.contains("(no changes)"))
    }

    func testParseTakesTheLastFencedVerdict() throws {
        let reply = """
        A handles the empty case; B does not.

        ```json
        {"winner": "B", "scores": {"A": {"correctness": 1}}}
        ```
        Actually, on reflection:
        ```json
        {"winner": "A", "scores": {"A": {"correctness": 9, "completeness": 8, "quality": 7, "tests": 10, "notes": "solid"},
                                   "B": {"correctness": 4, "completeness": 6, "quality": 8, "tests": 0, "notes": "breaks tests"}},
         "summary": "A is correct and tested."}
        ```
        """
        let verdict = try XCTUnwrap(DuelJudge.parse(reply))
        XCTAssertEqual(verdict.winnerLabel, "A")
        XCTAssertEqual(verdict.scores["A"]?.correctness, 9)
        XCTAssertEqual(verdict.scores["B"]?.notes, "breaks tests")
        XCTAssertEqual(verdict.summary, "A is correct and tested.")
        XCTAssertEqual(verdict.scores["A"]?.total, 8.6, "correctness counts double: (18+8+7+10)/5")
    }

    func testParseHandlesTiesBareJSONAndClampsScores() throws {
        let tie = try XCTUnwrap(DuelJudge.parse(#"Even. {"winner":"tie","scores":{"A":{"correctness":15},"B":{"correctness":-3}},"summary":"same"}"#))
        XCTAssertNil(tie.winnerLabel)
        XCTAssertEqual(tie.scores["A"]?.correctness, 10, "scores are clamped to 0…10")
        XCTAssertEqual(tie.scores["B"]?.correctness, 0)
        XCTAssertNil(DuelJudge.parse("I could not decide, sorry."))
    }

    // MARK: diff sizes

    func testShortstatParsing() {
        XCTAssertEqual(DiffStat.parse(shortstat: " 3 files changed, 40 insertions(+), 2 deletions(-)"), DiffStat(files: 3, insertions: 40, deletions: 2))
        XCTAssertEqual(DiffStat.parse(shortstat: " 1 file changed, 1 insertion(+)"), DiffStat(files: 1, insertions: 1, deletions: 0))
        XCTAssertEqual(DiffStat.parse(shortstat: ""), DiffStat(files: 0, insertions: 0, deletions: 0))
    }

    // MARK: review prompt

    func testReviewPromptNumbersEveryRemark() {
        let text = ReviewPrompt.compose(comments: [
            ReviewComment(path: "Sources/A.swift", quote: "`Sources/A.swift` lines 3–4:\n```diff\n+let x = 1\n```", text: "This should be a let constant elsewhere"),
            ReviewComment(path: "README.md", quote: nil, text: "Mention the new flag"),
            ReviewComment(path: nil, quote: nil, text: "Add tests for all of this"),
        ], base: "origin/main")
        XCTAssertTrue(text.hasPrefix("Review of the changes against `origin/main`"))
        XCTAssertTrue(text.contains("1. `Sources/A.swift` lines 3–4:"))
        XCTAssertTrue(text.contains("   This should be a let constant elsewhere"))
        XCTAssertTrue(text.contains("2. `README.md`: Mention the new flag"))
        XCTAssertTrue(text.contains("3. Add tests for all of this"))
    }

    // MARK: Telegram digest

    private func item(_ title: String, waiting: Bool = false, errors: Int = 0, reply: String? = nil) -> DigestItem {
        DigestItem(sessionId: UUID().uuidString, title: title, cwd: "/repo/app", status: .idle, updatedAt: Date(),
                   prompts: 2, files: ["a.swift"], fileCount: 3, commands: 1, errors: errors, lastReply: reply, waiting: waiting)
    }

    func testTelegramDigestEscapesAndOrdersWaitingFirst() {
        var task = AgentTask(title: "Bump deps <fast>", prompt: "p", cwd: "/repo/app", status: .done)
        task.pullRequestURL = "https://github.com/me/app/pull/7"
        let report = DigestReport(since: Date().addingTimeInterval(-8 * 3600),
                                  sessions: [item("Fix <b>crash</b> & tests", reply: "**Done.** See [PR](https://x)"), item("Needs you", waiting: true)],
                                  tasks: [task])
        let text = DigestTelegram.message(report, hostName: "Mac & Co", now: Date())
        XCTAssertTrue(text.contains("<b>Mac &amp; Co</b>"))
        XCTAssertTrue(text.contains("Fix &lt;b&gt;crash&lt;/b&gt; &amp; tests"), "titles are escaped, never markup")
        XCTAssertTrue(text.contains("<i>Done. See PR</i>"), "a reply's Markdown is flattened")
        XCTAssertLessThan(text.range(of: "Waiting for you")!.lowerBound, text.range(of: "Worked on")!.lowerBound)
        XCTAssertTrue(text.contains(#"<a href="https://github.com/me/app/pull/7">PR</a>"#))
        XCTAssertTrue(text.contains("Bump deps &lt;fast&gt;"))
    }

    func testTelegramDigestStaysUnderTheLimitWithoutBreakingTags() {
        let many = (0..<400).map { item("Session number \($0) with a fairly long title to fill the message", reply: String(repeating: "word ", count: 60)) }
        let text = DigestTelegram.message(DigestReport(since: Date().addingTimeInterval(-3600), sessions: many), hostName: "Mac")
        XCTAssertLessThanOrEqual(text.count, DigestTelegram.limit)
        XCTAssertEqual(text.components(separatedBy: "<b>").count, text.components(separatedBy: "</b>").count, "every opened tag is closed")
        XCTAssertEqual(text.components(separatedBy: "<i>").count, text.components(separatedBy: "</i>").count)
    }

    func testQuietNight() {
        XCTAssertTrue(DigestTelegram.message(DigestReport(since: Date()), hostName: "Mac").contains("Quiet night"))
    }
}
