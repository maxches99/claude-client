import Foundation
import WatchConnectivity
import ClaudeRemoteCore

/// Receives the pairing the iPhone sends over WatchConnectivity and hands it to the client.
@MainActor
final class WatchConnectivityReceiver: NSObject, WCSessionDelegate {
    private let onPairing: @MainActor (WatchPairing) -> Void

    init(onPairing: @escaping @MainActor (WatchPairing) -> Void) {
        self.onPairing = onPairing
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private func ingest(_ context: [String: Any]) {
        guard let pairing = WatchPairing.from(payload: context) else { return }
        Task { @MainActor in onPairing(pairing) }
    }

    /// Re-pull the pairing (e.g. when the Watch app returns to the foreground).
    func retry() { requestPairing(WCSession.default) }

    /// Ask the phone for the pairing directly — the reliable path when the phone is open but its
    /// application-context push was coalesced away or arrived before the Watch app was installed.
    private nonisolated func requestPairing(_ session: WCSession) {
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(["request": "pairing"],
                            replyHandler: { reply in Task { @MainActor in self.ingest(reply) } },
                            errorHandler: nil)
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let ctx = session.receivedApplicationContext
        if !ctx.isEmpty { Task { @MainActor in self.ingest(ctx) } }
        requestPairing(session)
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        requestPairing(session)
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.ingest(applicationContext) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in self.ingest(userInfo) }
    }
}
