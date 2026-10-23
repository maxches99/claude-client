import SwiftUI

/// "Connecting…" / "Disconnected" over the session list and the chat while the active Mac is not connected.
struct ConnectionBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.connection.status
        if status != .connected {
            CDSBanner(kind: .warning, text: text(for: status), systemImage: "wifi.exclamationmark", showsProgress: status == .connecting)
        }
    }

    /// Name the Mac while connecting — with several paired, "Connecting…" alone doesn't say which.
    private func text(for status: HostConnection.Status) -> String {
        let cached = model.showingCachedSessions ? " · showing what was last seen" : ""
        if status == .connecting, let mac = model.activeMac { return "Connecting to \(mac.displayName)…" + cached }
        return status.label + cached
    }
}
