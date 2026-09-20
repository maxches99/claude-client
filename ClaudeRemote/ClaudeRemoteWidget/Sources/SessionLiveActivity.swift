import WidgetKit
import SwiftUI
import ActivityKit
import ClaudeRemoteCore

@main
struct ClaudeRemoteWidgetBundle: WidgetBundle {
    var body: some Widget { SessionLiveActivity() }
}

/// A running session on the lock screen and in the Dynamic Island: what the agent is doing, a turn
/// timer, and — when it stops to ask — Allow / Deny right there.
struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            LockScreenView(info: context.attributes.info, state: context.state)
                .activityBackgroundTint(Palette.background)
                .activitySystemActionForegroundColor(Palette.textPrimary)
                .widgetURL(context.attributes.info.deepLink)
        } dynamicIsland: { context in
            let info = context.attributes.info
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        AgentGlyph(agent: info.agent, phase: state.phase)
                        Text(info.project.isEmpty ? info.title : info.project)
                            .font(.caption.weight(.semibold)).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TrailingStatus(state: state).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.headline)
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !state.detail.isEmpty {
                            Text(state.detail)
                                .font(.system(.caption, design: state.phase == .working || state.phase == .needsApproval ? .monospaced : .default))
                                .foregroundStyle(Palette.textSecondary)
                                .lineLimit(2)
                        }
                        if state.phase == .needsApproval {
                            ApprovalButtons(info: info, state: state)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                AgentGlyph(agent: info.agent, phase: state.phase).padding(.leading, 2)
            } compactTrailing: {
                CompactTrailing(state: state).padding(.trailing, 2)
            } minimal: {
                AgentGlyph(agent: info.agent, phase: state.phase)
            }
            .widgetURL(info.deepLink)
            .keylineTint(Palette.tint(for: info.agent))
        }
    }
}

// MARK: - Lock screen

struct LockScreenView: View {
    let info: SessionActivityInfo
    let state: SessionActivityState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                AgentGlyph(agent: info.agent, phase: state.phase, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.project.isEmpty ? info.title : "\(info.project) · \(info.title)")
                        .font(.caption).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    Text(state.headline)
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.textPrimary).lineLimit(1)
                    if !state.detail.isEmpty {
                        Text(state.detail)
                            .font(.system(.caption, design: state.phase == .working || state.phase == .needsApproval ? .monospaced : .default))
                            .foregroundStyle(Palette.textSecondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
                TrailingStatus(state: state)
            }
            if state.phase == .needsApproval {
                ApprovalButtons(info: info, state: state)
            }
        }
        .padding(14)
    }
}

// MARK: - Pieces

/// Claude's asterisk in clay, Codex in blue; the glyph itself says which agent and what mood.
struct AgentGlyph: View {
    let agent: AgentKind
    let phase: SessionActivityState.Phase
    var size: CGFloat = 16

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.8, weight: .bold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
    }

    private var symbol: String {
        switch phase {
        case .working: return agent == .codex ? "chevron.left.forwardslash.chevron.right" : "asterisk"
        case .needsApproval: return "hand.raised.fill"
        case .done: return "checkmark"
        case .failed, .stopped: return "exclamationmark"
        }
    }

    private var color: Color {
        switch phase {
        case .needsApproval: return Palette.warning
        case .failed, .stopped: return Palette.danger
        case .done: return Palette.success
        case .working: return Palette.tint(for: agent)
        }
    }
}

/// Turn timer while working, a badge while waiting, a tick when done.
struct TrailingStatus: View {
    let state: SessionActivityState

    var body: some View {
        switch state.phase {
        case .working:
            if let start = state.turnStartDate {
                Text(timerInterval: start...Date(timeIntervalSinceNow: 12 * 3600), countsDown: false)
                    .font(.caption.monospacedDigit().weight(.medium)).foregroundStyle(Palette.textSecondary)
                    .frame(width: 44, alignment: .trailing)
            } else {
                ProgressView().controlSize(.small).tint(Palette.textSecondary)
            }
        case .needsApproval:
            Text("Waiting").font(.caption.weight(.semibold)).foregroundStyle(Palette.warning)
        case .done:
            Text("Done").font(.caption.weight(.semibold)).foregroundStyle(Palette.success)
        case .failed:
            Text("Failed").font(.caption.weight(.semibold)).foregroundStyle(Palette.danger)
        case .stopped:
            Text("Stopped").font(.caption.weight(.semibold)).foregroundStyle(Palette.textSecondary)
        }
    }
}

struct CompactTrailing: View {
    let state: SessionActivityState

    var body: some View {
        switch state.phase {
        case .working:
            if let start = state.turnStartDate {
                Text(timerInterval: start...Date(timeIntervalSinceNow: 12 * 3600), countsDown: false)
                    .font(.caption2.monospacedDigit()).foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: 40)
            } else {
                Image(systemName: "ellipsis").font(.caption2).foregroundStyle(Palette.textSecondary)
            }
        case .needsApproval:
            Image(systemName: "exclamationmark.circle.fill").font(.caption).foregroundStyle(Palette.warning)
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(Palette.success)
        case .failed, .stopped:
            Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(Palette.danger)
        }
    }
}

/// Deny answers in place. Allow does too — unless the phone wants Face ID first, in which case it
/// opens the app on the session (the pending card is right there).
struct ApprovalButtons: View {
    let info: SessionActivityInfo
    let state: SessionActivityState

    var body: some View {
        if let requestId = state.pendingRequestId {
            HStack(spacing: 8) {
                Button(intent: DecidePermissionIntent(sessionId: info.sessionId, requestId: requestId, allow: false)) {
                    Text("Deny").frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(fill: Palette.fillNeutral, text: Palette.textPrimary))
                if state.approvalNeedsApp {
                    Link(destination: info.deepLink) {
                        Label("Allow", systemImage: "faceid").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle(fill: Palette.warning, text: .black))
                } else {
                    Button(intent: DecidePermissionIntent(sessionId: info.sessionId, requestId: requestId, allow: true)) {
                        Text("Allow").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle(fill: Palette.warning, text: .black))
                }
            }
        }
    }
}

struct PillButtonStyle: ButtonStyle {
    let fill: Color
    let text: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(text)
            .padding(.vertical, 8).padding(.horizontal, 12)
            .background(fill.opacity(configuration.isPressed ? 0.7 : 1), in: Capsule())
    }
}

/// A slice of the app's CDS tokens — the extension can't see Theme.swift.
enum Palette {
    static let background = Color(red: 0.043, green: 0.043, blue: 0.043)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.65)
    static let fillNeutral = Color.white.opacity(0.14)
    static let clay = Color(red: 0.851, green: 0.467, blue: 0.341)
    static let codex = Color(red: 0.427, green: 0.655, blue: 0.925)
    static let warning = Color(red: 0.980, green: 0.698, blue: 0.098)
    static let success = Color(red: 0.333, green: 0.749, blue: 0.314)
    static let danger = Color(red: 0.890, green: 0.286, blue: 0.282)

    static func tint(for agent: AgentKind) -> Color { agent == .codex ? codex : clay }
}
