import SwiftUI
import UniformTypeIdentifiers

/// An image the viewer was opened on, and the others next to it in the same turn.
struct ImageViewerTarget: Identifiable {
    let id = UUID()
    let images: [UIImage]
    let index: Int
    /// File name stem for exports ("screenshot" → screenshot-2.png).
    var name: String = "image"
}

/// Full-screen viewer for images in a transcript (simulator screenshots, pasted images, files the agent
/// sent): pinch or double-tap to zoom, swipe between the turn's images, swipe down to close, and
/// Share (Save Image, Files, AirDrop…), Save to Photos or Copy.
struct ImageViewer: View {
    let target: ImageViewerTarget
    @Environment(\.dismiss) private var dismiss

    @State private var index: Int
    @State private var dragOffset: CGFloat = 0
    @State private var chromeHidden = false
    @State private var saved: SaveResult?
    @State private var saver = PhotoSaver()

    enum SaveResult: Equatable { case saved, copied, failed(String) }

    init(target: ImageViewerTarget) {
        self.target = target
        _index = State(initialValue: min(max(target.index, 0), max(target.images.count - 1, 0)))
    }

    private var current: UIImage? { target.images.indices.contains(index) ? target.images[index] : nil }
    private var fileName: String { target.images.count > 1 ? "\(target.name)-\(index + 1).png" : "\(target.name).png" }
    /// 1 at rest, fading as the image is pulled down.
    private var backdrop: Double { 1 - min(Double(abs(dragOffset)) / 400, 0.7) }

    var body: some View {
        ZStack {
            Color.black.opacity(backdrop).ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(target.images.indices, id: \.self) { i in
                    ZoomableImage(image: target.images[i],
                                  onTap: { withAnimation(.easeOut(duration: 0.2)) { chromeHidden.toggle() } },
                                  onPull: { dragOffset = $0 },
                                  onRelease: release)
                        .ignoresSafeArea()
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .offset(y: dragOffset)

            if !chromeHidden && dragOffset == 0 { chrome.transition(.opacity) }
        }
        .statusBarHidden(chromeHidden)
        .sensoryFeedback(.success, trigger: saved) { _, new in new == .saved || new == .copied }
        .presentationBackground(.clear)
    }

    private func release(_ offset: CGFloat, _ velocity: CGFloat) {
        if abs(offset) > 120 || abs(velocity) > 900 {
            withAnimation(.easeOut(duration: 0.18)) { dragOffset = offset > 0 ? 1000 : -1000 }
            dismiss()
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragOffset = 0 }
        }
    }

    // MARK: chrome

    private var chrome: some View {
        VStack {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(ViewerButtonStyle())
                    .accessibilityLabel("Close")
                Spacer()
                if target.images.count > 1 {
                    Text("\(index + 1) of \(target.images.count)")
                        .font(CDS.captionMedium.monospacedDigit()).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.ultraThinMaterial.opacity(0.8), in: Capsule())
                        .environment(\.colorScheme, .dark)
                }
                Spacer()
                if let current {
                    ShareLink(item: ExportedImage(image: current, fileName: fileName),
                              preview: SharePreview(fileName, image: Image(uiImage: current))) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(ViewerButtonStyle())
                    .accessibilityLabel("Share")
                }
            }
            Spacer()
            if let saved { toast(saved) }
            HStack(spacing: 10) {
                Button {
                    guard let current else { return }
                    saver.save(current) { error in
                        show(error.map { .failed($0.localizedDescription) } ?? .saved)
                    }
                } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                    .buttonStyle(ViewerButtonStyle(wide: true))
                Button {
                    guard let current else { return }
                    UIPasteboard.general.image = current
                    show(.copied)
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(ViewerButtonStyle(wide: true))
            }
            if let current {
                Text(verbatim: "\(Int(current.size.width * current.scale)) × \(Int(current.size.height * current.scale))")
                    .font(CDS.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func toast(_ result: SaveResult) -> some View {
        let (text, symbol, color): (String, String, Color) = switch result {
        case .saved: ("Saved to Photos", "checkmark.circle.fill", CDS.success)
        case .copied: ("Copied", "checkmark.circle.fill", CDS.success)
        case .failed(let message): (message, "exclamationmark.triangle.fill", CDS.danger)
        }
        return HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).foregroundStyle(.white).lineLimit(2)
        }
        .font(CDS.captionMedium)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .padding(.bottom, 6)
    }

    private func show(_ result: SaveResult) {
        withAnimation(.spring(response: 0.3)) { saved = result }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation(.easeOut) { if saved == result { saved = nil } }
        }
    }
}

