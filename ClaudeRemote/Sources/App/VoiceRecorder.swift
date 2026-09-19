import Foundation
import AVFoundation
import Speech
import ClaudeRemoteCore

/// Records a short voice memo to an m4a file and, best-effort, transcribes it on-device. The memo is
/// sent as an `Attachment` (so it is genuinely uploaded and the agent has the file), and the transcript
/// is offered to prefill the composer — since the model reads text, not audio.
@Observable
@MainActor
final class VoiceRecorder {
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var fileURL: URL?

    /// Requests mic permission and starts recording. Returns false if denied or setup failed.
    func start() async -> Bool {
        guard await Self.ensureMicPermission() else { return false }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: [])
        } catch { return false }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            guard rec.record() else { return false }
            recorder = rec
            fileURL = url
            isRecording = true
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let r = self.recorder else { return }
                    self.elapsed = r.currentTime
                }
            }
            return true
        } catch { return false }
    }

    /// Stops recording; returns the recorded file URL (nil if nothing was captured).
    @discardableResult
    func stop() -> URL? {
        timer?.invalidate(); timer = nil
        recorder?.stop(); recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        return fileURL
    }

    /// Stops and discards the recording (e.g. the user swiped to cancel).
    func cancel() {
        let url = stop()
        if let url { try? FileManager.default.removeItem(at: url) }
        fileURL = nil
        elapsed = 0
    }

    /// The recorded memo as an upload-ready `Attachment` (nil if nothing recorded / over the size cap).
    func attachment() -> Attachment? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        let name = "voice-memo-\(Int(elapsed.rounded()))s.m4a"
        return Media.attachment(data: data, filename: name, mediaType: "audio/mp4")
    }

    /// Removes the temp file after the memo has been turned into an `Attachment`.
    func discardFile() {
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        fileURL = nil
    }

    /// Best-effort on-device transcription of the last recording. Empty when unavailable or denied.
    func transcribe() async -> String {
        guard let url = fileURL else { return "" }
        guard await Self.ensureSpeechPermission() else { return "" }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { return "" }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        let box = ResumeBox()
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    if box.claim() { cont.resume(returning: result.bestTranscription.formattedString) }
                } else if error != nil {
                    if box.claim() { cont.resume(returning: "") }
                }
            }
        }
    }

    private static func ensureMicPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in cont.resume(returning: granted) }
        }
    }

    private static func ensureSpeechPermission() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status == .authorized) }
        }
    }
}

/// Guards a CheckedContinuation against a double resume from a callback that may fire more than once.
private final class ResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true; return true
    }
}
