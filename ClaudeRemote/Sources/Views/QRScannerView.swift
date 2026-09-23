import SwiftUI
#if targetEnvironment(macCatalyst)
/// VisionKit's scanner doesn't exist on Mac Catalyst — the Mac pairs by the pasted link or the form instead.
struct QRScannerView: View {
    var accept: (String) -> Bool = { _ in true }
    var onScan: (String) -> Void
    var body: some View {
        ContentUnavailableView("No camera scanner on Mac", systemImage: "link",
                               description: Text("Use “Copy link” in the Host app's menu and paste it below, or pick the Mac from the list."))
    }
}
#else
import VisionKit

/// Camera QR scanner (VisionKit) with a viewfinder that finds the code: the corner brackets fly onto the
/// code in the frame, follow it while it's held, fill in and tick once the scan is through — then
/// `onScan` fires. Codes `accept` rejects turn the brackets red and are not reported.
/// Unavailable in the simulator (a DEBUG build shows a demo of the animation there instead).
struct QRScannerView: View {
    var accept: (String) -> Bool = { _ in true }
    var onScan: (String) -> Void
    var hint = "Point the camera at the QR code in the Host app's menu"
    var rejectedHint = "That's not a ccremote pairing code"

    @Environment(\.dismiss) private var dismiss
    @State private var tracker = ScanTracker()

    private var cameraAvailable: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if cameraAvailable {
                ScannerCamera(tracker: tracker).ignoresSafeArea()
                ScanOverlay(tracker: tracker).ignoresSafeArea()
            } else {
                #if DEBUG && targetEnvironment(simulator)
                ScanDemo(tracker: tracker).ignoresSafeArea()
                ScanOverlay(tracker: tracker).ignoresSafeArea()
                #else
                ContentUnavailableView("Camera unavailable", systemImage: "camera.fill",
                                       description: Text("Enter the token by hand instead."))
                    .environment(\.colorScheme, .dark)
                #endif
            }
            chrome
        }
        .onAppear {
            tracker.accept = accept
            tracker.onScan = onScan
            #if DEBUG && targetEnvironment(simulator)
            // The demo's code is no pairing code: let it through, and don't hand it on.
            if !cameraAvailable { tracker.accept = { _ in true }; tracker.onScan = { _ in } }
            #endif
        }
        .sensoryFeedback(.impact(weight: .light), trigger: tracker.lockCount)
        .sensoryFeedback(.success, trigger: tracker.phase) { _, new in new == .done }
        .sensoryFeedback(.error, trigger: tracker.phase) { _, new in new == .rejected }
    }

    private var chrome: some View {
        VStack {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Close")
            }
            Spacer()
            Text(tracker.phase == .rejected ? rejectedHint : hint)
                .font(CDS.bodyMedium).foregroundStyle(.white).multilineTextAlignment(.center)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: tracker.phase)
                .padding(.bottom, 24)
        }
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 16)
    }
}

// MARK: - Tracking

/// Four corners of a code on screen (top-left, top-right, bottom-right, bottom-left), animatable so the
/// viewfinder can glide from one shape to the next.
struct ScanQuad: Equatable, VectorArithmetic {
    var p: [CGPoint]

    init(_ p: [CGPoint]) { self.p = p.count == 4 ? p : Array(repeating: .zero, count: 4) }

    init(rect: CGRect) {
        self.init([CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                   CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)])
    }

    var center: CGPoint {
        CGPoint(x: p.map(\.x).reduce(0, +) / 4, y: p.map(\.y).reduce(0, +) / 4)
    }

    /// Shortest side, for sizing the brackets and the tick.
    var side: CGFloat { (0..<4).map { hypot(p[$0].x - p[($0 + 1) % 4].x, p[$0].y - p[($0 + 1) % 4].y) }.min() ?? 0 }

    /// Pushed out from the centre by `amount`, so the brackets sit around the code rather than on it.
    func inflated(by amount: CGFloat) -> ScanQuad {
        let c = center
        return ScanQuad(p.map { pt in
            let dx = pt.x - c.x, dy = pt.y - c.y
            let length = max(hypot(dx, dy), 0.001)
            return CGPoint(x: pt.x + dx / length * amount, y: pt.y + dy / length * amount)
        })
    }

    // VectorArithmetic
    static var zero: ScanQuad { ScanQuad(Array(repeating: .zero, count: 4)) }
    static func + (a: ScanQuad, b: ScanQuad) -> ScanQuad {
        ScanQuad((0..<4).map { CGPoint(x: a.p[$0].x + b.p[$0].x, y: a.p[$0].y + b.p[$0].y) })
    }
    static func - (a: ScanQuad, b: ScanQuad) -> ScanQuad {
        ScanQuad((0..<4).map { CGPoint(x: a.p[$0].x - b.p[$0].x, y: a.p[$0].y - b.p[$0].y) })
    }
    mutating func scale(by rhs: Double) { p = p.map { CGPoint(x: $0.x * rhs, y: $0.y * rhs) } }
    var magnitudeSquared: Double { p.reduce(0) { $0 + Double($1.x * $1.x + $1.y * $1.y) } }
}

