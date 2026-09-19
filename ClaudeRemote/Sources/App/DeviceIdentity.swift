import UIKit

/// What this phone tells the Mac about itself in `hello`, so the Mac can show "paired with …".
enum DeviceIdentity {
    /// The user's device name when the OS exposes it (simulators, and apps with the
    /// user-assigned-device-name entitlement); otherwise the model + OS version.
    static var name: String {
        let device = UIDevice.current
        if device.name != device.model, !device.name.isEmpty { return device.name }
        return "\(device.model) · iOS \(device.systemVersion)"
    }

    /// Stable per-install id (identifierForVendor), so a reconnecting phone is recognised.
    static var id: String? {
        UIDevice.current.identifierForVendor?.uuidString
    }
}
