import Foundation

/// What the phone's home-screen widget shows, written by the app through the shared App Group
/// whenever sessions change. Small on purpose — a widget reads it on a tight budget.
public struct WidgetSummary: Codable, Equatable, Sendable {
    public struct Row: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var title: String
        public var project: String
        public var status: SessionStatus
        public var agent: AgentKind
        public init(id: String, title: String, project: String, status: SessionStatus, agent: AgentKind) {
            self.id = id
            self.title = title
            self.project = project
            self.status = status
            self.agent = agent
        }
    }

    public var pending: Int
    public var running: Int
    public var hostName: String
    public var connected: Bool
    /// Sessions worth a glance, most urgent first (awaiting approval, then running, then recent).
    public var rows: [Row]
    public var updatedAt: Date

    public init(pending: Int, running: Int, hostName: String, connected: Bool, rows: [Row], updatedAt: Date = Date()) {
        self.pending = pending
        self.running = running
        self.hostName = hostName
        self.connected = connected
        self.rows = rows
        self.updatedAt = updatedAt
    }

    /// Where a tap should land: the first session needing approval, else the app.
    public var deepLinkURL: URL {
        if let row = rows.first(where: { $0.status == .awaitingPermission }) ?? rows.first(where: { $0.status == .running }),
           let url = URL(string: "ccremote://session/\(row.id)") { return url }
        return URL(string: "ccremote://open")!
    }

    public static let appGroup = "group.dev.maxches.ccremote"
    public static let kind = "SessionsOverview"
    private static let key = "phone.summary"

    public static func save(_ summary: WidgetSummary) {
        guard let defaults = UserDefaults(suiteName: appGroup), let data = try? JSONEncoder().encode(summary) else { return }
        defaults.set(data, forKey: key)
    }

    public static func load() -> WidgetSummary? {
        guard let defaults = UserDefaults(suiteName: appGroup), let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSummary.self, from: data)
    }
}
