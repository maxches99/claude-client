import XCTest
import ClaudeRemoteCore
@testable import ClaudeCodeHost

final class SubagentFilesTests: XCTestCase {
    func testHistoryIncludesTaggedSubagentEntries() throws {
        let dir = NSTemporaryDirectory() + "ccremote-sub-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sessionDir = dir + "/proj/abc"
        try FileManager.default.createDirectory(atPath: sessionDir + "/subagents", withIntermediateDirectories: true)
        let main = dir + "/proj/abc.jsonl"
        try #"{"type":"user","uuid":"u1","cwd":"/p","sessionId":"abc","message":{"role":"user","content":"hi"}}\#n"# .write(toFile: main, atomically: true, encoding: .utf8)
        try #"{"type":"assistant","uuid":"s1","isSidechain":true,"agentId":"a1","message":{"id":"m","content":[{"type":"text","text":"sub"}]}}"#
            .write(toFile: sessionDir + "/subagents/agent-a1.jsonl", atomically: true, encoding: .utf8)
        try #"{"agentType":"general-purpose","toolUseId":"toolu_1"}"#.write(toFile: sessionDir + "/subagents/agent-a1.meta.json", atomically: true, encoding: .utf8)
        let history = TranscriptStore().history(path: main)
        XCTAssertEqual(history.entries.count, 2)
        let sub = history.entries[1]
        XCTAssertEqual(sub["parent_tool_use_id"]?.string, "toolu_1")
        XCTAssertNil(sub["isSidechain"])
        var t = Transcript()
        t.apply(entries: history.entries)
        XCTAssertEqual(t.items.count, 1)
        XCTAssertEqual(t.subagents["toolu_1"]?.items.count, 1)
    }
}
