import SwiftUI
import ClaudeRemoteCore

/// Keeps the Mac client current from GitHub releases: checks at launch and every few hours, offers the
/// new version in the sidebar and the app menu, and installs it in place (the app restarts).
@Observable
@MainActor
final class MacUpdates {
    static let shared = MacUpdates()

    private(set) var status: HostUpdate?
    private let updater = AppUpdater(asset: "ClaudeRemote-Mac.zip") { NSLog("ClaudeRemote %@", $0) }
    private var timer: Timer?

    var available: Bool { status?.state == .available }
    var updating: Bool { status?.state == .updating }

    func start() {
        guard timer == nil else { return }
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in await MacUpdates.shared.check() }
        }
    }

    func check() async {
        guard !updating else { return }
        status = await updater.check()
    }

    func install() {
        Task {
            await updater.update { update in
                Task { @MainActor in MacUpdates.shared.status = update }
            }
        }
    }
}

/// "ClaudeRemote 1.7.0 is available" at the top of the sidebar.
struct UpdateBanner: View {
    @State private var updates = MacUpdates.shared

    var body: some View {
        if let status = updates.status, status.state == .available || status.state == .updating || (status.state == .failed && status.latest != nil) {
            HStack(spacing: 8) {
                Image(systemName: status.state == .failed ? "exclamationmark.triangle" : "arrow.down.circle")
                    .foregroundStyle(status.state == .failed ? CDS.danger : CDS.brand)
                Text(text(status)).font(CDS.caption).foregroundStyle(CDS.textSecondary).lineLimit(2)
                Spacer(minLength: 4)
                if status.state == .available {
                    Button("Update") { updates.install() }
                        .buttonStyle(CDSButtonStyle(variant: .brand))
                        .controlSize(.small)
                } else if status.state == .updating {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(CDS.fillNeutral, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 10).padding(.top, 6)
        }
    }

    private func text(_ status: HostUpdate) -> String {
        switch status.state {
        case .updating: return status.message ?? "Updating…"
        case .failed: return status.message ?? "The update failed."
        default: return "ClaudeRemote \(status.latest ?? "") is available"
        }
    }
}
