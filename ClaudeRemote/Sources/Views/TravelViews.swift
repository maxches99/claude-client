import SwiftUI
import PhotosUI
import ClaudeRemoteCore

/// Phrasebooks kept on the phone, one per language pair, so they work with no connection at all.
enum PhrasebookStore {
    private static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("phrasebooks")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func file(mine: String, theirs: String) -> URL { directory.appendingPathComponent("\(mine)_\(theirs).json") }

    static func load(mine: String, theirs: String) -> Phrasebook? {
        guard let data = try? Data(contentsOf: file(mine: mine, theirs: theirs)) else { return nil }
        return try? ProtocolCoding.decoder.decode(Phrasebook.self, from: data)
    }

    static func save(_ book: Phrasebook, mine: String, theirs: String) {
        guard let data = try? ProtocolCoding.encoder.encode(book) else { return }
        try? data.write(to: file(mine: mine, theirs: theirs), options: .atomic)
    }
}

// MARK: - Phrasebook

/// Situations with ready phrases; tap one to show it big and hear it in their language. Made once on the
/// Mac or hub ("Prepare for the trip"), then kept on the phone for offline use.
struct PhrasebookView: View {
    @Environment(AppModel.self) private var model
    let mine: TranslatorLanguage
    let theirs: TranslatorLanguage
    @State private var book: Phrasebook?
    @State private var preparing = false
    @State private var error: String?
    @State private var shown: PhraseSection.Phrase?
    @State private var query = ""
    /// Phrases you said more than once in the translator, or starred there.
    @State private var yours: [PhraseSection.Phrase] = []

