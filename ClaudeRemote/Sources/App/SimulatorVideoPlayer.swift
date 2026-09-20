import UIKit
import SwiftUI
import AVFoundation
import CoreMedia
import ClaudeRemoteCore

/// Decodes and shows the Mac's H.264 simulator stream. Each `SimulatorVideoFrame` is one AVCC access
/// unit; key frames bring SPS/PPS, from which the format description is built. Frames are handed to
/// an `AVSampleBufferDisplayLayer`, which decodes in hardware and displays immediately — no clock,
/// no buffering, so what is on screen is the latest frame the Mac sent.
@MainActor
final class SimulatorVideoPlayer {
    let layer = AVSampleBufferDisplayLayer()
    private var format: CMVideoFormatDescription?
    private var awaitingKeyframe = true

    init() {
        layer.videoGravity = .resizeAspect
        layer.preventsDisplaySleepDuringVideoPlayback = false
    }

    /// Forget the stream (switching simulators, or the Mac restarted it).
    func reset() {
        format = nil
        awaitingKeyframe = true
        layer.sampleBufferRenderer.flush()
    }

    func enqueue(_ frame: SimulatorVideoFrame) {
        if frame.keyframe, let sps = frame.spsBase64.flatMap({ Data(base64Encoded: $0) }), let pps = frame.ppsBase64.flatMap({ Data(base64Encoded: $0) }) {
            if let fresh = Self.makeFormat(sps: sps, pps: pps) {
                format = fresh
                awaitingKeyframe = false
            }
        }
        if layer.sampleBufferRenderer.status == .failed {
            // The renderer gave up (e.g. a resolution change it did not like): start over at the next key frame.
            layer.sampleBufferRenderer.flush()
            awaitingKeyframe = !frame.keyframe
        }
        guard !awaitingKeyframe, let format, let data = Data(base64Encoded: frame.dataBase64),
              let sample = Self.makeSample(data, format: format, ptsMillis: frame.ptsMillis) else { return }
        layer.sampleBufferRenderer.enqueue(sample)
    }

    private static func makeFormat(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        sps.withUnsafeBytes { spsBytes -> CMVideoFormatDescription? in
            pps.withUnsafeBytes { ppsBytes -> CMVideoFormatDescription? in
                let pointers: [UnsafePointer<UInt8>] = [spsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                                        ppsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self)]
                let sizes = [sps.count, pps.count]
                var format: CMVideoFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2,
                                                                                 parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                                 nalUnitHeaderLength: 4, formatDescriptionOut: &format)
                return status == noErr ? format : nil
            }
        }
    }

    private static func makeSample(_ data: Data, format: CMVideoFormatDescription, ptsMillis: Int) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copied = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
        guard copied == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: CMTimeValue(ptsMillis), timescale: 1000), decodeTimeStamp: .invalid)
        var size = data.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                        sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [CFMutableDictionary], let first = attachments.first {
            CFDictionarySetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

/// Hosts the player's layer in SwiftUI; the layer always fills the view (size it with `.aspectRatio`).
struct SimulatorVideoView: UIViewRepresentable {
    let player: SimulatorVideoPlayer

    func makeUIView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.backgroundColor = .black
        view.layer.addSublayer(player.layer)
        return view
    }

    func updateUIView(_ uiView: LayerHostView, context: Context) {
        if player.layer.superlayer !== uiView.layer {
            player.layer.removeFromSuperlayer()
            uiView.layer.addSublayer(player.layer)
        }
        uiView.setNeedsLayout()
    }

    final class LayerHostView: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.sublayers?.forEach { $0.frame = bounds }
            CATransaction.commit()
        }
    }
}
