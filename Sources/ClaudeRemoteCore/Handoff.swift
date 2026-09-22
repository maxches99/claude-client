import Foundation

/// Somewhere on the Mac a session can be continued: Claude Desktop, a terminal running the CLI, the
/// project in Finder or an editor. The Mac lists what it actually has; the phone shows the list.
public struct HandoffTarget: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Continue the conversation itself (the daemon lets go of the session first).
        case session
        /// Open the project folder.
        case folder
    }

    public var id: String
    public var label: String
    public var systemImage: String
    public var kind: Kind
    public var detail: String?

    public init(id: String, label: String, systemImage: String, kind: Kind, detail: String? = nil) {
        self.id = id
        self.label = label
        self.systemImage = systemImage
        self.kind = kind
        self.detail = detail
    }
}
