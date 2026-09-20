import UIKit
import Observation
import ClaudeRemoteCore

/// Booted simulators on the Mac and the latest decoded frame of the one being watched.
@MainActor
@Observable
final class SimulatorFeed {
    struct Frame {
        let image: UIImage
        let seq: Int
        let width: Int
        let height: Int
        let receivedAt: Date
    }

    /// Longer side of the requested video, in pixels — crisp on a phone, ~2.5 Mbit/s when the screen moves.
    static let maxPixelSize = 1400
    /// Video frame rate asked for; the JPEG fallback is capped by the Mac regardless.
    static let fps = 30.0
    /// No frame or heartbeat for this long means the stream is stale.
    static let staleAfter: TimeInterval = 6

    /// Every simulator on the Mac, booted ones first.
    var devices: [SimulatorInfo] = []
    var booted: [SimulatorInfo] { devices.filter(\.isBooted) }
    /// An action the Mac is still carrying out (a boot can take a minute).
    var pendingAction: (udid: String, action: SimulatorAction)?
    /// Installed apps of the simulator last asked about.
    var apps: (udid: String, items: [SimulatorApp], error: String?)?
    private(set) var watching: String?
    /// Latest JPEG frame (the fallback path); nil while video is flowing.
    private(set) var frame: Frame?
    /// Coded size of the video stream once the first key frame arrived; drives the picture's aspect ratio.
    private(set) var videoSize: CGSize?
    let player = SimulatorVideoPlayer()
    /// Last time the daemon confirmed the stream is alive (a frame or a heartbeat).
    private(set) var lastSignalAt: Date?
    private var arrivals: [Date] = []
    /// A short-lived message for the status line: an input the Mac could not deliver, or "Copied".
    var notice: (message: String, at: Date, isError: Bool)?
    /// Resolves the `simulatorScreenshot` reply the view is waiting for.
    var screenshotWaiter: ((UIImage?, String?) -> Void)?

    /// Size of what is on screen (video or JPEG), for aspect ratio and the status line.
    var pictureSize: CGSize? {
        if let videoSize { return videoSize }
        if let frame, frame.width > 0 { return CGSize(width: frame.width, height: frame.height) }
        return nil
    }

    var device: SimulatorInfo? { devices.first { $0.udid == watching } }

    func show(_ message: String, error: Bool = false) {
        notice = (message, Date(), error)
    }

    /// The current notice if it is still fresh.
    func notice(at now: Date) -> (message: String, isError: Bool)? {
        guard let notice, now.timeIntervalSince(notice.at) < 6 else { return nil }
        return (notice.message, notice.isError)
    }

    func isAlive(now: Date = Date()) -> Bool {
        guard let lastSignalAt else { return false }
        return now.timeIntervalSince(lastSignalAt) < Self.staleAfter
    }

    /// Frames per second over the last few seconds (0 while the screen is static).
    var measuredFPS: Double {
        let cutoff = Date().addingTimeInterval(-3)
        let recent = arrivals.filter { $0 > cutoff }
        guard recent.count >= 2, let first = recent.first, let last = recent.last, last > first else { return 0 }
        return Double(recent.count - 1) / last.timeIntervalSince(first)
    }

    func startWatching(_ udid: String) {
        if watching != udid { frame = nil; videoSize = nil; player.reset(); arrivals = []; lastSignalAt = nil }
        watching = udid
    }

    func stopWatching() {
        watching = nil
        frame = nil
        videoSize = nil
        player.reset()
        arrivals = []
        lastSignalAt = nil
        notice = nil
    }

    func receiveVideo(_ incoming: SimulatorVideoFrame) {
        guard incoming.udid == watching else { return }
        lastSignalAt = Date()
        player.enqueue(incoming)
        let size = CGSize(width: incoming.width, height: incoming.height)
        if videoSize != size { videoSize = size }
        if frame != nil { frame = nil }   // video took over from the JPEG fallback
        arrivals.append(Date())
        if arrivals.count > 90 { arrivals.removeFirst(arrivals.count - 90) }
    }

    func receive(_ incoming: SimulatorFrame) {
        guard incoming.udid == watching else { return }
        lastSignalAt = Date()
        guard let base64 = incoming.jpegBase64 else { return }   // heartbeat: unchanged screen
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let data = Data(base64Encoded: base64), let decoded = UIImage(data: data) else { return }
            let image = decoded.preparingForDisplay() ?? decoded
            await self?.apply(image, from: incoming)
        }
    }

    private func apply(_ image: UIImage, from incoming: SimulatorFrame) {
        guard incoming.udid == watching, videoSize == nil, incoming.seq >= (frame?.seq ?? 0) else { return }   // decoded out of order
        frame = Frame(image: image, seq: incoming.seq, width: incoming.width, height: incoming.height, receivedAt: Date())
        arrivals.append(Date())
        if arrivals.count > 40 { arrivals.removeFirst(arrivals.count - 40) }
    }
}
