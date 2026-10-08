#if os(macOS) || os(Linux)
import Foundation
import ClaudeRemoteCore
import ClaudeCodeHost

/// Updates a host to the newest release: the Mac app replaces its bundle, the hub its binary.
public protocol HostUpdater: AnyObject, Sendable {
    func check() async -> HostUpdate
    /// Downloads, installs and restarts; `progress` reports each step (and a failure).
    func update(progress: @escaping @Sendable (HostUpdate) -> Void) async
}

/// A member of the host as kept in `users.json` (the owner is the host's own pairing token, not in here).
struct StoredUser: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var token: String
    var createdAt: Date
    var lastSeenAt: Date?
    /// Their own `claude setup-token` token: their Claude sessions run on their account.
    var claudeToken: String?

    var public_: HostUser { HostUser(id: id, name: name, isOwner: false, createdAt: createdAt, lastSeenAt: lastSeenAt, ownClaudeLogin: claudeToken?.isEmpty == false) }
    var access: MemberAccess { MemberAccess(id: id, name: name, claudeToken: claudeToken) }
}

/// What phones may change about the host itself, beyond its sessions: the relay it joins and the
/// version it runs. The daemon configures it; phone sessions call it.
public final class HostControl: @unchecked Sendable {
    public static let shared = HostControl()

    private let lock = NSLock()
    private var _relay: RelaySetup?
    private var _supportDirectory: String?
    private var _restart: (@Sendable () -> Void)?
    private var _updater: HostUpdater?

    /// Set by the daemon when it starts.
    func configure(relay: RelaySetup?, supportDirectory: String, restart: (@Sendable () -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        _relay = relay
        _supportDirectory = supportDirectory
        _restart = restart
    }

    // MARK: people

    private var _users: [StoredUser] = []
    private var _pairingURL: (@Sendable (String) -> String)?
    private var _onMembers: (@Sendable ([MemberAccess]) -> Void)?

    /// Loads `users.json` and says how to build a member's pairing link and whom to tell about changes.
    func configureUsers(pairingURL: @escaping @Sendable (String) -> String, onMembers: @escaping @Sendable ([MemberAccess]) -> Void) {
        lock.lock()
        _pairingURL = pairingURL
        _onMembers = onMembers
        if let dir = _supportDirectory, let data = FileManager.default.contents(atPath: dir + "/users.json"),
           let stored = try? ProtocolCoding.decoder.decode([StoredUser].self, from: data) {
            _users = stored
        }
        let members = _users.map(\.access)
        lock.unlock()
        onMembers(members)
    }

    private func saveUsers() {
        guard let dir = _supportDirectory, let data = try? ProtocolCoding.encoder.encode(_users) else { return }
        let path = dir + "/users.json"
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        chmod(path, 0o600)
    }

    private func changed() {
        let members = _users.map(\.access), notify = _onMembers
        lock.unlock()
        notify?(members)
        lock.lock()
    }

    /// The member a pairing token belongs to (nil = not a member's).
    func member(forToken token: String) -> StoredUser? {
        lock.withLock { _users.first { $0.token == token } }
    }

    /// Every member's token, for the end-to-end handshake (which is keyed by the pairing token).
    var memberTokens: [String] { lock.withLock { _users.map(\.token) } }

    var users: [HostUser] { lock.withLock { _users.map(\.public_) } }

    func invite(name: String) -> (HostUser, String)? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let token = Daemon.newToken()
        let user = StoredUser(id: UUID().uuidString.lowercased(), name: trimmed, token: token, createdAt: Date())
        lock.lock()
        _users.append(user)
        saveUsers()
        let url = _pairingURL?(token) ?? ""
        changed()
        lock.unlock()
        return (user.public_, url)
    }

    func remove(userId: String) {
        lock.lock()
        _users.removeAll { $0.id == userId }
        saveUsers()
        changed()
        lock.unlock()
    }

    func setClaudeToken(userId: String, token: String?) {
        lock.lock()
        if let i = _users.firstIndex(where: { $0.id == userId }) {
            _users[i].claudeToken = token.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            saveUsers()
        }
        changed()
        lock.unlock()
    }

    func touch(userId: String) {
        lock.lock()
        if let i = _users.firstIndex(where: { $0.id == userId }) {
            _users[i].lastSeenAt = Date()
            saveUsers()
        }
        lock.unlock()
    }

    public var updater: HostUpdater? {
        get { lock.lock(); defer { lock.unlock() }; return _updater }
        set { lock.lock(); _updater = newValue; lock.unlock() }
    }

    /// The relay this host is on, to hand to another Mac.
    var relaySetup: RelaySetup? {
        lock.lock(); defer { lock.unlock() }
        return _relay
    }

    public enum RelayError: Error, CustomStringConvertible {
        case noConfig, needsRestart
        public var description: String {
            switch self {
            case .noConfig: return "This host has no settings file to write the relay into."
            case .needsRestart: return "Saved. Restart ccremote to join the relay."
            }
        }
    }

    /// Saves the relay into `config.json` and restarts the daemon into it (the Mac app does). A CLI
    /// daemon without a restart hook keeps running on the old settings and says so.
    func setRelay(_ setup: RelaySetup) throws {
        lock.lock()
        let dir = _supportDirectory, restart = _restart
        lock.unlock()
        guard let dir else { throw RelayError.noConfig }
        var config = DaemonConfig.load(directory: dir)
        config.relayURL = setup.url
        config.relaySecret = setup.secret
        try config.save(directory: dir)
        guard let restart else { throw RelayError.needsRestart }
        // Let the answer reach the phone before the connection goes down with the daemon.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { restart() }
    }
}
#endif
