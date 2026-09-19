import SwiftUI
import ClaudeRemoteCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.macs.isEmpty {
                PairingView()
            } else {
                NavigationStack(path: $model.path) {
                    SessionListView()
                        .navigationDestination(for: String.self) { sessionId in
                            ChatView(sessionId: sessionId)
                        }
                }
            }
        }
        .tint(CDS.brand)
        .onOpenURL { url in
            // ccremote://pair?host=…&port=…&token=…&name=… (the daemon's QR code / pair URL):
            // adds the Mac (or refreshes it if already paired) and switches to it.
            if let info = PairingInfo.parse(pairURL: url.absoluteString) { model.pair(info) }
        }
    }
}

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
        if status == .connecting, let mac = model.activeMac { return "Connecting to \(mac.displayName)…" }
        return status.label
    }
}
