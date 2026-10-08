import SwiftUI
import Vision
import Translation
import NaturalLanguage

/// On-device translation with Apple's models: a phrase in about a tenth of a second, with no connection
/// and at no cost. The sessions only live inside SwiftUI's `.translationTask`, so `fastTranslator(_:mine:theirs:)`
/// holds them and serves the jobs queued here; callers just await `translate`.
@Observable
@MainActor
final class FastTranslator {
    enum Status: Equatable {
        case checking
        /// Both directions are downloaded: translations are instant and offline.
        case ready
        /// The phone can do this pair once the languages are downloaded.
        case downloadable
        /// Not a pair Apple translates (or iOS older than 18).
        case unsupported
    }
    enum Direction { case toMine, toTheirs }

    private(set) var status = Status.checking
    private(set) var downloading = false

    private enum Job {
        case translate(id: UUID, lines: [String])
        case prepare(id: UUID)
    }
    @ObservationIgnored private var inboxes: [Direction: AsyncStream<Job>.Continuation] = [:]
    @ObservationIgnored private var generations: [Direction: Int] = [:]
    @ObservationIgnored private var waiting: [UUID: (direction: Direction, generation: Int, reply: CheckedContinuation<[String]?, Never>)] = [:]
    @ObservationIgnored private var checked: (mine: String, theirs: String)?

    /// The translation, or nil when the phone can't do it right now (the caller falls back to the Mac).
    func translate(_ text: String, _ direction: Direction) async -> String? {
        await translate(lines: [text], direction)?.first
    }

    /// Several lines at once (a photographed menu), in order.
    func translate(lines: [String], _ direction: Direction) async -> [String]? {
        guard !lines.isEmpty else { return [] }
        return await enqueue(direction) { .translate(id: $0, lines: lines) }
    }

    /// Downloads both directions of the pair (the system asks first), then checks again.
    func download() async {
        downloading = true
        defer { downloading = false }
        _ = await enqueue(.toMine) { .prepare(id: $0) }
        _ = await enqueue(.toTheirs) { .prepare(id: $0) }
        if let checked { await check(mine: checked.mine, theirs: checked.theirs, force: true) }
    }

    private func enqueue(_ direction: Direction, _ job: (UUID) -> Job) async -> [String]? {
        guard let inbox = inboxes[direction] else { return nil }
        let id = UUID()
        return await withCheckedContinuation { reply in
            waiting[id] = (direction, generations[direction] ?? 0, reply)
            inbox.yield(job(id))
        }
    }

    private func finish(_ id: UUID, _ result: [String]?) {
        waiting.removeValue(forKey: id)?.reply.resume(returning: result)
    }

    func check(mine: String, theirs: String, force: Bool = false) async {
        guard force || checked?.mine != mine || checked?.theirs != theirs else { return }
        checked = (mine, theirs)
        guard #available(iOS 18.0, macCatalyst 26.0, *), mine != theirs else { status = .unsupported; return }
        status = .checking
        let availability = LanguageAvailability()
        let there = await availability.status(from: Self.language(theirs), to: Self.language(mine))
        let back = await availability.status(from: Self.language(mine), to: Self.language(theirs))
        guard checked?.mine == mine, checked?.theirs == theirs else { return }
        if there == .unsupported || back == .unsupported { status = .unsupported }
        else if there == .installed && back == .installed { status = .ready }
        else { status = .downloadable }
    }

    /// Runs one direction's session for as long as SwiftUI keeps it (until the languages change).
    @available(iOS 18.0, macCatalyst 26.0, *)
    fileprivate func serve(_ session: TranslationSession, _ direction: Direction) async {
        let (stream, inbox) = AsyncStream.makeStream(of: Job.self)
        let generation = (generations[direction] ?? 0) + 1
        generations[direction] = generation
        inboxes[direction]?.finish()
        inboxes[direction] = inbox
        for await job in stream {
            switch job {
            case .translate(let id, let lines):
                if lines.count == 1 {
                    finish(id, (try? await session.translate(lines[0])).map { [$0.targetText] })
                } else {
                    let requests = lines.enumerated().map { TranslationSession.Request(sourceText: $1, clientIdentifier: String($0)) }
                    let responses = (try? await session.translations(from: requests)) ?? []
                    var out = lines
                    for response in responses {
                        if let index = response.clientIdentifier.flatMap(Int.init), out.indices.contains(index) { out[index] = response.targetText }
                    }
                    finish(id, responses.isEmpty ? nil : out)
                }
            case .prepare(let id):
                try? await session.prepareTranslation()
                finish(id, [])
            }
        }
        // The session is gone: whatever it didn't get to goes back unanswered.
        if generations[direction] == generation { inboxes[direction] = nil }
        for (id, entry) in waiting where entry.direction == direction && entry.generation == generation { finish(id, nil) }
    }

