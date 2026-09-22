import XCTest
@testable import ClaudeCodeHost
@testable import ClaudeRemoteCore

/// A real shell in a real pseudo-terminal: it runs what is typed, is a proper terminal for the
/// programs in it (tty, size, ^C), replays its screen to a phone that attaches later, and goes away
/// when closed.
final class TerminalTests: XCTestCase {
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: [UInt8] = []
        private(set) var exited = false
        var exitCode: Int32?

        func receive(_ message: ServerMessage) {
            lock.withLock {
                switch message {
                case .terminalOutput(_, let b64):
                    if let d = Data(base64Encoded: b64) { bytes += [UInt8](d) }
                case .terminalExited(_, let code):
                    exited = true
                    exitCode = code
                default: break
                }
            }
        }

        var text: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }
        var screen: TerminalScreen {
            var s = TerminalScreen(cols: 80, rows: 24)
            s.feed(lock.withLock { bytes })
            return s
        }
    }

    private func makeManager() -> SessionManager {
        SessionManager(cli: ClaudeCLI(path: "/nonexistent/claude"),
                       store: TranscriptStore(claudeHome: NSTemporaryDirectory() + "ccremote-term-" + UUID().uuidString))
    }

    private func eventually(_ condition: @Sendable () -> Bool, _ message: String, timeout: TimeInterval = 15,
                            file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail(message, file: file, line: line)
    }

    private func type(_ manager: SessionManager, _ id: String, _ text: String) async {
        await manager.terminalInput(terminalId: id, data: Array(text.utf8))
    }

    func testShellRunsCommandsInATerminalOfTheRightSize() async throws {
        let manager = makeManager()
        let phone = UUID(), sink = Sink()
        await manager.subscribe(phone) { sink.receive($0) }
        try await manager.openTerminal(sessionId: nil, terminalId: "t1", cols: 100, rows: 30, phone: phone)

        // `test -t 0` proves stdin is a tty; `stty size` that the kernel knows the size we asked for.
        await type(manager, "t1", "test -t 0 && echo IS-A-TTY; stty size; echo DONE-$((40+2))\r")
        await eventually({ sink.text.contains("DONE-42") }, "the shell never ran the command: \(sink.text.suffix(400))")
        XCTAssertTrue(sink.text.contains("IS-A-TTY"), "stdin is not a terminal")
        XCTAssertTrue(sink.text.contains("30 100"), "stty size did not report 30 rows × 100 columns: \(sink.text.suffix(300))")

        await manager.resizeTerminal(terminalId: "t1", cols: 60, rows: 20)
        await type(manager, "t1", "stty size; echo RESIZED\r")
        await eventually({ sink.text.contains("RESIZED") }, "no output after the resize")
        XCTAssertTrue(sink.text.contains("20 60"), "the new size did not reach the terminal: \(sink.text.suffix(300))")

        await type(manager, "t1", "exit\r")
        await eventually({ sink.exited }, "the shell did not exit")
        let left = await manager.listTerminals()
        XCTAssertTrue(left.isEmpty, "an exited terminal is forgotten")
    }

    /// ^C must reach the program in the foreground — the reason the shell gets a controlling terminal.
    func testControlCInterruptsTheForegroundProgram() async throws {
        let manager = makeManager()
        let phone = UUID(), sink = Sink()
        await manager.subscribe(phone) { sink.receive($0) }
        try await manager.openTerminal(sessionId: nil, terminalId: "t2", cols: 80, rows: 24, phone: phone)
        await type(manager, "t2", "sleep 30; echo AFTER-SLEEP-$?\r")
        try await Task.sleep(nanoseconds: 800_000_000)
        await manager.terminalInput(terminalId: "t2", data: TerminalKey.control("c").bytes(applicationCursor: false))
        // An interrupted sleep exits with 130, and the shell carries on.
        await type(manager, "t2", "echo STILL-HERE\r")
        await eventually({ sink.text.contains("STILL-HERE") }, "the shell did not survive ^C: \(sink.text.suffix(300))")
        XCTAssertFalse(sink.text.contains("AFTER-SLEEP-0"), "sleep ran to the end instead of being interrupted")
        await manager.closeTerminal(terminalId: "t2")
        await eventually({ sink.exited }, "close did not hang up the shell")
    }

    func testAttachingLaterReplaysTheScreen() async throws {
        let manager = makeManager()
        let first = UUID(), firstSink = Sink()
        await manager.subscribe(first) { firstSink.receive($0) }
        try await manager.openTerminal(sessionId: nil, terminalId: "t3", cols: 80, rows: 24, phone: first)
        await type(manager, "t3", "echo MARKER-BEFORE-ATTACH\r")
        await eventually({ firstSink.text.contains("MARKER-BEFORE-ATTACH\r\n") }, "no output")

        let later = UUID(), laterSink = Sink()
        await manager.subscribe(later) { laterSink.receive($0) }
        await manager.attachTerminal(terminalId: "t3", phone: later, attached: true)
        await eventually({ laterSink.text.contains("MARKER-BEFORE-ATTACH") }, "the screen was not replayed to the second phone")
        await manager.closeTerminal(terminalId: "t3")
        await eventually({ laterSink.exited }, "the attached phone was not told the shell exited")
    }
}
