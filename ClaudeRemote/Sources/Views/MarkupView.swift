import SwiftUI
#if os(iOS)
import UIKit
import PencilKit

// Camera capture and PencilKit markup are iOS-only; the Mac client attaches files instead.

/// The camera, as a sheet that hands back one photo.
struct CameraPicker: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onPick(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

/// Draw on a picture before it goes to the agent — circle the misaligned button, cross out the
/// wrong value. PencilKit's tools, on the image at its own resolution.
struct MarkupView: View {
    let image: UIImage
    let onDone: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var canvas = PKCanvasView()
    @State private var hasDrawing = false

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let rect = MarkupView.fittedRect(image.size, in: geo.size)
                ZStack(alignment: .topLeading) {
                    Color.black
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                    MarkupCanvas(canvas: canvas, hasDrawing: $hasDrawing)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Mark up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 18) {
                        Button { canvas.undoManager?.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                            .disabled(!hasDrawing)
                        Button { canvas.drawing = PKDrawing(); hasDrawing = false } label: { Image(systemName: "trash") }
                            .disabled(!hasDrawing)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone(render())
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    /// The picture with the drawing burned in, at the picture's own size.
    private func render() -> UIImage {
        guard !canvas.drawing.bounds.isEmpty, canvas.bounds.width > 0 else { return image }
        let scale = image.size.width / canvas.bounds.width
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
            // Rendered at the image's scale so strokes stay sharp, then laid over the whole picture.
            let strokes = canvas.drawing.image(from: canvas.bounds, scale: scale * image.scale)
            strokes.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    static func fittedRect(_ imageSize: CGSize, in bounds: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGRect(origin: .zero, size: bounds) }
        let s = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * s, height: imageSize.height * s)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
}

private struct MarkupCanvas: UIViewRepresentable {
    let canvas: PKCanvasView
    @Binding var hasDrawing: Bool

    func makeUIView(context: Context) -> PKCanvasView {
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        // A red marker to start with — circling the problem is what this is for. The picker drives
        // the canvas's tool once it observes it, so the default goes on the picker.
        let marker = PKInkingTool(.marker, color: .systemRed, width: 8)
        canvas.tool = marker
        canvas.delegate = context.coordinator
        let picker = context.coordinator.toolPicker
        picker.selectedTool = marker
        picker.setVisible(true, forFirstResponder: canvas)
        picker.addObserver(canvas)
        DispatchQueue.main.async { canvas.becomeFirstResponder() }
        return canvas
    }

    func updateUIView(_ view: PKCanvasView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let parent: MarkupCanvas
        let toolPicker = PKToolPicker()
        init(_ parent: MarkupCanvas) { self.parent = parent }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.hasDrawing = !canvasView.drawing.strokes.isEmpty
        }
    }
}

#else

/// The Mac has no camera picker; callers hide their camera buttons behind `isAvailable`.
struct CameraPicker: View {
    static let isAvailable = false
    let onPick: (UIImage) -> Void

    var body: some View {
        ContentUnavailableView("No camera", systemImage: "camera", description: Text("Attach a file instead."))
    }
}

/// Draw on a picture before it goes to the agent — circle the misaligned button, cross out the
/// wrong value. Red marker strokes over the image, burned in at the image's own size.
struct MarkupView: View {
    let image: UIImage
    let onDone: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    /// Strokes in unit coordinates of the picture, so they survive the window being resized.
    @State private var strokes: [[CGPoint]] = []
    @State private var current: [CGPoint] = []

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let rect = MarkupView.fittedRect(image.size, in: geo.size)
                ZStack(alignment: .topLeading) {
                    Color.black
                    MarkupLayer(image: image, strokes: strokes + [current], lineWidth: 8 * rect.width / max(1, image.size.width) * 2)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                current.append(CGPoint(x: (value.location.x) / rect.width, y: (value.location.y) / rect.height))
                            }
                            .onEnded { _ in
                                if current.count > 1 { strokes.append(current) }
                                current = []
                            })
                }
            }
            .navigationTitle("Mark up")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItemGroup(placement: .principal) {
                    Button { _ = strokes.popLast() } label: { Image(systemName: "arrow.uturn.backward") }
                        .disabled(strokes.isEmpty).keyboardShortcut("z", modifiers: .command)
                    Button { strokes = [] } label: { Image(systemName: "trash") }
                        .disabled(strokes.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone(render())
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    /// The picture with the drawing burned in, at the picture's own size.
    @MainActor private func render() -> UIImage {
        guard !strokes.isEmpty else { return image }
        let renderer = ImageRenderer(content: MarkupLayer(image: image, strokes: strokes, lineWidth: 16)
            .frame(width: image.size.width, height: image.size.height))
        return renderer.nsImage ?? image
    }

    static func fittedRect(_ imageSize: CGSize, in bounds: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGRect(origin: .zero, size: bounds) }
        let s = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * s, height: imageSize.height * s)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
}

/// The picture with marker strokes on top; strokes are in unit coordinates of its frame.
private struct MarkupLayer: View {
    let image: UIImage
    let strokes: [[CGPoint]]
    let lineWidth: CGFloat

    var body: some View {
        Image(uiImage: image).resizable()
            .overlay {
                Canvas { context, size in
                    for stroke in strokes where stroke.count > 1 {
                        var path = Path()
                        path.addLines(stroke.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) })
                        context.stroke(path, with: .color(.red.opacity(0.85)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                    }
                }
            }
    }
}
#endif
