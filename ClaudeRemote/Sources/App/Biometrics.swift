import Foundation
import LocalAuthentication

/// Face ID / Touch ID gate. Falls back to the device passcode when biometrics aren't enrolled
/// (so nobody is locked out), and reuses a recent success for a short window so a burst of
/// approvals in one working session doesn't prompt on every single Allow.
@MainActor
enum Biometrics {
    /// A recent biometric success is reused for this long (seconds) — a burst of approvals then
    /// authenticates once. Passcode fallback is never reused; it always prompts.
    private static let reuseWindow: TimeInterval = 60

    private static var context = makeContext()

    private static func makeContext() -> LAContext {
        let c = LAContext()
        c.touchIDAuthenticationAllowableReuseDuration = reuseWindow
        c.localizedFallbackTitle = "Use passcode"
        return c
    }

    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    static func authenticate(reason: String) async -> Bool {
        let ctx = context
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            return true   // no biometrics or passcode configured — don't lock the user out
        }
        let ok: Bool = await withCheckedContinuation { continuation in
            ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
        if !ok { context = makeContext() }   // reset after a failure/cancel so state isn't stuck
        return ok
    }

    /// Drop any reused-authentication window (call when the app locks) so the next approval re-prompts.
    static func resetReuse() {
        context = makeContext()
    }
}
