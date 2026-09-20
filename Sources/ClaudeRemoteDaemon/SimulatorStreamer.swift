#if os(macOS)
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ClaudeRemoteCore
import ClaudeCodeHost

/// Live view of the Mac's booted iOS Simulators for the phone.
///
/// While phones are connected it keeps the booted-device list fresh (`simctl list`, every few
/// seconds) and pushes it when it changes. While a phone watches a simulator it streams the screen:
/// H.264 straight from the simulator's framebuffer (`SimulatorScreen` + `SimulatorVideoEncoder`)
/// when the phone asks for video and the private display API cooperates, else JPEG snapshots from
/// `simctl io screenshot`, downscaled for the wire and sent only when the screen changed (a
/// heartbeat says "still the same"). Nothing runs when nobody is looking.
actor SimulatorStreamer {
    static let shared = SimulatorStreamer()

    /// Set once at startup, before any phone connects.
    nonisolated(unsafe) static var log: @Sendable (String) -> Void = { _ in }

    private struct Viewer {
        let send: @Sendable (ServerMessage) -> Void
        var maxPixelSize: Int
        var interval: TimeInterval
        /// Asked for H.264 (and the Mac could start it). Others get JPEG snapshots.
        var video: Bool
    }

    /// One H.264 stream per simulator, shared by every phone watching it as video.
    private final class VideoSession {
        let screen: SimulatorScreen
        let encoder: SimulatorVideoEncoder
        let frames: AsyncStream<SimulatorVideoEncoder.Frame>
        var pump: Task<Void, Never>?
        var seq = 0
        var lastSentAt = Date()

        init(screen: SimulatorScreen, maxPixelSize: Int, fps: Double) {
            self.screen = screen
            let (stream, continuation) = AsyncStream.makeStream(of: SimulatorVideoEncoder.Frame.self, bufferingPolicy: .bufferingNewest(8))
            frames = stream
            encoder = SimulatorVideoEncoder(maxPixelSize: maxPixelSize, fps: fps) { continuation.yield($0) }
        }

        func stop() {
            pump?.cancel()
            screen.stop()
            encoder.invalidate()
        }
    }

    private static let maxFPS = 4.0
    private static let maxVideoFPS = 30.0
    private static let defaultFPS = 3.0
    private static let heartbeatInterval: TimeInterval = 2
    private static let listInterval: TimeInterval = 4
    private static let jpegQuality: CGFloat = 0.6

    /// Phones that receive device-list pushes (every authenticated phone).
    private var listeners: [UUID: @Sendable (ServerMessage) -> Void] = [:]
    /// udid → phone → frame settings.
    private var viewers: [String: [UUID: Viewer]] = [:]
    private var frameLoops: [String: Task<Void, Never>] = [:]
    private var videoSessions: [String: VideoSession] = [:]
    /// Simulators whose framebuffer could not be opened this boot — no point retrying on every watch.
    private var videoUnavailable: Set<String> = []
    private var listLoop: Task<Void, Never>?
    private var devices: [SimulatorInfo] = []
    private var listedOnce = false

    // MARK: phones

    /// A phone authenticated: it gets the current list now and pushes on every change.
    func attach(_ id: UUID, send: @escaping @Sendable (ServerMessage) -> Void) async {
        listeners[id] = send
        if !listedOnce { await refreshDevices(broadcast: false) }
        send(.simulators(items: devices))
        ensureListLoop()
    }

    /// A phone went away: drop its list pushes and every frame subscription.
    func detach(_ id: UUID) {
        listeners[id] = nil
        for udid in Array(viewers.keys) { removeViewer(id, udid: udid) }
        if listeners.isEmpty {
            listLoop?.cancel()
            listLoop = nil
        }
    }

    func list() async -> [SimulatorInfo] {
        await refreshDevices(broadcast: true)
        return devices
    }

    func watch(udid: String, id: UUID, maxPixelSize: Int?, fps: Double?, codec: String?, send: @escaping @Sendable (ServerMessage) -> Void) {
        let wantsVideo = codec == "h264" && !videoUnavailable.contains(udid)
        let video = wantsVideo && startVideo(udid: udid, maxPixelSize: maxPixelSize, fps: fps)
        let rate = min(max(fps ?? Self.defaultFPS, 0.5), video ? Self.maxVideoFPS : Self.maxFPS)
        let size = min(max(maxPixelSize ?? 1000, 200), 2400)
        viewers[udid, default: [:]][id] = Viewer(send: send, maxPixelSize: size, interval: 1 / rate, video: video)
        if video {
            reconfigureVideo(udid: udid)
            videoSessions[udid]?.encoder.requestKeyframe()
            if let surface = videoSessions[udid]?.screen.surface { videoSessions[udid]?.encoder.encodeIfChanged(surface) }
        } else {
            // A new viewer wants a full frame right away, whatever the last one saw.
            lastRaw[udid] = nil
            if frameLoops[udid] == nil {
                Self.log("simulator: streaming \(udid.prefix(8)) as JPEG at ≤\(Int(rate)) fps, ≤\(size)px")
                frameLoops[udid] = Task { [weak self] in await self?.runFrameLoop(udid: udid) }
            }
        }
    }

    func unwatch(udid: String?, id: UUID) {
        if let udid { removeViewer(id, udid: udid) } else { for udid in Array(viewers.keys) { removeViewer(id, udid: udid) } }
    }

    private func removeViewer(_ id: UUID, udid: String) {
        viewers[udid]?[id] = nil
        let remaining = viewers[udid] ?? [:]
        if !remaining.values.contains(where: { !$0.video }) {
            frameLoops[udid]?.cancel()
            frameLoops[udid] = nil
            lastRaw[udid] = nil
        }
        if !remaining.values.contains(where: { $0.video }) {
            videoSessions[udid]?.stop()
            videoSessions[udid] = nil
        }
        if remaining.isEmpty {
            viewers[udid] = nil
            Self.log("simulator: stopped streaming \(udid.prefix(8))")
        } else if videoSessions[udid] != nil {
            reconfigureVideo(udid: udid)
        }
    }

    // MARK: video

    /// Opens the framebuffer and starts encoding; false (and remembered) when the private API says no.
    private func startVideo(udid: String, maxPixelSize: Int?, fps: Double?) -> Bool {
        if videoSessions[udid] != nil { return true }
        do {
            let screen = try SimulatorScreen(udid: udid)
            let session = VideoSession(screen: screen,
                                       maxPixelSize: min(max(maxPixelSize ?? 1400, 200), 2800),
                                       fps: min(max(fps ?? Self.maxVideoFPS, 1), Self.maxVideoFPS))
            let encoder = session.encoder
            try screen.start { [weak screen] in
                guard let surface = screen?.surface else { return }
                encoder.encodeIfChanged(surface)
            }
            session.pump = Task { [weak self] in
                for await frame in session.frames {
                    guard !Task.isCancelled else { return }
                    await self?.deliverVideo(udid: udid, frame: frame)
                }
            }
            videoSessions[udid] = session
            Self.log("simulator: streaming \(udid.prefix(8)) as H.264 from the framebuffer")
            ensureHeartbeat()
            return true
        } catch {
            Self.log("simulator: no video for \(udid.prefix(8)) (\(error.localizedDescription)) — falling back to JPEG")
            videoUnavailable.insert(udid)
            return false
        }
    }

    /// The largest size and fastest rate any current video viewer asked for.
    private func reconfigureVideo(udid: String) {
        guard let session = videoSessions[udid] else { return }
        let active = (viewers[udid] ?? [:]).values.filter(\.video)
        guard !active.isEmpty else { return }
        let size = min(active.map(\.maxPixelSize).max() ?? 1400, 2800)
        let rate = 1 / (active.map(\.interval).min() ?? (1 / Self.maxVideoFPS))
        session.encoder.reconfigure(maxPixelSize: size, fps: rate)
    }

    private func deliverVideo(udid: String, frame: SimulatorVideoEncoder.Frame) {
        guard let session = videoSessions[udid], let active = viewers[udid]?.values.filter(\.video), !active.isEmpty else { return }
        session.seq += 1
        session.lastSentAt = Date()
        let message = ServerMessage.simulatorVideo(frame: SimulatorVideoFrame(
            udid: udid, seq: session.seq, width: frame.width, height: frame.height, keyframe: frame.keyframe,
            spsBase64: frame.sps?.base64EncodedString(), ppsBase64: frame.pps?.base64EncodedString(),
            dataBase64: frame.data.base64EncodedString(), ptsMillis: frame.ptsMillis))
        for viewer in active { viewer.send(message) }
    }

    private var heartbeatLoop: Task<Void, Never>?

    /// A static screen produces no video frames; a heartbeat every couple of seconds keeps the phone's
    /// "Live" indicator honest (the same `simulatorFrame` heartbeat the JPEG path uses).
    private func ensureHeartbeat() {
        guard heartbeatLoop == nil else { return }
        heartbeatLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.heartbeatInterval * 1_000_000_000))
                guard let self else { return }
                if await self.sendVideoHeartbeats() == false { return }
            }
        }
    }

    /// False once there is nothing left to heartbeat (the loop ends and restarts with the next stream).
    private func sendVideoHeartbeats() -> Bool {
        guard !videoSessions.isEmpty else { heartbeatLoop = nil; return false }
        for (udid, session) in videoSessions where Date().timeIntervalSince(session.lastSentAt) >= Self.heartbeatInterval {
            let frame = SimulatorFrame(udid: udid, seq: session.seq, width: 0, height: 0, jpegBase64: nil, capturedAt: Date())
            session.lastSentAt = Date()
            for viewer in (viewers[udid] ?? [:]).values where viewer.video { viewer.send(.simulatorFrame(frame: frame)) }
        }
        return true
    }

    // MARK: device list

    private func ensureListLoop() {
        guard listLoop == nil else { return }
        listLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.listInterval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                await self.refreshDevices(broadcast: true)
            }
        }
    }

    private func refreshDevices(broadcast: Bool) async {
        let fresh = await Task.detached(priority: .utility) { Self.bootedDevices() }.value
        listedOnce = true
        guard fresh != devices else { return }
        let gone = Set(devices.map(\.udid)).subtracting(fresh.map(\.udid))
        for udid in gone {
            videoSessions[udid]?.stop()
            videoSessions[udid] = nil
            videoUnavailable.remove(udid)   // a reboot may bring the display port back
            await SimulatorInput.shared.forget(udid: udid)
        }
        devices = fresh
        guard broadcast else { return }
        for send in listeners.values { send(.simulators(items: fresh)) }
    }

    /// `simctl list devices booted -j` → the booted devices, newest runtime first.
    nonisolated private static func bootedDevices() -> [SimulatorInfo] {
        guard let data = try? run(["list", "devices", "booted", "-j"], timeout: 10),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = root["devices"] as? [String: [[String: Any]]] else { return [] }
        var result: [SimulatorInfo] = []
        for (runtimeId, list) in runtimes {
            for d in list {
                guard let udid = d["udid"] as? String, let name = d["name"] as? String,
                      let state = d["state"] as? String, state == "Booted" else { continue }
                result.append(SimulatorInfo(udid: udid, name: name, runtime: runtimeName(runtimeId), state: state))
            }
        }
        return result.sorted { ($0.runtime, $0.name) > ($1.runtime, $1.name) }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-2` → `iOS 26.2`.
    nonisolated private static func runtimeName(_ id: String) -> String {
        let tail = id.components(separatedBy: ".").last ?? id
        var parts = tail.components(separatedBy: "-")
        guard parts.count >= 2 else { return tail }
        let platform = parts.removeFirst()
        return "\(platform) \(parts.joined(separator: "."))"
    }

    // MARK: frames

    private var lastRaw: [String: Data] = [:]
    private var seq: [String: Int] = [:]
    private var lastSentAt: [String: Date] = [:]
    private var failures: [String: Int] = [:]

    private func runFrameLoop(udid: String) async {
        while !Task.isCancelled, let active = viewers[udid]?.filter({ !$0.value.video }), !active.isEmpty {
            let started = Date()
            let interval = active.values.map(\.interval).min() ?? (1 / Self.defaultFPS)
            let maxPixelSize = active.values.map(\.maxPixelSize).max() ?? 1000
            await captureAndSend(udid: udid, maxPixelSize: maxPixelSize)
            let elapsed = Date().timeIntervalSince(started)
            let wait = max(interval - elapsed, 0.02)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    private func captureAndSend(udid: String, maxPixelSize: Int) async {
        let raw = await Task.detached(priority: .userInitiated) { Self.screenshot(udid: udid) }.value
        guard let raw else {
            failures[udid, default: 0] += 1
            if failures[udid, default: 0] >= 3 {
                // The simulator probably shut down: tell the phones and stop trying.
                failures[udid] = 0
                await refreshDevices(broadcast: true)
                if !devices.contains(where: { $0.udid == udid }) {
                    for id in Array(viewers[udid]?.keys ?? [:].keys) { removeViewer(id, udid: udid) }
                }
            }
            return
        }
        failures[udid] = 0
        guard let active = viewers[udid]?.filter({ !$0.value.video }), !active.isEmpty else { return }

        if raw == lastRaw[udid] {
            // Unchanged screen: a heartbeat every couple of seconds keeps "Live" honest without traffic.
            if Date().timeIntervalSince(lastSentAt[udid] ?? .distantPast) >= Self.heartbeatInterval {
                let frame = SimulatorFrame(udid: udid, seq: seq[udid, default: 0], width: 0, height: 0, jpegBase64: nil, capturedAt: Date())
                lastSentAt[udid] = Date()
                for v in active.values { v.send(.simulatorFrame(frame: frame)) }
            }
            return
        }
        lastRaw[udid] = raw
        let scaledTask = Task.detached(priority: .userInitiated) { Self.downscale(raw, maxPixelSize: maxPixelSize) }
        guard let scaled = await scaledTask.value else { return }
        let next = seq[udid, default: 0] + 1
        seq[udid] = next
        lastSentAt[udid] = Date()
        let frame = SimulatorFrame(udid: udid, seq: next, width: scaled.width, height: scaled.height,
                                   jpegBase64: scaled.jpeg.base64EncodedString(), capturedAt: Date())
        for v in active.values { v.send(.simulatorFrame(frame: frame)) }
    }

    /// Full-resolution JPEG of the simulator's screen (`simctl` cannot write to stdout reliably, so via a temp file).
    nonisolated private static func screenshot(udid: String) -> Data? {
        let path = NSTemporaryDirectory() + "ccremote-sim-\(udid).jpg"
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard (try? run(["io", udid, "screenshot", "--type=jpeg", "--display=internal", path], timeout: 5)) != nil else { return nil }
        return FileManager.default.contents(atPath: path)
    }

    nonisolated private static func downscale(_ jpeg: Data, maxPixelSize: Int) -> (jpeg: Data, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (out as Data, image.width, image.height)
    }

    // MARK: simctl

    enum RunError: LocalizedError {
        case timeout, exit(Int32)
        var errorDescription: String? {
            switch self {
            case .timeout: return "simctl timed out"
            case .exit(let code): return "simctl failed (exit \(code))"
            }
        }
    }

    /// Runs `xcrun simctl …` (or, with `viaXcrun: false`, `/usr/bin/<args[0]> …`). stdin is /dev/null unless
    /// `input` is given (a child inheriting the terminal gets SIGTTIN'd under launchd); stdout is drained
    /// before waiting so a big output cannot deadlock the pipe.
    nonisolated static func run(_ args: [String], viaXcrun: Bool = true, input: Data? = nil, timeout: TimeInterval) throws -> Data {
        let p = Process()
        if viaXcrun {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            p.arguments = ["simctl"] + args
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/" + args[0])
            p.arguments = Array(args.dropFirst())
        }
        var env = ClaudeCLI.childEnvironment()
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }   // `simctl pbcopy` mangles UTF-8 stdin without a locale
        p.environment = env
        let stdin = input.map { _ in Pipe() }
        p.standardInput = stdin ?? FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        if let stdin, let input {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let timedOut = watchdog.isCancelled == false && p.terminationReason == .uncaughtSignal
        watchdog.cancel()
        if timedOut { throw RunError.timeout }
        guard p.terminationStatus == 0 else { throw RunError.exit(p.terminationStatus) }
        return data
    }
}
#endif
