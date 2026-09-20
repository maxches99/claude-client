import Foundation
import AVFoundation
import NaturalLanguage
import ClaudeRemoteCore

/// Reads replies aloud with the system voice. Markdown is flattened first (code blocks become a
/// short note — nobody wants a diff read out), the voice follows the text's language.
@Observable
@MainActor
final class Narrator: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var isSpeaking = false
    /// Which transcript item is being read, so the row can show it.
    private(set) var speakingItemId: String?
    private let synthesizer = AVSpeechSynthesizer()
    private var onFinish: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speaks `markdown`; `onFinish` runs when it ends (not when it is cut off by `stop`).
    func speak(_ markdown: String, itemId: String? = nil, onFinish: (() -> Void)? = nil) {
        stop()
        let text = Narrator.plainText(markdown)
        guard !text.isEmpty else { onFinish?(); return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true, options: [])
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Narrator.voice(for: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        self.onFinish = onFinish
        speakingItemId = itemId
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        onFinish = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false
        speakingItemId = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.speakingItemId = nil
            let finish = self.onFinish
            self.onFinish = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            finish?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.speakingItemId = nil
        }
    }

    /// A voice for the text's language (falls back to the system default).
    static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(400)))
        guard let language = recognizer.dominantLanguage?.rawValue else { return nil }
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(language) }
        // Prefer the enhanced / premium voice when one is downloaded.
        return candidates.max { a, b in a.quality.rawValue < b.quality.rawValue } ?? AVSpeechSynthesisVoice(language: language)
    }

    /// Markdown → something that reads well aloud.
    static func plainText(_ markdown: String) -> String {
        var text = markdown
        // Fenced code: replaced by a short spoken note (with the language when given).
        text = text.replacingOccurrences(of: "```([a-zA-Z0-9_+-]*)[^\n]*\n[\\s\\S]*?```", with: " (code block) ", options: .regularExpression)
        text = text.replacingOccurrences(of: "`([^`\n]*)`", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: "", options: .regularExpression)      // images
        text = text.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)   // links → label
        text = text.replacingOccurrences(of: "(?m)^#{1,6}\\s*", with: "", options: .regularExpression)               // headings
        text = text.replacingOccurrences(of: "(?m)^\\s*[-*+]\\s+", with: "", options: .regularExpression)            // bullets
        text = text.replacingOccurrences(of: "(?m)^\\s*\\d+\\.\\s+", with: "", options: .regularExpression)          // numbered
        text = text.replacingOccurrences(of: "(?m)^>\\s?", with: "", options: .regularExpression)                    // quotes
        text = text.replacingOccurrences(of: "(?m)^\\|.*\\|\\s*$", with: "", options: .regularExpression)            // table rows
        text = text.replacingOccurrences(of: "\\*\\*|__|~~", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?<![\\w])[*_](?=\\S)|(?<=\\S)[*_](?![\\w])", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^\\s*[-*_]{3,}\\s*$", with: "", options: .regularExpression)      // rules
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
