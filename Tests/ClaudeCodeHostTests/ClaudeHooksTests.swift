import XCTest
@testable import ClaudeCodeHost

final class ClaudeHooksTests: XCTestCase {
    private var path: String!

    override func setUp() {
        path = NSTemporaryDirectory() + "ccremote-hooks-\(UUID().uuidString)/settings.json"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    private func read() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
    }

    func testInstallCreatesFileAndUninstallCleansUp() throws {
        XCTAssertFalse(ClaudeHooks.isInstalled(path: path))
        try ClaudeHooks.install(path: path)
        XCTAssertTrue(ClaudeHooks.isInstalled(path: path))
        let hooks = try XCTUnwrap(read()["hooks"] as? [String: Any])
        let entries = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        let hook = try XCTUnwrap((entries[0]["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(hook["type"] as? String, "command")
        XCTAssertEqual(hook["timeout"] as? Int, 600)
        XCTAssertTrue((hook["command"] as? String ?? "").contains("ccremote/hook.sock"))
        // Installing twice does not duplicate.
        try ClaudeHooks.install(path: path)
        XCTAssertEqual(((try read()["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]])?.count, 1)
        try ClaudeHooks.uninstall(path: path)
        XCTAssertFalse(ClaudeHooks.isInstalled(path: path))
        XCTAssertNil(try read()["hooks"])
    }

    func testKeepsOtherSettingsAndHooks() throws {
        let existing: [String: Any] = [
            "permissions": ["allow": ["Bash(ls:*)"]],
            "hooks": [
                "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "echo pre"]]]],
                "PermissionRequest": [["matcher": "Edit", "hooks": [["type": "command", "command": "echo mine"]]]],
            ],
        ]
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: existing).write(to: URL(fileURLWithPath: path))
        try ClaudeHooks.install(path: path)
        var settings = try read()
        XCTAssertNotNil(settings["permissions"])
        var hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["PreToolUse"])
        XCTAssertEqual((hooks["PermissionRequest"] as? [[String: Any]])?.count, 2)
        try ClaudeHooks.uninstall(path: path)
        settings = try read()
        hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let left = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])
        XCTAssertEqual(left.count, 1)
        XCTAssertEqual(left[0]["matcher"] as? String, "Edit")
        XCTAssertNotNil(hooks["PreToolUse"])
    }

    func testMalformedFileIsReported() throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "not json".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ClaudeHooks.install(path: path))
        XCTAssertFalse(ClaudeHooks.isInstalled(path: path))
    }
}
