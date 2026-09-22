import SwiftUI
import UIKit
import PencilKit

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
