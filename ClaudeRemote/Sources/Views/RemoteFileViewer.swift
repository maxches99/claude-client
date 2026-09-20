import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import ClaudeRemoteCore

/// Shows a file the agent sent (SendUserFile) fetched from the Mac: Markdown rendered like a reply,
/// text and code monospaced, PDFs paged, images zoomable — and everything else as a card that can
/// still be saved. The share button hands the bytes to the share sheet as a real file, so "Save to
/// Files", AirDrop, or opening in another app all work.
struct RemoteFileViewer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let path: String

    private var file: AppModel.RemoteFile? { model.remoteFiles[path] }
    private var error: String? { model.remoteFileErrors[path] }
    private var name: String { (path as NSString).lastPathComponent }

    var body: some View {
        NavigationStack {
            Group {
                if let file {
                    content(file)
                } else if let error {
                    ContentUnavailableView {
                        Label("Couldn't load", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try again") { model.requestFile(path, force: true) }
                            .buttonStyle(CDSButtonStyle(variant: .secondary))
                    }
                } else {
                    VStack(spacing: 10) {
                        ProgressView().tint(CDS.textMuted)
                        Text("Fetching from the Mac…").font(CDS.caption).foregroundStyle(CDS.textMuted)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CDS.surface0)
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CDS.surface0, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    if let file {
                        ShareLink(item: RemoteFileDocument(file: file), preview: SharePreview(name, image: Image(systemName: Self.symbol(for: path)))) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let file, let text = Self.text(of: file) {
                        Button { UIPasteboard.general.string = text } label: { Image(systemName: "doc.on.doc") }
                            .accessibilityLabel("Copy contents")
                    }
                }
            }
        }
        .onAppear { if file == nil { model.requestFile(path, force: error != nil) } }
    }

    @ViewBuilder
    private func content(_ file: AppModel.RemoteFile) -> some View {
        if file.mediaType == "application/pdf" {
            PDFDocumentView(data: file.data)
        } else if file.mediaType == "text/markdown", let text = Self.text(of: file) {
            ScrollView {
                MarkdownText(text: text)
                    .padding(.horizontal, CDS.gutter).padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        } else if let text = Self.text(of: file) {
            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    .font(CDS.codeSmall).foregroundStyle(CDS.textPrimary)
                    .textSelection(.enabled)
                    .padding(CDS.gutter)
                    .fixedSize(horizontal: true, vertical: false)
            }
        } else if file.mediaType.hasPrefix("image/"), let ui = UIImage(data: file.data) {
            ScrollView([.vertical, .horizontal]) {
                Image(uiImage: ui).resizable().aspectRatio(contentMode: .fit)
            }
        } else {
            ContentUnavailableView {
                Label(name, systemImage: Self.symbol(for: path))
            } description: {
                Text("\(Self.kindLabel(for: file.mediaType)) · \(Media.humanSize(file.data.count))\nNo preview for this kind of file — share it to save or open it in another app.")
            }
        }
    }

    /// UTF-8 contents for text-like types (and anything small that decodes as text).
    static func text(of file: AppModel.RemoteFile) -> String? {
        let textLike = file.mediaType.hasPrefix("text/") || ["application/json", "application/xml", "application/x-yaml", "application/javascript"].contains(file.mediaType)
        guard textLike || file.data.count < 512 * 1024 else { return nil }
        guard let s = String(data: file.data, encoding: .utf8) else { return nil }
        // A binary that happens to decode isn't text; a NUL byte gives it away.
        return s.contains("\u{0}") ? nil : s
    }

    static func kindLabel(for mediaType: String) -> String {
        switch mediaType {
        case "text/markdown": return "Markdown"
        case "application/pdf": return "PDF"
        case "application/json": return "JSON"
        case "text/csv": return "CSV"
        case "text/html": return "HTML"
        case let t where t.hasPrefix("text/"): return "Text"
        case let t where t.hasPrefix("image/"): return "Image"
        case let t where t.hasPrefix("video/"): return "Video"
        case let t where t.hasPrefix("audio/"): return "Audio"
        default: return UTType(mimeType: mediaType)?.localizedDescription ?? "File"
        }
    }

    static func symbol(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "md", "markdown": return "doc.richtext"
        case "pdf": return "doc.text.image"
        case "json", "yml", "yaml", "toml", "xml": return "curlybraces"
        case "csv": return "tablecells"
        case "zip", "gz", "tar": return "archivebox"
        case "mov", "mp4", "m4v": return "film"
        case "m4a", "mp3", "wav": return "waveform"
        case "swift", "py", "js", "ts", "rb", "go", "rs", "sh", "c", "h", "cpp", "java", "kt": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }
}

/// PDFKit, wrapped — pages, pinch zoom, text selection.
struct PDFDocumentView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .clear
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.dataRepresentation() != data { uiView.document = PDFDocument(data: data) }
    }
}

/// The fetched bytes as a file for the share sheet, under the original name and type — so Files keeps
/// `report.md` a Markdown file, and "Open in…" offers the right apps.
struct RemoteFileDocument: Transferable {
    let file: AppModel.RemoteFile

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { doc in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ccremote-files", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(doc.file.name)
            try doc.file.data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
        .suggestedFileName { $0.file.name }
    }
}
