import SwiftUI

@main
struct ClaudeRemoteWatchApp: App {
    @State private var client = WatchClient()
    @State private var receiver: WatchConnectivityReceiver?
    @Environment(\.scenePhase) private var scenePhase

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
                .onChange(of: scenePhase) { _, phase in
                    // Coming to the foreground with the phone open is the moment to (re)fetch the pairing.
                    if phase == .active { receiver?.retry() }
                }
        }
    }
}