    /// "zh-TW" is written in traditional characters; everything else maps by its language code.
    static func language(_ code: String) -> Locale.Language {
        code == "zh-TW" ? Locale.Language(identifier: "zh-Hant") : Locale.Language(identifier: code)
    }

    /// A one-off translation outside any view (Siri, Shortcuts): only where the OS lets a session be made
    /// directly and the languages are already on the phone. Nil sends the caller to the Mac.
    static func translateNow(_ text: String, into target: String) async -> String? {
        guard #available(iOS 26.0, macCatalyst 26.0, *) else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let detected = recognizer.dominantLanguage?.rawValue else { return nil }
        let source = Locale.Language(identifier: detected), destination = language(target)
        guard source.languageCode != destination.languageCode,
              await LanguageAvailability().status(from: source, to: destination) == .installed else { return nil }
        return try? await TranslationSession(installedSource: source, target: destination).translate(text).targetText
    }

    // MARK: reading photos

    /// A line of text found in a camera frame; `box` is Vision's (normalized, origin bottom-left).
    struct FoundLine: Equatable {
        var text: String
        var box: CGRect
    }

    /// The text in a live camera frame, with where each line sits. `orientation` is how the frame is turned.
    nonisolated static func findText(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, language: String) -> [FoundLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let wanted = visionLanguage(language)
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        request.recognitionLanguages = supported.contains(wanted) ? [wanted, "en-US"] : ["en-US"]
        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence > 0.3 else { return nil }
            return FoundLine(text: candidate.string, box: observation.boundingBox)
        }
    }

    nonisolated static func visionLanguage(_ code: String) -> String {
        code == "zh-CN" ? "zh-Hans" : (code == "zh-TW" ? "zh-Hant" : code)
    }

    /// The lines of text in a photo, top to bottom, read on the phone.
    nonisolated static func readText(in image: UIImage, language: String) async -> [String] {
        guard let cgImage = image.cgImage else { return [] }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        let visionLanguage = visionLanguage(language)
        return await withCheckedContinuation { reply in
            DispatchQueue.global(qos: .userInitiated).async {
                func read(_ languages: [String]?) -> [String] {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    if let languages { request.recognitionLanguages = languages }
                    try? VNImageRequestHandler(cgImage: cgImage, orientation: orientation).perform([request])
                    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                }
                // A language Vision doesn't read fails the request: try again with its defaults.
                let lines = read([visionLanguage, "en-US"])
                reply.resume(returning: lines.isEmpty ? read(nil) : lines)
            }
        }
    }
}

extension View {
    /// Keeps the on-device sessions for the pair alive while this view is on screen.
    @ViewBuilder
    func fastTranslator(_ translator: FastTranslator, mine: String, theirs: String) -> some View {
        if #available(iOS 18.0, macCatalyst 26.0, *) {
            modifier(FastTranslatorSessions(translator: translator, mine: mine, theirs: theirs))
        } else {
            task(id: mine + theirs) { await translator.check(mine: mine, theirs: theirs) }
        }
    }
}

@available(iOS 18.0, macCatalyst 26.0, *)
private struct FastTranslatorSessions: ViewModifier {
    let translator: FastTranslator
    let mine: String
    let theirs: String

    func body(content: Content) -> some View {
        content
            .translationTask(configuration(from: theirs, to: mine)) { session in await translator.serve(session, .toMine) }
            .translationTask(configuration(from: mine, to: theirs)) { session in await translator.serve(session, .toTheirs) }
            .task(id: mine + theirs) { await translator.check(mine: mine, theirs: theirs) }
    }

    /// The low-latency models where the OS has them: speed is the point here, the Mac is there for nuance.
    private func configuration(from source: String, to target: String) -> TranslationSession.Configuration {
        if #available(iOS 26.4, macCatalyst 26.4, *) {
            return .init(source: FastTranslator.language(source), target: FastTranslator.language(target), preferredStrategy: .lowLatency)
        }
        return .init(source: FastTranslator.language(source), target: FastTranslator.language(target))
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
