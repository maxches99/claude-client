#if os(macOS)
import Foundation
import CoreVideo
import CoreMedia
import VideoToolbox
import IOSurface

/// Turns a simulator framebuffer into an H.264 stream: scales the BGRA IOSurface down to the
/// requested size, feeds it to a hardware `VTCompressionSession` and hands out AVCC access units with
/// their parameter sets. Encodes only when the surface's seed changed (i.e. something was drawn), at
/// most `fps` times a second, and always gets the last frame of a burst out.
final class SimulatorVideoEncoder: @unchecked Sendable {
    struct Frame: Sendable {
        let width: Int
        let height: Int
        let keyframe: Bool
        let sps: Data?
        let pps: Data?
        let data: Data
        let ptsMillis: Int
    }

    private let queue = DispatchQueue(label: "ccremote.simulator.encoder", qos: .userInteractive)
    private let output: @Sendable (Frame) -> Void
    private var maxPixelSize: Int
    private var fps: Double

    private var session: VTCompressionSession?
    private var sessionSize = (width: 0, height: 0)
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var lastSeed: UInt32?
    private var lastEncodeAt: Date = .distantPast
    private var pending: DispatchWorkItem?
    private var forceKeyframe = true
    private let started = Date()

    init(maxPixelSize: Int, fps: Double, output: @escaping @Sendable (Frame) -> Void) {
        self.maxPixelSize = maxPixelSize
        self.fps = fps
        self.output = output
    }

    deinit { invalidate() }

    /// New viewer, or rotated screen: the next frame must be decodable on its own.
    func requestKeyframe() {
        queue.async { self.forceKeyframe = true; self.lastSeed = nil }
    }

    func reconfigure(maxPixelSize: Int, fps: Double) {
        queue.async {
            guard self.maxPixelSize != maxPixelSize || self.fps != fps else { return }
            self.maxPixelSize = maxPixelSize
            self.fps = fps
            self.tearDownSession()
            self.forceKeyframe = true
            self.lastSeed = nil
        }
    }

    /// Encode `surface` if it changed since the last call (rate-limited; a call that arrives too early
    /// is deferred to the next slot, so the final state of an animation is never dropped).
    func encodeIfChanged(_ surface: IOSurface) {
        queue.async { self.encodeLocked(surface) }
    }

    func invalidate() {
        queue.sync {
            pending?.cancel()
            pending = nil
            tearDownSession()
        }
    }

    // MARK: encoding (on `queue`)

    private func encodeLocked(_ surface: IOSurface) {
        let ref = unsafeBitCast(surface, to: IOSurfaceRef.self)
        let seed = IOSurfaceGetSeed(ref)
        guard forceKeyframe || seed != lastSeed else { return }
        let interval = 1 / max(fps, 1)
        let elapsed = Date().timeIntervalSince(lastEncodeAt)
        if elapsed < interval {
            guard pending == nil else { return }   // one deferred encode is enough; it reads the latest pixels
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pending = nil
                self.encodeLocked(surface)
            }
            pending = item
            queue.asyncAfter(deadline: .now() + (interval - elapsed), execute: item)
            return
        }
        pending?.cancel()
        pending = nil
        lastSeed = seed
        lastEncodeAt = Date()

        let width = IOSurfaceGetWidth(ref), height = IOSurfaceGetHeight(ref)
        let scale = min(1, Double(maxPixelSize) / Double(max(width, height, 1)))
        let target = (width: max(2, Int(Double(width) * scale) & ~1), height: max(2, Int(Double(height) * scale) & ~1))
        if session == nil || sessionSize != target {
            tearDownSession()
            guard makeSession(width: target.width, height: target.height) else { return }
        }
        guard let scaled = scaledCopy(of: ref, width: target.width, height: target.height) else { return }

        let pts = CMTime(value: CMTimeValue(Date().timeIntervalSince(started) * 1000), timescale: 1000)
        var properties: [CFString: Any] = [:]
        if forceKeyframe { properties[kVTEncodeFrameOptionKey_ForceKeyFrame] = true }
        forceKeyframe = false
        let size = target
        let status = VTCompressionSessionEncodeFrame(session!, imageBuffer: scaled, presentationTimeStamp: pts, duration: .invalid,
                                                     frameProperties: properties as CFDictionary, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let frame = Self.frame(from: sample, width: size.width, height: size.height) else { return }
            self?.output(frame)
        }
        if status != noErr { tearDownSession(); forceKeyframe = true }
    }

    private func makeSession(width: Int, height: Int) -> Bool {
        var created: VTCompressionSession?
        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let created else { return false }
        // UI content: mostly static with sharp edges. Real-time, no B-frames, keyframes every few seconds.
        let bitrate = Self.bitrate(width: width, height: height)
        let settings: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Main_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: Int(fps * 3),
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 3,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_DataRateLimits: [bitrate / 8 * 3 / 2, 1] as [Int],
        ]
        VTSessionSetProperties(created, propertyDictionary: settings as CFDictionary)
        VTCompressionSessionPrepareToEncodeFrames(created)
        session = created
        sessionSize = (width, height)

        var transferSession: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transferSession)
        transfer = transferSession
        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
        ]
        var newPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, poolAttributes as CFDictionary, &newPool)
        pool = newPool
        return transfer != nil && pool != nil
    }

    private func tearDownSession() {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        sessionSize = (0, 0)
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
        transfer = nil
        pool = nil
    }

    /// The framebuffer, scaled into a buffer of our own so the encoder never reads a surface the
    /// render server is still drawing into.
    private func scaledCopy(of surface: IOSurfaceRef, width: Int, height: Int) -> CVPixelBuffer? {
        guard let transfer, let pool else { return nil }
        var source: Unmanaged<CVPixelBuffer>?
        guard CVPixelBufferCreateWithIOSurface(nil, surface, nil, &source) == kCVReturnSuccess, let source = source?.takeRetainedValue() else { return nil }
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination) == kCVReturnSuccess, let destination else { return nil }
        guard VTPixelTransferSessionTransferImage(transfer, from: source, to: destination) == noErr else { return nil }
        return destination
    }

    /// ~2.5 Mbit/s for a 640×1400 phone screen, scaled with the pixel count.
    private static func bitrate(width: Int, height: Int) -> Int {
        let reference = 640.0 * 1400.0
        return Int(min(max(2_500_000 * Double(width * height) / reference, 600_000), 8_000_000))
    }

    private static func frame(from sample: CMSampleBuffer, width: Int, height: Int) -> Frame? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let copied = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        guard copied == noErr else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false
        let keyframe = !notSync
        var sps: Data?, pps: Data?
        if keyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            sps = parameterSet(format, index: 0)
            pps = parameterSet(format, index: 1)
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        return Frame(width: width, height: height, keyframe: keyframe, sps: sps, pps: pps, data: data, ptsMillis: Int(CMTimeGetSeconds(pts) * 1000))
    }

    private static func parameterSet(_ format: CMFormatDescription, index: Int) -> Data? {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                 parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
              let pointer else { return nil }
        return Data(bytes: pointer, count: size)
    }
}
#endif
