import SwiftUI
import ClaudeRemoteCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.pairing == nil {
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
        .onOpenURL { url in
            // ccremote://pair?host=…&port=…&token=…&name=… (the daemon's QR code / pair URL)
            if let info = PairingInfo.parse(pairURL: url.absoluteString) { model.pair(info) }
        }
    }
}

struct ConnectionBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.connection.status
        if status != .connected {
            HStack(spacing: 8) {
                if status == .connecting { ProgressView().controlSize(.small) } else { Image(systemName: "wifi.exclamationmark") }
                Text(status.label).font(.footnote)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color.orange.opacity(0.15))
        }
    }
}
