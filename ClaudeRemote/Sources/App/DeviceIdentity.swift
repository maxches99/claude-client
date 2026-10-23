#if os(iOS)
import UIKit
#else
import Foundation
#endif

/// What this phone tells the Mac about itself in `hello`, so the Mac can show "paired with …".
enum DeviceIdentity {
    /// The user's device name when the OS exposes it (simulators, and apps with the
    /// user-assigned-device-name entitlement); otherwise the model + OS version.
    static var name: String {
        #if os(iOS)
        let device = UIDevice.current
        if device.name != device.model, !device.name.isEmpty { return device.name }
        return "\(device.model) · iOS \(device.systemVersion)"
        #else
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let host = Host.current().localizedName ?? "Mac"
        return "\(host) · macOS \(version.majorVersion).\(version.minorVersion)"
        #endif
    }

    /// Stable per-install id (identifierForVendor on iOS, a UUID kept in defaults on the Mac), so a
    /// reconnecting client is recognised.
    static var id: String? {
        #if os(iOS)
        UIDevice.current.identifierForVendor?.uuidString
        #else
        let key = "ccremote.deviceId"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
        #endif
    }
}
