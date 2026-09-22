import XCTest
@testable import ClaudeCodeHost
@testable import ClaudeRemoteCore

/// Worktrees against a real repository: the branch is created, the directory lands next to the repo,
/// and removing it is refused for the main working tree.
final class WorktreeTests: XCTestCase {
    private var root: String!
    private var repo: String { (root as NSString).appendingPathComponent("repo") }

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "ccremote-wt-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try run("git", ["init", "-q", "-b", "main", repo])
        try run("git", ["-C", repo, "config", "user.email", "test@example.com"])
        try run("git", ["-C", repo, "config", "user.name", "Test"])
        try "hello\n".write(toFile: (repo as NSString).appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try run("git", ["-C", repo, "add", "."])
        try run("git", ["-C", repo, "commit", "-qm", "first"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [tool] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    private func makeManager() -> SessionManager {
        SessionManager(cli: ClaudeCLI(path: "/nonexistent/claude"),
                       store: TranscriptStore(claudeHome: (root as NSString).appendingPathComponent("claude-home")))
    }

    func testAddingAWorktreeMakesABranchAndADirectoryNextToTheRepo() async throws {
        let manager = makeManager()
        let path = try await manager.addWorktree(repo: repo, name: "login-fix", branch: "task/login-fix", base: nil)
        XCTAssertEqual((path as NSString).lastPathComponent, "repo-login-fix")
        XCTAssertTrue(FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("README.md")),
                      "the worktree is a real checkout")

        let items = try await manager.worktrees(repo: repo)
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[0].isMain)
        XCTAssertEqual(items[0].branch, "main")
        XCTAssertEqual(items[1].branch, "task/login-fix")
    }

    func testASecondWorktreeWithTheSameNameGetsItsOwnDirectory() async throws {
        let manager = makeManager()
        let first = try await manager.addWorktree(repo: repo, name: "fix", branch: "fix-1", base: nil)
        let second = try await manager.addWorktree(repo: repo, name: "fix", branch: "fix-2", base: nil)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual((second as NSString).lastPathComponent, "repo-fix-2")
    }

    func testNonRepositoriesAreRefused() async throws {
        let manager = makeManager()
        let plain = (root as NSString).appendingPathComponent("not-a-repo")
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        do {
            _ = try await manager.addWorktree(repo: plain, name: "x", branch: "x", base: nil)
            XCTFail("a directory that is not a git repository must be refused")
        } catch {
            XCTAssertTrue("\(error)".lowercased().contains("git"), "unexpected error: \(error)")
        }
    }
}
