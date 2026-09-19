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

    /// Longer side of requested frames, in pixels — plenty for a phone screen, ~80 KB a frame.
    static let maxPixelSize = 1000
    static let fps = 3.0
    /// No frame or heartbeat for this long means the stream is stale.
    static let staleAfter: TimeInterval = 6

    var devices: [SimulatorInfo] = []
    private(set) var watching: String?
    private(set) var frame: Frame?
    /// Last time the daemon confirmed the stream is alive (a frame or a heartbeat).
    private(set) var lastSignalAt: Date?
    private var arrivals: [Date] = []

    var device: SimulatorInfo? { devices.first { $0.udid == watching } }

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
        if watching != udid { frame = nil; arrivals = []; lastSignalAt = nil }
        watching = udid
    }

    func stopWatching() {
        watching = nil
        frame = nil
        arrivals = []
        lastSignalAt = nil
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
        guard incoming.udid == watching, incoming.seq >= (frame?.seq ?? 0) else { return }   // decoded out of order
        frame = Frame(image: image, seq: incoming.seq, width: incoming.width, height: incoming.height, receivedAt: Date())
        arrivals.append(Date())
        if arrivals.count > 40 { arrivals.removeFirst(arrivals.count - 40) }
    }
}
