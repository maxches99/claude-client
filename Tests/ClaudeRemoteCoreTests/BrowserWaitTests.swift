import XCTest
@testable import ClaudeRemoteCore

final class BrowserWaitTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func tool(_ name: String, at date: Date) -> TranscriptItem {
        TranscriptItem(id: "t", kind: .toolUse(id: "tu1", name: name, input: .object([:]), partialInput: "", streaming: false), timestamp: date)
    }

    func testQuietBrowserToolIsAStall() {
        let items = [tool("mcp__Claude_Browser__javascript_tool", at: start)]
        let stall = BrowserWait.stalled(in: items, now: start.addingTimeInterval(90))
        XCTAssertEqual(stall?.toolUseId, "tu1")
        XCTAssertEqual(BrowserWait.shortName(stall?.toolName ?? ""), "javascript_tool")
    }

    func testNotYetLongEnoughOrNotABrowserTool() {
        XCTAssertNil(BrowserWait.stalled(in: [tool("mcp__Claude_Browser__navigate", at: start)], now: start.addingTimeInterval(20)))
        XCTAssertNil(BrowserWait.stalled(in: [tool("Bash", at: start)], now: start.addingTimeInterval(600)))
    }

    func testAnsweredToolIsNotAStall() {
        let items = [tool("mcp__claude-in-chrome__navigate", at: start),
                     TranscriptItem(id: "r", kind: .toolResult(toolUseId: "tu1", text: "ok", isError: false, images: []), timestamp: start)]
        XCTAssertNil(BrowserWait.stalled(in: items, now: start.addingTimeInterval(600)))
    }
}
