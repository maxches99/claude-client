import Foundation

/// Phone → Mac.
public enum ClientMessage: Codable, Sendable {
    /// Must be the first frame. `token` is the pairing secret shown by the daemon. `device` is a
    /// human-readable device name and `deviceId` a stable per-device id — both optional, shown on
    /// the Mac as "paired with …".
    case hello(token: String, client: String, device: String? = nil, deviceId: String? = nil)
    case listSessions
    case listProjects
    /// Attach to a session: resumes it under the daemon if needed, or tails it when it is open in desktop.
    case open(sessionId: String)
    case create(options: NewSessionOptions)
    /// Copy a session (including one open in Claude Desktop) into a new daemon-hosted session and continue there.
    case fork(sessionId: String)
    /// `attachments` are non-image files (documents, video, voice memos); the host stages them to disk
    /// and references them by path in the prompt. Images should travel in `images` for direct vision.
    case prompt(sessionId: String, text: String, images: [InlineImage] = [], attachments: [Attachment]? = nil)
    /// `remember: true` also persists the CLI's suggested permission rule (from `permission_suggestions`),
    /// so matching tool calls are auto-approved later ("Allow & remember"). Nil/false = one-off allow.
    case permission(sessionId: String, requestId: String, allow: Bool, message: String?, remember: Bool? = nil)
    case interrupt(sessionId: String)
    case setModel(sessionId: String, model: String)
    /// Claude: permission mode. Codex: approval policy.
    case setPermissionMode(sessionId: String, mode: String)
    /// Reasoning effort for the following turns (Codex).
    case setEffort(sessionId: String, effort: String)
    /// Codex sandbox mode for the following turns.
    case setSandbox(sessionId: String, mode: String)
    /// Models the host can run for an agent; answered with `models`.
    case listModels(agent: AgentKind)
    /// Stop the daemon's CLI process for this session (transcript stays on disk).
    case close(sessionId: String)
    /// Read an image file from the Mac (e.g. one referenced by a SendUserFile tool call).
    case fetchFile(path: String)
    /// Ask for the session repo's uncommitted changes (git status + diff) to review before approving.
    case gitDiff(sessionId: String)
    /// Fuzzy-search files under the session's cwd for the composer's "@" mention picker. Empty query
    /// returns a first page of files.
    case listFiles(sessionId: String, query: String)
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
    case models(agent: AgentKind, items: [ModelOption])
    case file(path: String, mediaType: String?, base64: String?, error: String?)
    case gitDiff(sessionId: String, diff: String, error: String?)
    /// Files matching a `listFiles` query, as paths relative to the session's cwd.
    case fileList(sessionId: String, paths: [String])
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
