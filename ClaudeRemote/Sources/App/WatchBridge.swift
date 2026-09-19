import Foundation
import WatchConnectivity
import ClaudeRemoteCore

/// Sends the currently-active Mac pairing to the Apple Watch over WatchConnectivity, so the Watch
/// app can connect on its own without the user typing a token there.
final class WatchBridge: NSObject, WCSessionDelegate {
    static let shared = WatchBridge()

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Push the active pairing as the latest application context (coalesced, delivered in background).
    func syncActivePairing() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let macs = PairedMacs.load()
        guard let active = macs.macs.first(where: { $0.id == macs.activeId }) ?? macs.macs.first else { return }
        let pairing = WatchPairing(name: active.displayName, token: active.token, host: active.host,
                                   port: active.port, useTLS: active.useTLS, fingerprint: active.fingerprint,
                                   relayURL: active.relayURL, room: active.room)
        try? session.updateApplicationContext(pairing.payload())
    }

    // MARK: WCSessionDelegate
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        syncActivePairing()
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
}
