import XCTest
@testable import ClaudeCodeHost
@testable import ClaudeRemoteCore

/// A background command really runs, really streams, and is really still there to attach to
/// afterwards — the whole point of not tying it to the phone's connection.
final class BackgroundProcessTests: XCTestCase {
    private func makeManager() -> SessionManager {
        SessionManager(cli: ClaudeCLI(path: "/nonexistent/claude"),
                       store: TranscriptStore(claudeHome: NSTemporaryDirectory() + "ccremote-proc-" + UUID().uuidString))
    }

    /// Collects the `commandOutput` frames a phone would receive.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var chunks: [String] = []
        private(set) var finished = false
        var exitCode: Int32?

        func receive(_ message: ServerMessage) {
            guard case .commandOutput(_, _, let chunk, let done, let code) = message else { return }
            lock.withLock {
                if !chunk.isEmpty { chunks.append(chunk) }
                if done { finished = true; exitCode = code }
            }
        }

        var text: String { lock.withLock { chunks.joined() } }
    }

    /// Polls until the condition holds, then fails with `message` if it never did.
    private func assertEventually(_ condition: @Sendable () -> Bool, _ message: String,
                                 timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail(message, file: file, line: line)
    }

    func testProcessStreamsOutputAndIsListedUntilItFinishes() async throws {
        let manager = makeManager()
        let phone = UUID()
        let sink = Sink()
        await manager.subscribe(phone) { message in sink.receive(message) }

        let runId = "run-1"
        try await manager.startProcess(sessionId: nil, runId: runId, command: "echo hello-from-the-mac", label: "Greeting", phone: phone)

        var listed = await manager.listProcesses()
        XCTAssertEqual(listed.first?.id, runId)
        XCTAssertEqual(listed.first?.label, "Greeting")

        await assertEventually({ sink.finished }, "the run never reported that it was done")
        XCTAssertTrue(sink.text.contains("hello-from-the-mac"), "output was not streamed: \(sink.text)")
        XCTAssertEqual(sink.exitCode, 0)

        listed = await manager.listProcesses()
        XCTAssertEqual(listed.first?.running, false, "a finished process stays in the list so its output can still be read")
        XCTAssertEqual(listed.first?.exitCode, 0)
    }

    func testAttachingLaterReplaysWhatWasBuffered() async throws {
        let manager = makeManager()
        let starter = UUID()
        let starterSink = Sink()
        await manager.subscribe(starter) { message in starterSink.receive(message) }
        try await manager.startProcess(sessionId: nil, runId: "run-2", command: "echo buffered-line", label: nil, phone: starter)
        await assertEventually({ starterSink.finished }, "the first run never finished")

        // A second phone (or the same one, reopened) attaches after the fact.
        let latecomer = UUID()
        let lateSink = Sink()
        await manager.subscribe(latecomer) { message in lateSink.receive(message) }
        await manager.attachProcess(runId: "run-2", phone: latecomer, attached: true)
        await assertEventually({ lateSink.finished }, "attaching to a finished run must also close it")
        XCTAssertTrue(lateSink.text.contains("buffered-line"), "the buffered tail was not replayed: \(lateSink.text)")
    }

    func testKillingAProcessStopsIt() async throws {
        let manager = makeManager()
        let phone = UUID()
        let sink = Sink()
        await manager.subscribe(phone) { message in sink.receive(message) }
        try await manager.startProcess(sessionId: nil, runId: "run-3", command: "sleep 30", label: "Sleeper", phone: phone)
        await manager.killProcess(runId: "run-3")
        await assertEventually({ sink.finished }, "the process did not stop")
        let listed = await manager.listProcesses()
        XCTAssertEqual(listed.first?.running, false)
    }
}
