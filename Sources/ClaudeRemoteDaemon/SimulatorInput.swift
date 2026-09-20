#if os(macOS)
import Foundation
import ClaudeRemoteCore
import ObjCExceptionGuard

/// Injects touches, keys and hardware buttons into a booted iOS Simulator for the phone.
///
/// `simctl` has no input commands, so this goes the way Simulator.app, idb and Claude Desktop's own
/// helper do: Apple's private SimulatorKit builds Indigo HID messages (`IndigoHIDMessageFor…`) and
/// `SimDeviceLegacyHIDClient` posts them to the device over its HID mach port (see
/// `SimulatorFrameworks`). Touch coordinates are unit ratios of the screen (top-left origin), which
/// is what the wire format wants anyway.
actor SimulatorInput {
    static let shared = SimulatorInput()

    /// Set once at startup, before any phone connects.
    nonisolated(unsafe) static var log: @Sendable (String) -> Void = { _ in }

    enum Failure: LocalizedError {
        case classMissing(String)
        case client(String)
        case send(String)
        case noPasteboard

        var errorDescription: String? {
            switch self {
            case .classMissing(let name): return "SimulatorKit has no \(name)"
            case .client(let why): return "Could not open the simulator's HID port: \(why)"
            case .send(let why): return "The simulator rejected the input: \(why)"
            case .noPasteboard: return "Text needs the simulator pasteboard, which this runtime has none of (watchOS?)"
            }
        }
    }

    private var builders: Builders?
    private var clients: [String: HIDClient] = [:]

    // MARK: events

    func perform(_ event: SimulatorInputEvent, udid: String) async throws {
        let kit = try loadBuilders()
        let client = try hidClient(udid: udid, kit: kit)
        do {
            switch event {
            case .tap(let x, let y, let hold):
                try await client.send(kit.touch(x: x, y: y, down: true))
                try await sleep(min(max(hold ?? 0.06, 0.03), 5))
                try await client.send(kit.touch(x: x, y: y, down: false))
            case .touch(let phase, let x, let y):
                // A finger tracked live from the phone: down / still down at a new point / up.
                try await client.send(kit.touch(x: x, y: y, down: phase != .ended))
            case .text(let text):
                try await type(text, udid: udid, client: client, kit: kit)
            case .key(let key):
                try await press(key.hidUsage, client: client, kit: kit)
            case .button(let button):
                try await client.send(kit.button(button, down: true))
                try await sleep(0.08)
                try await client.send(kit.button(button, down: false))
            }
        } catch {
            // A failed send usually means the device's IO went away: start over with a fresh client next time.
            clients[udid] = nil
            throw error
        }
    }

    /// The simulator shut down (or was never ours): forget its HID client.
    func forget(udid: String) {
        clients[udid] = nil
    }

    // MARK: keyboard

    /// Text goes through the simulator pasteboard and ⌘V, one line at a time with Return between
    /// lines. Typing by key code would be the obvious route, but HID codes go through the guest's
    /// active hardware-keyboard layout (a Russian layout turns "Hello" into "Руддщ"), while ⌘V works
    /// under any layout, handles emoji, and iOS takes a hardware-keyboard paste without a prompt.
    private func type(_ text: String, udid: String, client: HIDClient, kit: Builders) async throws {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            if !line.isEmpty {
                do { _ = try SimulatorStreamer.run(["pbcopy", udid], input: Data(line.utf8), timeout: 5) } catch { throw Failure.noPasteboard }
                try await client.send(kit.key(0xE3, down: true))                 // left ⌘
                try await press(0x19, client: client, kit: kit)                   // V
                try await client.send(kit.key(0xE3, down: false))
                try await sleep(0.08)
            }
            if index < lines.count - 1 { try await press(SimulatorKey.return.hidUsage, client: client, kit: kit) }
        }
    }

    private func press(_ usage: UInt32, client: HIDClient, kit: Builders) async throws {
        try await client.send(kit.key(usage, down: true))
        try await sleep(0.012)
        try await client.send(kit.key(usage, down: false))
        try await sleep(0.012)
    }

    private func sleep(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: SimulatorKit

    private func loadBuilders() throws -> Builders {
        if let builders { return builders }
        let loaded = try Builders()
        builders = loaded
        Self.log("simulator: SimulatorKit loaded from \((try? SimulatorFrameworks.shared.developerDir) ?? "?")")
        return loaded
    }

    private func hidClient(udid: String, kit: Builders) throws -> HIDClient {
        if let client = clients[udid] { return client }
        let client = try HIDClient(device: SimulatorFrameworks.shared.device(udid: udid))
        clients[udid] = client
        Self.log("simulator: HID client opened for \(udid.prefix(8))")
        return client
    }

    /// SimulatorKit's Indigo message builders.
    private final class Builders {
        private typealias ButtonFn = @convention(c) (Int32, Int32, Int32) -> UnsafeMutableRawPointer
        private typealias KeyboardFn = @convention(c) (Int32, Int32) -> UnsafeMutableRawPointer
        /// `IndigoHIDMessageForMouseNSEvent(CGPoint *, CGPoint *, IndigoHIDTarget, NSEventType, NSSize, IndigoHIDEdge)` —
        /// divides the point by the size to get the contact's ratio, so a unit size passes ratios through.
        private typealias MouseFn = @convention(c) (UnsafeMutablePointer<CGPoint>?, UnsafeMutablePointer<CGPoint>?, UInt32, UInt, CGSize, UInt32) -> UnsafeMutableRawPointer

        private let button: ButtonFn
        private let keyboard: KeyboardFn
        private let mouse: MouseFn

        init() throws {
            let frameworks = SimulatorFrameworks.shared
            button = unsafeBitCast(try frameworks.symbol("IndigoHIDMessageForButton"), to: ButtonFn.self)
            keyboard = unsafeBitCast(try frameworks.symbol("IndigoHIDMessageForKeyboardArbitrary"), to: KeyboardFn.self)
            mouse = unsafeBitCast(try frameworks.symbol("IndigoHIDMessageForMouseNSEvent"), to: MouseFn.self)
        }

        /// The digitizer service target the touch builder addresses.
        private static let touchTarget: UInt32 = 0x32
        /// `IndigoMessage` header: `innerSize` at 0x18, `eventType` at 0x1C, first `IndigoPayload` at 0x20
        /// (`eventKind`, `timestamp` at +4, the `IndigoTouch` event at +0x10). Layout per Simulator.app's
        /// class-dump, as used by idb's FBSimulatorControl.
        private static let payloadOffset = 0x20
        private static let payloadSize = 0x90
        private static let touchSize = 0x70

        /// A single-finger contact. SimulatorKit only builds *multi*-touch messages (eventType 3), so the
        /// builder's `IndigoTouch` is copied into a hand-made single-touch envelope (eventType 2, two
        /// payloads, the second marked as the repeated contact) — exactly what idb does.
        func touch(x: Double, y: Double, down: Bool) -> Data {
            var point = CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
            let source = mouse(&point, nil, Self.touchTarget, down ? 1 : 2, CGSize(width: 1, height: 1), 0)
            defer { free(source) }
            let size = Self.payloadOffset + 2 * Self.payloadSize   // 0x140
            let message = calloc(1, size)!
            message.storeBytes(of: UInt32(Self.payloadSize), toByteOffset: 0x18, as: UInt32.self)
            message.storeBytes(of: UInt8(2), toByteOffset: 0x1C, as: UInt8.self)
            message.storeBytes(of: UInt32(0xB), toByteOffset: Self.payloadOffset, as: UInt32.self)
            message.storeBytes(of: mach_absolute_time(), toByteOffset: Self.payloadOffset + 4, as: UInt64.self)
            let event = Self.payloadOffset + 0x10
            memcpy(message + event, source + event, Self.touchSize)
            message.storeBytes(of: point.x, toByteOffset: event + 0xC, as: Double.self)    // xRatio
            message.storeBytes(of: point.y, toByteOffset: event + 0x14, as: Double.self)   // yRatio
            let second = Self.payloadOffset + Self.payloadSize
            memcpy(message + second, message + Self.payloadOffset, Self.payloadSize)
            message.storeBytes(of: UInt32(1), toByteOffset: second + 0x10, as: UInt32.self)
            message.storeBytes(of: UInt32(2), toByteOffset: second + 0x14, as: UInt32.self)
            return Data(bytesNoCopy: message, count: size, deallocator: .free)
        }

        /// A hardware-keyboard key by USB HID usage (keyboard page).
        func key(_ usage: UInt32, down: Bool) -> Data {
            Self.wrap(keyboard(Int32(bitPattern: usage), down ? 1 : 2))
        }

        func button(_ button: SimulatorHardwareButton, down: Bool) -> Data {
            let source: Int32
            switch button {
            case .home: source = 0x0
            case .lock: source = 0x1
            case .siri: source = 0x400002
            }
            return Self.wrap(self.button(source, down ? 1 : 2, 0x33))   // ButtonEventTargetHardware
        }

        private static func wrap(_ message: UnsafeMutableRawPointer) -> Data {
            Data(bytesNoCopy: message, count: malloc_size(message), deallocator: .free)
        }
    }

    /// One `SimDeviceLegacyHIDClient`. Looked up by name and messaged through an informal protocol so
    /// no link-time reference to the private class exists.
    private final class HIDClient: @unchecked Sendable {
        private let client: AnyObject
        private let queue = DispatchQueue(label: "ccremote.simulator.hid")

        init(device: AnyObject) throws {
            let names = ["SimulatorKit.SimDeviceLegacyHIDClient", "SimDeviceLegacyHIDClient"]
            guard let cls = names.lazy.compactMap({ NSClassFromString($0) }).first else {
                throw Failure.classMissing("SimDeviceLegacyHIDClient")
            }
            var initError: AnyObject?
            var made: AnyObject?
            var raised: NSError?
            ObjCExceptionGuardRun({
                let allocated = (cls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
                made = allocated.flatMap { unsafeBitCast($0, to: HIDClientMessaging.self).initWithDevice(device, error: &initError) }
            }, &raised)
            guard let made else {
                throw Failure.client((initError as? Error)?.localizedDescription ?? raised?.localizedDescription ?? "init returned nil")
            }
            client = made
        }

        /// Posts one Indigo message and waits for the port to take it.
        func send(_ data: Data) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [client, queue] in
                    // The client frees the buffer once delivered (freeWhenDone), so hand it a copy.
                    let raw = malloc(data.count)!
                    data.withUnsafeBytes { raw.copyMemory(from: $0.baseAddress!, byteCount: data.count) }
                    var raised: NSError?
                    let ok = ObjCExceptionGuardRun({
                        unsafeBitCast(client, to: HIDClientMessaging.self).send(withMessage: raw, freeWhenDone: true, completionQueue: queue) { error in
                            if let error { continuation.resume(throwing: Failure.send(error.localizedDescription)) } else { continuation.resume() }
                        }
                    }, &raised)
                    // On a raise the buffer is deliberately leaked: ownership may already have moved to the client.
                    if !ok { continuation.resume(throwing: Failure.send(raised?.localizedDescription ?? "exception")) }
                }
            }
        }
    }
}

