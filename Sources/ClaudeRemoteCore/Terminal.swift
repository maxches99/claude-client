import Foundation

/// A shell running on the Mac in a pseudo-terminal. Like a background process it outlives the
/// phone's connection: coming back attaches to the same shell, with the screen replayed.
public struct TerminalInfo: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var cwd: String
    public var sessionId: String?
    public var title: String?
    public var cols: Int
    public var rows: Int
    public var startedAt: Date
    public var running: Bool
    public var exitCode: Int32?

    public init(id: String, cwd: String, sessionId: String? = nil, title: String? = nil, cols: Int, rows: Int,
                startedAt: Date = Date(), running: Bool = true, exitCode: Int32? = nil) {
        self.id = id
        self.cwd = cwd
        self.sessionId = sessionId
        self.title = title
        self.cols = cols
        self.rows = rows
        self.startedAt = startedAt
        self.running = running
        self.exitCode = exitCode
    }

    public var projectName: String { (cwd as NSString).lastPathComponent }
    public var displayName: String { title?.isEmpty == false ? title! : projectName }
}
