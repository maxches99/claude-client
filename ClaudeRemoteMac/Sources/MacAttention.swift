import SwiftUI
import AppKit
import UserNotifications
import ClaudeRemoteCore

/// What the Mac client does to get your attention while you are in another app: the Dock badge counts
/// approvals waiting on any host, and each new one becomes a notification with Allow / Deny buttons.
@MainActor
final class MacAttention: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MacAttention()

    private weak var model: AppModel?
    private var announced: Set<String> = []
    private static let category = "ccremote.approval"
    private static let doneCategory = "ccremote.done"
    /// Last seen status of every session on every host, to notice a turn ending.
    private var statuses: [String: SessionStatus] = [:]

    func attach(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [
                UNNotificationAction(identifier: "allow", title: "Allow", options: [.authenticationRequired]),
                UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive]),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.doneCategory, actions: [], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        // Requests already waiting when the app starts are on screen; only later ones are news.
        announced = Set(model.pendingApprovals.map(\.id))
        observe()
        observeTurns()
    }

    /// A session going from working to idle while you are elsewhere: "done", with the start of the reply.
    private func observeTurns() {
        guard let model else { return }
        let byMac = withObservationTracking { model.sessionsByMac } onChange: {
            Task { @MainActor [weak self] in self?.observeTurns() }
        }
        var next: [String: SessionStatus] = [:]
        for (macId, sessions) in byMac {
            for session in sessions {
                let key = macId + "\n" + session.id
                next[key] = session.status
                if statuses[key] == .running, session.status == .idle, !NSApp.isActive {
                    postDone(macId: macId, session: session)
                }
            }
        }
        statuses = next
    }

    private func postDone(macId: String, session: SessionSummary) {
        guard let model else { return }
        let content = UNMutableNotificationContent()
        content.title = session.title
        var subtitle = session.kind == .chat ? "Chat · replied" : "\(session.projectName) · finished"
        if model.macs.count > 1 { subtitle += " · " + model.macName(macId) }
        content.subtitle = subtitle
        if let reply = lastReply(session.id) { content.body = reply }
        content.sound = .default
        content.categoryIdentifier = Self.doneCategory
        content.userInfo = ["macId": macId, "sessionId": session.id, "kind": session.kind == .chat ? "chat" : "agent"]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "done-" + session.id, content: content, trigger: nil))
    }

    /// The start of the latest reply, when the transcript is loaded (the open session or a recent one).
    private func lastReply(_ sessionId: String) -> String? {
        guard let items = model?.transcripts[sessionId]?.items else { return nil }
        for item in items.reversed() {
            if case .assistantText(let text, _) = item.kind, !text.isEmpty { return String(text.prefix(240)) }
        }
        return nil
    }

    /// Re-arms itself on every change of the pending approvals (Observation has no "for each change").
    private func observe() {
        guard let model else { return }
        let approvals = withObservationTracking { model.pendingApprovals } onChange: {
            Task { @MainActor [weak self] in self?.observe() }
        }
        update(approvals)
    }

    private func update(_ approvals: [PendingApproval]) {
        NSApp.dockTile.badgeLabel = approvals.isEmpty ? nil : "\(approvals.count)"
        let ids = Set(approvals.map(\.id))
        let fresh = approvals.filter { !announced.contains($0.id) }
        // Answered elsewhere (the phone, the Host app, this window): take the notification back.
        let gone = announced.subtracting(ids)
        if !gone.isEmpty {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: Array(gone))
        }
        announced = ids
        guard !NSApp.isActive else { return }
        for approval in fresh { post(approval) }
    }

    private func post(_ approval: PendingApproval) {
        guard let model else { return }
        let request = approval.request
        let content = UNMutableNotificationContent()
        content.title = request.title ?? ToolSummary.displayName(request.toolName)
        let session = model.session(for: approval)
        var subtitle = session?.title ?? "Session"
        if model.macs.count > 1 { subtitle += " · " + model.macName(approval.macId) }
        content.subtitle = subtitle
        content.body = ToolSummary.line(name: request.toolName, input: request.input)
        content.sound = .default
        content.categoryIdentifier = Self.category
        content.userInfo = ["requestId": request.id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: request.id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let requestId = response.notification.request.identifier
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        if let macId = info["macId"] as? String, let sessionId = info["sessionId"] as? String {
            let kind: SessionKind = info["kind"] as? String == "chat" ? .chat : .agent
            await MainActor.run {
                NSApp.activate()
                guard let model else { return }
                if macId != model.activeMacId { model.switchTo(macId) }
                model.present(sessionId, kind: kind)
            }
            return
        }
        await MainActor.run {
            guard let model, let approval = model.pendingApprovals.first(where: { $0.id == requestId }) else { return }
            switch action {
            case "allow": model.decide(approval.request, allow: true)
            case "deny": model.decide(approval.request, allow: false, reason: "Denied from a notification on the Mac")
            default:
                NSApp.activate()
                model.openSession(for: approval)
            }
        }
    }

    /// While the window is in front the inline card is the prompt; no banner on top of it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }
}

