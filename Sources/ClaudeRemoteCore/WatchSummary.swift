import Foundation

/// Compact state the Watch app writes for its complication to read (via an App Group). Kept tiny
/// because the widget process reads it on a tight budget.
public struct WatchSummary: Codable, Equatable, Sendable {
    public var pending: Int      // sessions awaiting approval
    public var running: Int      // sessions currently working
    public var total: Int
    public var hostName: String
    public var connected: Bool
    /// The session the complication deep-links to (the oldest one awaiting approval), if any.
    public var pendingSessionId: String?
    public var updatedAt: Date

    public init(pending: Int, running: Int, total: Int, hostName: String, connected: Bool,
                pendingSessionId: String? = nil, updatedAt: Date = Date()) {
        self.pending = pending
        self.running = running
        self.total = total
        self.hostName = hostName
        self.connected = connected
        self.pendingSessionId = pendingSessionId
        self.updatedAt = updatedAt
    }

    /// Deep link the complication opens: straight to the session needing approval, else the app root.
    public var deepLinkURL: URL {
        if let id = pendingSessionId, let url = URL(string: "ccwatch://session/\(id)") { return url }
        return URL(string: "ccwatch://open")!
    }

    /// Shared between the Watch app and its widget extension.
    public static let appGroup = "group.dev.maxches.ccremote"
    private static let key = "watch.summary"

    public static func save(_ summary: WatchSummary) {
        guard let defaults = UserDefaults(suiteName: appGroup), let data = try? JSONEncoder().encode(summary) else { return }
        defaults.set(data, forKey: key)
    }

    public static func load() -> WatchSummary? {
        guard let defaults = UserDefaults(suiteName: appGroup), let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WatchSummary.self, from: data)
    }
}
