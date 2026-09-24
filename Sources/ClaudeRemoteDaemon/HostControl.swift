#if os(macOS) || os(Linux)
import Foundation
import ClaudeRemoteCore

/// Updates a host to the newest release: the Mac app replaces its bundle, the hub its binary.
public protocol HostUpdater: AnyObject, Sendable {
    func check() async -> HostUpdate
    /// Downloads, installs and restarts; `progress` reports each step (and a failure).
    func update(progress: @escaping @Sendable (HostUpdate) -> Void) async
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
