import Foundation
import Network

/// How to reach the daemon, plus the shared secret and (for wss) the pinned cert.
struct PairingInfo: Codable, Equatable {
    var name: String
    var host: String?
    var port: UInt16
    var serviceName: String?
    var token: String
    /// SHA-256 of the daemon's TLS cert (DER). From the QR when present; learned on first
    /// connect (TOFU) otherwise. Once set, the connection pins it.
    var fingerprint: String?
    /// wss:// (default). Only false when the daemon is explicitly run with --no-tls (tls=0 in the QR).
    var useTLS: Bool = true
    /// Relay base URL (e.g. `wss://vps.example.com`) for reaching the Mac when it isn't on the LAN.
    var relayURL: String?
    /// Room id on the relay that this Mac's daemon registers under.
    var room: String?

    var isBonjour: Bool { host?.isEmpty ?? true }
    var hasDirect: Bool { !(host?.isEmpty ?? true) || serviceName != nil }
    var hasRelay: Bool { !(relayURL?.isEmpty ?? true) && !(room?.isEmpty ?? true) }

    var scheme: String { useTLS ? "wss" : "ws" }

    var serviceEndpoint: NWEndpoint {
        .service(name: serviceName ?? name, type: "_ccremote._tcp", domain: "local.", interface: nil)
    }

    /// `wss://host:port/` for a direct address. Bonjour pairings are resolved first (see HostConnection).
    var directURL: URL? {
        guard let host, !host.isEmpty else { return nil }
        return webSocketURL(host: host, port: port)
    }

    func webSocketURL(host: String, port: UInt16) -> URL? {
        var h = host
        if h.contains(":") { h = "[" + h.replacingOccurrences(of: "%", with: "%25") + "]" }
        return URL(string: "\(scheme)://\(h):\(port)/")
    }

    /// `<relay>/client?room=…` — the phone's entry point on the relay.
    var relayClientURL: URL? {
        guard let relayURL, let room, var c = URLComponents(string: relayURL) else { return nil }
        c.path = (c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path) + "/client"
        c.queryItems = [URLQueryItem(name: "room", value: room)]
        return c.url
    }

    var displayAddress: String {
        if let host, !host.isEmpty { return "\(host):\(port)" }
        if hasRelay { return "via relay" }
        return "\(serviceName ?? name) (Bonjour)"
    }

    /// Parses `ccremote://pair?host=…&port=…&token=…&name=…&fp=…&tls=…` from the daemon's QR code.
    static func parse(pairURL: String) -> PairingInfo? {
        guard let components = URLComponents(string: pairURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "ccremote", components.host == "pair" else { return nil }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] { values[item.name] = item.value }
        guard let token = values["token"], !token.isEmpty else { return nil }
        let port = values["port"].flatMap { UInt16($0) } ?? 7811
        let name = values["name"] ?? values["host"] ?? "Mac"
        let useTLS = values["tls"] != "0"
        return PairingInfo(name: name, host: values["host"], port: port, serviceName: values["name"],
                           token: token, fingerprint: values["fp"], useTLS: useTLS,
                           relayURL: values["relay"], room: values["room"])
    }

    private static let defaultsKey = "ccremote.pairing"

    static func load() -> PairingInfo? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(PairingInfo.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: PairingInfo.defaultsKey) }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}