/// Informal protocol for the runtime-only `SimDeviceLegacyHIDClient` (a Swift class inside SimulatorKit,
/// exposed to Objective-C as `initWithDevice:error:` / `sendWithMessage:freeWhenDone:completionQueue:completion:`).
@objc private protocol HIDClientMessaging {
    @objc(initWithDevice:error:)
    func initWithDevice(_ device: Any, error: AutoreleasingUnsafeMutablePointer<AnyObject?>?) -> AnyObject?
    @objc(sendWithMessage:freeWhenDone:completionQueue:completion:)
    func send(withMessage message: UnsafeMutableRawPointer, freeWhenDone: Bool, completionQueue: DispatchQueue,
              completion: @escaping @Sendable (Error?) -> Void)
}

private extension SimulatorKey {
    /// USB HID keyboard-page usage ids.
    var hidUsage: UInt32 {
        switch self {
        case .return: return 40
        case .escape: return 41
        case .backspace: return 42
        case .tab: return 43
        case .space: return 44
        case .delete: return 76
        case .right: return 79
        case .left: return 80
        case .down: return 81
        case .up: return 82
        }
    }
}

/// `ccremote --sim-input UDID JSON`: exercise the HID path from a terminal without a phone.
public func injectSimulatorInput(_ event: SimulatorInputEvent, udid: String, log: @escaping @Sendable (String) -> Void) async throws {
    SimulatorInput.log = log
    try await SimulatorInput.shared.perform(event, udid: udid)
}
#endif
