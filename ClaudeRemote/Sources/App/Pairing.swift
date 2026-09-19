import Foundation
import Network

/// How to reach one Mac's daemon, plus the shared secret and (for wss) the pinned cert.
struct PairingInfo: Codable, Equatable, Identifiable {
    /// The app's own stable id for this Mac — survives re-pairing (new token / IP / cert).
    var id: String = UUID().uuidString
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
    /// The Mac's name as it reported itself in `welcome`; until then the QR / Bonjour name stands in.
    var hostName: String?
    var lastConnectedAt: Date?

    var isBonjour: Bool { host?.isEmpty ?? true }
    var hasDirect: Bool { !(host?.isEmpty ?? true) || serviceName != nil }
    var hasRelay: Bool { !(relayURL?.isEmpty ?? true) && !(room?.isEmpty ?? true) }

    var scheme: String { useTLS ? "wss" : "ws" }

    /// What the Mac is called in the UI (switcher, title, settings): the name its daemon advertises
    /// (`--name`, defaulting to the Mac's own name) when we have it, else what it said in `welcome`,
    /// else whatever was typed at pairing (an address).
    var displayName: String {
        if let serviceName, !serviceName.isEmpty { return serviceName }
        return hostName ?? name
    }

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

    /// The routes the app can race for this Mac: "192.168.1.40:7811 + relay", "MacBook (Bonjour)", "relay".
    var routeSummary: String {
        var routes: [String] = []
        if let host, !host.isEmpty {
            routes.append("\(host):\(port)")
        } else if let serviceName, !serviceName.isEmpty {
            routes.append("\(serviceName) (Bonjour)")
        }
        if hasRelay { routes.append("relay") }
        return routes.isEmpty ? "no route" : routes.joined(separator: " + ")
    }

    /// Whether `other` points at the Mac this entry already describes, so re-scanning a QR after
    /// a token / IP / cert change updates the entry instead of adding a duplicate. The cert
    /// fingerprint and relay room are per-Mac; the Bonjour name and LAN address are the fallback.
    func isSameMac(as other: PairingInfo) -> Bool {
        if let a = fingerprint, let b = other.fingerprint, a == b { return true }
        if let a = room, let b = other.room, !a.isEmpty, a == b { return true }
        if let a = serviceName, let b = other.serviceName, !a.isEmpty, a == b { return true }
        if let a = host, let b = other.host, !a.isEmpty, a == b, port == other.port { return true }
        return false
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
}

extension PairingInfo {
    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, serviceName, token, fingerprint, useTLS, relayURL, room, hostName, lastConnectedAt
    }

    /// Tolerant of entries saved by earlier builds (no `id` / `hostName`); lives in an extension
    /// so the memberwise initializer stays available.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decode(String.self, forKey: .name)
        host = try c.decodeIfPresent(String.self, forKey: .host)
        port = try c.decode(UInt16.self, forKey: .port)
        serviceName = try c.decodeIfPresent(String.self, forKey: .serviceName)
        token = try c.decode(String.self, forKey: .token)
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint)
        useTLS = try c.decodeIfPresent(Bool.self, forKey: .useTLS) ?? true
        relayURL = try c.decodeIfPresent(String.self, forKey: .relayURL)
        room = try c.decodeIfPresent(String.self, forKey: .room)
        hostName = try c.decodeIfPresent(String.self, forKey: .hostName)
        lastConnectedAt = try c.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
    }
}

/// Every Mac this phone has paired with, and which one the app is currently showing.
struct PairedMacs: Codable {
    var macs: [PairingInfo] = []
    var activeId: String?

    private static let defaultsKey = "ccremote.pairings"
    /// Builds before multi-Mac stored a single PairingInfo here.
    private static let legacyKey = "ccremote.pairing"

    static func load() -> PairedMacs {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: defaultsKey), let saved = try? JSONDecoder().decode(PairedMacs.self, from: data) {
            return saved
        }
        // Migrate the single pairing of earlier builds into a one-entry list.
        if let data = defaults.data(forKey: legacyKey), let single = try? JSONDecoder().decode(PairingInfo.self, from: data) {
            let migrated = PairedMacs(macs: [single], activeId: single.id)
            migrated.save()
            defaults.removeObject(forKey: legacyKey)
            return migrated
        }
        return PairedMacs()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }
}
