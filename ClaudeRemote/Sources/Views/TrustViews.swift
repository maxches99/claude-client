import SwiftUI
import ClaudeRemoteCore

/// "Trust for…" on a permission request: this tool or everything, this session or the whole project,
/// for half an hour or two. The host answers matching requests itself until the grant runs out.
struct TrustMenu: View {
    @Environment(AppModel.self) private var model
    let request: PermissionRequest
    var onDone: () -> Void = {}

    private var suggested: String { TrustGrant.suggestedTool(toolName: request.toolName, input: request.input) }
    private var suggestedLabel: String { TrustGrant(sessionId: nil, cwd: nil, tool: suggested, expiresAt: .now).toolLabel }

    var body: some View {
        Menu {
            ForEach([30, 120], id: \.self) { minutes in
                Section(minutes < 60 ? "For 30 minutes" : "For 2 hours") {
                    button("\(suggestedLabel) in this session", tool: suggested, projectWide: false, minutes: minutes)
                    button("\(suggestedLabel) in this project", tool: suggested, projectWide: true, minutes: minutes)
                    button("Everything in this session", tool: nil, projectWide: false, minutes: minutes)
                    button("Everything in this project", tool: nil, projectWide: true, minutes: minutes)
                }
            }
        } label: {
            Label("Trust for a while…", systemImage: "clock.badge.checkmark")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(CDSButtonStyle(variant: .secondary, fullWidth: true))
    }

    private func button(_ title: String, tool: String?, projectWide: Bool, minutes: Int) -> some View {
        Button(title) {
            model.trust(request, tool: tool, projectWide: projectWide, minutes: minutes)
            onDone()
        }
    }
}

/// Live grants with the time left and a way to end each one early.
struct TrustListSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let grants = model.allTrust
        if !grants.isEmpty {
            Section {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(spacing: 0) {
                        ForEach(grants, id: \.grant.id) { item in
                            row(item.grant, macId: item.macId, now: context.date)
                        }
                    }
                }
            } header: {
                Label("Trusted for now", systemImage: "clock.badge.checkmark")
                    .font(.caption2.weight(.semibold)).foregroundStyle(CDS.textMuted)
            }
        }
    }

    private func row(_ grant: TrustGrant, macId: String, now: Date) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(grant.toolLabel.prefix(1).uppercased() + grant.toolLabel.dropFirst()) in \(grant.sessionId == nil ? "project" : "session") \(grant.cwd.map { ($0 as NSString).lastPathComponent } ?? "")")
                    .font(CDS.captionMedium).foregroundStyle(CDS.textPrimary).lineLimit(1)
                Text("\(ActivitySummary.format(max(0, grant.expiresAt.timeIntervalSince(now)))) left\(model.macs.count > 1 ? " · " + model.macName(macId) : "")")
                    .font(CDS.caption).foregroundStyle(CDS.textMuted)
            }
            Spacer(minLength: 4)
            Button("End") { model.revokeTrust(grant, mac: macId) }
                .buttonStyle(CDSButtonStyle(variant: .secondary))
        }
        .padding(.vertical, 4)
    }
}
