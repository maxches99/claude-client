import XCTest
@testable import ClaudeRemoteCore

final class MarkdownTests: XCTestCase {
    func testHeadingsParagraphsAndRules() {
        let blocks = MarkdownParser.parse("# Title\n\nSome text\nsecond line\n\n---\n\n### Sub ##")
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "Title"),
            .paragraph("Some text\nsecond line"),
            .rule,
            .heading(level: 3, text: "Sub"),
        ])
    }

    func testFencedCodeKeepsIndentationAndSurvivesMissingClose() {
        let blocks = MarkdownParser.parse("```swift\nlet x = 1\n    indented\n```\ntail\n```\nstreaming")
        XCTAssertEqual(blocks, [
            .code("let x = 1\n    indented", language: "swift"),
            .paragraph("tail"),
            .code("streaming", language: nil),
        ])
    }

    func testBulletListWithNestingAndContinuation() {
        let blocks = MarkdownParser.parse("- one\n  continued\n  - nested\n- two\nlazy\n\nafter")
        XCTAssertEqual(blocks, [
            .list(ordered: false, start: 1, items: [
                MarkdownListItem(blocks: [
                    .paragraph("one\ncontinued"),
                    .list(ordered: false, start: 1, items: [MarkdownListItem(blocks: [.paragraph("nested")])]),
                ]),
                MarkdownListItem(blocks: [.paragraph("two\nlazy")]),
            ]),
            .paragraph("after"),
        ])
    }

    func testOrderedListStartsAtFirstNumberAndTaskItems() {
        let blocks = MarkdownParser.parse("3. a\n4) b\n\n- [ ] todo\n- [x] done")
        XCTAssertEqual(blocks, [
            .list(ordered: true, start: 3, items: [
                MarkdownListItem(blocks: [.paragraph("a")]),
                MarkdownListItem(blocks: [.paragraph("b")]),
            ]),
            .list(ordered: false, start: 1, items: [
                MarkdownListItem(checked: false, blocks: [.paragraph("todo")]),
                MarkdownListItem(checked: true, blocks: [.paragraph("done")]),
            ]),
        ])
    }

    func testListInterruptsParagraphButBoldDoesNot() {
        let blocks = MarkdownParser.parse("intro:\n- a\n**bold** start\n*emph* too")
        XCTAssertEqual(blocks, [
            .paragraph("intro:"),
            .list(ordered: false, start: 1, items: [MarkdownListItem(blocks: [.paragraph("a\n**bold** start\n*emph* too")])]),
        ])
    }

    func testBlockQuoteIsParsedRecursively() {
        let blocks = MarkdownParser.parse("> # Note\n> - item\n>\n> text")
        XCTAssertEqual(blocks, [
            .quote([
                .heading(level: 1, text: "Note"),
                .list(ordered: false, start: 1, items: [MarkdownListItem(blocks: [.paragraph("item")])]),
                .paragraph("text"),
            ]),
        ])
    }

    func testTableWithAlignmentsAndEscapedPipe() {
        let blocks = MarkdownParser.parse("| Name | Count | Note |\n|:-----|------:|:---:|\n| a \\| b | 1 |\n| c | 2 | z | extra |")
        XCTAssertEqual(blocks, [
            .table(header: ["Name", "Count", "Note"],
                   rows: [["a | b", "1", ""], ["c", "2", "z"]],
                   alignments: [.leading, .trailing, .center]),
        ])
    }

    func testPlainTextWithNumbersIsNotAList() {
        let blocks = MarkdownParser.parse("2024 was fine\n3.5 GB used\n-not a bullet")
        XCTAssertEqual(blocks, [.paragraph("2024 was fine\n3.5 GB used\n-not a bullet")])
    }
}
