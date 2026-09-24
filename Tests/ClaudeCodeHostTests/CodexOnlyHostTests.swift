import XCTest
import ClaudeRemoteCore
@testable import ClaudeCodeHost

/// A Mac with Codex and no Claude CLI: the daemon runs, says so, and refuses only what needs Claude.
final class CodexOnlyHostTests: XCTestCase {
    func testNoneDisablesClaude() {
        XCTAssertNil(ClaudeCLI.locate(environment: ["CCREMOTE_CLAUDE_PATH": "none"]))
    }

    func testMissingCLIAnswersNothing() {
        let cli = ClaudeCLI.missing
        XCTAssertFalse(cli.isInstalled)
        XCTAssertNil(cli.version())
        XCTAssertNil(cli.authStatus())
    }

    func testOlderHostsCountAsHavingClaude() throws {
        let old = #"{"hostName":"Mac","daemonVersion":"0.2.0","cliPath":"/x/claude","protocolVersion":5}"#
        let info = try ProtocolCoding.decode(HostInfo.self, from: old)
        XCTAssertNil(info.hasClaude)
        XCTAssertTrue(info.claudeInstalled)
        let codexOnly = HostInfo(hostName: "Mac", daemonVersion: "0.2.0", cliVersion: nil, cliPath: "", loggedIn: nil, hasClaude: false)
        let decoded = try ProtocolCoding.decode(HostInfo.self, from: try ProtocolCoding.encode(codexOnly))
        XCTAssertFalse(decoded.claudeInstalled)
    }

    func testClaudeSessionIsRefusedWithAClearError() async throws {
        let dir = NSTemporaryDirectory() + "codex-only-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let manager = SessionManager(cli: .missing)
        let info = await manager.hostInfo(daemonVersion: "test")
        XCTAssertEqual(info.hasClaude, false)
        do {
            _ = try await manager.create(NewSessionOptions(cwd: dir, agent: .claude))
            XCTFail("a Claude session started without Claude")
        } catch {
            XCTAssertTrue("\(error)".contains("not installed"), "\(error)")
        }
    }
}
