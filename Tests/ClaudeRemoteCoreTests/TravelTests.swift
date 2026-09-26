import XCTest
@testable import ClaudeRemoteCore

final class TravelTests: XCTestCase {
    func testPhrasebookParse() {
        let reply = """
        ```json
        {"sections": [{"situation": "Restaurant", "phrases": [{"mine": "Счёт, пожалуйста", "theirs": "お会計お願いします", "reading": "okaikei onegaishimasu"},
          {"mine": "", "theirs": "x"}]}, {"situation": "Empty", "phrases": []}]}
        ```
        """
        let book = Phrasebook.parse(reply, mine: "ru-RU", theirs: "ja-JP")
        XCTAssertEqual(book?.sections.count, 1)
        XCTAssertEqual(book?.sections.first?.phrases.count, 1)
        XCTAssertEqual(book?.sections.first?.phrases.first?.reading, "okaikei onegaishimasu")
    }

    func testReceiptParseAndSplit() throws {
        let reply = #"{"currency": "jpy", "items": [{"name": "Рамен", "price": "1,200"}, {"name": "Пиво", "price": 600, "quantity": 2}], "extras": 180, "total": 1980}"#
        let receipt = try XCTUnwrap(Receipt.parse(reply))
        XCTAssertEqual(receipt.currency, "JPY")
        XCTAssertEqual(receipt.itemsTotal, 1800)
        XCTAssertEqual(receipt.total, 1980)
        // Ramen is Anna's, the beer is shared; the 180 of extras goes by share of the items.
        let split = receipt.split(people: ["Max", "Anna"], assignments: [receipt.items[0].id: ["Anna"]])
        XCTAssertEqual(split["Anna"]!, 1200 + 300 + 180 * 1500 / 1800, accuracy: 0.001)
        XCTAssertEqual(split["Max"]!, 300 + 180 * 300 / 1800, accuracy: 0.001)
        XCTAssertEqual(split.values.reduce(0, +), 1980, accuracy: 0.001)
    }

    func testReviewCommentsParse() throws {
        let lines = try JSONValue.parse(Data(#"[{"id": 1, "user": {"login": "anna"}, "body": "Rename this", "path": "a.swift", "line": 12, "created_at": "2026-09-25T10:00:00Z"}, {"id": 2, "user": {"login": "maxches99"}, "body": "me", "created_at": "2026-09-25T09:00:00Z"}]"#.utf8))
        let issue = try JSONValue.parse(Data(#"[{"id": 3, "user": {"login": "bob"}, "body": "Looks off", "created_at": "2026-09-25T08:00:00Z"}]"#.utf8))
        let reviews = try JSONValue.parse(Data(#"{"reviews": [{"id": "R1", "author": {"login": "anna"}, "body": "", "submittedAt": "2026-09-25T11:00:00Z"}]}"#.utf8))
        let comments = TaskReviews.parse(lineComments: lines, issueComments: issue, reviews: reviews, me: "maxches99")
        XCTAssertEqual(comments.map(\.id), ["issue-3", "line-1"])   // own and empty ones left out, oldest first
        let prompt = TaskReviews.prompt(pullRequest: "https://x/pull/1", comments: comments)
        XCTAssertTrue(prompt.contains("@anna on `a.swift` line 12"))
    }
}
