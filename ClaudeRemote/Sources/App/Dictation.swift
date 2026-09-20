import Foundation
import AVFoundation
import Speech

/// Live speech-to-text for the composer: the mic feeds `SFSpeechRecognizer` as you talk and the
/// partial transcript lands in the draft word by word. On-device when the recognizer supports it.
/// Unlike `VoiceRecorder`, nothing is kept — the text is the product.
@Observable
@MainActor
final class Dictation {
    enum Failure: Equatable { case microphone, speech, unavailable }

    private(set) var isListening = false
    /// The transcript of the current utterance so far (partial results replace, not append).
    private(set) var text = ""
    /// Rough input level 0…1 for the meter while listening.
    private(set) var level: Float = 0
    private(set) var failure: Failure?

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var idleTimer: Timer?

    /// Starts listening; `onText` fires on every partial result with the full text so far.
    func start() async -> Bool {
        failure = nil
        guard await Self.ensureMicPermission() else { failure = .microphone; return false }
        guard await Self.ensureSpeechPermission() else { failure = .speech; return false }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { failure = .unavailable; return false }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: [])
        } catch { failure = .unavailable; return false }

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        if #available(iOS 16, *) { request.addsPunctuation = true }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { failure = .unavailable; return false }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let rms = Self.rms(buffer)
            Task { @MainActor [weak self] in self?.level = rms }
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            failure = .unavailable
            return false
        }

        self.engine = engine
        self.request = request
        text = ""
        isListening = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                if let result {
                    self.text = result.bestTranscription.formattedString
                    if result.isFinal { self.stop() }
                } else if error != nil {
                    // Silence → the recognizer times out with an error; keep what we have.
                    self.stop()
                }
            }
        }
        return true
    }

    /// Stops listening and keeps `text` as the final transcript.
    func stop() {
        guard isListening else { return }
        isListening = false
        idleTimer?.invalidate(); idleTimer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        request?.endAudio()
        task?.cancel()
        engine = nil; request = nil; task = nil
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Stops and throws the text away.
    func cancel() {
        stop()
        text = ""
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(n))
        // Speech sits around -40…-10 dBFS; map that onto 0…1.
        let db = 20 * log10(max(rms, 1e-6))
        return min(max((db + 45) / 35, 0), 1)
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
