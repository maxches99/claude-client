import Foundation
import IOKit.pwr_mgt
import IOKit.ps

/// Holds a "prevent idle system sleep" assertion while enabled *and* the Mac is on AC power —
/// the same policy as `caffeinate -s`, which the LaunchAgent install used. A sleeping Mac is
/// unreachable from the phone, but draining a MacBook's battery for that is not worth it.
final class KeepAwake {
    private var assertion: IOPMAssertionID = 0
    private var holding = false
    private var powerSource: CFRunLoopSource?

    var enabled = false { didSet { evaluate() } }
    /// Whether the assertion is currently held (for the UI).
    private(set) var active = false
    var onChange: (() -> Void)?

    init() {
        // Re-evaluate whenever the power source changes (plugged in / unplugged).
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<KeepAwake>.fromOpaque(context).takeUnretainedValue().evaluate()
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
    }

    deinit {
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode) }
        release()
    }

    var onACPower: Bool {
        guard let type = IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue() else { return true }
        return (type as String) == kIOPMACPowerKey
    }

    private func evaluate() {
        let want = enabled && onACPower
        if want && !holding {
            let reason = "ClaudeRemote Host keeps this Mac reachable from your phone" as CFString
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &assertion) == kIOReturnSuccess {
                holding = true
            }
        } else if !want && holding {
            release()
        }
        let nowActive = holding
        if nowActive != active {
            active = nowActive
            onChange?()
        }
    }

    private func release() {
        guard holding else { return }
        IOPMAssertionRelease(assertion)
        holding = false
    }
}
