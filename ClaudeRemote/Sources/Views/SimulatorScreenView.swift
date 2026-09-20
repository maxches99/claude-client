import SwiftUI
import ClaudeRemoteCore

/// The simulator's picture (video, or the JPEG fallback) with everything that touches it: one finger is
/// forwarded live to the simulator, two fingers zoom and pan the picture for precise taps, and a landscape
/// simulator can be shown rotated so it fills a portrait phone in the full-screen view.
struct SimulatorScreenView: View {
    /// Rotate a landscape picture 90° so it fills a portrait screen (full-screen mode).
    var rotateLandscape = false
    /// Draw the black bezel around the picture (the sheet); the full-screen view is black already.
    var bezel = true

    @Environment(AppModel.self) private var model

    /// The finger currently on the simulator's screen: where the last `moved` went and when.
    @State private var touch: (point: CGPoint, sentAt: Date)?
    /// `began` is held back briefly so a second finger landing (a pinch) does not become a stray tap.
    @State private var pendingBegan: Task<Void, Never>?
    @State private var heldPoint: CGPoint?
    @State private var pinching = false
    /// Drag callbacks that trail a pinch (SwiftUI may or may not end the drag when the pinch does) are ignored.
    @State private var pinchEndedAt: Date = .distantPast
    /// Brief ring where the last tap landed.
    @State private var tapMark: (point: CGPoint, id: UUID)?
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var zoomAtPinchStart: CGFloat = 1
    @State private var panAtPinchStart: CGSize = .zero

    private var feed: SimulatorFeed { model.simulatorFeed }

    /// Whether the picture is drawn rotated (landscape simulator in a view that asked for it).
    private var rotated: Bool {
        guard rotateLandscape, let size = feed.pictureSize else { return false }
        return size.width > size.height
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let size = feed.pictureSize {
                    let aspect = max(size.width, 1) / max(size.height, 1)
                    // The unrotated picture must fit the container's dimensions swapped when it is shown rotated.
                    let box = rotated ? CGSize(width: geo.size.height, height: geo.size.width) : geo.size
                    let inset: CGFloat = bezel ? 12 : 0
                    let fitted = Self.fit(aspect: aspect, in: CGSize(width: box.width - inset, height: box.height - inset))
                    picture
                        .frame(width: fitted.width + inset, height: fitted.height + inset)
                        .rotationEffect(.degrees(rotated ? 90 : 0))
                        .scaleEffect(zoom)
                        .offset(pan)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .contentShape(Rectangle())
                        .simultaneousGesture(magnify(in: geo.size))
                        .overlay(alignment: .bottomTrailing) { zoomBadge }
                } else {
                    VStack(spacing: 10) {
                        ProgressView().tint(CDS.textMuted)
                        Text("Connecting to \(feed.device?.name ?? "the simulator")…")
                            .font(CDS.body).foregroundStyle(CDS.textMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onChange(of: feed.watching) { _, _ in resetZoom() }
    }

    private static func fit(aspect: CGFloat, in box: CGSize) -> CGSize {
        guard box.width > 0, box.height > 0 else { return .zero }
        let byWidth = CGSize(width: box.width, height: box.width / aspect)
        return byWidth.height <= box.height ? byWidth : CGSize(width: box.height * aspect, height: box.height)
    }

    private var picture: some View {
        Group {
            if feed.videoSize != nil {
                SimulatorVideoView(player: feed.player)
            } else if let frame = feed.frame {
                Image(uiImage: frame.image).resizable()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay { touchSurface }
        .padding(bezel ? 6 : 0)
        .background(Color.black, in: RoundedRectangle(cornerRadius: bezel ? 28 : 22))
        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(bezel ? CDS.border : .clear))
    }

    // MARK: touch forwarding

    /// Sits exactly over the picture, so gesture locations are fractions of the simulator screen.
    /// The finger is forwarded live — down on first contact, moves as it goes, up on release — so
    /// scrolls and drags happen under it; a quick down/up is simply a tap on the other side.
    private var touchSurface: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.clear
                if let tapMark {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
                        .background(Circle().fill(Color.white.opacity(0.25)))
                        .frame(width: 28, height: 28)
                        .position(tapMark.point)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                        .id(tapMark.id)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        guard !pinching, !justPinched else { return }
                        if touch == nil && pendingBegan == nil {
                            holdBegan(at: value.location, in: geo.size)
                        } else if pendingBegan != nil {
                            heldPoint = value.location
                        } else if let touch, Date().timeIntervalSince(touch.sentAt) >= 1 / 40 || hypot(value.location.x - touch.point.x, value.location.y - touch.point.y) >= 6 {
                            forward(.moved, value.location, in: geo.size)
                        }
                    }
                    .onEnded { value in
                        defer { touch = nil; heldPoint = nil }
                        if pinching || justPinched { return }
                        if pendingBegan != nil {
                            // Lifted before the hold-back elapsed: a very quick tap. Send it whole.
                            pendingBegan?.cancel()
                            pendingBegan = nil
                            forward(.began, value.location, in: geo.size)
                            showTapMark(at: value.location)
                        } else if touch == nil {
                            forward(.began, value.location, in: geo.size)
                        }
                        forward(.ended, value.location, in: geo.size)
                    }
            )
        }
    }

    private var justPinched: Bool { Date().timeIntervalSince(pinchEndedAt) < 0.3 }

    /// Wait ~120 ms before putting the finger down: a pinch's second finger lands (and starts moving,
    /// which is when SwiftUI reports it) within that, and then the first contact must not reach the
    /// simulator at all. A quick tap ends before the hold-back and is sent whole on release.
    private func holdBegan(at point: CGPoint, in size: CGSize) {
        heldPoint = point
        pendingBegan = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, !pinching else { return }
            pendingBegan = nil
            forward(.began, point, in: size)
            showTapMark(at: point)
            if let held = heldPoint, held != point { forward(.moved, held, in: size) }
        }
    }

