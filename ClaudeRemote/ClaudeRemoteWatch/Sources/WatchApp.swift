import SwiftUI

@main
struct ClaudeRemoteWatchApp: App {
    @State private var client = WatchClient()
    @State private var receiver: WatchConnectivityReceiver?

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(client)
                .onAppear {
                    client.loadStoredPairing()
                    if receiver == nil {
                        let c = client
                        receiver = WatchConnectivityReceiver { pairing in c.configure(pairing) }
                    }
                }
        }
    }
}
