import XCTest
@testable import ClaudeRemoteCore

/// The phone→Mac simulator input messages must survive the wire unchanged (labels on every payload,
/// optionals dropped when nil) — the host replays them with the timing they carry.
final class SimulatorInputRoundTripTests: XCTestCase {
    private func roundTrip(_ event: SimulatorInputEvent) throws -> SimulatorInputEvent {
        let decoded = try ProtocolCoding.decode(ClientMessage.self, from: ProtocolCoding.encode(ClientMessage.simulatorInput(udid: "U", event: event)))
        guard case .simulatorInput(let udid, let back) = decoded, udid == "U" else { XCTFail("not simulatorInput"); throw CancellationError() }
        return back
    }

    func testEveryEventRoundTrips() throws {
        let events: [SimulatorInputEvent] = [
            .tap(x: 0.25, y: 0.75),
            .tap(x: 0.5, y: 0.5, holdSeconds: 1.2),
            .touch(phase: .moved, x: 0.8, y: 0.5),
            .text(text: "Hello\nпривет 🙂"),
            .key(key: .backspace),
            .button(button: .home),
        ]
        for event in events {
            XCTAssertEqual(try roundTrip(event), event)
        }
    }

    func testTapWithoutHoldOmitsTheField() throws {
        let json = try ProtocolCoding.encode(SimulatorInputEvent.tap(x: 0.1, y: 0.2))
        XCTAssertFalse(json.contains("holdSeconds"))
        XCTAssertTrue(json.contains(#""tap""#))
    }

    func testVideoFrameRoundTrips() throws {
        let frame = SimulatorVideoFrame(udid: "U", seq: 7, width: 640, height: 1390, keyframe: true, spsBase64: "Zw==", ppsBase64: "aA==", dataBase64: "AAAA", ptsMillis: 1234)
        let decoded = try ProtocolCoding.decode(ServerMessage.self, from: ProtocolCoding.encode(ServerMessage.simulatorVideo(frame: frame)))
        guard case .simulatorVideo(let back) = decoded else { return XCTFail("not simulatorVideo") }
        XCTAssertEqual(back, frame)
    }

    func testFailureMessageRoundTrips() throws {
        let decoded = try ProtocolCoding.decode(ServerMessage.self, from: ProtocolCoding.encode(ServerMessage.simulatorInputFailed(udid: "U", message: "no pasteboard")))
        guard case .simulatorInputFailed(let udid, let message) = decoded else { return XCTFail("not simulatorInputFailed") }
        XCTAssertEqual(udid, "U")
        XCTAssertEqual(message, "no pasteboard")
    }
}
