import Foundation
import ClaudeRemoteCore
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
import UIKit

/// Keeps one Live Activity per busy session: starts it when a hosted session begins working, updates
/// it from the state the app already receives, ends it a while after the turn finishes. Push tokens
/// go to the Mac so it can keep updating the activity once iOS has closed the app's socket.
@MainActor
final class LiveActivityController {
    /// Called whenever an activity gets (or loses) a push token — the model forwards it to the Mac.
    var onPushToken: ((_ sessionId: String, _ token: String?) -> Void)?

    private var activities: [String: Activity<SessionActivityAttributes>] = [:]
    private var tokenTasks: [String: Task<Void, Never>] = [:]
    private var lastStates: [String: SessionActivityState] = [:]

    static var isSupported: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Activities that survived a relaunch (the app was killed while one was showing) are adopted
    /// so they keep updating instead of going stale.
    func adoptExisting() {
        for activity in Activity<SessionActivityAttributes>.activities {
            let id = activity.attributes.info.sessionId
            if let existing = activities[id], existing.id != activity.id {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
                continue
            }
            activities[id] = activity
            lastStates[id] = activity.content.state
            observeTokens(activity)
        }
    }

    /// Ids of sessions with an activity showing, for re-registering push tokens after a reconnect.
    var activeSessionIds: [String] { Array(activities.keys) }

    func pushToken(for sessionId: String) -> String? {
        activities[sessionId]?.pushToken?.map { String(format: "%02x", $0) }.joined()
    }

    /// Brings the session's activity in line with `state`: start, update, or end it.
    func sync(_ info: SessionActivityInfo, state: SessionActivityState) {
        let id = info.sessionId
        if state.isTerminal {
            guard let activity = activities[id] else { return }
            let hold: TimeInterval = state.phase == .stopped ? 5 * 60 : 15 * 60
            let content = ActivityContent(state: state, staleDate: nil)
            activities[id] = nil
            lastStates[id] = nil
            tokenTasks[id]?.cancel(); tokenTasks[id] = nil
            Task { await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(hold))) }
            onPushToken?(id, nil)
            return
        }
        guard lastStates[id] != state else { return }
        lastStates[id] = state
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(20 * 60), relevanceScore: state.phase == .needsApproval ? 100 : 50)
        if let activity = activities[id] {
            let alert: AlertConfiguration? = state.phase == .needsApproval
                ? AlertConfiguration(title: "\(info.project.isEmpty ? info.title : info.project) needs approval",
                                     body: "\(state.pendingTool ?? "Tool"): \(state.detail)", sound: .default)
                : nil
            Task { await activity.update(content, alertConfiguration: alert) }
            return
        }
        guard Self.isSupported else { return }
        let attributes = SessionActivityAttributes(info: info)
        do {
            // Ask for a push token; a build without the push entitlement simply never receives one.
            let activity = try Activity.request(attributes: attributes, content: content, pushType: .token)
            activities[id] = activity
            observeTokens(activity)
        } catch {
            if let activity = try? Activity.request(attributes: attributes, content: content, pushType: nil) {
                activities[id] = activity
            }
        }
    }

    /// Ends every activity at once (switching Macs, signing out).
    func endAll() {
        for (id, activity) in activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
            tokenTasks[id]?.cancel()
        }
        activities = [:]
        tokenTasks = [:]
        lastStates = [:]
    }

    private func observeTokens(_ activity: Activity<SessionActivityAttributes>) {
        let id = activity.attributes.info.sessionId
        tokenTasks[id]?.cancel()
        tokenTasks[id] = Task { [weak self] in
            for await data in activity.pushTokenUpdates {
                let token = data.map { String(format: "%02x", $0) }.joined()
                await MainActor.run { self?.onPushToken?(id, token) }
            }
        }
    }
}
#else
/// Live Activities don't exist on Mac Catalyst; the model talks to this stub instead.
@MainActor
final class LiveActivityController {
    var onPushToken: ((_ sessionId: String, _ token: String?) -> Void)?
    static var isSupported: Bool { false }
    var activeSessionIds: [String] { [] }
    func adoptExisting() {}
    func pushToken(for sessionId: String) -> String? { nil }
    func sync(_ info: SessionActivityInfo, state: SessionActivityState) {}
    func endAll() {}
}
#endif

/// Tracks, per session, the bits of the stream the activity headline needs — the same cheap
/// bookkeeping the Mac does for its pushes, so both sides describe the turn the same way.
struct ActivityTracker {
    var lastTool: (name: String, line: String)?
    var thinking = false
    var turnStartedAt: Date?

    mutating func apply(_ payload: JSONValue) {
        switch payload["type"]?.string {
        case "assistant":
            for block in payload["message"]?["content"]?.array ?? [] {
                switch block["type"]?.string {
                case "tool_use":
                    let name = block["name"]?.string ?? "tool"
                    lastTool = (name, ToolSummary.line(name: name, input: block["input"] ?? .object([:])))
                    thinking = false
                case "thinking": thinking = true
                case "text": thinking = false
                default: break
                }
            }
        case "user":
            if payload["message"]?["content"]?.array?.contains(where: { $0["type"]?.string == "tool_result" }) == true { lastTool = nil }
        case "result":
            lastTool = nil
            thinking = false
        default:
            break
        }
    }
}
