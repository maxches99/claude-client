import Foundation

/// Phone → Mac.
public enum ClientMessage: Codable, Sendable {
    /// Must be the first frame. `token` is the pairing secret shown by the daemon.
    case hello(token: String, client: String)
    case listSessions
    case listProjects
    /// Attach to a session: resumes it under the daemon if needed, or tails it when it is open in desktop.
    case open(sessionId: String)
    case create(options: NewSessionOptions)
    /// Copy a session (including one open in Claude Desktop) into a new daemon-hosted session and continue there.
    case fork(sessionId: String)
    case prompt(sessionId: String, text: String, images: [InlineImage] = [])
    case permission(sessionId: String, requestId: String, allow: Bool, message: String?)
    case interrupt(sessionId: String)
    case setModel(sessionId: String, model: String)
    case setPermissionMode(sessionId: String, mode: String)
    /// Stop the daemon's CLI process for this session (transcript stays on disk).
    case close(sessionId: String)
    /// Read an image file from the Mac (e.g. one referenced by a SendUserFile tool call).
    case fetchFile(path: String)
    /// Booted iOS Simulators on the Mac (also pushed as `simulators` whenever the set changes).
    case listSimulators
    /// Start / stop receiving live frames of a booted simulator. `maxPixelSize` bounds the frame's
    /// longer side, `fps` the capture rate (capped by the daemon). Frames stop when the phone disconnects.
    case simulatorStream(udid: String, enabled: Bool, maxPixelSize: Int?, fps: Double?)
    case ping
}

/// Mac → Phone.
public enum ServerMessage: Codable, Sendable {
    case welcome(host: HostInfo)
    case error(message: String, sessionId: String?)
    case sessions(items: [SessionSummary])
    case projects(items: [ProjectInfo])
    /// Transcript entries loaded from disk (same shape as live `event` payloads).
    case history(sessionId: String, entries: [JSONValue])
    /// A raw stream-json message from the CLI (assistant / user / stream_event / result / system).
    case event(sessionId: String, payload: JSONValue)
    case permissionRequest(request: PermissionRequest)
    case permissionResolved(sessionId: String, requestId: String)
    case state(state: SessionState)
    case file(path: String, mediaType: String?, base64: String?, error: String?)
    case simulators(items: [SimulatorInfo])
    case simulatorFrame(frame: SimulatorFrame)
    case pong
}

public enum ProtocolCoding {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    public static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        try decoder.decode(type, from: Data(text.utf8))
    }
}
