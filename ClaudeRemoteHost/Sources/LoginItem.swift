import Foundation
import ServiceManagement

/// "Open at login" via SMAppService — shows up under System Settings › General › Login Items.
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// When the user has denied the login item in System Settings, registering again is refused
    /// until they flip it there.
    static var needsApproval: Bool { status == .requiresApproval }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