    private func forward(_ phase: SimulatorTouchPhase, _ point: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let x = Double(min(max(point.x / size.width, 0), 1)), y = Double(min(max(point.y / size.height, 0), 1))
        model.sendSimulatorInput(.touch(phase: phase, x: x, y: y))
        touch = (point, Date())
    }

    private func showTapMark(at point: CGPoint) {
        withAnimation(.easeOut(duration: 0.15)) { tapMark = (point, UUID()) }
        let marked = tapMark?.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if tapMark?.id == marked { withAnimation(.easeIn(duration: 0.2)) { tapMark = nil } }
        }
    }

    // MARK: zoom

    /// Two fingers: pinch to zoom (1–4×) around the spot between them — zoom where you pinch, pinch
    /// somewhere else to move. One finger stays the simulator's.
    private func magnify(in size: CGSize) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0)
            .onChanged { value in
                if !pinching {
                    pinching = true
                    pendingBegan?.cancel()
                    pendingBegan = nil
                    if touch != nil, let point = touch?.point { forward(.ended, point, in: size) }   // finger already down: lift it
                    touch = nil
                    zoomAtPinchStart = zoom
                    panAtPinchStart = pan
                }
                let newZoom = min(max(zoomAtPinchStart * value.magnification, 1), 4)
                // Keep the content under the pinch's anchor where it is: solve pan so that the anchor
                // maps to the same content point before and after the scale change.
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let anchor = CGPoint(x: value.startAnchor.x * size.width, y: value.startAnchor.y * size.height)
                let content = CGPoint(x: (anchor.x - center.x - panAtPinchStart.width) / zoomAtPinchStart,
                                      y: (anchor.y - center.y - panAtPinchStart.height) / zoomAtPinchStart)
                let newPan = CGSize(width: anchor.x - center.x - content.x * newZoom, height: anchor.y - center.y - content.y * newZoom)
                zoom = newZoom
                pan = Self.clampPan(newPan, zoom: newZoom, in: size)
            }
            .onEnded { _ in
                pinching = false
                pinchEndedAt = Date()
                if zoom < 1.05 { withAnimation(.easeOut(duration: 0.2)) { zoom = 1; pan = .zero } }
            }
    }

    /// Keep the zoomed picture covering the container — no empty margins to pan into.
    private static func clampPan(_ pan: CGSize, zoom: CGFloat, in size: CGSize) -> CGSize {
        let maxX = max(0, (zoom - 1) * size.width / 2), maxY = max(0, (zoom - 1) * size.height / 2)
        return CGSize(width: min(max(pan.width, -maxX), maxX), height: min(max(pan.height, -maxY), maxY))
    }

    private func resetZoom() {
        zoom = 1
        pan = .zero
    }

    @ViewBuilder private var zoomBadge: some View {
        if zoom > 1.05 {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { resetZoom() }
            } label: {
                Text(String(format: "%.1f×", zoom))
                    .font(CDS.captionMedium).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(10)
            .accessibilityLabel("Reset zoom")
        }
    }
}
