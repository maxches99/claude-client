import SwiftUI
import AVFoundation
import ClaudeRemoteCore

// MARK: - Face to face

/// The phone flat on the table between two people: their half upside down facing them, yours facing you.
/// Each half shows the conversation in its reader's language, with its own microphone.
struct FaceToFaceView: View {
    let cards: [TranslationCard]
    let mine: TranslatorLanguage
    let theirs: TranslatorLanguage
    let listening: TranslationCard.Kind?
    let partial: String
    let livePartial: String?
    @Binding var autoTurns: Bool
    let toggle: (TranslationCard.Kind) -> Void

    var body: some View {
        VStack(spacing: 0) {
            half(for: .heard, language: theirs, tint: CDS.surface2)
                .rotationEffect(.degrees(180))
            HStack {
                Rectangle().fill(CDS.border).frame(height: 1)
                Toggle(isOn: $autoTurns) { Image(systemName: "arrow.triangle.2.circlepath") }
                    .toggleStyle(.button).controlSize(.small)
                    .accessibilityLabel("Take turns on their own")
                Rectangle().fill(CDS.border).frame(height: 1)
            }
            .padding(.horizontal, CDS.gutter)
            half(for: .said, language: mine, tint: CDS.brand.opacity(0.08))
        }
    }

    /// One reader's half: the latest exchanges in their language, newest at the bottom, and a mic.
    private func half(for kind: TranslationCard.Kind, language: TranslatorLanguage, tint: Color) -> some View {
        VStack(spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(cards.filter { $0.kind != .photo }.suffix(4)) { card in
                        // What this reader understands: the translation of the other side, their own words as said.
                        let text = card.kind == kind ? card.original : (card.translation ?? card.quick ?? "…")
                        Text(text)
                            .font(card.kind == kind ? CDS.body : .title2.weight(.semibold))
                            .foregroundStyle(card.kind == kind ? CDS.textMuted : CDS.textPrimary)
                            .frame(maxWidth: .infinity, alignment: card.kind == kind ? .trailing : .leading)
                    }
                    if listening != nil, !partial.isEmpty {
                        Text(listening == kind ? partial : (livePartial ?? "…"))
                            .font(CDS.body).foregroundStyle(CDS.textSecondary)
                            .frame(maxWidth: .infinity, alignment: listening == kind ? .trailing : .leading)
                    }
                }
                .padding(CDS.gutter)
            }
            .defaultScrollAnchor(.bottom)
            Button { toggle(kind) } label: {
                HStack(spacing: 8) {
                    Image(systemName: listening == kind ? "waveform" : "mic.fill")
                    Text(language.name)
                }
                .font(CDS.bodyMedium)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .foregroundStyle(listening == kind ? Color.white : CDS.textPrimary)
                .background(listening == kind ? CDS.brand : CDS.surface1, in: RoundedRectangle(cornerRadius: CDS.radiusComposer))
            }
            .padding(.horizontal, CDS.gutter).padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tint)
    }
}

// MARK: - Live camera

/// Point the camera at a sign: the translation sits on top of the text as it's read, on the phone.
struct LiveCameraTranslateView: View {
    @Environment(\.dismiss) private var dismiss
    let fast: FastTranslator
    let theirs: TranslatorLanguage
    let mine: TranslatorLanguage
    @State private var camera = LiveTextCamera()
    @State private var lines: [FastTranslator.FoundLine] = []
    @State private var translations: [String: String] = [:]
    @State private var frameSize = CGSize(width: 3, height: 4)
    @State private var paused = false
    @State private var denied = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if denied {
                Text("The camera is off for this app — turn it on in Settings.").foregroundStyle(.white).padding()
            } else {
                CameraPreview(session: camera.session).ignoresSafeArea()
                GeometryReader { geometry in
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        if let translation = translations[line.text] {
                            let rect = viewRect(line.box, in: geometry.size)
                            Text(translation)
                                .font(.system(size: max(11, min(rect.height * 0.8, 28)), weight: .semibold))
                                .minimumScaleFactor(0.4).lineLimit(2)
                                .foregroundStyle(.black)
                                .padding(.horizontal, 3)
                                .frame(minWidth: rect.width, minHeight: rect.height)
                                .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
                                .position(x: rect.midX, y: rect.midY)
                        }
                    }
                }
                .ignoresSafeArea()
            }
            VStack {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.title3.weight(.semibold)).padding(10) }
                        .background(.ultraThinMaterial, in: Circle())
                    Spacer()
                    Text("\(theirs.name) → \(mine.name)").font(CDS.caption).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
                Button { paused.toggle(); camera.paused = paused } label: {
                    Label(paused ? "Go on" : "Hold", systemImage: paused ? "play.fill" : "pause.fill")
                        .font(CDS.bodyMedium).padding(.horizontal, 20).padding(.vertical, 12)
                }
                .background(.ultraThinMaterial, in: Capsule())
            }
            .foregroundStyle(.white)
            .padding()
        }
        .task {
            guard await AVCaptureDevice.requestAccess(for: .video) else { denied = true; return }
            camera.language = theirs.code
            camera.onLines = { found, size in Task { await show(found, frame: size) } }
            camera.start()
        }
        .onDisappear { camera.stop() }
    }

    /// Translates the lines it hasn't seen yet (a sign held in view isn't translated twice).
    private func show(_ found: [FastTranslator.FoundLine], frame: CGSize) async {
        guard !paused else { return }
        frameSize = frame
        let fresh = Array(Set(found.map(\.text).filter { translations[$0] == nil }))
        if !fresh.isEmpty, let translated = await fast.translate(lines: fresh, .toMine) {
            for (source, target) in zip(fresh, translated) { translations[source] = target }
        }
        guard !paused else { return }
        lines = found
    }

    /// Vision's box (normalized, bottom-left origin, in the upright frame) on the aspect-filled preview.
    private func viewRect(_ box: CGRect, in view: CGSize) -> CGRect {
        let scale = max(view.width / frameSize.width, view.height / frameSize.height)
        let shown = CGSize(width: frameSize.width * scale, height: frameSize.height * scale)
        let dx = (shown.width - view.width) / 2, dy = (shown.height - view.height) / 2
        return CGRect(x: box.minX * shown.width - dx, y: (1 - box.maxY) * shown.height - dy,
                      width: box.width * shown.width, height: box.height * shown.height)
    }
}