    var body: some View {
        List {
            let own = filtered(yours)
            if !own.isEmpty {
                Section {
                    ForEach(own) { phrase in
                        Button { show(phrase) } label: { phraseRow(phrase) }
                    }
                    .onDelete { offsets in
                        for phrase in offsets.map({ own[$0] }) { PersonalPhrases.remove(phrase, mine: mine.code, theirs: theirs.code) }
                        reload()
                    }
                } header: {
                    Text("Yours")
                } footer: {
                    Text("What you said twice in Talk, or starred there.")
                }
            }
            if let book {
                ForEach(book.sections) { section in
                    let phrases = filtered(section.phrases)
                    if !phrases.isEmpty {
                        Section(section.situation) {
                            ForEach(phrases) { phrase in
                                Button { show(phrase) } label: { phraseRow(phrase) }
                            }
                        }
                    }
                }
                Section {
                    Text("Kept on this phone — works offline. Made \(book.createdAt.formatted(date: .abbreviated, time: .omitted)).")
                        .font(CDS.caption).foregroundStyle(CDS.textMuted)
                    Button("Make it again", systemImage: "arrow.clockwise") { Task { await prepare() } }.disabled(preparing || !model.isConnected)
                }
            } else {
                Section {
                    Text("A phrasebook for \(theirs.name): greetings, restaurant, shop, taxi, hotel, directions, pharmacy, emergency, money, small talk. Your Mac or hub writes it once; it then stays on the phone and works with no connection.")
                        .font(CDS.body).foregroundStyle(CDS.textSecondary)
                    Button {
                        Task { await prepare() }
                    } label: {
                        HStack {
                            Label(preparing ? "Writing it…" : "Prepare for the trip", systemImage: "suitcase")
                            if preparing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(preparing || !model.isConnected)
                    if let error { Text(error).font(CDS.caption).foregroundStyle(CDS.danger) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(CDS.surface0)
        .searchable(text: $query, prompt: "Find a phrase")
        .onAppear { reload() }
        .onChange(of: theirs) { _, _ in reload() }
        .onChange(of: mine) { _, _ in reload() }
        .fullScreenCover(item: $shown) { phrase in PhraseCard(phrase: phrase, language: theirs.code) }
    }

    private func reload() {
        book = PhrasebookStore.load(mine: mine.code, theirs: theirs.code)
        yours = PersonalPhrases.load(mine: mine.code, theirs: theirs.code)
    }

    private func phraseRow(_ phrase: PhraseSection.Phrase) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(phrase.mine).font(CDS.body).foregroundStyle(CDS.textPrimary)
            Text(phrase.theirs).font(CDS.bodyMedium).foregroundStyle(CDS.brand)
            if let reading = phrase.reading { Text(reading).font(CDS.caption).foregroundStyle(CDS.textMuted) }
        }
    }

    private func filtered(_ phrases: [PhraseSection.Phrase]) -> [PhraseSection.Phrase] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return phrases }
        return phrases.filter { $0.mine.lowercased().contains(q) || $0.theirs.lowercased().contains(q) || ($0.reading?.lowercased().contains(q) ?? false) }
    }

    private func show(_ phrase: PhraseSection.Phrase) {
        shown = phrase
        model.narrator.speak(phrase.theirs, language: theirs.code)
    }

    private func prepare() async {
        preparing = true
        error = nil
        defer { preparing = false }
        do {
            let agent = model.defaultAgent
            let reply = try await model.askChat(Phrasebook.prompt(mine: mine.name, theirs: theirs.name), agent: agent,
                                                model: agent == .claude ? "claude-sonnet-5-5" : nil, timeout: 240)
            guard let made = Phrasebook.parse(reply, mine: mine.code, theirs: theirs.code) else {
                error = "The phrasebook did not come back readable — try again."
                return
            }
            PhrasebookStore.save(made, mine: mine.code, theirs: theirs.code)
            book = made
        } catch {
            self.error = "It took too long or the connection dropped — try again."
        }
    }
}

/// One phrase, big, to show the person you're talking to; tap to hear it again.
struct PhraseCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let phrase: PhraseSection.Phrase
    let language: String

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.title3.weight(.semibold)) }
                    .foregroundStyle(CDS.textSecondary)
            }
            Spacer()
            Text(phrase.theirs).font(.system(size: 44, weight: .semibold)).multilineTextAlignment(.center).minimumScaleFactor(0.4)
                .foregroundStyle(CDS.textPrimary)
            if let reading = phrase.reading { Text(reading).font(.title3).foregroundStyle(CDS.textSecondary).multilineTextAlignment(.center) }
            Text(phrase.mine).font(CDS.body).foregroundStyle(CDS.textMuted).multilineTextAlignment(.center)
            Spacer()
            Button { model.narrator.speak(phrase.theirs, language: language) } label: {
                Label("Say it again", systemImage: "speaker.wave.2.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(CDSButtonStyle(variant: .primary, fullWidth: true))
        }
        .padding(24)
        .background(CDS.surface0)
    }
}

// MARK: - Receipts

/// A photo of a receipt or bill: its lines translated, converted to your currency, and split between people.
struct ReceiptView: View {
    @Environment(AppModel.self) private var model
    let mine: TranslatorLanguage
    @AppStorage("ccremote.receipt.currency") private var myCurrency = Locale.current.currency?.identifier ?? "RUB"
    @AppStorage("ccremote.receipt.people") private var peopleText = "Me"
    @State private var receipt: Receipt?
    @State private var image: UIImage?
    @State private var reading = false
    @State private var error: String?
    @State private var rate: Double?
    @State private var rateText = ""
    @State private var assignments: [String: Set<String>] = [:]
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var pickerItem: PhotosPickerItem?