/// Round translucent buttons over the photo, like the system's photo viewer.
private struct ViewerButtonStyle: ButtonStyle {
    var wide = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: wide ? 15 : 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(minWidth: 44, minHeight: 44)
            .padding(.horizontal, wide ? 14 : 0)
            .background(.ultraThinMaterial.opacity(configuration.isPressed ? 1 : 0.8), in: Capsule())
            .environment(\.colorScheme, .dark)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
    }
}

/// PNG for the share sheet: "Save Image", Files, AirDrop and Copy all take it, with a real file name.
struct ExportedImage: Transferable {
    let image: UIImage
    let fileName: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            guard let data = item.image.pngData() else { throw CocoaError(.fileWriteUnknown) }
            return data
        }
        .suggestedFileName { $0.fileName }
    }
}

/// UIImageWriteToSavedPhotosAlbum reports back through an Objective-C selector.
final class PhotoSaver: NSObject {
    private var completion: ((Error?) -> Void)?

    func save(_ image: UIImage, completion: @escaping (Error?) -> Void) {
        self.completion = completion
        UIImageWriteToSavedPhotosAlbum(image, self, #selector(done(_:didFinishSavingWithError:contextInfo:)), nil)
    }

    @objc private func done(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
        let completion = self.completion
        self.completion = nil
        DispatchQueue.main.async { completion?(error) }
    }
}

// MARK: - Zoom

/// A UIScrollView-backed image: pinch to zoom, double-tap to zoom in on the spot (and back out), pan when
/// zoomed. At rest, a mostly-vertical drag is reported through `onPull` / `onRelease` so the viewer can
/// be pulled away; horizontal drags are left to the page view.
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    var onTap: () -> Void = {}
    var onPull: (CGFloat) -> Void = { _ in }
    var onRelease: (CGFloat, CGFloat) -> Void = { _, _ in }

    func makeUIView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView(image: image)
        view.onTap = onTap
        view.onPull = onPull
        view.onRelease = onRelease
        return view
    }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        view.onTap = onTap
        view.onPull = onPull
        view.onRelease = onRelease
        if view.imageView.image !== image { view.setImage(image) }
    }
}

final class ZoomScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let imageView = UIImageView()
    var onTap: () -> Void = {}
    var onPull: (CGFloat) -> Void = { _ in }
    var onRelease: (CGFloat, CGFloat) -> Void = { _, _ in }
    private var lastSize: CGSize = .zero
    private lazy var pull = UIPanGestureRecognizer(target: self, action: #selector(pulled(_:)))

    init(image: UIImage) {
        super.init(frame: .zero)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.accessibilityIgnoresInvertColors = true
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.require(toFail: doubleTap)
        addGestureRecognizer(tap)
        pull.delegate = self
        addGestureRecognizer(pull)
        setImage(image)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ image: UIImage) {
        imageView.image = image
        lastSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastSize, let image = imageView.image, image.size.width > 0, image.size.height > 0 else {
            center()
            return
        }
        lastSize = bounds.size
        // Fit the image at zoom 1; allow zooming to 1:1 pixels (at least 3×).
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let fitted = CGSize(width: image.size.width * fit, height: image.size.height * fit)
        zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: fitted)
        contentSize = fitted
        minimumZoomScale = 1
        maximumZoomScale = max(3, (image.size.width * image.scale) / max(fitted.width * UIScreen.main.scale, 1) * 2)
        center()
    }

    /// Keeps a smaller-than-screen image in the middle.
    private func center() {
        let dx = max((bounds.width - contentSize.width) / 2, 0)
        let dy = max((bounds.height - contentSize.height) / 2, 0)
        contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

    @objc private func tapped() { onTap() }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale * 1.01 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let scale = min(maximumZoomScale, 2.5)
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }

    @objc private func pulled(_ gesture: UIPanGestureRecognizer) {
        let y = gesture.translation(in: self).y
        switch gesture.state {
        case .changed: onPull(y)
        case .ended, .cancelled, .failed: onRelease(y, gesture.velocity(in: self).y)
        default: break
        }
    }

    /// The pull only starts at rest and for a mostly vertical drag; everything else is zoom / pan / paging.
    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === pull else { return super.gestureRecognizerShouldBegin(gesture) }
        guard zoomScale <= minimumZoomScale * 1.01 else { return false }
        let v = pull.velocity(in: self)
        return abs(v.y) > abs(v.x) * 1.4
    }
}
