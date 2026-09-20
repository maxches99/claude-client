import WidgetKit
import SwiftUI
import ClaudeRemoteCore

/// Home-screen and lock-screen glance at the Mac's sessions: how many wait for an approval, how
/// many are working, and the ones worth a look. Tapping opens the first session needing approval.
struct SessionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSummary.kind, provider: SessionsProvider()) { entry in
            SessionsWidgetView(summary: entry.summary)
                .containerBackground(Palette.background, for: .widget)
                .widgetURL(entry.summary.deepLinkURL)
        }
        .configurationDisplayName("Sessions")
        .description("Sessions on your Mac: approvals waiting and agents at work.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct SessionsEntry: TimelineEntry {
    let date: Date
    let summary: WidgetSummary
}

struct SessionsProvider: TimelineProvider {
    private static let placeholder = WidgetSummary(pending: 1, running: 2, hostName: "MacBook Pro", connected: true, rows: [
        WidgetSummary.Row(id: "1", title: "Fix the login flow", project: "app", status: .awaitingPermission, agent: .claude),
        WidgetSummary.Row(id: "2", title: "Write release notes", project: "docs", status: .running, agent: .codex),
        WidgetSummary.Row(id: "3", title: "Refactor the parser", project: "core", status: .idle, agent: .claude),
    ])

    func placeholder(in context: Context) -> SessionsEntry { SessionsEntry(date: Date(), summary: Self.placeholder) }

    func getSnapshot(in context: Context, completion: @escaping (SessionsEntry) -> Void) {
        completion(SessionsEntry(date: Date(), summary: WidgetSummary.load() ?? Self.placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SessionsEntry>) -> Void) {
        let summary = WidgetSummary.load() ?? WidgetSummary(pending: 0, running: 0, hostName: "", connected: false, rows: [])
        // The app refreshes the timeline itself; this is the fallback when it has not run for a while.
        completion(Timeline(entries: [SessionsEntry(date: Date(), summary: summary)], policy: .after(Date().addingTimeInterval(30 * 60))))
    }
}

struct SessionsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let summary: WidgetSummary

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: summary.pending > 0 ? "bell.badge.fill" : "sparkle")
                        .font(.system(size: 14, weight: .semibold))
                    Text(summary.pending > 0 ? "\(summary.pending)" : "\(summary.running)")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                }
            }
        case .accessoryInline:
            Text(inlineText)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.headline).lineLimit(1)
                ForEach(summary.rows.prefix(2)) { row in
                    Text(row.title).font(.caption).lineLimit(1)
                }
            }
        case .systemSmall:
            VStack(alignment: .leading, spacing: 6) {
                header
                Spacer(minLength: 0)
                Text("\(summary.pending)").font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(summary.pending > 0 ? Palette.warning : Palette.textPrimary)
                Text(summary.pending == 1 ? "needs approval" : "need approval").font(.caption).foregroundStyle(Palette.textSecondary)
                Text("\(summary.running) working").font(.caption).foregroundStyle(Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        default:
            VStack(alignment: .leading, spacing: 6) {
                header
                if summary.rows.isEmpty {
                    Text(summary.connected ? "No sessions" : "Not connected").font(.caption).foregroundStyle(Palette.textSecondary)
                    Spacer(minLength: 0)
                } else {
                    ForEach(summary.rows.prefix(3)) { row in
                        HStack(spacing: 6) {
                            Circle().fill(color(for: row.status)).frame(width: 7, height: 7)
                            Text(row.title).font(.caption).foregroundStyle(Palette.textPrimary).lineLimit(1)
                            Spacer(minLength: 2)
                            Text(row.project).font(.caption2).foregroundStyle(Palette.textSecondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle").foregroundStyle(Palette.clay)
            Text(summary.hostName.isEmpty ? "ClaudeRemote" : summary.hostName).font(.caption.weight(.semibold)).foregroundStyle(Palette.textSecondary).lineLimit(1)
            Spacer()
            if summary.pending > 0 {
                Text("\(summary.pending)").font(.caption2.weight(.bold)).foregroundStyle(Palette.background)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Palette.warning, in: Capsule())
            }
        }
    }

    private var headline: String {
        if summary.pending > 0 { return summary.pending == 1 ? "1 approval waiting" : "\(summary.pending) approvals waiting" }
        if summary.running > 0 { return summary.running == 1 ? "1 session working" : "\(summary.running) sessions working" }
        return summary.connected ? "All quiet" : "Not connected"
    }

    private var inlineText: String {
        if summary.pending > 0 { return "🔔 \(summary.pending) waiting · \(summary.running) working" }
        return summary.running > 0 ? "✳︎ \(summary.running) working" : "ClaudeRemote · quiet"
    }

    private func color(for status: SessionStatus) -> Color {
        switch status {
        case .awaitingPermission: return Palette.warning
        case .running: return Palette.success
        case .exited: return Palette.danger
        default: return Palette.textSecondary.opacity(0.5)
        }
    }
}
