import XCTest
import ClaudeRemoteCore
@testable import ClaudeCodeHost

final class PeopleHostTests: XCTestCase {
    private func tempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "people-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func testMemberSeesOnlyTheirOwn() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let manager = SessionManager(cli: .missing, taskStore: dir + "/tasks.json", workspaceRoot: dir + "/work")
        await manager.setMembers([MemberAccess(id: "m1", name: "Anna", claudeToken: "tok")])
        await manager.claim("s-anna", for: "m1")
        let annaSees = await manager.canAccess("s-anna", user: "m1")
        let annaSeesOwner = await manager.canAccess("s-owner", user: "m1")
        let ownerSees = await manager.canAccess("s-anna", user: nil)
        XCTAssertTrue(annaSees); XCTAssertFalse(annaSeesOwner); XCTAssertTrue(ownerSees)

        let folder = await manager.memberWorkspace("m1")
        XCTAssertTrue(folder.hasSuffix("/work/anna"))
        let inside = await manager.inMemberWorkspace(folder + "/repo", user: "m1")
        let outside = await manager.inMemberWorkspace(dir + "/work/other", user: "m1")
        XCTAssertTrue(inside); XCTAssertFalse(outside)

        let env = await manager.environment(forSession: "s-anna")
        XCTAssertEqual(env["CLAUDE_CODE_OAUTH_TOKEN"], "tok")
        let ownerEnv = await manager.environment(forSession: "s-owner")
        XCTAssertTrue(ownerEnv.isEmpty)

        let state = SessionState(id: "s-owner", origin: .host, status: .idle, cwd: "/x")
        let hidden = await manager.filtered(.state(state: state), for: "m1")
        XCTAssertNil(hidden)
        let dropped = await manager.filtered(.duels(items: []), for: "m1")
        XCTAssertNil(dropped)

        // Owners survive a restart.
        let again = SessionManager(cli: .missing, taskStore: dir + "/tasks.json", workspaceRoot: dir + "/work")
        await again.loadSessionOwners()
        let owner = await again.owner(of: "s-anna")
        XCTAssertEqual(owner, "m1")
    }

    func testPackageRoundTripBetweenClones() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        func git(_ repo: String, _ args: [String]) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repo, "-c", "user.name=t", "-c", "user.email=t@t"] + args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
        }
        // A "remote", the sender's clone with a branch, a commit and an uncommitted change.
        let origin = dir + "/origin.git"
        try FileManager.default.createDirectory(atPath: origin, withIntermediateDirectories: true)
        git(origin, ["init", "-q", "--bare"])
        let seed = dir + "/seed"
        try FileManager.default.createDirectory(atPath: seed, withIntermediateDirectories: true)
        git(seed, ["init", "-q", "-b", "main"]); try "one\n".write(toFile: seed + "/a.txt", atomically: true, encoding: .utf8)
        git(seed, ["add", "-A"]); git(seed, ["commit", "-q", "-m", "init"]); git(seed, ["remote", "add", "origin", origin]); git(seed, ["push", "-q", "origin", "main"])
        git(seed, ["fetch", "-q", "origin"]); git(seed, ["branch", "-q", "--set-upstream-to=origin/main"])
        git(seed, ["checkout", "-q", "-b", "feature"])
        try "two\n".write(toFile: seed + "/b.txt", atomically: true, encoding: .utf8)
        git(seed, ["add", "-A"]); git(seed, ["commit", "-q", "-m", "feature work"])
        try "one\nedited\n".write(toFile: seed + "/a.txt", atomically: true, encoding: .utf8)

        // Built by hand the way exportSession packs it (no transcript store in a test).
        let manager = SessionManager(cli: .missing, taskStore: dir + "/support/tasks.json", workspaceRoot: dir + "/work")
        let bundleFile = dir + "/f.bundle"
        git(seed, ["bundle", "create", bundleFile, "feature", "^origin/main"])
        let base = { () -> String in
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = ["-C", seed, "rev-parse", "origin/main"]
            let pipe = Pipe(); p.standardOutput = pipe; try? p.run(); p.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }()
        let patch = { () -> String in
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = ["-C", seed, "diff", "HEAD", "--binary"]
            let pipe = Pipe(); p.standardOutput = pipe; try? p.run(); p.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }()
        let id = UUID().uuidString.lowercased()
        let transcript = #"{"type":"user","cwd":"\#(seed)","sessionId":"\#(id)","message":{"content":"hi"}}"# + "\n"
        let package = SessionPackage(agent: .claude, title: "Feature", sessionId: id, cwd: seed, remoteURL: origin, branch: "feature",
                                     baseCommit: base, transcript: Data(transcript.utf8).base64EncodedString(),
                                     gitBundle: try Data(contentsOf: URL(fileURLWithPath: bundleFile)).base64EncodedString(), patch: patch, from: "test")
        let result = try await manager.importSession(package, cwd: nil, user: nil)
        defer {
            let encoded = String(result.cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
            try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/.claude/projects/" + encoded)
        }
        XCTAssertEqual(result.sessionId, id)
        XCTAssertEqual(try String(contentsOfFile: result.cwd + "/b.txt", encoding: .utf8), "two\n")          // the commit
        XCTAssertEqual(try String(contentsOfFile: result.cwd + "/a.txt", encoding: .utf8), "one\nedited\n")  // the uncommitted change
        let encoded = String(result.cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        let written = try String(contentsOfFile: NSHomeDirectory() + "/.claude/projects/\(encoded)/\(id).jsonl", encoding: .utf8)
        XCTAssertTrue(written.contains(#""cwd":"\#(result.cwd)""#))
    }
}
