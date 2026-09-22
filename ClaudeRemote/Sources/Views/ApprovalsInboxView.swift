import SwiftUI
import ClaudeRemoteCore

/// Everything waiting on you, from every paired Mac, in one list — the screen the phone exists for.
/// Swipe a row to allow or deny without opening the session; tap it for the full request.
struct ApprovalsInboxView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var presented: PermissionRequest?

    private var approvals: [PendingApproval] { model.pendingApprovals }

    /// One section per Mac when several have something waiting.
    private var byMac: [(macId: String, items: [PendingApproval])] {
        let grouped = Dictionary(grouping: approvals, by: \.macId)
        return model.macs.compactMap { mac in
            guard let items = grouped[mac.id], !items.isEmpty else { return nil }
            return (mac.id, items)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if approvals.isEmpty {
                    empty
                } else {
                    List {
                        ForEach(byMac, id: \.macId) { group in
                            Section {
                                ForEach(group.items) { approval in row(approval) }
                            } header: {
                                if byMac.count > 1 || model.macs.count > 1 {
                                    Label(model.macName(group.macId), systemImage: "desktopcomputer")
                                        .font(.caption2.weight(.semibold)).foregroundStyle(CDS.textMuted)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(CDS.surface0)
            .navigationTitle(approvals.isEmpty ? "Inbox" : "Waiting · \(approvals.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CDS.surface0, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $presented) { request in
                if request.isQuestion {
                    QuestionSheet(request: request).presentationDetents([.large])
                } else if request.isPlanReview {
                    PlanSheet(request: request).presentationDetents([.large])
                } else {
                    PermissionSheet(request: request).presentationDetents([.medium, .large])
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray").font(.system(size: 30, weight: .medium)).foregroundStyle(CDS.textMuted)
            Text("Nothing waiting").font(.title3.weight(.semibold)).foregroundStyle(CDS.textPrimary)
            Text(model.connectedMacCount > 1
                 ? "Approvals from all \(model.connectedMacCount) connected Macs land here."
                 : "Approvals land here as soon as an agent stops to ask.")
                .font(CDS.body).foregroundStyle(CDS.textMuted).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ approval: PendingApproval) -> some View {
        let request = approval.request
        let session = model.session(for: approval)
        let summaryLine = ToolSummary.line(name: request.toolName, input: request.input)
        return Button {
            presented = request
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: icon(request))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(request.runsCode ? CDS.warningFill : CDS.accent)
                    Text(request.title ?? ToolSummary.displayName(request.toolName))
                        .font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(RelativeTime.string(request.createdAt))
                        .font(CDS.caption).foregroundStyle(CDS.textMuted)
                }
                if !summaryLine.isEmpty {
                    Text(summaryLine)
                        .font(CDS.codeSmall).foregroundStyle(CDS.textSecondary)
                        .lineLimit(2).truncationMode(.middle)
                }
                HStack(spacing: 5) {
                    Text(session?.title ?? "Session").lineLimit(1)
                    if let project = session?.projectName, !project.isEmpty {
                        Text("·")
                        Text(project).lineLimit(1)
                    }
                    if model.macs.count > 1 {
                        Text("·")
                        Text(model.macName(approval.macId)).lineLimit(1)
                    }
                }
                .font(CDS.caption).foregroundStyle(CDS.textMuted)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(CDS.surface0)
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                model.decide(request, allow: false, reason: "Denied from the inbox")
            } label: { Label("Deny", systemImage: "xmark") }
        }
        .swipeActions(edge: .leading) {
            // A question or a plan runs nothing yet, so it is answered in the sheet, not by a swipe.
            if request.runsCode {
                Button {
                    model.decide(request, allow: true)
                } label: { Label("Allow", systemImage: "checkmark") }
                .tint(CDS.successFill)
            }
        }
        .contextMenu {
            Button("Open the session", systemImage: "arrow.up.forward.app") {
                model.openSession(for: approval)
                dismiss()
            }
            if request.runsCode {
                Button("Allow", systemImage: "checkmark") { model.decide(request, allow: true) }
                Button("Deny", systemImage: "xmark", role: .destructive) { model.decide(request, allow: false, reason: "Denied from the inbox") }
            }
        }
    }

    private func icon(_ request: PermissionRequest) -> String {
        if request.isQuestion { return "questionmark.bubble" }
        if request.isPlanReview { return "list.bullet.clipboard" }
        switch request.toolName {
        case "Bash": return "terminal"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return "square.and.pencil"
        case "Read": return "doc.text"
        default: return "bell.badge"
        }
    }
}

/// The bell that opens the inbox, with the count of what is waiting anywhere.
struct ApprovalsToolbarButton: View {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool

    var body: some View {
        let count = model.pendingApprovals.count
        if count > 0 {
            Button { isPresented = true } label: {
                Image(systemName: "bell.badge.fill")
                    .foregroundStyle(CDS.warningFill)
                    .overlay(alignment: .topTrailing) {
                        Text("\(min(count, 9))\(count > 9 ? "+" : "")")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(CDS.dangerFill, in: Capsule())
                            .offset(x: 10, y: -8)
                    }
            }
            .accessibilityLabel("\(count) approvals waiting")
        }
    }
}
