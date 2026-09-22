import Foundation

/// A transcript published as a read-only link. The phone renders the page and seals it with a key
/// only it knows; the relay stores ciphertext and serves a small viewer, and the key travels in the
/// link's `#fragment`, which browsers never send to the server — so neither the Mac nor the relay
/// can read what was shared.
public struct ShareInfo: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var sessionId: String
    public var title: String
    /// The link without the key (`https://relay/s/<id>`); the phone appends `#<key>`.
    public var url: String
    public var createdAt: Date
    public var expiresAt: Date

    public init(id: String, sessionId: String, title: String, url: String, createdAt: Date = Date(), expiresAt: Date) {
        self.id = id
        self.sessionId = sessionId
        self.title = title
        self.url = url
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    public var isExpired: Bool { expiresAt <= Date() }
}

/// What the phone sends to publish: the sealed page (AES-256-GCM — `iv` 12 bytes, `ciphertext`
/// with the 16-byte tag appended, as WebCrypto expects) and how long it may live.
public struct SharePayload: Codable, Equatable, Sendable {
    public var ivBase64: String
    public var ciphertextBase64: String
    public var ttlSeconds: Int

    public init(ivBase64: String, ciphertextBase64: String, ttlSeconds: Int) {
        self.ivBase64 = ivBase64
        self.ciphertextBase64 = ciphertextBase64
        self.ttlSeconds = ttlSeconds
    }

    /// The choices the share sheet offers, and the relay's ceiling.
    public static let ttlChoices: [(label: String, seconds: Int)] = [("1 hour", 3600), ("1 day", 86_400), ("7 days", 7 * 86_400)]
    public static let maxTTL = 7 * 86_400
    /// Ciphertext the relay accepts (transcripts are text; this is generous).
    public static let maxBytes = 4 * 1024 * 1024
}
