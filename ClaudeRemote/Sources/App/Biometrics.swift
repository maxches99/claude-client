import Foundation
import LocalAuthentication

/// Face ID / Touch ID gate. Falls back to the device passcode when biometrics aren't available.
enum Biometrics {
    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    @MainActor
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "Use passcode"
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            return true   // no biometrics/passcode configured — don't lock the user out
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
