import UIKit
import Observation
import ClaudeRemoteCore

/// Decodes inline base64 images and daemon-fetched files into downscaled UIImages, once.
@MainActor
@Observable
final class ImageCache {
    private(set) var images: [String: UIImage] = [:]
    private(set) var failures: Set<String> = []
    private var inflight: Set<String> = []

    /// Returns the decoded image, or nil while decoding (the view re-renders when it lands).
    func image(key: String, base64: String) -> UIImage? {
        if let image = images[key] { return image }
        guard !inflight.contains(key), !failures.contains(key) else { return nil }
        inflight.insert(key)
        Task.detached(priority: .utility) { [weak self] in
            let decoded = await ImageCache.decode(base64: base64)
            await MainActor.run {
                guard let self else { return }
                self.inflight.remove(key)
                if let decoded { self.images[key] = decoded } else { self.failures.insert(key) }
            }
        }
        return nil
    }

    func store(key: String, base64: String) {
        _ = image(key: key, base64: base64)
    }

    func fail(key: String) {
        failures.insert(key)
        inflight.remove(key)
    }

    /// Drops everything — used when switching Macs, where the same path can name a different file.
    func reset() {
        images = [:]
        failures = []
        inflight = []
    }

    private static func decode(base64: String) async -> UIImage? {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), let image = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 1400
        let size = image.size
        guard max(size.width, size.height) > maxSide else { return image }
        let scale = maxSide / max(size.width, size.height)
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        return await image.byPreparingThumbnail(ofSize: target) ?? image
    }
}
