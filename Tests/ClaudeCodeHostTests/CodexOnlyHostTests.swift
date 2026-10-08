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

    func testDesktopBundledFindsBothLayouts() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? fm.removeItem(atPath: root) }
        func make(_ path: String) throws {
            let full = root + "/" + path + "/claude.app/Contents/MacOS"
            try fm.createDirectory(atPath: full, withIntermediateDirectories: true)
            fm.createFile(atPath: full + "/claude", contents: Data(), attributes: [.posixPermissions: 0o755])
        }
        try make("2.1.280")
        XCTAssertEqual(ClaudeCLI.desktopBundled(root: root), root + "/2.1.280/claude.app/Contents/MacOS/claude")
        // The newer version's build sits one level deeper; an unverified sibling loses to the verified one.
        try make("2.1.293/aaaa")
        try make("2.1.293/bbbb")
        fm.createFile(atPath: root + "/2.1.293/bbbb/.verified", contents: Data())
        XCTAssertEqual(ClaudeCLI.desktopBundled(root: root), root + "/2.1.293/bbbb/claude.app/Contents/MacOS/claude")
    }
}
