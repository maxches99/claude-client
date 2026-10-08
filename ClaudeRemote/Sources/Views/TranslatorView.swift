import SwiftUI
import PhotosUI
import ClaudeRemoteCore

/// A language for the translator: what the recognizer listens for and what the agent writes.
struct TranslatorLanguage: Hashable, Identifiable {
    let code: String
    let name: String
    var id: String { code }

    static let all: [TranslatorLanguage] = [
        .init(code: "ja-JP", name: "Japanese"), .init(code: "zh-CN", name: "Chinese"), .init(code: "zh-TW", name: "Chinese (Taiwan)"),
        .init(code: "ko-KR", name: "Korean"), .init(code: "th-TH", name: "Thai"), .init(code: "vi-VN", name: "Vietnamese"),
        .init(code: "id-ID", name: "Indonesian"), .init(code: "hi-IN", name: "Hindi"), .init(code: "tr-TR", name: "Turkish"),
        .init(code: "ar-SA", name: "Arabic"), .init(code: "he-IL", name: "Hebrew"), .init(code: "ka-GE", name: "Georgian"),
        .init(code: "en-US", name: "English"), .init(code: "es-ES", name: "Spanish"), .init(code: "fr-FR", name: "French"),
        .init(code: "de-DE", name: "German"), .init(code: "it-IT", name: "Italian"), .init(code: "pt-PT", name: "Portuguese"),
        .init(code: "el-GR", name: "Greek"), .init(code: "ru-RU", name: "Russian"), .init(code: "uk-UA", name: "Ukrainian"),
    ]

    static func named(_ code: String) -> TranslatorLanguage { all.first { $0.code == code } ?? .init(code: code, name: code) }

    /// The code for a language given by name, in English or the phone's language ("Russian", "русский"), or a code itself.
    static func code(named name: String) -> String? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        return all.first { language in
            let base = String(language.code.prefix(2))
            return language.name.lowercased() == wanted || language.code.lowercased() == wanted || base == wanted
                || Locale.current.localizedString(forLanguageCode: base)?.lowercased() == wanted
                || Locale(identifier: base).localizedString(forLanguageCode: base)?.lowercased() == wanted
        }?.code
    }
}

/// One exchange: what was seen or heard, and its translation.
struct TranslationCard: Identifiable, Equatable {
    enum Kind { case photo, heard, said }
    let id = UUID()
    let kind: Kind
    var original: String
    var image: UIImage?
    var translation: String?
    /// How many agent replies the chat had when this was sent; the next one is this card's. Nil while the
    /// phone translates it itself.
    var repliesBefore: Int?
    /// The phone's own translation, kept on screen while the Mac writes a better one.
    var quick: String?
    var onDevice = false
    /// Which way it goes, and so which voice reads it.
    var target: String
    /// For a photographed menu: what the dishes are, from the Mac.
    var explanation: String?
    var explaining = false
}

/// Where translations come from: the phone's own models (instant, offline), or the Mac / hub (smarter, slower).
enum TranslatorEngine: String, CaseIterable, Identifiable {
    case auto, phone, mac
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Fastest available"
        case .phone: "On this phone"
        case .mac: "Mac or hub"
        }
    }
}

