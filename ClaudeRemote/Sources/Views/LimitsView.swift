import SwiftUI
import ClaudeRemoteCore

/// The data behind Claude Code's `/usage`: plan rate-limit windows (5-hour, weekly, per-model) with
/// utilization bars and reset times, plus session cost. Fetched live from a hosted CLI session.
struct LimitsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sessionId: String

    /// The windows the CLI reports, in the order we show them.
    private static let windows: [(key: String, label: String)] = [
        ("five_hour", "Current session · 5 hours"),
        ("seven_day", "Weekly · all models"),
        ("seven_day_opus", "Weekly · Opus"),
        ("seven_day_sonnet", "Weekly · Sonnet"),
        ("seven_day_oauth_apps", "Weekly · apps"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let report = model.usageReport {
                        content(report)
                    } else if let err = model.usageError {
                        notice(err, systemImage: "exclamationmark.triangle")
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading limits…").font(CDS.body).foregroundStyle(CDS.textMuted)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding()
            }
            .background(CDS.surface0)
            .navigationTitle("Plan limits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CDS.surface0, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.requestUsage(sessionId) } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .task { model.requestUsage(sessionId) }
        }
    }

    @ViewBuilder private func content(_ report: JSONValue) -> some View {
        if let plan = report["subscription_type"]?.string, !plan.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle").foregroundStyle(CDS.textMuted)
                Text(plan.capitalized).font(.headline).foregroundStyle(CDS.textPrimary)
            }
        }

        if report["rate_limits_available"]?.bool == false {
            notice("Plan limits aren't available for this account (API key or third-party provider).",
                   systemImage: "info.circle")
        } else if let limits = report["rate_limits"] {
            VStack(spacing: 14) {
                ForEach(Self.windows, id: \.key) { window in
                    if let w = limits[window.key], !w.isNull {
                        windowRow(window.label, w)
                    }
                }
            }
        }

        if let cost = report["session"]?["total_cost_usd"]?.double, cost > 0 {
            Divider().overlay(CDS.border)
            HStack {
                Text("Session cost").font(CDS.body).foregroundStyle(CDS.textSecondary)
                Spacer()
                Text(cost < 0.1 ? String(format: "$%.3f", cost) : String(format: "$%.2f", cost))
                    .font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary)
            }
        }
    }

    private func windowRow(_ label: String, _ window: JSONValue) -> some View {
        let util = window["utilization"]?.double
        let resets = window["resets_at"]?.string.flatMap(Self.parseDate)
        let fraction = min(max((util ?? 0) / 100, 0), 1)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary)
                Spacer()
                Text(util.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(CDS.bodyMedium).foregroundStyle(barColor(fraction))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(CDS.fillControl).frame(height: 8)
                    Capsule().fill(barColor(fraction)).frame(width: max(6, geo.size.width * fraction), height: 8)
                }
            }
            .frame(height: 8)
            if let resets {
                Text("Resets \(Self.relativeReset(resets))").font(CDS.caption).foregroundStyle(CDS.textMuted)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CDS.surface2, in: RoundedRectangle(cornerRadius: CDS.radius))
        .overlay(RoundedRectangle(cornerRadius: CDS.radius).strokeBorder(CDS.border))
    }

    private func barColor(_ fraction: Double) -> Color {
        if fraction >= 0.9 { return CDS.danger }
        if fraction >= 0.7 { return CDS.warning }
        return CDS.success
    }

    private func notice(_ text: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(CDS.textMuted)
            Text(text).font(CDS.body).foregroundStyle(CDS.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(CDS.surface2, in: RoundedRectangle(cornerRadius: CDS.radius))
    }

    /// Future-aware relative time ("in 2 hr", "in 3 days") — unlike the list's past-oriented helper.
    private static func relativeReset(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    private static func parseDate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }
}