/// The menu-bar item's window: approvals waiting on every host, answerable without opening the app.
struct ApprovalsMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("ClaudeRemote").font(.headline)
                Spacer()
                Text(statusLine).font(CDS.caption).foregroundStyle(CDS.textMuted)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if model.pendingApprovals.isEmpty {
                Text("Nothing is waiting on you.")
                    .font(CDS.body).foregroundStyle(CDS.textMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 22)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.pendingApprovals) { approval in
                            row(approval)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 420)
            }
            Divider()
            HStack {
                Button("Open ClaudeRemote") { showWindow() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14).padding(.vertical, 9)
        }
        .frame(width: 360)
    }

    private var statusLine: String {
        let connected = model.connectedMacCount
        if model.macs.isEmpty { return "Not paired" }
        return connected == model.macs.count ? (connected == 1 ? "Connected" : "\(connected) hosts connected")
                                             : "\(connected) of \(model.macs.count) connected"
    }

    private func row(_ approval: PendingApproval) -> some View {
        let request = approval.request
        let session = model.session(for: approval)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: request.runsCode ? "exclamationmark.shield" : "questionmark.bubble")
                    .foregroundStyle(request.runsCode ? CDS.warningFill : CDS.accent)
                Text(request.title ?? ToolSummary.displayName(request.toolName))
                    .font(CDS.bodyMedium).lineLimit(1)
                Spacer(minLength: 0)
                Text(RelativeTime.string(request.createdAt)).font(CDS.caption).foregroundStyle(CDS.textMuted)
            }
            let line = ToolSummary.line(name: request.toolName, input: request.input)
            if !line.isEmpty {
                Text(line).font(CDS.codeSmall).foregroundStyle(CDS.textSecondary).lineLimit(3).truncationMode(.middle)
            }
            Text([session?.title ?? "Session", model.macs.count > 1 ? model.macName(approval.macId) : nil].compactMap { $0 }.joined(separator: " · "))
                .font(CDS.caption).foregroundStyle(CDS.textMuted).lineLimit(1)
            HStack(spacing: 8) {
                // Questions and plans need their form; only plain tool calls are answered from here.
                if request.toolName == "AskUserQuestion" || request.toolName == "ExitPlanMode" {
                    Button("Answer…") { open(approval) }.buttonStyle(.borderedProminent)
                } else {
                    Button("Allow") { model.decide(request, allow: true) }.buttonStyle(.borderedProminent)
                    Button("Deny") { model.decide(request, allow: false, reason: "Denied from the Mac menu bar") }
                }
                Spacer()
                Button("Open") { open(approval) }.buttonStyle(.borderless)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func open(_ approval: PendingApproval) {
        showWindow()
        model.openSession(for: approval)
    }

    private func showWindow() {
        openWindow(id: MacUI.mainWindowId)
        NSApp.activate()
    }
}