/// The back camera feeding Vision a couple of frames a second.
final class LiveTextCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "ccremote.livetext")
    private var configured = false
    private var busy = false
    private var lastRead = Date.distantPast
    // Set on the main thread before `start`, read on the queue.
    var language = "en-US"
    var paused = false
    /// The lines found and the upright frame's size, on the main thread.
    var onLines: (([FastTranslator.FoundLine], CGSize) -> Void)?

    func start() {
        queue.async { [self] in
            if !configured { configure() }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() { queue.async { [self] in session.stopRunning() } }

    private func configure() {
        configured = true
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
        }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !busy, !paused, Date().timeIntervalSince(lastRead) > 0.4, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        busy = true
        lastRead = Date()
        // The sensor is landscape; held upright, the frame is turned right.
        let lines = FastTranslator.findText(in: pixels, orientation: .right, language: language)
        let size = CGSize(width: CVPixelBufferGetHeight(pixels), height: CVPixelBufferGetWidth(pixels))
        busy = false
        DispatchQueue.main.async { [onLines] in onLines?(lines, size) }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

// MARK: - Trip log

/// Everything translated, by day, and a summary of what matters from it (addresses, prices, what was agreed).
struct TripLogView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let mine: TranslatorLanguage
    let theirs: TranslatorLanguage
    @State private var entries: [TripEntry] = []
    @State private var summary: String?
    @State private var summarizing = false
    @State private var error: String?
    @State private var confirmClear = false

    private var days: [(day: Date, entries: [TripEntry])] {
        let calendar = Calendar.current
        return Dictionary(grouping: entries.filter { $0.theirs == theirs.code }) { calendar.startOfDay(for: $0.date) }
            .sorted { $0.key > $1.key }
            .map { ($0.key, $0.value.sorted { $0.date > $1.date }) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task { await summarize() }
                    } label: {
                        HStack {
                            Label(summarizing ? "Summing up…" : "Sum up the trip", systemImage: "list.bullet.rectangle")
                            if summarizing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(summarizing || !model.isConnected || days.isEmpty)
                    if let summary { MarkdownText(text: summary).font(CDS.body) }
                    if let error { Text(error).font(CDS.caption).foregroundStyle(CDS.danger) }
                } footer: {
                    Text("Addresses, prices, times and what was agreed, pulled out by your Mac or hub.")
                }
                ForEach(days, id: \.day) { day in
                    Section(day.day.formatted(date: .complete, time: .omitted)) {
                        ForEach(day.entries) { entry in row(entry) }
                            .onDelete { offsets in
                                TripLog.remove(Set(offsets.map { day.entries[$0].id }))
                                entries = TripLog.load()
                            }
                    }
                }
                if days.isEmpty {
                    Text("Nothing translated into \(theirs.name) yet.").font(CDS.body).foregroundStyle(CDS.textMuted)
                }
            }
            .navigationTitle("Trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Clear", role: .destructive) { confirmClear = true }.disabled(entries.isEmpty)
                }
            }
            .confirmationDialog("Forget every translation on this phone?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Forget them", role: .destructive) { TripLog.clear(); entries = [] }
            }
            .onAppear { entries = TripLog.load() }
        }
    }

    private func row(_ entry: TripEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: entry.kind == .photo ? "camera" : (entry.kind == .heard ? "ear" : "mouth"))
                Text(entry.date.formatted(date: .omitted, time: .shortened))
            }
            .font(CDS.caption).foregroundStyle(CDS.textMuted)
            if !entry.original.isEmpty { Text(entry.original).font(CDS.body).foregroundStyle(CDS.textSecondary).lineLimit(4) }
            Text(entry.translation).font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary).lineLimit(6)
        }
    }

    private func summarize() async {
        summarizing = true
        error = nil
        defer { summarizing = false }
        let chosen = days.flatMap(\.entries).sorted { $0.date < $1.date }.suffix(400)
        do {
            summary = try await model.askChat(TripLog.summaryPrompt(Array(chosen), mine: mine.name), agent: model.defaultAgent, timeout: 180)
        } catch {
            self.error = "It took too long or the connection dropped — try again."
        }
    }
}
