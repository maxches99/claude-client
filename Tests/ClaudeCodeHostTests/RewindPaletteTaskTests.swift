import XCTest
@testable import ClaudeCodeHost
@testable import ClaudeRemoteCore

/// The Mac-side pieces of rewind, the palette and the queue's clock — the parts that touch files and
/// dates, where being wrong is expensive.
final class RewindPaletteTaskTests: XCTestCase {
    private var directory: String!

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "ccremote-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: directory)
    }

    // MARK: rewind

    private func writeTranscript(_ lines: [String]) throws -> String {
        let path = (directory as NSString).appendingPathComponent("\(UUID().uuidString.lowercased()).jsonl")
        try lines.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func testRewindKeepsEverythingBeforeThePromptAndRewritesTheSessionId() throws {
        let path = try writeTranscript([
            #"{"type":"user","uuid":"u1","sessionId":"old","message":{"content":"first"}}"#,
            #"{"type":"assistant","uuid":"a1","sessionId":"old","message":{"content":[{"type":"text","text":"ok"}]}}"#,
            #"{"type":"user","uuid":"u2","sessionId":"old","message":{"content":"second"}}"#,
            #"{"type":"assistant","uuid":"a2","sessionId":"old","message":{"content":[{"type":"text","text":"done"}]}}"#,
            #"{"type":"last-prompt","leafUuid":"a2","sessionId":"old","lastPrompt":"second"}"#,
        ])
        let result = try SessionManager.writeRewound(from: path, upTo: "u2", newSessionId: "new-id")
        XCTAssertEqual(result.dropped, 3, "the prompt itself and everything after it are left behind")

        let written = try String(contentsOfFile: result.path, encoding: .utf8)
        let entries = written.split(separator: "\n").map { try! JSONValue.parse(Data($0.utf8)) }
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map { $0["uuid"]?.string }, ["u1", "a1"])
        XCTAssertTrue(entries.allSatisfy { $0["sessionId"]?.string == "new-id" }, "the copy must belong to the new session")
        XCTAssertTrue(result.path.hasSuffix("/new-id.jsonl"), "the CLI resumes a session by its file name")
    }

    func testRewindRefusesWhenTheMessageIsGoneOrNothingWouldBeLeft() throws {
        let path = try writeTranscript([
            #"{"type":"user","uuid":"u1","sessionId":"old","message":{"content":"first"}}"#,
        ])
        XCTAssertThrowsError(try SessionManager.writeRewound(from: path, upTo: "nope", newSessionId: "x"))
        XCTAssertThrowsError(try SessionManager.writeRewound(from: path, upTo: "u1", newSessionId: "x"),
                             "rewinding to the very first prompt would leave an empty transcript")
    }

    // MARK: palette

    func testFrontMatterReadsNameAndDescription() throws {
        let path = (directory as NSString).appendingPathComponent("SKILL.md")
        try """
        ---
        name: code-review
        description: "Review the diff for correctness"
        metadata:
          type: reference
        ---

        # Body
        name: not-this
        """.write(toFile: path, atomically: true, encoding: .utf8)
        let meta = SessionManager.frontMatter(path: path)
        XCTAssertEqual(meta["name"], "code-review")
        XCTAssertEqual(meta["description"], "Review the diff for correctness", "quotes are stripped")
        XCTAssertNil(meta["type"], "indented keys belong to a nested block, not the top level")
    }

    func testSkillAndCommandDiscovery() throws {
        let skills = (directory as NSString).appendingPathComponent("skills/deploy")
        try FileManager.default.createDirectory(atPath: skills, withIntermediateDirectories: true)
        try "---\nname: deploy\ndescription: Ship it\n---\n".write(toFile: (skills as NSString).appendingPathComponent("SKILL.md"),
                                                                   atomically: true, encoding: .utf8)
        let commands = (directory as NSString).appendingPathComponent("commands")
        try FileManager.default.createDirectory(atPath: commands, withIntermediateDirectories: true)
        try "Just a prompt, no front matter.\n".write(toFile: (commands as NSString).appendingPathComponent("tidy.md"),
                                                      atomically: true, encoding: .utf8)

        let skillItems = SessionManager.skillItems(in: (directory as NSString).appendingPathComponent("skills"), scope: .project)
        XCTAssertEqual(skillItems.map(\.name), ["deploy"])
        XCTAssertEqual(skillItems.first?.detail, "Ship it")
        XCTAssertEqual(skillItems.first?.insert, "/deploy ")

        let commandItems = SessionManager.markdownItems(in: commands, kind: .command, scope: .user)
        XCTAssertEqual(commandItems.map(\.name), ["tidy"], "a command without front matter is named by its file")
        XCTAssertNil(commandItems.first?.detail)

        XCTAssertEqual(SessionManager.markdownItems(in: (directory as NSString).appendingPathComponent("nothing-here"),
                                                    kind: .agent, scope: .project), [])
    }

    func testWorktreeSlugIsSafeForBranchesAndDirectories() {
        XCTAssertEqual(SessionManager.worktreeSlug("Fix the login bug!"), "fix-the-login-bug")
        XCTAssertEqual(SessionManager.worktreeSlug("  --weird--  "), "weird")
        XCTAssertEqual(SessionManager.worktreeSlug(String(repeating: "a", count: 80)).count, 40)
    }

    // MARK: the queue's clock

    func testNextDailyPicksTodayThenTomorrow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let noon = calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 12))!

        let later = SessionManager.nextDaily(minutes: 18 * 60, from: noon, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.day, .hour], from: later).day, 22)
        XCTAssertEqual(calendar.dateComponents([.day, .hour], from: later).hour, 18)

        let earlier = SessionManager.nextDaily(minutes: 9 * 60, from: noon, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.day, .hour], from: earlier).day, 23, "a time that has passed today runs tomorrow")
        XCTAssertEqual(calendar.dateComponents([.day, .hour], from: earlier).hour, 9)

        let clamped = SessionManager.nextDaily(minutes: 5000, from: noon, calendar: calendar)
        XCTAssertLessThan(clamped.timeIntervalSince(noon), 36 * 3600, "an out-of-range minute is clamped into a real time of day")
    }
}
