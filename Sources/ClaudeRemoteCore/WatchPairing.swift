import Foundation

/// The minimum a client needs to reach one Mac's daemon. The iPhone hands this to the Watch over
/// WatchConnectivity (typing a token on the wrist is a non-starter), and both sides share this type.
public struct WatchPairing: Codable, Equatable, Sendable {
    public var name: String
    public var token: String
    public var host: String?
    public var port: UInt16
    public var useTLS: Bool
    public var fingerprint: String?
    public var relayURL: String?
    public var room: String?

    public init(name: String, token: String, host: String?, port: UInt16, useTLS: Bool,
                fingerprint: String?, relayURL: String?, room: String?) {
        self.name = name
        self.token = token
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.fingerprint = fingerprint
        self.relayURL = relayURL
        self.room = room
    }

    public var hasRelay: Bool { !(relayURL?.isEmpty ?? true) && !(room?.isEmpty ?? true) }
    public var hasDirect: Bool { !(host?.isEmpty ?? true) }

    /// `wss://host:port/` for a direct LAN/VPN address.
    public func directURL() -> URL? {
        guard let host, !host.isEmpty else { return nil }
        let scheme = useTLS ? "wss" : "ws"
        var h = host
        if h.contains(":") { h = "[" + h.replacingOccurrences(of: "%", with: "%25") + "]" }
        return URL(string: "\(scheme)://\(h):\(port)/")
    }

    /// `<relay>/client?room=…` — reaches the Mac when it isn't on the LAN.
    public func relayClientURL() -> URL? {
        guard let relayURL, let room, var c = URLComponents(string: relayURL) else { return nil }
        c.path = (c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path) + "/client"
        c.queryItems = [URLQueryItem(name: "room", value: room)]
        return c.url
    }

    /// Routes to try, relay first (works anywhere), then a direct address, each with its TLS role.
    public func routes() -> [(url: URL, tls: TLSRole)] {
        var out: [(URL, TLSRole)] = []
        if let r = relayClientURL() { out.append((r, r.scheme == "wss" ? .clientDefault : .none)) }
        if let d = directURL() {
            let tls: TLSRole = useTLS ? .clientPinned(expected: fingerprint, learned: nil) : .none
            out.append((d, tls))
        }
        return out
    }

    // MARK: JSON payload for WatchConnectivity

    public func payload() -> [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    public static func from(payload: [String: Any]) -> WatchPairing? {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return try? JSONDecoder().decode(WatchPairing.self, from: data)
    }
}
