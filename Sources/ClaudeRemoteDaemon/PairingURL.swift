#if os(macOS)
import Foundation

/// The `ccremote://pair?…` URL the phone scans: a direct route (LAN address + port + cert
/// fingerprint), the pairing token, and — when a relay is configured — the relay route.
public struct PairingURL: Equatable, Sendable {
    public var host: String
    public var port: UInt16
    public var token: String
    public var serviceName: String
    public var fingerprint: String?
    public var useTLS: Bool
    public var relayURL: String?
    public var room: String?

    public var scheme: String { useTLS ? "wss" : "ws" }

    public var url: URL {
        var components = URLComponents()
        components.scheme = "ccremote"
        components.host = "pair"
        var items = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "name", value: serviceName),
        ]
        if let fingerprint { items.append(URLQueryItem(name: "fp", value: fingerprint)) }
        if !useTLS { items.append(URLQueryItem(name: "tls", value: "0")) }
        if let relayURL, let room, !relayURL.isEmpty {
            items.append(URLQueryItem(name: "relay", value: relayURL))
            items.append(URLQueryItem(name: "room", value: room))
        }
        components.queryItems = items
        return components.url!
    }

    public var absoluteString: String { url.absoluteString }
}
#endif
