import XCTest
@testable import ClaudeCodeHost
@testable import ClaudeRemoteCore

/// What the host makes of crash reports: a baseline first, news after that, and fix tasks.
final class CrashHostTests: XCTestCase {
    private var directory: String!

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "ccremote-crash-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: directory)
    }

    private func makeManager() -> SessionManager {
        SessionManager(cli: ClaudeCLI(path: "/nonexistent/claude"),
                       store: TranscriptStore(claudeHome: directory + "/claude-home"),
                       taskStore: (directory as NSString).appendingPathComponent("tasks.json"))
    }

    /// A source whose address fails at once, so nothing leaves the machine.
    private func source(autoFix: Bool = false) -> CrashSource {
        CrashSource(baseURL: "http://127.0.0.1:9", organization: "acme", project: "ios", cwd: directory, autoFix: autoFix,
                    hasToken: true, token: "t")
    }

    private func issue(_ id: String, source: CrashSource) -> CrashIssue {
        CrashIssue(sourceId: source.id, issueId: id, title: "Crash \(id)", count: 1)
    }

    func testTheFirstLookIsABaselineAndLaterOnesAreNews() async throws {
        let manager = makeManager()
        let src = source()
        await manager.mergeCrashes([issue("1", source: src)], from: src, announce: false)
        var events = await manager.events
        XCTAssertFalse(events.contains { $0.title.contains("New crash") }, "what a project already had is not news")

        await manager.mergeCrashes([issue("1", source: src), issue("2", source: src)], from: src, announce: true)
        events = await manager.events
        XCTAssertEqual(events.filter { $0.title.contains("New crash") }.count, 1, "only the crash not seen before is announced")
        let crashes = await manager.crashIssues
        XCTAssertEqual(crashes.count, 2)
    }

    func testFixingACrashQueuesAWorktreeTaskOnce() async throws {
        let manager = makeManager()
        let src = source()
        await manager.setCrashSourcesForTest([src])
        await manager.mergeCrashes([issue("7", source: src)], from: src, announce: false)
        try await manager.fixCrash(id: "\(src.id):7")
        let tasks = await manager.taskList().items
        let task = try XCTUnwrap(tasks.first)
        XCTAssertTrue(task.title.hasPrefix("Fix crash"))
        XCTAssertTrue(task.inWorktree)
        XCTAssertTrue(task.prompt.contains("Crash 7"))
        let crash = await manager.crashIssues.first
        XCTAssertEqual(crash?.taskId, task.id)
    }

    func testTokensStayInTheHostFileOnly() async throws {
        let manager = makeManager()
        await manager.setCrashSourcesForTest([source()])
        await manager.saveCrashes()
        let report = await manager.crashReport()
        guard case .crashes(let sources, _, _) = report else { return XCTFail() }
        XCTAssertNil(sources.first?.token)
        XCTAssertEqual(sources.first?.hasToken, true)
        let path = (directory as NSString).appendingPathComponent("crashes.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}

extension SessionManager {
    func setCrashSourcesForTest(_ sources: [CrashSource]) { crashSources = sources }
}
