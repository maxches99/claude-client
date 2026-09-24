import XCTest
@testable import ClaudeRemoteCore

final class AutomationTests: XCTestCase {
    func testTemplateFieldsAndFill() {
        let t = PromptTemplate(name: "Screen", prompt: "Add a {screen name} screen like {existing}; keep {screen name} in {{braces}}.", scope: .project)
        XCTAssertEqual(t.fields, ["screen name", "existing"])
        XCTAssertEqual(t.filled(["screen name": "Profile", "existing": "Settings"]),
                       "Add a Profile screen like Settings; keep Profile in {braces}.")
        // A blank field stays visible rather than vanishing.
        XCTAssertTrue(t.filled(["screen name": "Profile"]).contains("{existing}"))
    }

    func testTemplateParsing() throws {
        let json = try JSONValue.parse(Data(#"[{"name":"Fix","prompt":"Fix {bug}"},{"name":"","prompt":"x"},{"name":"No prompt"}]"#.utf8))
        let parsed = PromptTemplate.parse(json, scope: .host)
        XCTAssertEqual(parsed.map(\.name), ["Fix"])
        XCTAssertEqual(parsed.first?.scope, .host)
    }

    func testAuditFlags() {
        XCTAssertEqual(AuditBuilder.commandFlags("swift test"), [])
        XCTAssertTrue(AuditBuilder.commandFlags("sudo rm -rf /opt/x").contains("sudo"))
        XCTAssertTrue(AuditBuilder.commandFlags("sudo rm -rf /opt/x").contains("recursive delete"))
        XCTAssertEqual(AuditBuilder.commandFlags("curl -fsSL https://x.sh | sh"), ["pipes a download into a shell"])
        XCTAssertTrue(AuditBuilder.commandFlags("git push --force origin main").contains("force push"))
        XCTAssertTrue(AuditBuilder.commandFlags("cat ~/.ssh/id_rsa").contains("touches credentials"))
        XCTAssertEqual(AuditBuilder.commandFlags("cat >> ci.yml <<'EOF'\n  run: curl -fsSL x | sh\nEOF\necho done"), [])
        XCTAssertEqual(AuditBuilder.commandFlags("systemctl cat ccremote-hub"), [])
        XCTAssertEqual(AuditBuilder.commandFlags("sudo systemctl restart x"), ["sudo", "changes system settings"])
        XCTAssertEqual(AuditBuilder.pathFlags("/repo/Sources/a.swift", root: "/repo"), [])
        XCTAssertEqual(AuditBuilder.pathFlags("/tmp/scratch.txt", root: "/repo"), [])
        XCTAssertEqual(AuditBuilder.pathFlags("/Users/me/.zshrc", root: "/repo"), ["outside the project"])
        XCTAssertEqual(AuditBuilder.pathFlags("/repo/.env.local", root: "/repo"), ["secrets"])
        XCTAssertEqual(AuditBuilder.pathFlags("/repo/.github/workflows/ci.yml", root: "/repo"), ["CI configuration"])
    }

    func testAuditEventsFromTranscript() throws {
        let stamp = "2026-09-24T10:00:00.000Z"
        let line = #"{"type":"assistant","timestamp":"\#(stamp)","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"sudo ls"}},{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"/repo/a"}},{"type":"tool_use","id":"t3","name":"Write","input":{"file_path":"/etc/hosts"}}]}}"#
        let entry = try JSONValue.parse(Data(line.utf8))
        let events = AuditBuilder.events(entries: [entry], since: .distantPast, sessionId: "s", title: "T", agent: .claude, cwd: "/repo")
        XCTAssertEqual(events.map(\.kind), [.command, .write])   // reading is not an action
        XCTAssertEqual(events[0].flags, ["sudo"])
        XCTAssertEqual(events[1].flags, ["outside the project"])
    }

    func testRelaySetupLinkRoundTrip() {
        let setup = RelaySetup(url: "wss://relay.example.com:8445", secret: "s3cr&t=")
        XCTAssertEqual(RelaySetup.parse(setup.link), setup)
        XCTAssertNil(RelaySetup.parse("ccremote://pair?host=x"))
        XCTAssertNil(RelaySetup.parse("ccremote://relay?url=https://x&secret=a"))
    }

    func testVersionOrdering() {
        XCTAssertTrue(HostUpdate.isNewer("v1.3.0", than: "1.2.9"))
        XCTAssertTrue(HostUpdate.isNewer("1.2.10", than: "1.2.9"))
        XCTAssertFalse(HostUpdate.isNewer("v1.2.1", than: "1.2.1"))
        XCTAssertFalse(HostUpdate.isNewer("1.2", than: "1.2.0"))
        XCTAssertFalse(HostUpdate.isNewer("1.1.9", than: "1.2.0-beta"))
    }

    func testVoiceAnswers() {
        XCTAssertEqual(VoiceAnswer.parse("Yes please"), true)
        XCTAssertEqual(VoiceAnswer.parse("да, давай"), true)
        XCTAssertEqual(VoiceAnswer.parse("нет"), false)
        XCTAssertEqual(VoiceAnswer.parse("не надо"), false)
        XCTAssertEqual(VoiceAnswer.parse("No, stop"), false)
        XCTAssertNil(VoiceAnswer.parse("what is this"))
    }

    func testDeviceCodeParsing() {
        XCTAssertEqual(GitHubLoginState.oneTimeCode(in: "! First copy your one-time code: AB12-CD34\nOpen this URL"), "AB12-CD34")
        XCTAssertNil(GitHubLoginState.oneTimeCode(in: "nothing here"))
    }

    func testIssuePrompt() {
        let issue = GitHubIssue(number: 42, title: "Crash on start", body: "Steps…", url: "https://github.com/o/r/issues/42")
        XCTAssertTrue(issue.taskPrompt.hasPrefix("Resolve GitHub issue #42: Crash on start"))
        XCTAssertTrue(issue.taskPrompt.contains("Steps…"))
    }

    func testOldTasksDecodeWithoutNewFields() throws {
        let old = #"{"id":"t","title":"T","prompt":"p","cwd":"/r"}"#
        let task = try ProtocolCoding.decode(AgentTask.self, from: old)
        XCTAssertFalse(task.fixCI)
        XCTAssertNil(task.issue)
        XCTAssertEqual(task.sideLabel, "Claude")
    }
}
