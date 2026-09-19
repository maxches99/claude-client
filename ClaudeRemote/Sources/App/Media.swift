import UIKit
import UniformTypeIdentifiers
import ClaudeRemoteCore

/// Turns a picked photo into a downscaled JPEG `InlineImage` suitable for sending over the wire
/// (base64 goes into the transcript and stdin, so keep it modest).
enum Media {
    static func inlineImage(from data: Data, maxSide: CGFloat = 1600, quality: CGFloat = 0.7) -> InlineImage? {
        guard let image = UIImage(data: data) else { return nil }
        let scaled = downscale(image, maxSide: maxSide)
        guard let jpeg = scaled.jpegData(compressionQuality: quality) else { return nil }
        return InlineImage(mediaType: "image/jpeg", base64: jpeg.base64EncodedString())
    }

    private static func downscale(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return image }
        let scale = maxSide / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

extension Media {
    /// Upper bound on a single attachment's raw size — base64 rides the WebSocket and the CLI's stdin,
    /// so keep videos and documents reasonable.
    static let maxAttachmentBytes = 50 * 1024 * 1024

    /// A human-readable size like "2.4 MB", for chips and error notices.
    static func humanSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Builds a non-image `Attachment` (document, video, voice memo) from raw data. Returns nil when the
    /// data is empty or exceeds `maxAttachmentBytes`.
    static func attachment(data: Data, filename: String, mediaType: String) -> Attachment? {
        guard !data.isEmpty, data.count <= maxAttachmentBytes else { return nil }
        return Attachment(filename: filename, mediaType: mediaType, base64: data.base64EncodedString())
    }

    /// Best-effort MIME type for a filename extension (falls back to octet-stream).
    static func mediaType(forExtension ext: String) -> String {
        guard !ext.isEmpty, let ut = UTType(filenameExtension: ext), let mime = ut.preferredMIMEType else {
            return "application/octet-stream"
        }
        return mime
    }

    /// Reads a security-scoped file URL (as returned by the document picker) into an `Attachment`.
    static func attachment(fileURL url: URL) -> Attachment? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return attachment(data: data, filename: url.lastPathComponent, mediaType: mediaType(forExtension: url.pathExtension))
    }
}
