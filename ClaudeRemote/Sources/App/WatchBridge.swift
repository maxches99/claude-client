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

    /// Push the active pairing to the Watch. `updateApplicationContext` is coalesced and deduped (so a
    /// repeat of the same context may never re-deliver), so we also queue it with `transferUserInfo`,
    /// which is guaranteed and survives the app being backgrounded — belt and suspenders.
    func syncActivePairing() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, let payload = activePairingPayload() else { return }
        try? session.updateApplicationContext(payload)
        session.transferUserInfo(payload)
    }

    private func activePairingPayload() -> [String: Any]? {
        let macs = PairedMacs.load()
        guard let active = macs.macs.first(where: { $0.id == macs.activeId }) ?? macs.macs.first else { return nil }
        let pairing = WatchPairing(name: active.displayName, token: active.token, host: active.host,
                                   port: active.port, useTLS: active.useTLS, fingerprint: active.fingerprint,
                                   relayURL: active.relayURL, room: active.room)
        return pairing.payload()
    }

    // MARK: WCSessionDelegate
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        syncActivePairing()
    }

    /// The Watch pulls the pairing on launch when it has none — the reliable path while the phone is open.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        replyHandler(activePairingPayload() ?? [:])
    }
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        syncActivePairing()
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
}