/// What the viewfinder shows: searching (a breathing square in the middle), locking onto a code (the
/// brackets follow it while the hold runs), done (filled with a tick) or rejected (red).
@MainActor
@Observable
final class ScanTracker {
    enum Phase: Equatable { case searching, locking, done, rejected }

    private(set) var phase: Phase = .searching
    /// The code's corners in the camera view's coordinates; nil while searching.
    private(set) var quad: ScanQuad?
    /// Bumps each time a new code is picked up (for the haptic tap).
    private(set) var lockCount = 0

    @ObservationIgnored var accept: (String) -> Bool = { _ in true }
    @ObservationIgnored var onScan: (String) -> Void = { _ in }
    /// How long the code has to stay in view before it counts — long enough to see the lock.
    @ObservationIgnored var hold: Duration = .milliseconds(750)

    private var payload: String?
    private var holdTask: Task<Void, Never>?
    private var lostTask: Task<Void, Never>?

    /// Codes in the current frame, as payload + corners.
    func update(_ codes: [(payload: String, quad: ScanQuad)]) {
        // Once through, keep the tick on the code (if it's still in view) until the sheet goes.
        if phase == .done {
            if let same = codes.first(where: { $0.payload == payload }) { quad = same.quad }
            return
        }
        // Stay on the code already being followed when several are in view.
        guard let code = codes.first(where: { $0.payload == payload }) ?? codes.first else {
            // Detection flickers for a frame or two; only give up after a short grace.
            if lostTask == nil, payload != nil {
                lostTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    self?.reset()
                }
            }
            return
        }
        lostTask?.cancel(); lostTask = nil
        quad = code.quad
        guard code.payload != payload else { return }

        payload = code.payload
        lockCount += 1
        holdTask?.cancel()
        guard accept(code.payload) else {
            phase = .rejected
            return
        }
        phase = .locking
        let locked = code.payload
        holdTask = Task { [weak self, hold] in
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled, let self, self.payload == locked, self.phase == .locking else { return }
            self.phase = .done
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self.onScan(locked)
        }
    }

    func reset() {
        holdTask?.cancel(); holdTask = nil
        lostTask?.cancel(); lostTask = nil
        payload = nil
        quad = nil
        phase = .searching
    }
}

/// The VisionKit camera, reporting every QR it sees (with its corners) to the tracker. Its own
/// highlighting is off — the overlay draws the viewfinder.
private struct ScannerCamera: UIViewControllerRepresentable {
    let tracker: ScanTracker

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, recognizesMultipleItems: false,
                                                isHighFrameRateTrackingEnabled: true, isHighlightingEnabled: false)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(tracker: tracker) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let tracker: ScanTracker
        init(tracker: ScanTracker) { self.tracker = tracker }

        func dataScanner(_ scanner: DataScannerViewController, didAdd added: [RecognizedItem], allItems: [RecognizedItem]) { report(allItems) }
        func dataScanner(_ scanner: DataScannerViewController, didUpdate updated: [RecognizedItem], allItems: [RecognizedItem]) { report(allItems) }
        func dataScanner(_ scanner: DataScannerViewController, didRemove removed: [RecognizedItem], allItems: [RecognizedItem]) { report(allItems) }

        private func report(_ items: [RecognizedItem]) {
            let codes: [(payload: String, quad: ScanQuad)] = items.compactMap { item in
                guard case .barcode(let barcode) = item, let payload = barcode.payloadStringValue else { return nil }
                let b = barcode.bounds
                return (payload, ScanQuad([b.topLeft, b.topRight, b.bottomRight, b.bottomLeft]))
            }
            tracker.update(codes)
        }
    }
}

// MARK: - Overlay

private struct ScanOverlay: View {
    let tracker: ScanTracker
    @State private var breathe = false

    var body: some View {
        GeometryReader { geo in
            let target = displayQuad(in: geo.size)
            let searching = tracker.phase == .searching
            ZStack {
                ScanDimming(quad: target)
                    .fill(Color.black.opacity(searching ? 0.55 : 0.4), style: FillStyle(eoFill: true))
                ScanFill(quad: target)
                    .fill(color.opacity(tracker.phase == .done ? 0.28 : 0))
                ScanFill(quad: target)
                    .trim(from: 0, to: tracker.phase == .searching || tracker.phase == .rejected ? 0 : 1)
                    .stroke(color.opacity(0.55), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .animation(tracker.phase == .locking ? .linear(duration: 0.75) : .easeOut(duration: 0.15), value: tracker.phase)
                ScanBrackets(quad: target)
                    .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    .shadow(color: .black.opacity(0.35), radius: 4)
                    .scaleEffect(searching && breathe ? 0.96 : 1)
                if tracker.phase == .done {
                    Image(systemName: "checkmark")
                        .font(.system(size: min(max(target.side * 0.32, 28), 64), weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.3), radius: 6)
                        .position(target.center)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.78), value: target)
            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: tracker.phase)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { breathe = true }
        }
    }

