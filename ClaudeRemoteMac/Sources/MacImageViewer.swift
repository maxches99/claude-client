import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Viewer for images in a transcript (simulator screenshots, pasted images, files the agent sent):
/// ← / → between the turn's images, pinch or ⌘+ / ⌘− to zoom, double-click to fit, Esc to close,
/// and Copy, Save… or Share.
struct ImageViewer: View {
    let target: ImageViewerTarget
    @Environment(\.dismiss) private var dismiss

    @State private var index: Int
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var notice: String?

    init(target: ImageViewerTarget) {
        self.target = target
        _index = State(initialValue: min(max(target.index, 0), max(target.images.count - 1, 0)))
    }

    private var current: NSImage? { target.images.indices.contains(index) ? target.images[index] : nil }
    private var fileName: String { target.images.count > 1 ? "\(target.name)-\(index + 1).png" : "\(target.name).png" }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let current {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: current)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: fittedSize(current).width * zoom * pinch, height: fittedSize(current).height * zoom * pinch)
                    }
                    .defaultScrollAnchor(.center)
                    .gesture(MagnifyGesture()
                        .onChanged { pinch = $0.magnification }
                        .onEnded { _ in zoom = clamp(zoom * pinch); pinch = 1 })
                    .onTapGesture(count: 2) { withAnimation(.easeOut(duration: 0.2)) { zoom = zoom == 1 ? 2 : 1 } }
                }
                if let notice {
                    Text(notice)
                        .font(CDS.captionMedium).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .environment(\.colorScheme, .dark)
                        .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 14)
                        .transition(.opacity)
                }
            }
            bar
        }
        .frame(minWidth: 720, idealWidth: 1000, minHeight: 520, idealHeight: 760)
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private var bar: some View {
        HStack(spacing: 10) {
            if target.images.count > 1 {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }.disabled(index == 0)
                Text("\(index + 1) of \(target.images.count)").font(CDS.caption.monospacedDigit()).foregroundStyle(CDS.textMuted)
                Button { step(1) } label: { Image(systemName: "chevron.right") }.disabled(index >= target.images.count - 1)
            }
            if let current, let rep = current.representations.first {
                Text(verbatim: "\(rep.pixelsWide) × \(rep.pixelsHigh)").font(CDS.caption.monospacedDigit()).foregroundStyle(CDS.textMuted)
            }
            Spacer()
            Button { zoom = clamp(zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command)
            Button { zoom = 1 } label: { Text("Fit") }
                .keyboardShortcut("0", modifiers: .command)
            Button { zoom = clamp(zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("=", modifiers: .command)
            Divider().frame(height: 16)
            Button("Copy", systemImage: "doc.on.doc") {
                guard let current else { return }
                UIPasteboard.general.image = current
                show("Copied")
            }
            .keyboardShortcut("c", modifiers: .command)
            Button("Save…", systemImage: "square.and.arrow.down") { save() }
                .keyboardShortcut("s", modifiers: .command)
            if let current {
                ShareLink(item: ExportedImage(image: current, fileName: fileName),
                          preview: SharePreview(fileName, image: Image(nsImage: current)))
            }
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(CDS.surface0)
    }

    private func fittedSize(_ image: NSImage) -> CGSize {
        // Fit inside a typical window; zoom scales from there and the scroll view takes over.
        let box = CGSize(width: 960, height: 660)
        let size = image.size
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height, 1)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private func clamp(_ value: CGFloat) -> CGFloat { min(max(value, 0.25), 8) }

    private func step(_ delta: Int) {
        let next = index + delta
        guard target.images.indices.contains(next) else { return }
        index = next
        zoom = 1
    }

    private func save() {
        guard let current, let data = current.pngData() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = fileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            show("Saved")
        } catch {
            show(error.localizedDescription)
        }
    }

    private func show(_ text: String) {
        withAnimation { notice = text }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation { if notice == text { notice = nil } }
        }
    }
}
