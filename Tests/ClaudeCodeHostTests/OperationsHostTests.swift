import XCTest
import ClaudeRemoteCore
@testable import ClaudeCodeHost

final class OperationsHostTests: XCTestCase {
    private func git(_ repo: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", repo, "-c", "user.name=t", "-c", "user.email=t@t"] + args
        try? p.run(); p.waitUntilExit()
    }

    func testSnapshotAndRestore() throws {
        let repo = NSTemporaryDirectory() + "snap-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: repo) }
        func write(_ name: String, _ text: String) throws { try text.write(toFile: repo + "/" + name, atomically: true, encoding: .utf8) }
        func read(_ name: String) -> String? { try? String(contentsOfFile: repo + "/" + name, encoding: .utf8) }
        git(repo, ["init", "-q"])
        try write(".gitignore", "build/\n")
        try write("a.txt", "one\n")
        git(repo, ["add", "-A"]); git(repo, ["commit", "-q", "-m", "init"])
        // Before the task: an uncommitted edit, an untracked file, an ignored file.
        try write("a.txt", "one\nlocal edit\n")
        try write("notes.txt", "mine\n")
        try FileManager.default.createDirectory(atPath: repo + "/build", withIntermediateDirectories: true)
        try write("build/out", "artifact\n")

        let manager = SessionManager(cli: .missing)
        let snapshot = try XCTUnwrap(manager.takeSnapshot(repo: repo, id: "t1"))
        // Taking it changed nothing.
        XCTAssertEqual(read("a.txt"), "one\nlocal edit\n")
        XCTAssertEqual(read("notes.txt"), "mine\n")

        // The "task": edits, deletes, adds, commits.
        try write("a.txt", "rewritten\n")
        try FileManager.default.removeItem(atPath: repo + "/notes.txt")
        try write("new.swift", "let x = 1\n")
        git(repo, ["add", "-A"]); git(repo, ["commit", "-q", "-m", "task"])
        try write("scratch.txt", "left over\n")

        try manager.restoreSnapshot(snapshot, repo: repo)
        XCTAssertEqual(read("a.txt"), "one\nlocal edit\n")
        XCTAssertEqual(read("notes.txt"), "mine\n")
        XCTAssertNil(read("new.swift"))
        XCTAssertNil(read("scratch.txt"))
        XCTAssertEqual(read("build/out"), "artifact\n")   // ignored files are left alone
        let head = Process()
        head.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        head.arguments = ["-C", repo, "rev-parse", "HEAD"]
        let pipe = Pipe(); head.standardOutput = pipe
        try head.run(); head.waitUntilExit()
        XCTAssertEqual(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), snapshot.head)
    }

    func testEventsPersistAndFilter() async throws {
        let dir = NSTemporaryDirectory() + "events-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let manager = SessionManager(cli: .missing, taskStore: dir + "/tasks.json")
        let old = HostEvent(date: Date(timeIntervalSinceNow: -100), kind: .task, title: "old")
        await manager.recordEvent(old)
        await manager.recordEvent(HostEvent(kind: .ci, title: "new"))
        let recent = await manager.eventList(since: Date(timeIntervalSinceNow: -10))
        XCTAssertEqual(recent.map(\.title), ["new"])
        let reloaded = SessionManager(cli: .missing, taskStore: dir + "/tasks.json")
        await reloaded.loadEvents()
        let all = await reloaded.eventList(since: nil)
        XCTAssertEqual(all.map(\.title), ["old", "new"])
    }

    func testMeasureReportsTheMachine() {
        let report = SessionManager.measure()
        XCTAssertNotNil(report.diskFree)
        XCTAssertNotNil(report.memoryUsed)
        XCTAssertGreaterThan(report.cpuCount, 0)
    }
}

/// Needs a booted Simulator; runs with CCREMOTE_PREVIEW_TEST=1 (and CCREMOTE_PREVIEW_DEVICE=<udid> when several are booted).
final class PreviewCaptureTests: XCTestCase {
    func testCaptureTakesAStill() throws {
        guard ProcessInfo.processInfo.environment["CCREMOTE_PREVIEW_TEST"] == "1" else { throw XCTSkip("set CCREMOTE_PREVIEW_TEST=1 with a Simulator booted") }
        let dir = NSTemporaryDirectory() + "preview-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let manager = SessionManager(cli: .missing)
        let device = ProcessInfo.processInfo.environment["CCREMOTE_PREVIEW_DEVICE"] ?? "booted"
        let config = PreviewConfig(command: "xcrun simctl openurl \(device) https://example.com", device: device, settle: 2)
        let result = manager.capturePreview(config, dir: dir, output: dir + "/after.jpg")
        let path = try result.get()
        let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(size, 10_000)
    }
}
