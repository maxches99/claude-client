import Foundation
import Network

/// How to reach the daemon, plus the shared secret.
struct PairingInfo: Codable, Equatable {
    var name: String
    var host: String?
    var port: UInt16
    var serviceName: String?
    var token: String

    var isBonjour: Bool { host?.isEmpty ?? true }

    var serviceEndpoint: NWEndpoint {
        .service(name: serviceName ?? name, type: "_ccremote._tcp", domain: "local.", interface: nil)
    }

    /// `ws://host:port/` for a direct address. Bonjour pairings are resolved first (see HostConnection).
    var directURL: URL? {
        guard let host, !host.isEmpty else { return nil }
        return PairingInfo.webSocketURL(host: host, port: port)
    }

    static func webSocketURL(host: String, port: UInt16) -> URL? {
        var h = host
        if h.contains(":") { h = "[" + h.replacingOccurrences(of: "%", with: "%25") + "]" }
        return URL(string: "ws://\(h):\(port)/")
    }

    var displayAddress: String {
        if let host, !host.isEmpty { return "\(host):\(port)" }
        return "\(serviceName ?? name) (Bonjour)"
    }

    /// Parses `ccremote://pair?host=…&port=…&token=…&name=…` from the daemon's QR code.
    static func parse(pairURL: String) -> PairingInfo? {
        guard let components = URLComponents(string: pairURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "ccremote", components.host == "pair" else { return nil }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] { values[item.name] = item.value }
        guard let token = values["token"], !token.isEmpty else { return nil }
        let port = values["port"].flatMap { UInt16($0) } ?? 7811
        let name = values["name"] ?? values["host"] ?? "Mac"
        return PairingInfo(name: name, host: values["host"], port: port, serviceName: values["name"], token: token)
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
