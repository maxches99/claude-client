import XCTest
@testable import ClaudeRemoteCore

/// Guards the daemon→phone Codable round trip for every message shape this feature set added or changed,
/// including a representative `/usage` payload (the kind of nested nulls/numbers that a naive generic
/// JSON type can mis-decode into a `TypeMismatch`).
final class UsageRoundTripTests: XCTestCase {
    private func roundTripServer(_ m: ServerMessage) throws -> ServerMessage {
        try ProtocolCoding.decode(ServerMessage.self, from: ProtocolCoding.encode(m))
    }
    private func roundTripClient(_ m: ClientMessage) throws -> ClientMessage {
        try ProtocolCoding.decode(ClientMessage.self, from: ProtocolCoding.encode(m))
    }

    /// Shaped like the real `get_usage` response: mixed int/float/null/bool, nested objects and arrays.
    private static let usageJSON = #"""
    {"session":{"total_cost_usd":1.23,"total_lines_added":0,"model_usage":{}},
     "subscription_type":"max","rate_limits_available":true,
     "rate_limits":{"five_hour":{"utilization":35,"resets_at":"2026-09-19T21:10:00.5+00:00","limit_dollars":null},
                    "seven_day":{"utilization":38.4,"resets_at":"2026-09-21T07:00:00+00:00"},
                    "seven_day_opus":null,"nimbus_quill":{"utilization":0,"resets_at":null}},
     "limits":[{"kind":"session","percent":35,"is_active":false},{"kind":"weekly_all","percent":38,"is_active":true}],
     "behaviors":null}
    """#

    func testUsagePayloadRoundTrips() throws {
        let payload = try JSONValue.parse(Self.usageJSON)
        let decoded = try roundTripServer(.usage(sessionId: "s", data: payload, error: nil))
        guard case .usage(_, let d, _) = decoded, let d else { return XCTFail("not usage") }
        XCTAssertEqual(d, payload, "the usage payload must survive the round trip byte-for-byte")
        XCTAssertEqual(d["rate_limits"]?["five_hour"]?["utilization"]?.double, 35)
    }

    func testChangedServerMessagesRoundTrip() throws {
        _ = try roundTripServer(.fileList(sessionId: "s", paths: ["a/b.swift", "c.md"]))
        _ = try roundTripServer(.gitDiff(sessionId: "s", diff: "# Status\n+added\n-removed", error: nil))
        _ = try roundTripServer(.usage(sessionId: "s", data: nil, error: "no session"))
        let state = SessionState(id: "s", origin: .host, status: .idle, cwd: "/x", slashCommands: ["review", "compact"])
        let back = try roundTripServer(.state(state: state))
        guard case .state(let s) = back else { return XCTFail("not state") }
        XCTAssertEqual(s.slashCommands, ["review", "compact"])
    }

    func testChangedClientMessagesRoundTrip() throws {
        _ = try roundTripClient(.permission(sessionId: "s", requestId: "r", allow: true, message: nil, remember: true))
        _ = try roundTripClient(.permission(sessionId: "s", requestId: "r", allow: false, message: "no"))
        _ = try roundTripClient(.prompt(sessionId: "s", text: "hi", images: [],
                                        attachments: [Attachment(filename: "a.pdf", mediaType: "application/pdf", base64: "AAAA")]))
        _ = try roundTripClient(.getUsage(sessionId: "s"))
        _ = try roundTripClient(.listFiles(sessionId: "s", query: "chat"))
    }
}