/// Travel translator on the Mac or the hub: a photo of a sign or menu, their speech heard live, or yours
/// spoken back in their language. Runs in a quick tool-less chat, so it costs a chat's worth.
struct TranslatorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ccremote.translator.theirs") private var theirsCode = "ja-JP"
    @AppStorage("ccremote.translator.mine") private var mineCode = "ru-RU"
    @State private var chatId: String?
    @State private var cards: [TranslationCard] = []
    @State private var dictation = Dictation()
    @State private var listening: TranslationCard.Kind?
    @State private var pauseTask: Task<Void, Never>?
    @State private var showCamera = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var showLibrary = false
    @State private var speakTranslations = true
    @State private var starting = false
    /// The warm-up turn sent on open (the first turn of a chat pays the CLI's start-up), until it answers.
    @State private var warming = false
    @State private var mode = Mode.talk
    @AppStorage("ccremote.translator.engine") private var engine = TranslatorEngine.auto
    @State private var fast = FastTranslator()
    /// The phone's running translation of what the recognizer has heard so far.
    @State private var liveTranslation: String?
    @State private var liveTask: Task<Void, Never>?
    @AppStorage("ccremote.translator.tone") private var tone = TranslatorTone.neutral
    /// What you can't or won't eat, for explaining menus.
    @AppStorage("ccremote.translator.food") private var foodNotes = ""
    /// Face to face: once a phrase is translated and read out, the other side's microphone opens.
    @AppStorage("ccremote.translator.turns") private var autoTurns = true
    @State private var nextTurn: TranslationCard.Kind?
    @State private var showLiveCamera = false
    @State private var showTrip = false
    @State private var editingFood = false
    @State private var foodDraft = ""

    enum Mode: String, CaseIterable, Identifiable {
        case talk, face, phrases, receipt
        var id: String { rawValue }
        var label: String {
            switch self {
            case .talk: "Talk"
            case .face: "Face to face"
            case .phrases: "Phrases"
            case .receipt: "Receipt"
            }
        }
    }

    private var theirs: TranslatorLanguage { .named(theirsCode) }
    /// The phone translates itself when it has the pair downloaded (and wasn't told to leave it to the Mac).
    private var onDevice: Bool { engine != .mac && fast.status == .ready }
    private var mine: TranslatorLanguage { .named(mineCode) }
    private var replies: [String] {
        guard let chatId, let transcript = model.transcripts[chatId] else { return [] }
        return transcript.items.compactMap { item in
            if case .assistantText(let text, false) = item.kind { return text } else { return nil }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                languageBar
                Picker("Mode", selection: $mode) { ForEach(Mode.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).padding(.horizontal, CDS.gutter).padding(.bottom, 6)
                switch mode {
                case .phrases: PhrasebookView(mine: mine, theirs: theirs)
                case .receipt: ReceiptView(mine: mine)
                case .talk: talk
                case .face:
                    FaceToFaceView(cards: cards, mine: mine, theirs: theirs, listening: listening, partial: dictation.text,
                                   livePartial: liveTranslation, autoTurns: $autoTurns, toggle: toggle)
                        .disabled((!model.isConnected && !onDevice) || starting)
                }
            }
            .background(CDS.surface0)
            .fastTranslator(fast, mine: mineCode, theirs: theirsCode)
            .navigationTitle("Translator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { stopListening(); dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Translate with", selection: $engine) { ForEach(TranslatorEngine.allCases) { Text($0.label).tag($0) } }
                        Picker("When you speak", selection: $tone) { ForEach(TranslatorTone.allCases) { Text($0.label).tag($0) } }
                        Button("Food notes…", systemImage: "fork.knife") { foodDraft = foodNotes; editingFood = true }
                        Button("Trip log", systemImage: "book.pages") { showTrip = true }
                    } label: {
                        Image(systemName: onDevice ? "bolt.fill" : "desktopcomputer")
                    }
                    .accessibilityLabel("Translator settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Toggle(isOn: $speakTranslations) { Image(systemName: speakTranslations ? "speaker.wave.2.fill" : "speaker.slash") }
                        .toggleStyle(.button)
                        .accessibilityLabel("Read translations aloud")
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in send(photo: image) }.ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $showLiveCamera) { LiveCameraTranslateView(fast: fast, theirs: theirs, mine: mine) }
            .sheet(isPresented: $showTrip) { TripLogView(mine: mine, theirs: theirs) }
            .alert("Food notes", isPresented: $editingFood) {
                TextField("No pork, allergic to peanuts…", text: $foodDraft)
                Button("Save") { foodNotes = foodDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Menus are explained with these in mind.")
            }
            // Not a PhotosPicker inside the Menu: from there it never opens.
            .photosPicker(isPresented: $showLibrary, selection: $pickerItem, matching: .images)
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) { send(photo: image) }
                    pickerItem = nil
                }
            }
            .onChange(of: replies.count) { _, _ in matchReplies() }
            .onChange(of: dictation.text) { _, text in armPause(text); translateLive(text) }
            .onChange(of: dictation.isListening) { was, now in
                // The recognizer stopped by itself (a long silence): send what it heard, keep going.
                if was, !now, let kind = listening { flushSpeech(kind, restart: true) }
            }
        }
        .onDisappear { stopListening() }
        // The Mac chat is only warmed up when it's going to be used.
        .task(id: fast.status) { if fast.status != .checking && !onDevice { await warmUp() } }
    }

    /// Live translation: what the camera saw, what they said, what you said.
    private var talk: some View {
        VStack(spacing: 0) {
            ScrollView {
                    LazyVStack(spacing: 10) {
                        if engine != .mac { downloadBanner }
                        if listening != nil, !dictation.text.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(dictation.text).font(CDS.prose).foregroundStyle(CDS.textSecondary)
                                if let liveTranslation { Text(liveTranslation).font(.title3).foregroundStyle(CDS.textPrimary) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12).background(CDS.surface2, in: RoundedRectangle(cornerRadius: CDS.radius))
                        }
                        ForEach(cards.reversed()) { card in cardView(card) }
                        if cards.isEmpty && listening == nil {
                            Text("Point the camera at a sign or a menu, or let the phone listen — the translation comes from your Mac or hub.")
                                .font(CDS.body).foregroundStyle(CDS.textMuted).multilineTextAlignment(.center).padding(.top, 40)
                        }
                    }
                    .padding(CDS.gutter)
                }
            controls
        }
    }

    // MARK: pieces

    /// Offers the pair's on-device models, or says why the Mac does the work.
    @ViewBuilder
    private var downloadBanner: some View {
        switch fast.status {
        case .downloadable:
            Button { Task { await fast.download() } } label: {
                HStack(spacing: 10) {
                    Image(systemName: fast.downloading ? "arrow.down.circle.dotted" : "bolt.fill").foregroundStyle(CDS.brand)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Download \(theirs.name) ↔ \(mine.name)").font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary)
                        Text("Instant translations on the phone, even with no connection.").font(CDS.caption).foregroundStyle(CDS.textMuted)
                    }
                    Spacer()
                }
                .padding(12).background(CDS.surface2, in: RoundedRectangle(cornerRadius: CDS.radius))
            }
            .buttonStyle(.plain)
            .disabled(fast.downloading)
        case .unsupported where engine == .phone:
            Text("The phone can't translate \(theirs.name) ↔ \(mine.name) itself — your Mac or hub does it.")
                .font(CDS.caption).foregroundStyle(CDS.textMuted).frame(maxWidth: .infinity, alignment: .leading)
        default:
            EmptyView()
        }
    }

    private var languageBar: some View {
        HStack(spacing: 8) {
            Menu { languagePicker($theirsCode) } label: { langChip(theirs.name, caption: "They speak") }
            Button { swap(&theirsCode, &mineCode) } label: { Image(systemName: "arrow.left.arrow.right") }
                .foregroundStyle(CDS.textSecondary)
            Menu { languagePicker($mineCode) } label: { langChip(mine.name, caption: "You read") }
        }
        .padding(.horizontal, CDS.gutter).padding(.vertical, 8)
    }

    private func languagePicker(_ binding: Binding<String>) -> some View {
        Picker("Language", selection: binding) {
            ForEach(TranslatorLanguage.all) { Text($0.name).tag($0.code) }
        }
    }

    private func langChip(_ name: String, caption: String) -> some View {
        VStack(spacing: 1) {
            Text(caption).font(.caption2).foregroundStyle(CDS.textMuted)
            Text(name).font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(CDS.surface2, in: RoundedRectangle(cornerRadius: CDS.radius))
    }

    private func cardView(_ card: TranslationCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: card.kind == .photo ? "camera" : (card.kind == .heard ? "ear" : "mouth"))
                Text(card.kind == .said ? "You said" : (card.kind == .heard ? "They said" : "Photo"))
            }
            .font(CDS.caption).foregroundStyle(CDS.textMuted)
            if let image = card.image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 160)
                    .clipShape(RoundedRectangle(cornerRadius: CDS.radius))
            }
            if !card.original.isEmpty { Text(card.original).font(CDS.body).foregroundStyle(CDS.textSecondary) }
            if let translation = card.translation {
                Group {
                    // The phone's lines are plain text: markdown would fold a menu's lines into one.
                    if card.onDevice { Text(translation) } else { MarkdownText(text: translation) }
                }
                .font(.title3)
                .onTapGesture { model.narrator.speak(translation, language: card.target) }
                if card.kind == .said, let reading = Transliteration.reading(translation, language: card.target) {
                    Text(reading).font(CDS.caption).foregroundStyle(CDS.textMuted)
                }
                if let explanation = card.explanation { MarkdownText(text: explanation).font(CDS.body) }
                cardActions(card)
            } else {
                if let quick = card.quick { Text(quick).font(.title3).foregroundStyle(CDS.textMuted) }
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(card.quick == nil ? "Translating…" : "Getting a better one…").font(CDS.caption).foregroundStyle(CDS.textMuted) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(card.kind == .said ? CDS.brand.opacity(0.08) : CDS.surface2, in: RoundedRectangle(cornerRadius: CDS.radius))
    }

    /// A better translation from the host, the dishes on a menu, a phrase kept for the phrasebook.
    private func cardActions(_ card: TranslationCard) -> some View {
        HStack(spacing: 14) {
            if card.onDevice, model.isConnected {
                Button { refine(card) } label: { Label("Better translation", systemImage: "sparkles") }
            }
            if card.kind == .photo, card.explanation == nil, model.isConnected {
                Button { explain(card) } label: {
                    if card.explaining { ProgressView().controlSize(.small) } else { Label("What are these dishes?", systemImage: "fork.knife") }
                }
                .disabled(card.explaining)
            }
            if card.kind == .said, let translation = card.translation {
                let saved = PersonalPhrases.contains(card.original, mine: mine.code, theirs: theirs.code)
                Button {
                    if !saved { PersonalPhrases.add(mine: card.original, theirs: translation, mine: mine.code, theirs: theirs.code) }
                    update(card.id) { _ in }   // redraw the star
                } label: { Image(systemName: saved ? "star.fill" : "star") }
                .accessibilityLabel(saved ? "In your phrasebook" : "Keep in the phrasebook")
            }
        }
        .font(CDS.caption).foregroundStyle(CDS.textMuted).buttonStyle(.plain)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Menu {
                Button("Live camera", systemImage: "text.viewfinder") { showLiveCamera = true }.disabled(!onDevice)
                Button("Take a photo", systemImage: "camera") { showCamera = true }
                Button("From the library", systemImage: "photo") { showLibrary = true }
            } label: {
                bigButton("camera.fill", "Photo", active: false)
            }
            Button { toggle(.heard) } label: { bigButton(listening == .heard ? "stop.fill" : "ear", listening == .heard ? "Stop" : "Listen", active: listening == .heard) }
            Button { toggle(.said) } label: { bigButton(listening == .said ? "stop.fill" : "mic.fill", listening == .said ? "Stop" : "Speak", active: listening == .said) }
        }
        .padding(CDS.gutter)
        .disabled((!model.isConnected && !onDevice) || starting)
    }

    private func bigButton(_ symbol: String, _ label: String, active: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 22, weight: .semibold))
            Text(label).font(CDS.caption)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 12)
        .foregroundStyle(active ? Color.white : CDS.textPrimary)
        .background(active ? CDS.brand : CDS.surface2, in: RoundedRectangle(cornerRadius: CDS.radiusComposer))
    }

    // MARK: talking to the host

    /// The chat on the host, started on first use: Haiku for speed, or Codex at low effort.
    private func ensureChat() async -> String? {
        if let chatId { return chatId }
        starting = true
        defer { starting = false }
        let agent = model.defaultAgent
        chatId = await model.createQuietly(.chat(agent: agent, model: agent == .claude ? "claude-haiku-4-5" : nil, effort: agent == .codex ? "low" : nil))
        return chatId
    }

    private func send(photo: UIImage) {
        Task {
            if onDevice {
                // Read and translate on the phone; the Mac is a tap away for what the lines mean.
                let card = TranslationCard(kind: .photo, original: "", image: photo, onDevice: true, target: mine.code)
                cards.append(card)
                let lines = await FastTranslator.readText(in: photo, language: theirs.code)
                if !lines.isEmpty, let translated = await fast.translate(lines: lines, .toMine) {
                    update(card.id) { $0.original = lines.joined(separator: "\n"); $0.translation = translated.joined(separator: "\n") }
                    completed(card.id)
                    return
                }
                cards.removeAll { $0.id == card.id }
                guard model.isConnected else { return }
            }
            guard let chat = await ensureChat(), let jpeg = photo.jpegData(compressionQuality: 0.8) else { return }
            let card = TranslationCard(kind: .photo, original: "", image: photo, repliesBefore: replies.count + pendingCount, target: mine.code)
            cards.append(card)
            model.prompt(chat, text: photoPrompt, images: [InlineImage(mediaType: "image/jpeg", base64: jpeg.base64EncodedString())])
        }
    }

    private var photoPrompt: String {
        "Translate everything written in this photo into \(mine.name). Reply in \(mine.name) only: the translation, line by line as laid out in the photo, then one short line in italics saying what it is (a menu, a sign, a label…). No headings, no original text."
    }

    private func textPrompt(_ text: String, kind: TranslationCard.Kind) -> String {
        let target = kind == .said ? theirs.name : mine.name
        let register = kind == .said ? tone.instruction.map { " " + $0 } ?? "" : ""
        return "Translate into \(target). Reply with the translation only\(kind == .said ? ", written in \(target)'s own script" : "").\(register)\n\n\(text)"
    }

    /// What the dishes on a photographed menu are, with your food notes in mind — asked in a chat of its own.
    private func explain(_ card: TranslationCard) {
        guard let jpeg = card.image?.jpegData(compressionQuality: 0.8) else { return }
        update(card.id) { $0.explaining = true }
        let notes = foodNotes.isEmpty ? "" : " Keep in mind: \(foodNotes). Warn clearly about any dish that doesn't fit that."
        let prompt = "This is a menu. In \(mine.name), for each dish: its name as written, what it is in a few words, how spicy it is, and the usual allergens (nuts, gluten, dairy, seafood, egg, pork).\(notes) Short lines, no preamble."
        Task {
            let agent = model.defaultAgent
            let reply = try? await model.askChat(prompt, agent: agent, model: agent == .claude ? "claude-haiku-4-5" : nil,
                                                 images: [InlineImage(mediaType: "image/jpeg", base64: jpeg.base64EncodedString())], timeout: 90)
            update(card.id) { $0.explaining = false; $0.explanation = reply ?? "Couldn't get an answer — try again." }
        }
    }

    /// Hands a card the phone translated to the Mac, which knows idioms, dishes and politeness better.
    private func refine(_ card: TranslationCard) {
        Task {
            guard let chat = await ensureChat() else { return }
            let before = replies.count + pendingCount
            update(card.id) { $0.quick = $0.translation; $0.translation = nil; $0.onDevice = false; $0.repliesBefore = before }
            if card.kind == .photo, let jpeg = card.image?.jpegData(compressionQuality: 0.8) {
                model.prompt(chat, text: photoPrompt, images: [InlineImage(mediaType: "image/jpeg", base64: jpeg.base64EncodedString())])
            } else {
                model.prompt(chat, text: textPrompt(card.original, kind: card.kind))
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout TranslationCard) -> Void) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        change(&cards[index])
    }

    private func speakIfWanted(_ card: TranslationCard) {
        // Their language out loud for them; yours only when you were listening.
        guard speakTranslations, card.kind != .photo, let translation = card.translation else { return }
        model.narrator.speak(translation, language: card.target)
    }

    /// A card has its translation: read it out, log it for the trip, keep a phrase you say often, pass the turn.
    private func completed(_ id: UUID, speak: Bool = true) {
        guard let card = cards.first(where: { $0.id == id }), let translation = card.translation else { return }
        if speak { speakIfWanted(card) }
        let kind: TripEntry.Kind = card.kind == .said ? .said : (card.kind == .heard ? .heard : .photo)
        TripLog.record(TripEntry(id: card.id, date: Date(), kind: kind, original: card.original, translation: translation,
                                 theirs: theirs.code, mine: mine.code))
        // Said twice (or more): it goes into your phrasebook.
        if card.kind == .said, TripLog.timesSaid(card.original, theirs: theirs.code) >= 2 {
            PersonalPhrases.add(mine: card.original, theirs: translation, mine: mine.code, theirs: theirs.code)
        }
        if speak { passTurn() }
    }

    /// Face to face with turns on: the other side's microphone opens once the phone has finished talking.
    private func passTurn() {
        guard let next = nextTurn else { return }
        Task {
            while model.narrator.isSpeaking { try? await Task.sleep(nanoseconds: 200_000_000) }
            guard nextTurn == next, mode == .face, listening == nil else { return }
            nextTurn = nil
            toggle(next)
        }
    }

    private func send(text: String, kind: TranslationCard.Kind) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let target = kind == .said ? theirs.code : mine.code
        Task {
            if onDevice {
                let card = TranslationCard(kind: kind, original: trimmed, onDevice: true, target: target)
                cards.append(card)
                if let translated = await fast.translate(trimmed, kind == .said ? .toTheirs : .toMine) {
                    update(card.id) { $0.translation = translated }
                    // A register to keep: the phone's version shows at once, the host's is the one read out.
                    let mind = kind == .said && tone != .neutral && model.isConnected
                    completed(card.id, speak: !mind)
                    if mind, let done = cards.first(where: { $0.id == card.id }) { refine(done) }
                    return
                }
                cards.removeAll { $0.id == card.id }
                guard model.isConnected else { return }
            }
            guard let chat = await ensureChat() else { return }
            cards.append(TranslationCard(kind: kind, original: trimmed, repliesBefore: replies.count + pendingCount, target: target))
            model.prompt(chat, text: textPrompt(trimmed, kind: kind))
        }
    }

    /// Cards the Mac still owes a reply (plus the warm-up), to know which reply is whose.
    private var pendingCount: Int { cards.filter { $0.repliesBefore != nil && $0.translation == nil }.count + (warming ? 1 : 0) }

    /// Opens the chat and has it say OK, so the first real phrase comes back in a couple of seconds.
    private func warmUp() async {
        guard chatId == nil, model.isConnected, let chat = await ensureChat() else { return }
        warming = true
        model.prompt(chat, text: "Reply with just OK.")
    }

    /// Hands the chat's new replies to the cards waiting for them, oldest first.
    private func matchReplies() {
        let all = replies
        if warming, !all.isEmpty { warming = false }
        for i in cards.indices where cards[i].translation == nil {
            guard let index = cards[i].repliesBefore, all.indices.contains(index) else { continue }
            cards[i].translation = all[index]
            cards[i].quick = nil
            completed(cards[i].id)
        }
    }

    // MARK: listening

    private func toggle(_ kind: TranslationCard.Kind) {
        nextTurn = nil
        if listening == kind { flushSpeech(kind, restart: false); stopListening(); return }
        stopListening()
        listening = kind
        dictation.locale = Locale(identifier: kind == .heard ? theirs.code : mine.code)
        Task { if await !dictation.start() { listening = nil } }
    }

    /// Subtitles while they talk: the phone translates the unfinished phrase every few words.
    private func translateLive(_ text: String) {
        liveTask?.cancel()
        guard onDevice, let kind = listening, !text.isEmpty else { liveTranslation = nil; return }
        liveTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, let translated = await fast.translate(text, kind == .said ? .toTheirs : .toMine),
                  !Task.isCancelled, listening == kind else { return }
            liveTranslation = translated
        }
    }

    private func stopListening() {
        liveTask?.cancel()
        liveTranslation = nil
        pauseTask?.cancel()
        listening = nil
        if dictation.isListening { dictation.cancel() }
    }

    /// A pause of a second and a half ends a phrase: it goes off to be translated while listening goes on.
    private func armPause(_ text: String) {
        pauseTask?.cancel()
        guard let kind = listening, !text.isEmpty else { return }
        pauseTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, listening == kind else { return }
            flushSpeech(kind, restart: true)
        }
    }

    private func flushSpeech(_ kind: TranslationCard.Kind, restart: Bool) {
        let heard = dictation.text
        liveTask?.cancel()
        liveTranslation = nil
        if dictation.isListening { dictation.cancel() }
        let said = !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        send(text: heard, kind: kind)
        // Face to face: the phrase ended, so it's the other side's turn once it's been read out.
        if restart, said, mode == .face, autoTurns, listening == kind {
            stopListening()
            nextTurn = kind == .heard ? .said : .heard
            return
        }
        guard restart, listening == kind else { return }
        Task { if await !dictation.start() { listening = nil } }
    }
}
