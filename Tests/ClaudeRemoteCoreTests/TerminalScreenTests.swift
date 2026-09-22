import XCTest
@testable import ClaudeRemoteCore

/// The terminal emulator against the sequences shells and full-screen programs actually send.
final class TerminalScreenTests: XCTestCase {
    func testTextWrapsAndScrollsIntoTheScrollback() {
        var s = TerminalScreen(cols: 10, rows: 3)
        s.feed("one\r\ntwo\r\nthree\r\nfour")
        XCTAssertEqual((0..<3).map { s.text(row: $0) }, ["two", "three", "four"])
        XCTAssertEqual(s.scrollback.map(TerminalScreen.plainText), ["one"])
        s.feed("\r\n0123456789AB")
        XCTAssertEqual(s.text(row: 1), "0123456789", "a full line wraps only when the next character arrives")
        XCTAssertEqual(s.text(row: 2), "AB")
    }

    func testCursorMovementAndErasing() {
        var s = TerminalScreen(cols: 20, rows: 5)
        s.feed("hello world")
        s.feed("\u{1B}[1;7H")          // row 1, column 7
        s.feed("\u{1B}[K")              // erase to the end of the line
        XCTAssertEqual(s.text(row: 0), "hello")
        s.feed("\u{1B}[3;3Hx\u{1B}[2J")
        XCTAssertEqual((0..<5).map { s.text(row: $0) }.joined(), "", "ED 2 clears the screen")
        s.feed("\u{1B}[HAB\u{1B}[D\u{1B}[@")   // insert a blank before B
        XCTAssertEqual(s.text(row: 0), "A B")
        s.feed("\u{1B}[1G\u{1B}[P")           // delete the first character
        XCTAssertEqual(s.text(row: 0), " B")
    }

    func testBackspaceAndCarriageReturnRedrawALine() {
        var s = TerminalScreen(cols: 20, rows: 2)
        // What a shell line editor does when you delete a character: back, blank, back.
        s.feed("ls -la\u{08} \u{08}")
        XCTAssertEqual(s.text(row: 0), "ls -l")
        s.feed("\r\u{1B}[Kgit status")
        XCTAssertEqual(s.text(row: 0), "git status")
    }

    func testColoursAndAttributes() {
        var s = TerminalScreen(cols: 20, rows: 2)
        s.feed("\u{1B}[1;31mR\u{1B}[0m\u{1B}[38;5;208mO\u{1B}[38;2;1;2;3mT\u{1B}[7mI\u{1B}[m.")
        let row = s.lines[0]
        XCTAssertEqual(row[0].attributes.fg, .indexed(1))
        XCTAssertTrue(row[0].attributes.bold)
        XCTAssertEqual(row[1].attributes.fg, .indexed(208))
        XCTAssertFalse(row[1].attributes.bold, "SGR 0 resets bold")
        XCTAssertEqual(row[2].attributes.fg, .rgb(1, 2, 3))
        XCTAssertTrue(row[3].attributes.inverse)
        XCTAssertEqual(row[4].attributes, .plain)
    }

    func testAlternateScreenLeavesTheMainScreenIntact() {
        var s = TerminalScreen(cols: 20, rows: 3)
        s.feed("prompt$ vim")
        s.feed("\u{1B}[?1049h\u{1B}[HEDITOR")
        XCTAssertTrue(s.usingAlternateScreen)
        XCTAssertEqual(s.text(row: 0), "EDITOR")
        s.feed("\u{1B}[?1049l")
        XCTAssertFalse(s.usingAlternateScreen)
        XCTAssertEqual(s.text(row: 0), "prompt$ vim", "leaving the editor brings the shell's screen back")
        XCTAssertEqual(s.cursorX, 11, "and the cursor where it was")
    }

    func testScrollRegionScrollsOnlyInside() {
        var s = TerminalScreen(cols: 10, rows: 4)
        s.feed("top\r\na\r\nb\r\nstatus")
        s.feed("\u{1B}[2;3r")               // rows 2…3 scroll; 1 and 4 stay
        s.feed("\u{1B}[3;1H\nc")            // line feed at the bottom of the region
        XCTAssertEqual((0..<4).map { s.text(row: $0) }, ["top", "b", "c", "status"])
        XCTAssertTrue(s.scrollback.isEmpty, "a region that does not start at the top keeps nothing")
    }

    func testRepliesToStatusQueries() {
        var s = TerminalScreen(cols: 80, rows: 24)
        s.feed("\u{1B}[5;10H")
        XCTAssertEqual(String(decoding: s.feed("\u{1B}[6n"), as: UTF8.self), "\u{1B}[5;10R", "cursor position report")
        XCTAssertEqual(String(decoding: s.feed("\u{1B}[c"), as: UTF8.self), "\u{1B}[?1;2c", "device attributes")
    }

