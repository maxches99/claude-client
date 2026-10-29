import XCTest
@testable import ClaudeRemoteCore

final class TrustTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func bash(_ command: String) -> JSONValue { .object(["command": .string(command)]) }

    func testProjectGrantCoversSubfoldersOnly() {
        let grant = TrustGrant(sessionId: nil, cwd: "/p/app", tool: nil, createdAt: now, expiresAt: now.addingTimeInterval(60))
        XCTAssertTrue(grant.covers(sessionId: "s", sessionCwd: "/p/app/sub", toolName: "Edit", input: .object([:]), now: now))
        XCTAssertFalse(grant.covers(sessionId: "s", sessionCwd: "/p/application", toolName: "Edit", input: .object([:]), now: now))
        XCTAssertFalse(grant.covers(sessionId: "s", sessionCwd: "/p/app", toolName: "Edit", input: .object([:]), now: now.addingTimeInterval(61)))
        XCTAssertFalse(grant.covers(sessionId: "s", sessionCwd: "/p/app", toolName: "AskUserQuestion", input: .object([:]), now: now))
    }

    func testSessionGrantAndBashPrefix() {
        let grant = TrustGrant(sessionId: "s1", cwd: "/p", tool: "Bash(git *)", createdAt: now, expiresAt: now.addingTimeInterval(60))
        XCTAssertTrue(grant.covers(sessionId: "s1", sessionCwd: "/x", toolName: "Bash", input: bash("git status"), now: now))
        XCTAssertFalse(grant.covers(sessionId: "s2", sessionCwd: "/p", toolName: "Bash", input: bash("git status"), now: now))
        XCTAssertFalse(grant.covers(sessionId: "s1", sessionCwd: "/p", toolName: "Bash", input: bash("gitx"), now: now))
        XCTAssertFalse(grant.covers(sessionId: "s1", sessionCwd: "/p", toolName: "Bash", input: bash("git status && rm -rf /"), now: now))
        XCTAssertFalse(grant.covers(sessionId: "s1", sessionCwd: "/p", toolName: "Edit", input: .object([:]), now: now))
    }

    func testSuggestedTool() {
        XCTAssertEqual(TrustGrant.suggestedTool(toolName: "Bash", input: bash("npm test --watch")), "Bash(npm *)")
        XCTAssertEqual(TrustGrant.suggestedTool(toolName: "Write", input: .object([:])), "Write")
        XCTAssertEqual(TrustGrant(sessionId: nil, cwd: nil, tool: "Bash(npm *)", expiresAt: now).toolLabel, "`npm` commands")
    }
}
