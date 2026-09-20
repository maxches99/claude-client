import Foundation

/// What a session's Live Activity shows. The phone renders it from the state it already has, and the
/// Mac pushes the very same shape through APNs (as the `content-state`) when the app isn't running —
/// so the encoding here *is* the push payload; keep the keys stable.
public struct SessionActivityState: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case working
        case needsApproval
        case done
        case failed
        case stopped
    }

    public var phase: Phase
    /// One line of what's happening: "Running Bash", "Thinking…", "Needs approval: Bash", the final answer.
    public var headline: String
    /// A second line: the command / file, or the pending tool's summary.
    public var detail: String
    /// When the current turn started, as Unix seconds — a plain number so the APNs `content-state`
    /// decodes the same way ActivityKit encodes it (no date-strategy guesswork).
    public var turnStartedAt: TimeInterval?
    /// The approval waiting on the user, so the Dynamic Island can answer it in place.
    public var pendingRequestId: String?
    public var pendingTool: String?
    /// The phone requires Face ID for Allow — the widget then opens the app instead of approving inline.
    public var approvalNeedsApp: Bool

    public init(phase: Phase, headline: String, detail: String = "", turnStartedAt: TimeInterval? = nil,
                pendingRequestId: String? = nil, pendingTool: String? = nil, approvalNeedsApp: Bool = true) {
        self.phase = phase
        self.headline = headline
        self.detail = detail
        self.turnStartedAt = turnStartedAt
        self.pendingRequestId = pendingRequestId
        self.pendingTool = pendingTool
        self.approvalNeedsApp = approvalNeedsApp
    }

    /// Builds the state from what both sides know: the session state plus the last tool the agent
    /// called (the Mac tracks it per session; the phone reads it off the transcript).
    public static func make(status: SessionStatus, pending: PermissionRequest?, lastTool: (name: String, line: String)?,
                            thinking: Bool, turnStartedAt: Date?, lastError: String?, approvalNeedsApp: Bool) -> SessionActivityState {
        let turnStartedAt = turnStartedAt?.timeIntervalSince1970
        switch status {
        case .awaitingPermission:
            let tool = pending.map { $0.displayName ?? ToolSummary.displayName($0.toolName) } ?? "tool"
            let line = pending.map { $0.title ?? ToolSummary.line(name: $0.toolName, input: $0.input) } ?? ""
            return SessionActivityState(phase: .needsApproval, headline: "\(tool) needs approval", detail: oneLine(line),
                                        turnStartedAt: turnStartedAt, pendingRequestId: pending?.id, pendingTool: tool,
                                        approvalNeedsApp: approvalNeedsApp)
        case .running:
            if let tool = lastTool {
                return SessionActivityState(phase: .working, headline: "Running \(ToolSummary.displayName(tool.name))", detail: oneLine(tool.line),
                                            turnStartedAt: turnStartedAt, approvalNeedsApp: approvalNeedsApp)
            }
            return SessionActivityState(phase: .working, headline: thinking ? "Thinking…" : "Working…", turnStartedAt: turnStartedAt,
                                        approvalNeedsApp: approvalNeedsApp)
        case .idle, .unknown:
            if let lastError, !lastError.isEmpty {
                return SessionActivityState(phase: .failed, headline: "Turn failed", detail: oneLine(lastError), approvalNeedsApp: approvalNeedsApp)
            }
            return SessionActivityState(phase: .done, headline: "Done", approvalNeedsApp: approvalNeedsApp)
        case .exited:
            return SessionActivityState(phase: .stopped, headline: "Session stopped", detail: oneLine(lastError ?? ""), approvalNeedsApp: approvalNeedsApp)
        }
    }

    static func oneLine(_ text: String, limit: Int = 120) -> String {
        let collapsed = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }

    /// True for the states that end the activity (after a grace period on the phone).
    public var isTerminal: Bool { phase == .done || phase == .failed || phase == .stopped }
    public var turnStartDate: Date? { turnStartedAt.map { Date(timeIntervalSince1970: $0) } }
}

/// Fixed facts of an activity, set when it starts. Mirrors the app's `ActivityAttributes`.
public struct SessionActivityInfo: Codable, Hashable, Sendable {
    public var sessionId: String
    public var title: String
    public var project: String
    public var agent: AgentKind

    public init(sessionId: String, title: String, project: String, agent: AgentKind) {
        self.sessionId = sessionId
        self.title = title
        self.project = project
        self.agent = agent
    }
}
