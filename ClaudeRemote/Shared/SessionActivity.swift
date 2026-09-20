import Foundation
import AppIntents
import ClaudeRemoteCore
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit

// Compiled into both the app and the widget extension: the activity's shape and the intents its
// buttons fire. `ContentState` is the Core struct so the Mac's APNs payload decodes straight into it.

struct SessionActivityAttributes: ActivityAttributes {
    typealias ContentState = SessionActivityState
    var info: SessionActivityInfo
}
#endif

/// Answers a permission request from the Live Activity / Dynamic Island. A `LiveActivityIntent`
/// runs inside the app process (launched in the background if needed), so it can talk to the Mac
/// over the app's own connection.
struct DecidePermissionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Answer a permission request"
    static var description = IntentDescription("Allows or denies a tool the agent is waiting on.")
    static var isDiscoverable = false

    @Parameter(title: "Session") var sessionId: String
    @Parameter(title: "Request") var requestId: String
    @Parameter(title: "Allow") var allow: Bool

    init() {}
    init(sessionId: String, requestId: String, allow: Bool) {
        self.sessionId = sessionId
        self.requestId = requestId
        self.allow = allow
    }

    func perform() async throws -> some IntentResult {
        await LiveActivityDecisions.shared.decide(sessionId: sessionId, requestId: requestId, allow: allow)
        return .result()
    }
}

/// Where the intent hands the decision over. The app installs a handler at launch; the widget
/// extension never performs the intent itself, so its copy stays a no-op.
final class LiveActivityDecisions: @unchecked Sendable {
    static let shared = LiveActivityDecisions()
    var handler: (@Sendable (_ sessionId: String, _ requestId: String, _ allow: Bool) async -> Void)?

    func decide(sessionId: String, requestId: String, allow: Bool) async {
        await handler?(sessionId, requestId, allow)
    }
}

extension SessionActivityInfo {
    /// Deep link into the session (the activity's tap target).
    var deepLink: URL { URL(string: "ccremote://session/\(sessionId)")! }
}
