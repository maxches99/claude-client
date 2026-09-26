import Foundation
import ClaudeRemoteCore

/// How the Mac should address people when it translates what you say.
enum TranslatorTone: String, CaseIterable, Identifiable {
    case polite, neutral, casual
    var id: String { rawValue }
    var label: String {
        switch self {
        case .polite: "Polite"
        case .neutral: "Neutral"
        case .casual: "Friendly"
        }
    }
    /// The instruction added to the prompt; nil when nothing needs saying.
    var instruction: String? {
        switch self {
        case .polite: "Use the polite, respectful register a traveller would use with a stranger (honorifics where the language has them)."
        case .neutral: nil
        case .casual: "Use a friendly, casual register, as between people of the same age who have just met."
        }
    }
}

/// Everything translated on a trip, kept on the phone: to look back at, and for the Mac to sum up.
struct TripEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case heard, said, photo }
    let id: UUID
    var date: Date
    var kind: Kind
    var original: String
    var translation: String
    /// The pair, as recognizer codes ("ja-JP"): what they speak, what you read.
    var theirs: String
    var mine: String
}

@MainActor
enum TripLog {
    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("trip-log.json")
    }

    private static var cache: [TripEntry]?

    static func load() -> [TripEntry] {
        if let cache { return cache }
        let entries = (try? Data(contentsOf: file)).flatMap { try? ProtocolCoding.decoder.decode([TripEntry].self, from: $0) } ?? []
        cache = entries
        return entries
    }

    /// Adds the entry, or replaces the one with its id (a card the Mac translated better).
    static func record(_ entry: TripEntry) {
        var entries = load()
        if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry } else { entries.append(entry) }
        save(entries)
    }

    static func remove(_ ids: Set<UUID>) { save(load().filter { !ids.contains($0.id) }) }
    static func clear() { save([]) }

    private static func save(_ entries: [TripEntry]) {
        cache = entries
        guard let data = try? ProtocolCoding.encoder.encode(entries) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// How many times you have said this (the same words, give or take case and punctuation).
    static func timesSaid(_ text: String, theirs: String) -> Int {
        let key = normalized(text)
        return load().filter { $0.kind == .said && $0.theirs == theirs && normalized($0.original) == key }.count
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }.trimmingCharacters(in: .whitespaces)
    }

    static func summaryPrompt(_ entries: [TripEntry], mine: String) -> String {
        let lines = entries.map { entry -> String in
            let who = entry.kind == .said ? "I said" : (entry.kind == .heard ? "They said" : "Photo")
            return "[\(entry.date.formatted(date: .abbreviated, time: .shortened))] \(who): \(entry.original) → \(entry.translation)"
        }
        return """
        These are the translations from my trip, oldest first. Write me a short summary in \(mine): \
        the addresses and places, prices and amounts paid or quoted, times and bookings, names and contacts, \
        and anything agreed or promised. Group it under short headings, skip small talk, and leave out a heading with nothing under it.

        \(lines.joined(separator: "\n"))
        """
    }
}

/// Phrases you keep saying, saved into the phrasebook on their own (and ones you starred).
@MainActor
enum PersonalPhrases {
    private static func file(mine: String, theirs: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("phrasebooks")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(mine)_\(theirs)_mine.json")
    }

    static func load(mine: String, theirs: String) -> [PhraseSection.Phrase] {
        (try? Data(contentsOf: file(mine: mine, theirs: theirs))).flatMap { try? ProtocolCoding.decoder.decode([PhraseSection.Phrase].self, from: $0) } ?? []
    }

    static func save(_ phrases: [PhraseSection.Phrase], mine: String, theirs: String) {
        guard let data = try? ProtocolCoding.encoder.encode(phrases) else { return }
        try? data.write(to: file(mine: mine, theirs: theirs), options: .atomic)
    }

    static func contains(_ text: String, mine: String, theirs: String) -> Bool {
        let key = TripLog.normalized(text)
        return load(mine: mine, theirs: theirs).contains { TripLog.normalized($0.mine) == key }
    }

    /// Adds a phrase (or updates its translation), newest first.
    static func add(mine text: String, theirs translation: String, mine: String, theirs: String) {
        let key = TripLog.normalized(text)
        var phrases = load(mine: mine, theirs: theirs).filter { TripLog.normalized($0.mine) != key }
        phrases.insert(.init(mine: text, theirs: translation, reading: Transliteration.reading(translation, language: theirs)), at: 0)
        save(phrases, mine: mine, theirs: theirs)
    }

    static func remove(_ phrase: PhraseSection.Phrase, mine: String, theirs: String) {
        save(load(mine: mine, theirs: theirs).filter { $0.id != phrase.id }, mine: mine, theirs: theirs)
    }
}

/// How to read a phrase in Latin letters, worked out on the phone.
enum Transliteration {
    /// Nil for languages already written in Latin letters (or when there is nothing to add).
    static func reading(_ text: String, language: String) -> String? {
        let code = String(language.prefix(2))
        guard !["en", "es", "fr", "de", "it", "pt", "id", "tr", "vi"].contains(code) else { return nil }
        // Kanji have Japanese readings; the generic transform would read them as Mandarin.
        let latin = code == "ja" ? romaji(text) : text.applyingTransform(.toLatin, reverse: false)
        guard let latin, !latin.isEmpty, latin != text else { return nil }
        return latin
    }

    private static func romaji(_ text: String) -> String? {
        let string = text as NSString
        guard let tokenizer = CFStringTokenizerCreate(nil, text as CFString, CFRangeMake(0, string.length),
                                                      kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja") as CFLocale) else { return nil }
        var words: [String] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let token = string.substring(with: NSRange(location: range.location, length: range.length))
            if let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String {
                words.append(latin)
            } else if token.unicodeScalars.contains(where: { $0.properties.isAlphabetic }) {
                words.append(token.applyingTransform(.toLatin, reverse: false) ?? token)
            }
        }
        return words.joined(separator: " ")
    }
}
