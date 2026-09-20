#if os(macOS)
import Foundation
import IOSurface
import ObjCExceptionGuard

/// A booted simulator's main display, read straight from its framebuffer.
///
/// CoreSimulator exposes the display as an IO port whose descriptor (`SimScreen`, a proxy into the
/// device's SimRenderServer) vends the framebuffer `IOSurface` and calls back once per rendered
/// frame — the same objects Simulator.app draws from, and what idb's video stream reads. The surface
/// is BGRA at the device's native pixel size and is replaced on rotation, which the surfaces
/// callback reports. Only known-safe messages are sent to the proxy (see `SimulatorFrameworks`).
final class SimulatorScreen: @unchecked Sendable {
    enum Failure: LocalizedError {
        case noDisplay(String)
        case noSurface

        var errorDescription: String? {
            switch self {
            case .noDisplay(let udid): return "Simulator \(udid.prefix(8)) has no display port"
            case .noSurface: return "The simulator's framebuffer is not available"
            }
        }
    }

    let udid: String
    private let descriptor: NSObject
    private let lock = NSLock()
    private var currentSurface: IOSurface?
    private var token: NSUUID?
    /// Serial queue the proxy delivers callbacks on; also serializes register/unregister.
    private let queue = DispatchQueue(label: "ccremote.simulator.screen", qos: .userInteractive)

    init(udid: String) throws {
        self.udid = udid
        let device = try SimulatorFrameworks.shared.device(udid: udid)
        guard let io = device.perform(NSSelectorFromString("io"))?.takeUnretainedValue() as? NSObject,
              let ports = io.perform(NSSelectorFromString("ioPorts"))?.takeUnretainedValue() as? [NSObject],
              let screenProtocol = NSProtocolFromString("SimScreen") else { throw Failure.noDisplay(udid) }
        // Prefer display class 0 (the main screen); CarPlay / external displays come after it.
        var fallback: NSObject?
        var main: NSObject?
        for port in ports {
            guard let candidate = try SimulatorFrameworks.guarded({ port.perform(NSSelectorFromString("descriptor"))?.takeUnretainedValue() as? NSObject }),
                  candidate.conforms(to: screenProtocol) else { continue }
            if Self.displayClass(of: candidate) == 0 { main = candidate; break }
            if fallback == nil { fallback = candidate }
        }
        guard let found = main ?? fallback else { throw Failure.noDisplay(udid) }
        let surface = try SimulatorFrameworks.guarded { found.perform(NSSelectorFromString("framebufferSurface"))?.takeUnretainedValue() as? IOSurface }
        guard surface != nil else { throw Failure.noSurface }
        descriptor = found
        currentSurface = surface
    }

    deinit { stop() }

    /// The live framebuffer (nil between a rotation and the surfaces callback that follows it).
    var surface: IOSurface? {
        lock.lock(); defer { lock.unlock() }
        return currentSurface
    }

    /// Start receiving `onFrame` after every rendered frame (on an internal queue).
    func start(onFrame: @escaping @Sendable () -> Void) throws {
        let token = NSUUID()
        let frameBlock: @convention(block) () -> Void = { onFrame() }
        let surfacesBlock: @convention(block) (IOSurface?, IOSurface?) -> Void = { [weak self] framebuffer, _ in
            guard let self else { return }
            self.lock.lock(); self.currentSurface = framebuffer; self.lock.unlock()
            onFrame()
        }
        let propertiesBlock: @convention(block) (AnyObject?) -> Void = { _ in }
        typealias Register = @convention(c) (AnyObject, Selector, NSUUID, DispatchQueue, AnyObject, AnyObject, AnyObject) -> Void
        let register = unsafeBitCast(SimulatorFrameworks.msgSend, to: Register.self)
        try SimulatorFrameworks.guarded {
            register(descriptor, NSSelectorFromString("registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:"),
                     token, queue, unsafeBitCast(frameBlock, to: AnyObject.self), unsafeBitCast(surfacesBlock, to: AnyObject.self), unsafeBitCast(propertiesBlock, to: AnyObject.self))
        }
        lock.lock(); self.token = token; lock.unlock()
    }

    func stop() {
        lock.lock()
        let token = self.token
        self.token = nil
        lock.unlock()
        guard let token else { return }
        _ = try? SimulatorFrameworks.guarded { descriptor.perform(NSSelectorFromString("unregisterScreenCallbacksWithUUID:"), with: token) }
    }

    /// `state.displayClass` — 0 for the main screen. Read through `objc_msgSend` because the state
    /// object is an immutable proxy that is not KVC-compliant.
    private static func displayClass(of descriptor: NSObject) -> Int? {
        guard let state = try? SimulatorFrameworks.guarded({ descriptor.perform(NSSelectorFromString("state"))?.takeUnretainedValue() as? NSObject }),
              state.responds(to: NSSelectorFromString("displayClass")) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt16
        return Int(unsafeBitCast(SimulatorFrameworks.msgSend, to: Getter.self)(state, NSSelectorFromString("displayClass")))
    }
}
#endif
