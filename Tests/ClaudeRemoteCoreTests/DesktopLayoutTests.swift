import XCTest
@testable import ClaudeRemoteCore

final class DesktopLayoutTests: XCTestCase {
    func testParsesPinsSectionsAndProjectOrder() throws {
        let json = """
        {"starred-local-code-sessions": ["local_a", "local_gone"],
         "dframe-code-sections": {"acct/org": {"sections": [
            {"id": "pinned", "kind": "pinned", "name": ""},
            {"id": "s1", "kind": "custom", "name": "Release", "collapsed": true, "sessionIds": ["local_b", "local_a"]}]}},
         "code-projects-order.acct": ["/Users/me/app", "owner/repo", "/Users/me/lib"]}
        """
        let prefs = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let layout = DesktopLayout.parse(prefs: prefs, cliIdForLocal: ["local_a": "A", "local_b": "B"])
        XCTAssertEqual(layout.pinned, ["A"])
        XCTAssertEqual(layout.sections, [DesktopLayout.Section(id: "s1", name: "Release", sessionIds: ["B", "A"], collapsed: true)])
        XCTAssertEqual(layout.projectOrder, ["/Users/me/app", "/Users/me/lib"])
    }
}