    func testUTF8SplitAcrossReadsAndWideCharacters() {
        var s = TerminalScreen(cols: 10, rows: 2)
        let bytes = Array("Привет".utf8)
        s.feed(Array(bytes.prefix(5)))       // cut in the middle of a character
        s.feed(Array(bytes.dropFirst(5)))
        XCTAssertEqual(s.text(row: 0), "Привет")
        s.feed("\r\n日本")
        XCTAssertEqual(s.text(row: 1), "日本")
        XCTAssertEqual(s.cursorX, 4, "wide characters take two columns")
    }

    func testTitleAndModes() {
        var s = TerminalScreen(cols: 20, rows: 2)
        s.feed("\u{1B}]0;~/claude-client\u{07}\u{1B}[?1h\u{1B}[?25l\u{1B}[?2004h")
        XCTAssertEqual(s.title, "~/claude-client")
        XCTAssertTrue(s.applicationCursorKeys)
        XCTAssertFalse(s.cursorVisible)
        XCTAssertTrue(s.bracketedPaste)
        XCTAssertEqual(TerminalKey.up.bytes(applicationCursor: true), Array("\u{1B}OA".utf8))
        XCTAssertEqual(TerminalKey.control("c").bytes(applicationCursor: false), [0x03])
    }

    func testResizeKeepsTheCursorLineOnScreen() {
        var s = TerminalScreen(cols: 20, rows: 5)
        s.feed("1\r\n2\r\n3\r\n4\r\n5")
        s.resize(cols: 10, rows: 3)
        XCTAssertEqual((0..<3).map { s.text(row: $0) }, ["3", "4", "5"])
        XCTAssertEqual(s.cursorY, 2)
        XCTAssertEqual(s.scrollback.map(TerminalScreen.plainText), ["1", "2"])
    }
}

/// What a share link shows, and what it must never let through.
final class ShareAndDigestTests: XCTestCase {
    func testTranscriptPageEscapesEverythingFromTheTranscript() throws {
        var transcript = Transcript()
        transcript.apply(try JSONValue.parse(#"{"type":"user","uuid":"u1","message":{"content":"<script>alert(1)</script> **bold** and `a<b`"}}"#))
        transcript.apply(try JSONValue.parse(#"{"type":"assistant","uuid":"a1","message":{"id":"m1","content":[{"type":"text","text":"See [docs](https://example.com?a=1&b=2) and [bad](javascript:alert(1))\n\n```\n<img onerror=x>\n```"}]}}"#))
        let html = TranscriptHTML.page(items: transcript.items, options: TranscriptExport.Options(title: "T <1>", agentName: "Claude"))
        XCTAssertFalse(html.contains("<script>alert"), "script tags from the transcript must be escaped")
        XCTAssertFalse(html.contains("<img onerror"), "markup inside code must be escaped")
        XCTAssertFalse(html.contains("javascript:"), "only http(s) / mailto links survive")
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<code>a&lt;b</code>"))
        XCTAssertTrue(html.contains(#"<a href="https://example.com?a=1&amp;b=2" rel="noopener noreferrer">docs</a>"#))
        XCTAssertTrue(html.contains("<title>T &lt;1&gt;</title>"))
    }

    func testDigestCountsWhatHappenedAfterTheCutoff() throws {
        let since = Transcript.parseDate("2026-09-22T10:00:00Z")!
        let lines = [
            #"{"type":"user","timestamp":"2026-09-22T09:00:00Z","message":{"content":"old prompt"}}"#,
            #"{"type":"user","timestamp":"2026-09-22T10:05:00Z","message":{"content":"fix the build"}}"#,
            #"{"type":"assistant","timestamp":"2026-09-22T10:06:00Z","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/repo/Sources/A.swift"}},{"type":"tool_use","name":"Edit","input":{"file_path":"/repo/Sources/A.swift"}},{"type":"tool_use","name":"Bash","input":{"command":"swift build"}}]}}"#,
            #"{"type":"user","timestamp":"2026-09-22T10:07:00Z","message":{"content":[{"type":"tool_result","tool_use_id":"x","is_error":true,"content":"error"}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-22T10:08:00Z","message":{"content":[{"type":"text","text":"Fixed it."}]}}"#,
        ]
        let entries = try lines.map { try JSONValue.parse($0) }
        let facts = DigestBuilder.summarize(entries: entries, since: since, cwd: "/repo")
        XCTAssertEqual(facts.prompts, 1, "the prompt before the cutoff is not news")
        XCTAssertEqual(facts.files, ["Sources/A.swift"])
        XCTAssertEqual(facts.fileCount, 1, "a file written twice counts once")
        XCTAssertEqual(facts.commands, 1)
        XCTAssertEqual(facts.errors, 1)
        XCTAssertEqual(facts.lastReply, "Fixed it.")
    }
}