    private var people: [String] {
        peopleText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    Button { showCamera = true } label: { Label("Photo", systemImage: "camera") }
                    Button { showLibrary = true } label: { Label("Library", systemImage: "photo") }
                }
                .buttonStyle(CDSButtonStyle(variant: .secondary))
                if reading { HStack { ProgressView(); Text("Reading the receipt…").foregroundStyle(CDS.textMuted) } }
                if let error { Text(error).font(CDS.caption).foregroundStyle(CDS.danger) }
            }
            if let receipt {
                Section {
                    ForEach(receipt.items) { item in itemRow(item, currency: receipt.currency) }
                    if receipt.extras != 0 { amountRow("Tax, service, discounts", receipt.extras, currency: receipt.currency) }
                    amountRow("Total", receipt.total, currency: receipt.currency).font(CDS.bodyMedium)
                } header: { Text("Receipt") } footer: {
                    if people.count > 1 { Text("Tap the names on a line to say who had it; a line nobody is marked on is shared by everyone.") }
                }
                Section("Rate") {
                    HStack {
                        Text("1 \(receipt.currency) =")
                        TextField("rate", text: $rateText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .onChange(of: rateText) { _, t in rate = Double(t.replacingOccurrences(of: ",", with: ".")) }
                        TextField("", text: $myCurrency).frame(width: 52).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    }
                }
                Section {
                    TextField("Names, separated by commas", text: $peopleText)
                    let split = receipt.split(people: people, assignments: assignments)
                    ForEach(people, id: \.self) { person in amountRow(person, split[person] ?? 0, currency: receipt.currency) }
                } header: { Text("Who pays what") }
            }
        }
        .scrollContentBackground(.hidden)
        .background(CDS.surface0)
        .fullScreenCover(isPresented: $showCamera) { CameraPicker { read($0) }.ignoresSafeArea() }
        .photosPicker(isPresented: $showLibrary, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let ui = UIImage(data: data) { read(ui) }
                pickerItem = nil
            }
        }
    }

    private func itemRow(_ item: Receipt.Item, currency: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            amountRow(item.quantity > 1 ? "\(item.name) ×\(item.quantity)" : item.name, item.price, currency: currency)
            if people.count > 1 {
                HStack(spacing: 6) {
                    ForEach(people, id: \.self) { person in
                        let on = assignments[item.id]?.contains(person) ?? false
                        Button(person) {
                            var set = assignments[item.id] ?? []
                            if on { set.remove(person) } else { set.insert(person) }
                            assignments[item.id] = set
                        }
                        .font(CDS.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(on ? CDS.brand.opacity(0.2) : CDS.fillNeutral, in: Capsule())
                        .foregroundStyle(on ? CDS.brand : CDS.textSecondary)
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func amountRow(_ title: String, _ amount: Double, currency: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(CDS.textPrimary)
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(amount.formatted(.currency(code: currency.isEmpty ? "XXX" : currency))).monospacedDigit()
                if let rate, rate > 0 {
                    Text((amount * rate).formatted(.currency(code: myCurrency))).font(CDS.caption).foregroundStyle(CDS.textMuted).monospacedDigit()
                }
            }
        }
    }

    private func read(_ photo: UIImage) {
        image = photo
        guard let jpeg = photo.jpegData(compressionQuality: 0.8) else { return }
        reading = true
        error = nil
        Task {
            defer { reading = false }
            do {
                let agent = model.defaultAgent
                let reply = try await model.askChat(Receipt.prompt(mine: mine.name), agent: agent,
                                                    model: agent == .claude ? "claude-sonnet-5-5" : nil,
                                                    images: [InlineImage(mediaType: "image/jpeg", base64: jpeg.base64EncodedString())], timeout: 120)
                guard let parsed = Receipt.parse(reply) else { error = "Couldn't read that receipt — try a straighter, closer photo."; return }
                receipt = parsed
                assignments = [:]
                await fetchRate(from: parsed.currency)
            } catch {
                self.error = "It took too long or the connection dropped — try again."
            }
        }
    }

    /// Today's rate from a free public feed (no key); editable when it is off or missing.
    private func fetchRate(from currency: String) async {
        guard !currency.isEmpty, currency != myCurrency,
              let url = URL(string: "https://open.er-api.com/v6/latest/\(currency)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONValue.parse(data), let value = json["rates"]?[myCurrency.uppercased()]?.double else {
            if currency == myCurrency { rate = 1; rateText = "1" }
            return
        }
        rate = value
        rateText = String(format: value < 1 ? "%.4f" : "%.2f", value)
    }
}
