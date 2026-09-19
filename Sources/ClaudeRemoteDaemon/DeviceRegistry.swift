#if os(macOS) || os(Linux)
import Foundation

/// How a phone reached the daemon.
public enum PhoneRoute: String, Codable, Equatable, Sendable {
    /// Accepted by the LAN listener (same network, or a mesh VPN).
    case lan
    /// Bridged through the relay.
    case relay

    public var label: String {
        switch self {
        case .lan: return "Local network"
        case .relay: return "Relay"
        }
    }
}

/// A phone that is connected and authenticated right now.
public struct PhoneLink: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// The `client` string from `hello` (e.g. "ios").
    public let client: String
    /// Device name sent by the app, when it sends one (e.g. "iPhone · iOS 26").
    public let device: String?
    /// Stable per-device id sent by the app, when it sends one.
    public let deviceId: String?
    public let route: PhoneRoute
    /// Remote endpoint as seen by the listener (LAN only).
    public let remote: String?
    public let since: Date

    public var displayName: String { device ?? client }

    public init(id: UUID, client: String, device: String?, deviceId: String?, route: PhoneRoute, remote: String?, since: Date = Date()) {
        self.id = id
        self.client = client
        self.device = device
        self.deviceId = deviceId
        self.route = route
        self.remote = remote
        self.since = since
    }
}

/// A phone that has paired (authenticated) at least once. Remembered across restarts so the
/// Mac can show "paired · last seen …" while the phone is away.
public struct PairedDevice: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var firstSeen: Date
    public var lastSeen: Date
    public var lastRoute: PhoneRoute
    public var connections: Int
    /// Refused at `hello` even with the right token — "forget this phone" without a new token for
    /// every other one. (The id is what the phone reports, so this keeps an old phone out, not an
    /// attacker with the token; rotate the token for that.)
    public var blocked: Bool

    public init(id: String, name: String, firstSeen: Date, lastSeen: Date, lastRoute: PhoneRoute, connections: Int, blocked: Bool = false) {
        self.id = id
        self.name = name
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.lastRoute = lastRoute
        self.connections = connections
        self.blocked = blocked
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        firstSeen = try c.decode(Date.self, forKey: .firstSeen)
        lastSeen = try c.decode(Date.self, forKey: .lastSeen)
        lastRoute = try c.decode(PhoneRoute.self, forKey: .lastRoute)
        connections = try c.decode(Int.self, forKey: .connections)
        blocked = try c.decodeIfPresent(Bool.self, forKey: .blocked) ?? false
    }
}

/// Persists `PairedDevice`s as `devices.json` in the support directory.
final class DeviceRegistry: @unchecked Sendable {
    private let path: String
    private let lock = NSLock()
    private var devices: [PairedDevice]

    init(directory: String) {
        path = directory + "/devices.json"
        if let data = FileManager.default.contents(atPath: path),
           let list = try? DeviceRegistry.decoder.decode([PairedDevice].self, from: data) {
            devices = list
        } else {
            devices = []
        }
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    var all: [PairedDevice] {
        lock.withLock { devices.sorted { $0.lastSeen > $1.lastSeen } }
    }

    /// Records an authenticated connection and returns the updated list.
    @discardableResult
    func recordConnection(_ link: PhoneLink, at date: Date = Date()) -> [PairedDevice] {
        let id = link.deviceId ?? "client:\(link.client)"
        return lock.withLock {
            if let i = devices.firstIndex(where: { $0.id == id }) {
                devices[i].name = link.displayName
                devices[i].lastSeen = date
                devices[i].lastRoute = link.route
                devices[i].connections += 1
            } else {
                devices.append(PairedDevice(id: id, name: link.displayName, firstSeen: date, lastSeen: date, lastRoute: link.route, connections: 1))
            }
            persist()
            return devices.sorted { $0.lastSeen > $1.lastSeen }
        }
    }

    /// Marks a device as seen now (on disconnect, so "last seen" covers the whole session).
    @discardableResult
    func touch(_ link: PhoneLink, at date: Date = Date()) -> [PairedDevice] {
        let id = link.deviceId ?? "client:\(link.client)"
        return lock.withLock {
            if let i = devices.firstIndex(where: { $0.id == id }) {
                devices[i].lastSeen = date
                persist()
            }
            return devices.sorted { $0.lastSeen > $1.lastSeen }
        }
    }

    var blockedIds: Set<String> {
        lock.withLock { Set(devices.filter(\.blocked).map(\.id)) }
    }

    @discardableResult
    func setBlocked(_ id: String, _ blocked: Bool) -> [PairedDevice] {
        lock.withLock {
            if let i = devices.firstIndex(where: { $0.id == id }) { devices[i].blocked = blocked; persist() }
            return devices.sorted { $0.lastSeen > $1.lastSeen }
        }
    }

    @discardableResult
    func remove(_ id: String) -> [PairedDevice] {
        lock.withLock {
            devices.removeAll { $0.id == id }
            persist()
            return devices.sorted { $0.lastSeen > $1.lastSeen }
        }
    }

    /// Forgets every paired device (used together with token rotation).
    func removeAll() {
        lock.withLock {
            devices = []
            persist()
        }
    }

    private func persist() {
        guard let data = try? DeviceRegistry.encoder.encode(devices) else { return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}
#endif
