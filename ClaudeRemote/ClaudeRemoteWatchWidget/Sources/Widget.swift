import WidgetKit
import SwiftUI
import ClaudeRemoteCore

struct SummaryEntry: TimelineEntry {
    let date: Date
    let summary: WatchSummary?
}

struct SummaryProvider: TimelineProvider {
    func placeholder(in context: Context) -> SummaryEntry {
        SummaryEntry(date: Date(), summary: WatchSummary(pending: 2, running: 1, total: 5, hostName: "Mac", connected: true))
    }
    func getSnapshot(in context: Context, completion: @escaping (SummaryEntry) -> Void) {
        completion(SummaryEntry(date: Date(), summary: WatchSummary.load() ?? placeholder(in: context).summary))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SummaryEntry>) -> Void) {
        let entry = SummaryEntry(date: Date(), summary: WatchSummary.load())
        // The app pushes reloads on change; this is just a lazy fallback refresh.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900))))
    }
}

struct PendingApprovalsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PendingApprovals", provider: SummaryProvider()) { entry in
            ComplicationView(summary: entry.summary)
                .containerBackground(.clear, for: .widget)
                .widgetURL(entry.summary?.deepLinkURL ?? URL(string: "ccwatch://open")!)
        }
        .configurationDisplayName("ccremote")
        .description("Sessions waiting for approval on your Mac.")
        .supportedFamilies([.accessoryCircular, .accessoryInline, .accessoryRectangular, .accessoryCorner])
    }
}

@main
struct ClaudeRemoteWatchWidgetBundle: WidgetBundle {
    var body: some Widget { PendingApprovalsWidget() }
}

struct ComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let summary: WatchSummary?

    private var pending: Int { summary?.pending ?? 0 }
    private var running: Int { summary?.running ?? 0 }

    var body: some View {
        switch family {
        case .accessoryInline:
            Label(inlineText, systemImage: pending > 0 ? "hand.raised.fill" : "checkmark.circle")
        case .accessoryRectangular:
            rectangular
        case .accessoryCorner:
            corner
        default:
            circular   // .accessoryCircular
        }
    }

    private var inlineText: String {
        if pending > 0 { return "\(pending) to approve" }
        if summary?.connected == false { return "ccremote offline" }
        return running > 0 ? "\(running) working" : "ccremote idle"
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if pending > 0 {
                VStack(spacing: -1) {
                    Image(systemName: "hand.raised.fill").font(.system(size: 11))
                    Text("\(pending)").font(.system(size: 16, weight: .bold))
                }
            } else {
                Image(systemName: summary?.connected == false ? "wifi.slash" : "checkmark")
                    .font(.system(size: 18, weight: .semibold))
            }
        }
        .widgetLabel { Text(pending > 0 ? "approve" : "ccremote") }
    }

    private var corner: some View {
        Text("\(pending)")
            .font(.system(size: 18, weight: .bold))
            .widgetLabel(pending > 0 ? "\(pending) to approve" : "ccremote")
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(summary?.hostName ?? "ccremote").font(.headline).lineLimit(1)
            if pending > 0 {
                Label("\(pending) to approve", systemImage: "hand.raised.fill").foregroundStyle(.orange)
            } else if summary?.connected == false {
                Label("offline", systemImage: "wifi.slash").foregroundStyle(.secondary)
            } else {
                Label(running > 0 ? "\(running) working" : "idle", systemImage: "circle.fill")
            }
            Text("\(summary?.total ?? 0) sessions").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
