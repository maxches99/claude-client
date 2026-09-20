import XCTest
@testable import ClaudeRemoteCore

final class TranscriptExportTests: XCTestCase {
    private var items: [TranscriptItem] {
        [
            TranscriptItem(id: "u1", kind: .user(text: "Fix the build", images: [])),
            TranscriptItem(id: "t1", kind: .toolUse(id: "tu1", name: "Bash", input: .object(["command": .string("swift build")]), partialInput: "", streaming: false)),
            TranscriptItem(id: "r1", kind: .toolResult(toolUseId: "tu1", text: (1...50).map { "line \($0)" }.joined(separator: "\n"), isError: false, images: [])),
            TranscriptItem(id: "a1", kind: .assistantText(text: "Done — the **build** passes.", streaming: false)),
        ]
    }

    func testMarkdownHasPromptsRepliesAndFoldedTools() {
        let md = TranscriptExport.markdown(items: items, options: .init(title: "My session", subtitle: "proj · Claude", maxResultLines: 10))
        XCTAssertTrue(md.hasPrefix("# My session\n"))
        XCTAssertTrue(md.contains("## You\n\nFix the build"))
        XCTAssertTrue(md.contains("## Claude\n\nDone — the **build** passes."))
        XCTAssertTrue(md.contains("<details>"))
        XCTAssertTrue(md.contains("**Bash** `swift build`"))
        XCTAssertTrue(md.contains("line 10\n… (40 more lines)"))
        XCTAssertFalse(md.contains("line 11\n"))
    }

    func testLastReplyAndFileName() {
        XCTAssertEqual(TranscriptExport.lastReply(items: items), "Done — the **build** passes.")
        XCTAssertEqual(TranscriptExport.fileName(for: " a/b:c? "), "a-b-c-.md")
        XCTAssertEqual(TranscriptExport.fileName(for: ""), "transcript.md")
    }

    func testSearchFindsBlocksAndSteps() {
        let blocks = TranscriptLayout.blocks(for: items, sessionRunning: false)
        XCTAssertEqual(TranscriptSearch.matches(in: blocks, query: "BUILD").map(\.blockId), ["u1", "activity:t1", "a1"])
        let toolHit = TranscriptSearch.matches(in: blocks, query: "line 42")
        XCTAssertEqual(toolHit.count, 1)
        XCTAssertEqual(toolHit.first?.stepId, "t1")
        XCTAssertTrue(TranscriptSearch.matches(in: blocks, query: "  ").isEmpty)
    }
}
