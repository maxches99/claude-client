import XCTest
@testable import ClaudeCodeHost
@testable import ClaudeRemoteCore

/// Phone sessions in the desktop apps' own lists: the Codex app's projects file and Claude
/// Desktop's per-session records — written into temporary copies, never the real ones.
final class DesktopAppsTests: XCTestCase {
    private var dir: String!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "ccremote-desktop-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    func testLocalProjectIdMatchesTheCodexApp() {
        // An id the Codex app gave one of its projects.
        XCTAssertEqual(CodexAppState.localProjectId(for: "/Users/maxches99/Desktop/VoiceToText"),
                       "local-63d13f18a11961f395fa9f5991a97e3e")
    }

    func testProjectRootsAndContainment() {
        let state: [String: Any] = [
            "local-projects": ["a": ["id": "a", "rootPaths": ["/p/app"]]],
            "electron-saved-workspace-roots": ["/p/app", "/p/site"],
        ]
        let roots = CodexAppState.projectRoots(state)
        XCTAssertEqual(Set(roots), ["/p/app", "/p/site"])
        XCTAssertTrue(CodexAppState.contains("/p/app", roots: roots))
        XCTAssertTrue(CodexAppState.contains("/p/app/Sources", roots: roots))
        XCTAssertFalse(CodexAppState.contains("/p/application", roots: roots))
    }

    func testAssignFilesThreadsAndKeepsEverythingElse() throws {
        let file = dir + "/state.json"
        let state: [String: Any] = [
            "local-projects": ["uuid-1": ["id": "uuid-1", "name": "app", "rootPaths": ["/p/app"]]],
            "project-order": ["uuid-1"],
            "electron-saved-workspace-roots": ["/p/app"],
            "thread-project-assignments": ["old": ["projectKind": "local", "projectId": "uuid-1"]],
            "something-else": ["kept": true],
        ]
        try JSONSerialization.data(withJSONObject: state).write(to: URL(fileURLWithPath: file))

        let done = try CodexAppState.assign(threads: [("t1", "/p/app/Sources"), ("t2", "/p/new")], file: file)
        XCTAssertEqual(done, ["t1", "t2"])

        let saved = try XCTUnwrap(CodexAppState.load(from: file))
        let assignments = try XCTUnwrap(saved["thread-project-assignments"] as? [String: [String: String]])
        XCTAssertEqual(assignments["t1"]?["projectId"], "uuid-1")
        let newId = CodexAppState.localProjectId(for: "/p/new")
        XCTAssertEqual(assignments["t2"]?["projectId"], newId)
        XCTAssertEqual(assignments["old"]?["projectId"], "uuid-1")
        let projects = try XCTUnwrap(saved["local-projects"] as? [String: [String: Any]])
        XCTAssertEqual(projects[newId]?["rootPaths"] as? [String], ["/p/new"])
        XCTAssertEqual(projects[newId]?["name"] as? String, "new")
        XCTAssertEqual(saved["project-order"] as? [String], [newId, "uuid-1"])
        XCTAssertEqual(saved["electron-saved-workspace-roots"] as? [String], ["/p/new", "/p/app"])
        XCTAssertEqual((saved["something-else"] as? [String: Bool])?["kept"], true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file + ".ccremote-backup"))
    }

    func testClaudeDesktopRecordIsWrittenThenOnlyRefreshed() throws {
        let org = dir + "/account/org"
        try FileManager.default.createDirectory(atPath: org, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: org + "/local_existing.json"))
        XCTAssertEqual(ClaudeDesktopSessions.activeDirectory(root: dir), org)

        var session = ClaudeDesktopSessions.Session(cliSessionId: "cli-1", cwd: "/p/app", title: nil, model: "claude-opus-5",
                                                    effort: nil, permissionMode: "acceptEdits",
                                                    createdAt: Date(timeIntervalSince1970: 100), lastActivityAt: Date(timeIntervalSince1970: 200))
        let id = try ClaudeDesktopSessions.upsert(session, recordId: nil, in: org)
        XCTAssertTrue(id.hasPrefix("local_"))
        func record() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(org)/\(id).json"))) as? [String: Any])
        }
        var r = try record()
        XCTAssertEqual(r["sessionId"] as? String, id)
        XCTAssertEqual(r["cliSessionId"] as? String, "cli-1")
        XCTAssertEqual(r["cwd"] as? String, "/p/app")
        XCTAssertEqual(r["permissionMode"] as? String, "acceptEdits")
        XCTAssertEqual(r["lastActivityAt"] as? Int, 200_000)

        // Desktop adds its own fields; a later turn must not drop them.
        r["remoteMcpServersConfig"] = ["x"]
        try JSONSerialization.data(withJSONObject: r).write(to: URL(fileURLWithPath: "\(org)/\(id).json"))
        session.title = "Fix the build"
        session.lastActivityAt = Date(timeIntervalSince1970: 300)
        XCTAssertEqual(try ClaudeDesktopSessions.upsert(session, recordId: id, in: org), id)
        r = try record()
        XCTAssertEqual(r["title"] as? String, "Fix the build")
        XCTAssertEqual(r["lastActivityAt"] as? Int, 300_000)
        XCTAssertEqual(r["remoteMcpServersConfig"] as? [String], ["x"])

        // Renamed in Desktop: the user's title wins.
        r["title"] = "Mine"
        r["titleSource"] = "user"
        try JSONSerialization.data(withJSONObject: r).write(to: URL(fileURLWithPath: "\(org)/\(id).json"))
        _ = try ClaudeDesktopSessions.upsert(session, recordId: id, in: org)
        XCTAssertEqual(try record()["title"] as? String, "Mine")

        // Deleted in Desktop: not brought back.
        try FileManager.default.removeItem(atPath: "\(org)/\(id).json")
        _ = try ClaudeDesktopSessions.upsert(session, recordId: id, in: org)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(org)/\(id).json"))
    }

    func testPhoneSessionsAreRememberedAcrossRestarts() async throws {
        let taskStore = dir + "/tasks.json"
        func manager() -> SessionManager {
            SessionManager(cli: ClaudeCLI(path: "/nonexistent/claude"),
                           store: TranscriptStore(claudeHome: dir + "/claude"), taskStore: taskStore)
        }
        let first = manager()
        await first.notePhoneSession(SessionState(id: "s1", origin: .host, status: .idle, cwd: "/p/app"))
        await first.notePhoneSession(SessionState(id: "chat", origin: .host, status: .idle, cwd: "/tmp", kind: .chat))
        let remembered = await first.recentPhoneSessions()
        XCTAssertEqual(remembered.map(\.id), ["s1"])

        let second = manager()
        await second.loadPhoneSessions()
        let reloaded = await second.recentPhoneSessions()
        XCTAssertEqual(reloaded.map(\.id), ["s1"])
        XCTAssertEqual(reloaded.first?.projectName, "app")
    }
}
