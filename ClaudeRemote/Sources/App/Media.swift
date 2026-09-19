import UIKit
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
