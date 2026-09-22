#if os(macOS) || os(Linux)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ClaudeRemoteCore

/// Where share links are published: the relay the daemon already dials, reached over HTTP(S) with
/// the same room and secret. The page travels sealed — the key stays on the phone.
public struct ShareConfig: Sendable {
    /// Base the Mac posts to (`https://relay.example.com`, or `http://127.0.0.1:8787` on the relay host).
    public var endpoint: URL
    /// Base of the links people open (the public relay address).
    public var publicBase: URL
    public var room: String
    public var secret: String

    public init(endpoint: URL, publicBase: URL, room: String, secret: String) {
        self.endpoint = endpoint
        self.publicBase = publicBase
        self.room = room
        self.secret = secret
    }

    /// `wss://host/path` → `https://host/path` (and `ws` → `http`).
    public static func httpBase(fromRelay url: URL) -> URL? {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        switch c.scheme?.lowercased() {
        case "wss": c.scheme = "https"
        case "ws": c.scheme = "http"
        case "https", "http": break
        default: return nil
        }
        c.query = nil
        if c.path.hasSuffix("/") { c.path.removeLast() }
        return c.url
    }
}

extension SessionManager {
    public enum ShareError: Error, CustomStringConvertible {
        case notConfigured
        case tooLarge
        case relay(String)

        public var description: String {
            switch self {
            case .notConfigured: return "Share links go through the relay, and this Mac has none configured (Host → Settings → Remote access)."
            case .tooLarge: return "That transcript is too large to share as a link."
            case .relay(let why): return "The relay refused the link: \(why)"
            }
        }
    }

    public func setShareConfig(_ config: ShareConfig?) {
        shareConfig = config
    }

    public func shareTranscript(sessionId: String, title: String, payload: SharePayload) async throws -> ShareInfo {
        guard let config = shareConfig else { throw ShareError.notConfigured }
        guard payload.ciphertextBase64.count <= SharePayload.maxBytes * 4 / 3 + 64 else { throw ShareError.tooLarge }
        let ttl = min(max(60, payload.ttlSeconds), SharePayload.maxTTL)
        var request = URLRequest(url: config.endpoint.appendingPathComponent("share"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.room, forHTTPHeaderField: "X-Relay-Room")
        request.setValue(config.secret, forHTTPHeaderField: "X-Relay-Secret")
        // Only ciphertext and a lifetime: the relay learns nothing about what is shared, not even the title.
        let body: JSONValue = .object(["iv": .string(payload.ivBase64), "ct": .string(payload.ciphertextBase64), "ttl": .number(Double(ttl))])
        request.httpBody = Data(body.serializedString().utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try? JSONValue.parse(data), let id = json["id"]?.string else {
            let reason = (try? JSONValue.parse(data))?["error"]?.string ?? "HTTP \(status)"
            throw ShareError.relay(reason)
        }
        let expires = json["expiresAt"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date().addingTimeInterval(TimeInterval(ttl))
        let url = config.publicBase.appendingPathComponent("s").appendingPathComponent(id).absoluteString
        log("[\(sessionId.prefix(8))] shared as \(id) until \(expires)")
        return ShareInfo(id: id, sessionId: sessionId, title: title, url: url, expiresAt: expires)
    }

    public func revokeShare(shareId: String) async throws {
        guard let config = shareConfig else { throw ShareError.notConfigured }
        var request = URLRequest(url: config.endpoint.appendingPathComponent("share").appendingPathComponent(shareId))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 20
        request.setValue(config.room, forHTTPHeaderField: "X-Relay-Room")
        request.setValue(config.secret, forHTTPHeaderField: "X-Relay-Secret")
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 404 else { throw ShareError.relay("HTTP \(status)") }
        log("share \(shareId) revoked")
    }
}
#endif
