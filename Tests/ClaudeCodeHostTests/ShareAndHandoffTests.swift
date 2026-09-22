import XCTest
@testable import ClaudeCodeHost
@testable import ClaudeRemoteCore

/// Share links against the real relay (started from relay/ with node), and the handoff list for a
/// real project folder.
final class ShareAndHandoffTests: XCTestCase {
    func testRelayAddressBecomesAnHTTPBase() {
        XCTAssertEqual(ShareConfig.httpBase(fromRelay: URL(string: "wss://relay.example.com:8445")!)?.absoluteString, "https://relay.example.com:8445")
        XCTAssertEqual(ShareConfig.httpBase(fromRelay: URL(string: "ws://127.0.0.1:8787/")!)?.absoluteString, "http://127.0.0.1:8787")
        XCTAssertNil(ShareConfig.httpBase(fromRelay: URL(string: "ftp://nope")!))
    }

    /// Publish, read back, revoke — through the relay code this repository deploys.
    func testShareRoundTripThroughTheRelay() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let relayScript = repo.appendingPathComponent("relay/relay.mjs").path
        guard let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"].first(where: FileManager.default.isExecutableFile(atPath:)),
              FileManager.default.fileExists(atPath: repo.appendingPathComponent("relay/node_modules/ws").path) else {
            throw XCTSkip("node or the relay's node_modules are not available")
        }
        let port = Int.random(in: 20000...40000)
        let relay = Process()
        relay.executableURL = URL(fileURLWithPath: node)
        relay.arguments = [relayScript, "--port", "\(port)", "--host", "127.0.0.1"]
        relay.environment = ["CCRELAY_SECRET": "test-secret", "PATH": "/usr/bin:/bin"]
        relay.standardOutput = FileHandle.nullDevice
        relay.standardError = FileHandle.nullDevice
        try relay.run()
        defer { relay.terminate() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        for _ in 0..<50 {   // wait for it to listen
            if (try? await URLSession.shared.data(from: base.appendingPathComponent("healthz"))) != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let manager = SessionManager(cli: ClaudeCLI(path: "/nonexistent/claude"),
                                     store: TranscriptStore(claudeHome: NSTemporaryDirectory() + "ccremote-share-" + UUID().uuidString))
        let payload = SharePayload(ivBase64: Data(repeating: 7, count: 12).base64EncodedString(),
                                   ciphertextBase64: Data("sealed page".utf8).base64EncodedString(), ttlSeconds: 3600)
        do {
            _ = try await manager.shareTranscript(sessionId: "s", title: "T", payload: payload)
            XCTFail("sharing without a relay configured must fail")
        } catch {}

        await manager.setShareConfig(ShareConfig(endpoint: base, publicBase: URL(string: "https://relay.example.com")!, room: "room-1", secret: "wrong"))
        do {
            _ = try await manager.shareTranscript(sessionId: "s", title: "T", payload: payload)
            XCTFail("the relay must refuse a wrong secret")
        } catch {}

        await manager.setShareConfig(ShareConfig(endpoint: base, publicBase: URL(string: "https://relay.example.com")!, room: "room-1", secret: "test-secret"))
        let share = try await manager.shareTranscript(sessionId: "s", title: "T", payload: payload)
        XCTAssertTrue(share.url.hasPrefix("https://relay.example.com/s/"), "links use the public address: \(share.url)")
        XCTAssertGreaterThan(share.expiresAt.timeIntervalSinceNow, 3500)

        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("s/\(share.id)/data"))
        let stored = try JSONValue.parse(data)
        XCTAssertEqual(stored["ct"]?.string, payload.ciphertextBase64, "the relay keeps exactly the ciphertext")
        XCTAssertEqual(stored["iv"]?.string, payload.ivBase64)

        let (page, response) = try await URLSession.shared.data(from: base.appendingPathComponent("s/\(share.id)"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("/viewer.js"))

        try await manager.revokeShare(shareId: share.id)
        let (_, gone) = try await URLSession.shared.data(from: base.appendingPathComponent("s/\(share.id)/data"))
        XCTAssertEqual((gone as? HTTPURLResponse)?.statusCode, 404, "a revoked link is gone")
    }

    /// A project on disk offers Terminal and Finder always, Xcode when it has a package or project.
    func testHandoffTargetsForAProject() async throws {
        let home = NSTemporaryDirectory() + "ccremote-handoff-" + UUID().uuidString
        let project = home + "/work/app"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        try "// swift-tools-version: 5.10\n".write(toFile: project + "/Package.swift", atomically: true, encoding: .utf8)
        let sessionId = UUID().uuidString.lowercased()
        let projects = home + "/claude/projects/-work-app"
        try FileManager.default.createDirectory(atPath: projects, withIntermediateDirectories: true)
        let line = #"{"type":"user","uuid":"u1","sessionId":"\#(sessionId)","cwd":"\#(project)","message":{"content":"hello"}}"#
        try (line + "\n").write(toFile: "\(projects)/\(sessionId).jsonl", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: home) }

        let manager = SessionManager(cli: ClaudeCLI(path: "/nonexistent/claude"), store: TranscriptStore(claudeHome: home + "/claude"))
        let ids = await manager.handoffTargets(sessionId: sessionId).map(\.id)
        XCTAssertTrue(ids.contains("terminal"))
        XCTAssertTrue(ids.contains("finder"))
        if SessionManager.applicationPath("Xcode") != nil { XCTAssertTrue(ids.contains("xcode"), "a Swift package opens in Xcode") }
        if SessionManager.applicationPath("Claude") != nil { XCTAssertEqual(ids.first, "desktop", "Claude Desktop comes first when installed") }
        XCTAssertEqual(SessionManager.xcodeProject(in: project), project + "/Package.swift")
        XCTAssertEqual(SessionManager.shellQuote("it's"), #"'it'\''s'"#)
    }
}
