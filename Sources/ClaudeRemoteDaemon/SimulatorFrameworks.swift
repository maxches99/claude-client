#if os(macOS)
import Foundation
import ObjCExceptionGuard

/// Apple's private simulator frameworks, loaded on demand: CoreSimulator (device lookup) and
/// Xcode's SimulatorKit (HID message builders). Everything goes through `dlopen`/`dlsym` and the
/// Objective-C runtime, so nothing links against them and a Mac without Xcode fails softly.
///
/// One thing to know before adding calls: the IO-port objects a `SimDevice` hands out are ROCK
/// proxies to the per-device SimRenderServer, and a wrong message (e.g. `connectToDeviceIO:`)
/// asserts *in that server* and takes the simulator's display down with it. Stick to what
/// Simulator.app and idb are known to call.
final class SimulatorFrameworks: @unchecked Sendable {
    static let shared = SimulatorFrameworks()

    enum Failure: LocalizedError {
        case xcodeMissing
        case symbol(String)
        case classMissing(String)
        case notBooted(String)
        case context(String)

        var errorDescription: String? {
            switch self {
            case .xcodeMissing: return "Xcode's SimulatorKit was not found on the Mac"
            case .symbol(let name): return "SimulatorKit has no \(name)"
            case .classMissing(let name): return "CoreSimulator has no \(name)"
            case .notBooted(let udid): return "Simulator \(udid.prefix(8)) is not booted"
            case .context(let why): return "CoreSimulator is unavailable: \(why)"
            }
        }
    }

    private let lock = NSLock()
    private var loaded: Loaded?
    private var loadError: Error?

    private struct Loaded {
        let developerDir: String
        let kitHandle: UnsafeMutableRawPointer
        let serviceContext: NSObject
    }

    /// `DEVELOPER_DIR`, else `xcode-select -p`, else the default Xcode.
    static func findDeveloperDir() -> String {
        if let env = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !env.isEmpty { return env }
        if let out = try? SimulatorStreamer.run(["xcode-select", "-p"], viaXcrun: false, timeout: 5),
           let path = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            return path
        }
        return "/Applications/Xcode.app/Contents/Developer"
    }

    private func load() throws -> Loaded {
        lock.lock(); defer { lock.unlock() }
        if let loaded { return loaded }
        if let loadError { throw loadError }
        do {
            let developerDir = Self.findDeveloperDir()
            let core = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"
            let kit = developerDir + "/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"
            guard FileManager.default.fileExists(atPath: kit), dlopen(core, RTLD_NOW) != nil,
                  let handle = dlopen(kit, RTLD_NOW) else { throw Failure.xcodeMissing }
            guard let contextClass = NSClassFromString("SimServiceContext") else { throw Failure.classMissing("SimServiceContext") }
            // The `error:` out-params are passed as nil: `perform` boxes Swift pointers, and the failures
            // these calls can report ("no such developer dir") are already covered by the checks above.
            guard let context = (contextClass as AnyObject).perform(NSSelectorFromString("sharedServiceContextForDeveloperDir:error:"),
                                                                   with: developerDir as NSString, with: nil)?.takeUnretainedValue() as? NSObject else {
                throw Failure.context("no SimServiceContext for \(developerDir)")
            }
            let result = Loaded(developerDir: developerDir, kitHandle: handle, serviceContext: context)
            loaded = result
            return result
        } catch {
            loadError = error
            throw error
        }
    }

    var developerDir: String { get throws { try load().developerDir } }

    /// A C function exported by SimulatorKit.
    func symbol(_ name: String) throws -> UnsafeMutableRawPointer {
        guard let p = dlsym(try load().kitHandle, name) else { throw Failure.symbol(name) }
        return p
    }

    /// The `SimDevice` for a udid from the default device set (the one `simctl` lists).
    func device(udid: String) throws -> NSObject {
        let context = try load().serviceContext
        guard let set = context.perform(NSSelectorFromString("defaultDeviceSetWithError:"), with: nil)?.takeUnretainedValue() as? NSObject else {
            throw Failure.context("no default device set")
        }
        let devices = set.perform(NSSelectorFromString("devices"))?.takeUnretainedValue() as? [NSObject] ?? []
        let wanted = udid.uppercased()
        guard let device = devices.first(where: { ($0.perform(NSSelectorFromString("UDID"))?.takeUnretainedValue() as? UUID)?.uuidString.uppercased() == wanted }) else {
            throw Failure.notBooted(udid)
        }
        return device
    }

    // MARK: objc_msgSend with signatures `perform` cannot express

    static let msgSend: UnsafeMutableRawPointer = dlsym(dlopen(nil, RTLD_NOW), "objc_msgSend")!

    /// Runs `body`, converting an Objective-C exception into a thrown error.
    static func guarded<T>(_ body: () -> T) throws -> T {
        var result: T?
        var raised: NSError?
        ObjCExceptionGuardRun({ result = body() }, &raised)
        if let raised { throw raised }
        return result!
    }
}
#endif

#if os(macOS)
/// `ccremote --sim-video UDID SECONDS [FILE]`: encode the simulator's framebuffer for a while, print
/// frame statistics and optionally write an Annex-B `.h264` file — a check of the private display API
/// and the encoder without a phone.
public func probeSimulatorVideo(udid: String, seconds: TimeInterval, output path: String?, log: @escaping @Sendable (String) -> Void) async throws {
    let screen = try SimulatorScreen(udid: udid)
    let counter = ProbeCounter(path: path)
    let encoder = SimulatorVideoEncoder(maxPixelSize: 1400, fps: 30) { frame in counter.record(frame) }
    try screen.start { [weak screen] in
        guard let surface = screen?.surface else { return }
        encoder.encodeIfChanged(surface)
    }
    if let surface = screen.surface { encoder.encodeIfChanged(surface) }
    log("probing \(udid.prefix(8)) for \(Int(seconds))s — move something on the simulator's screen")
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    screen.stop()
    encoder.invalidate()
    log(counter.summary())
}

private final class ProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0, keyframes = 0, bytes = 0
    private var size = (0, 0)
    private let handle: FileHandle?

    init(path: String?) {
        if let path { FileManager.default.createFile(atPath: path, contents: nil); handle = FileHandle(forWritingAtPath: path) } else { handle = nil }
    }

    func record(_ frame: SimulatorVideoEncoder.Frame) {
        lock.lock(); defer { lock.unlock() }
        frames += 1
        bytes += frame.data.count
        size = (frame.width, frame.height)
        if frame.keyframe { keyframes += 1 }
        guard let handle else { return }
        // Annex B: start codes instead of AVCC lengths, parameter sets ahead of key frames.
        let start = Data([0, 0, 0, 1])
        if let sps = frame.sps, let pps = frame.pps { handle.write(start + sps + start + pps) }
        var offset = 0
        let data = frame.data
        while offset + 4 <= data.count {
            let length = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            offset += 4
            guard length > 0, offset + length <= data.count else { break }
            handle.write(start + data[offset..<offset + length])
            offset += length
        }
    }

    func summary() -> String {
        lock.lock(); defer { lock.unlock() }
        try? handle?.close()
        return "frames: \(frames) (\(keyframes) key), \(size.0)×\(size.1), \(bytes / 1024) KB total"
    }
}
#endif
