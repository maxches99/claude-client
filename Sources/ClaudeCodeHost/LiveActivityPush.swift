#if os(macOS)
import Foundation
import CryptoKit

/// Pushes Live Activity updates to phones through APNs (token-based auth with a `.p8` key), so the
/// Dynamic Island keeps moving after iOS has cut the app's socket. Optional: without a key the phone
/// still updates its activity itself while it is running.
public struct LiveActivityPushConfig: Sendable, Equatable {
    public var keyPath: String
    public var keyId: String
    public var teamId: String
    /// The iOS app's bundle id (the topic is `<bundle>.push-type.liveactivity`).
    public var bundleId: String
    /// Xcode / TestFlight-internal builds register with the sandbox gateway.
    public var sandbox: Bool

    public init(keyPath: String, keyId: String, teamId: String, bundleId: String = "dev.maxches.ClaudeRemote", sandbox: Bool = false) {
        self.keyPath = keyPath
        self.keyId = keyId
        self.teamId = teamId
        self.bundleId = bundleId
        self.sandbox = sandbox
    }

    public var isComplete: Bool { !keyPath.isEmpty && !keyId.isEmpty && !teamId.isEmpty && !bundleId.isEmpty }
}

public final class LiveActivityPusher: @unchecked Sendable {
    public enum Event: String, Sendable { case update, end }

    private let config: LiveActivityPushConfig
    private let key: P256.Signing.PrivateKey
    private let session: URLSession
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var cachedJWT: (token: String, issuedAt: Date)?

    /// Fails when the key file is missing or not a PKCS#8 P-256 key (what Apple hands out as `AuthKey_XXXX.p8`).
    public init(config: LiveActivityPushConfig, log: @escaping @Sendable (String) -> Void = { _ in }) throws {
        self.config = config
        self.log = log
        let pem = try String(contentsOfFile: (config.keyPath as NSString).expandingTildeInPath, encoding: .utf8)
        self.key = try P256.Signing.PrivateKey(pemRepresentation: pem)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: cfg)
    }

    /// Sends one update. `state` is any Encodable matching the app's `ContentState`; `alert` makes the
    /// phone light up (used for approvals). `dismissAfter` only matters for `.end`.
    public func push<State: Encodable>(token: String, event: Event, state: State, alert: (title: String, body: String)? = nil,
                                       priority: Int = 10, dismissAfter: TimeInterval? = nil) {
        let host = config.sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com"
        guard let url = URL(string: "https://\(host)/3/device/\(token)") else { return }
        var aps: [String: Any] = ["timestamp": Int(Date().timeIntervalSince1970), "event": event.rawValue]
        let encoder = JSONEncoder()
        guard let stateData = try? encoder.encode(state), let stateJSON = try? JSONSerialization.jsonObject(with: stateData) else { return }
        aps["content-state"] = stateJSON
        if let alert { aps["alert"] = ["title": alert.title, "body": alert.body] }
        if event == .end, let dismissAfter { aps["dismissal-date"] = Int(Date().addingTimeInterval(dismissAfter).timeIntervalSince1970) }
        guard let body = try? JSONSerialization.data(withJSONObject: ["aps": aps]) else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("bearer \(jwt())", forHTTPHeaderField: "authorization")
        req.setValue("\(config.bundleId).push-type.liveactivity", forHTTPHeaderField: "apns-topic")
        req.setValue("liveactivity", forHTTPHeaderField: "apns-push-type")
        req.setValue("\(priority)", forHTTPHeaderField: "apns-priority")
        req.setValue("0", forHTTPHeaderField: "apns-expiration")
        req.httpBody = body
        let log = self.log
        session.dataTask(with: req) { data, response, error in
            if let error { log("live push failed: \(error.localizedDescription)"); return }
            if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
                let reason = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                log("live push HTTP \(http.statusCode) \(reason)")
            }
        }.resume()
    }

    /// Apple accepts a provider token for an hour and asks for no more than one refresh per 20 minutes.
    private func jwt() -> String {
        lock.lock(); defer { lock.unlock() }
        if let cached = cachedJWT, Date().timeIntervalSince(cached.issuedAt) < 45 * 60 { return cached.token }
        let header = Self.base64url(try! JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": config.keyId]))
        let now = Date()
        let claims = Self.base64url(try! JSONSerialization.data(withJSONObject: ["iss": config.teamId, "iat": Int(now.timeIntervalSince1970)]))
        let signingInput = "\(header).\(claims)"
        let signature = (try? key.signature(for: Data(signingInput.utf8)).rawRepresentation) ?? Data()
        let token = signingInput + "." + Self.base64url(signature)
        cachedJWT = (token, now)
        return token
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
#endif