    private var color: Color {
        switch tracker.phase {
        case .done: CDS.success
        case .rejected: CDS.danger
        default: .white
        }
    }

    /// The code (with some room around it), or the centred square while searching.
    private func displayQuad(in size: CGSize) -> ScanQuad {
        if let quad = tracker.quad { return quad.inflated(by: tracker.phase == .done ? 14 : 10) }
        let side = min(size.width, size.height) * 0.64
        return ScanQuad(rect: CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2 - 30, width: side, height: side))
    }
}

/// The screen with a quad-shaped hole (even-odd fill).
private struct ScanDimming: Shape {
    var quad: ScanQuad
    var animatableData: ScanQuad { get { quad } set { quad = newValue } }
    func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: -200, dy: -200))
        path.addPath(ScanFill(quad: quad).path(in: rect))
        return path
    }
}

/// The quad itself, with softly rounded corners.
private struct ScanFill: Shape {
    var quad: ScanQuad
    var animatableData: ScanQuad { get { quad } set { quad = newValue } }
    func path(in rect: CGRect) -> Path {
        let p = quad.p
        let r = min(quad.side * 0.12, 18)
        var path = Path()
        for i in 0..<4 {
            let corner = p[i], prev = p[(i + 3) % 4], next = p[(i + 1) % 4]
            let a = ScanBrackets.point(from: corner, toward: prev, distance: r)
            let b = ScanBrackets.point(from: corner, toward: next, distance: r)
            if i == 0 { path.move(to: a) } else { path.addLine(to: a) }
            path.addQuadCurve(to: b, control: corner)
        }
        path.closeSubpath()
        return path
    }
}

/// Four rounded corner brackets on the quad's corners.
private struct ScanBrackets: Shape {
    var quad: ScanQuad
    var animatableData: ScanQuad { get { quad } set { quad = newValue } }

    func path(in rect: CGRect) -> Path {
        let p = quad.p
        let arm = min(quad.side * 0.26, 38)
        let r = min(quad.side * 0.12, 18, arm * 0.6)
        var path = Path()
        for i in 0..<4 {
            let corner = p[i], prev = p[(i + 3) % 4], next = p[(i + 1) % 4]
            path.move(to: Self.point(from: corner, toward: prev, distance: arm))
            path.addLine(to: Self.point(from: corner, toward: prev, distance: r))
            path.addQuadCurve(to: Self.point(from: corner, toward: next, distance: r), control: corner)
            path.addLine(to: Self.point(from: corner, toward: next, distance: arm))
        }
        return path
    }

    static func point(from a: CGPoint, toward b: CGPoint, distance: CGFloat) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = max(hypot(dx, dy), 0.001)
        return CGPoint(x: a.x + dx / length * distance, y: a.y + dy / length * distance)
    }
}

#if DEBUG && targetEnvironment(simulator)
import CoreImage.CIFilterBuiltins

/// The simulator has no camera: a QR code drifting over a dark "camera" so the viewfinder can be seen
/// finding it, following it, ticking — and starting over.
private struct ScanDemo: View {
    let tracker: ScanTracker
    @State private var start = Date()

    private static let code: UIImage? = {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data("ccremote://demo".utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }()

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSince(start).truncatingRemainder(dividingBy: 6)
                let rect = codeRect(t: t, in: geo.size)
                ZStack {
                    LinearGradient(colors: [Color(white: 0.22), Color(white: 0.08)], startPoint: .top, endPoint: .bottom)
                    if let code = Self.code {
                        Image(uiImage: code).interpolation(.none).resizable()
                            .frame(width: rect.width, height: rect.height)
                            .padding(16).background(.white, in: RoundedRectangle(cornerRadius: 12))
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
                .onChange(of: context.date) { _, _ in
                    // The code enters the frame at 1 s, is followed until the scan ticks, and leaves at 5.5 s.
                    if t > 1 && t < 5.5 { tracker.update([("ccremote://demo", ScanQuad(rect: rect))]) }
                    else if t >= 5.5 { tracker.reset() }
                }
            }
        }
    }

    private func codeRect(t: Double, in size: CGSize) -> CGRect {
        let side = min(size.width, size.height) * 0.36
        let x = size.width * 0.62 + sin(t * 1.3) * 22
        let y = size.height * 0.58 + cos(t * 1.1) * 30
        return CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side)
    }
}
#endif
#endif
