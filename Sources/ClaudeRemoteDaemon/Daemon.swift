#if os(macOS) || os(Linux)
import Foundation
#if canImport(Network)
import Network
#endif
import ClaudeRemoteCore
import ClaudeCodeHost

/// What the daemon knows about the local `claude` CLI.
public struct ClaudeStatus: Equatable, Sendable {
    public var path: String
    public var version: String?
    /// `nil` while unknown (the check runs the CLI and takes a moment).
    public var loggedIn: Bool?
    public var email: String?
}

/// A snapshot of the running daemon for a UI or a status printout.
/// The Codex CLI next to Claude's, when installed.
public struct CodexStatus: Equatable, Sendable {
    public var path: String
    public var version: String?
    /// `~/.codex/auth.json` present — the desktop app and the CLI share it.
    public var loggedIn: Bool?
}

public struct DaemonStatus: Equatable, Sendable {
    public enum Listener: Equatable, Sendable {
        case stopped
        case starting
        case listening(port: UInt16)
        case failed(String)
    }

    public enum Relay: Equatable, Sendable {
        case off
        case connecting
        case connected
        case waiting(String)
        case failed(String)
    }

    public var listener: Listener = .stopped
    public var relay: Relay = .off
    /// Phones connected and authenticated right now.
    public var phones: [PhoneLink] = []
    /// Phones that have paired at least once, most recent first.
    public var paired: [PairedDevice] = []
    public var addresses: [NetworkAddress] = []
    public var pairing: PairingURL
    public var claude: ClaudeStatus
    public var codex: CodexStatus?

    public var isListening: Bool {
        if case .listening = listener { return true }
        return false
    }
}

public enum DaemonError: Error, CustomStringConvertible {
    case claudeNotFound
    case relaySecretMissing

    public var description: String {
        switch self {
        case .claudeNotFound: return "claude binary not found. Install Claude Code (or Claude Desktop), or set the path in the config."
        case .relaySecretMissing: return "A relay URL is configured without a relay secret."
        }
    }
}

/// The pairing token, shared by every component that checks it so rotation applies at once —
/// plus the device ids that are refused even with the right token.
final class TokenStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String
    private var blocked: Set<String> = []
    init(_ value: String) { self.value = value }
    var current: String {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
    var blockedDeviceIds: Set<String> {
        get { lock.withLock { blocked } }
        set { lock.withLock { blocked = newValue } }
    }
    func isBlocked(_ deviceId: String?) -> Bool {
        guard let deviceId else { return false }
        return lock.withLock { blocked.contains(deviceId) }
    }
}

/// The ccremote daemon as an object: builds everything from a `DaemonConfig`, runs the LAN
/// listener (+ Bonjour), the optional relay link and notifier, tracks phones, and publishes a
/// `DaemonStatus` whenever something changes. Hosted by the CLI and by the menu-bar app.
public final class Daemon: @unchecked Sendable {
    public static let version = "0.2.0"

    public let config: DaemonConfig
    public let supportDirectory: String
    public let cli: ClaudeCLI
    /// `nil` when no Codex CLI was found; sessions are Claude-only then.
    public let codex: CodexCLI?
    public let serviceName: String
    /// Effective transport: `false` when TLS was requested but the identity could not be set up.
    public let useTLS: Bool
    public let fingerprint: String?
    public let room: String?
    public let manager: SessionManager

    /// Status changes, delivered on an arbitrary queue. Coalesce/hop to the main thread in a UI.
    public var onStatus: (@Sendable (DaemonStatus) -> Void)? {
        get { lock.withLock { _onStatus } }
        set { lock.withLock { _onStatus = newValue } }
    }

    private let log: @Sendable (String) -> Void
    private let tokenStore: TokenStore
    #if os(macOS)
    private let tlsIdentity: TLSIdentity?
    #endif
    private let notifier: Notifier?
    private let registry: DeviceRegistry
    private var server: WebSocketServer?
    private var relay: RelayClient?
    #if os(macOS)
    private var hooks: HookServer?
    #endif
    #if canImport(Network)
    private var pathMonitor: NWPathMonitor?
    #endif
    private let monitorQueue = DispatchQueue(label: "ccremote.daemon.path")
    private let lock = NSLock()
    private var _status: DaemonStatus
    private var _onStatus: (@Sendable (DaemonStatus) -> Void)?
    private var started = false

    /// Prepares the daemon: locates `claude`, loads/creates the token, TLS identity and relay room.
    /// Nothing listens until `start()`.
    public init(config: DaemonConfig, tokenOverride: String? = nil, rotateToken: Bool = false,
                supportDirectory: String = DaemonConfig.supportDirectory,
                log: @escaping @Sendable (String) -> Void = { _ in }) throws {
        self.config = config
        self.supportDirectory = supportDirectory
        self.log = log

        if let p = config.claudePath, !p.isEmpty {
            cli = ClaudeCLI(path: p)
        } else if let found = ClaudeCLI.locate() {
            cli = found
        } else {
            throw DaemonError.claudeNotFound
        }

        if let p = config.codexPath, !p.isEmpty {
            codex = CodexCLI(path: p)
        } else {
            codex = CodexCLI.locate()
        }

        try? FileManager.default.createDirectory(atPath: supportDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        tokenStore = TokenStore(Daemon.loadOrCreateToken(directory: supportDirectory, override: tokenOverride, rotate: rotateToken))
        serviceName = config.serviceName.flatMap { $0.isEmpty ? nil : $0 } ?? HostPaths.machineName

        #if os(macOS)
        var tls: TLSIdentity?
        if config.useTLS {
            do {
                tls = try TLSIdentity.loadOrCreate(directory: supportDirectory)
            } catch {
                log("TLS setup failed (\(error)); falling back to plain ws://.")
            }
        }
        tlsIdentity = tls
        useTLS = tls != nil
        fingerprint = tls?.fingerprint
        #else
        // The Linux build serves plain ws:// — put it behind a relay on the same host or a mesh VPN.
        if config.useTLS { log("TLS is not available in the Linux build; serving plain ws://.") }
        useTLS = false
        fingerprint = nil
        #endif

        if config.relayEnabled {
            guard let s = config.relaySecret, !s.isEmpty else { throw DaemonError.relaySecretMissing }
            room = config.relayRoom.flatMap { $0.isEmpty ? nil : $0 } ?? Daemon.loadOrCreateRoom(directory: supportDirectory)
        } else {
            room = nil
        }

        let notifierConfig = config.notifierConfig
        notifier = notifierConfig.isEnabled ? Notifier(config: notifierConfig, log: log) : nil
        registry = DeviceRegistry(directory: supportDirectory)
        tokenStore.blockedDeviceIds = registry.blockedIds
        var livePusher: LiveActivityPusher?
        if let pushConfig = config.livePushConfig {
            do {
                livePusher = try LiveActivityPusher(config: pushConfig, log: log)
                log("live activity push: on (\(pushConfig.sandbox ? "sandbox" : "production"), key \(pushConfig.keyId))")
            } catch {
                log("live activity push: off — cannot load APNs key \(pushConfig.keyPath): \(error)")
            }
        }
        let codexBackend = codex.map { CodexBackend(cli: $0, listenPort: config.codexPort, log: log) }
        manager = SessionManager(cli: cli, codex: codexBackend, notifier: notifier, livePusher: livePusher,
                                 approvalLog: SessionManager.approvalLogPath(supportDirectory: supportDirectory), log: log)
        if let minutes = config.idleTimeoutMinutes, minutes > 0 {
            Task { [manager] in await manager.setIdleTimeout(TimeInterval(minutes * 60)) }
        }
        #if os(macOS)
        SimulatorStreamer.log = log
        SimulatorInput.log = log
        #endif

        let addresses = NetworkInfo.lanAddresses()
        _status = DaemonStatus(paired: registry.all, addresses: addresses,
                               pairing: Daemon.makePairing(config: config, token: tokenStore.current, serviceName: serviceName, useTLS: useTLS,
                                                           fingerprint: fingerprint, room: room, addresses: addresses),
                               claude: ClaudeStatus(path: cli.path), codex: codex.map { CodexStatus(path: $0.path) })
    }

    // MARK: state

    public var status: DaemonStatus { lock.withLock { _status } }
    public var token: String { tokenStore.current }
    public var pairing: PairingURL { status.pairing }

    /// Names of the enabled notification channels, for display.
    public var notificationChannels: [String] {
        var channels: [String] = []
        if config.notifierConfig.ntfyURL != nil { channels.append("ntfy") }
        if config.notifierConfig.telegramToken != nil && config.notifierConfig.telegramChatID != nil { channels.append("Telegram") }
        return channels
    }

    private func update(_ change: (inout DaemonStatus) -> Void) {
        let (snapshot, handler): (DaemonStatus, (@Sendable (DaemonStatus) -> Void)?) = lock.withLock {
            change(&_status)
            return (_status, _onStatus)
        }
        handler?(snapshot)
    }

    private static func makePairing(config: DaemonConfig, token: String, serviceName: String, useTLS: Bool, fingerprint: String?,
                                    room: String?, addresses: [NetworkAddress]) -> PairingURL {
        PairingURL(host: addresses.first?.address ?? "127.0.0.1", port: config.port, token: token, serviceName: serviceName,
                   fingerprint: fingerprint, useTLS: useTLS, relayURL: config.relayEnabled ? config.relayURLForPhones : nil, room: room)
    }

    private func refreshPairing() {
        let addresses = NetworkInfo.lanAddresses()
        update { s in
            s.addresses = addresses
            s.pairing = Daemon.makePairing(config: config, token: tokenStore.current, serviceName: serviceName, useTLS: useTLS,
                                           fingerprint: fingerprint, room: room, addresses: addresses)
        }
    }

    // MARK: lifecycle

    public func start() throws {
        guard lock.withLock({ !started }) else { return }
        lock.withLock { started = true }

        #if os(macOS)
        let serverTLS: TLSRole = tlsIdentity.map { .server(identity: $0.identity) } ?? .none
        #else
        let serverTLS: TLSRole = .none
        #endif
        let server = WebSocketServer(port: config.port, listenHost: config.listenHost, tokenStore: tokenStore, serviceName: serviceName, manager: manager,
                                     daemonVersion: Daemon.version, tls: serverTLS, log: log,
                                     onAuthenticated: { [weak self] link in self?.phoneAuthenticated(link) },
                                     onPhoneClosed: { [weak self] id in self?.phoneClosed(id) })
        server.onState = { [weak self] state in
            guard let self else { return }
            self.update { s in
                switch state {
                case .starting: s.listener = .starting
                case .listening(let port): s.listener = .listening(port: port)
                case .failed(let why): s.listener = .failed(why)
                case .stopped: s.listener = .stopped
                }
            }
            // The relay follows the listener: register with the relay only once this instance
            // owns the port, and drop it if the port is taken — another ccremote owns this Mac
            // and would otherwise be kicked out of the relay room by us every few seconds.
            switch state {
            case .listening: self.startRelayIfNeeded()
            case .failed: self.stopRelay()
            default: break
            }
        }
        self.server = server
        try server.start()

        #if os(macOS)
        // Permission prompts of Desktop / terminal sessions arrive here when the hook is installed.
        let hooks = HookServer(path: ClaudeHooks.socketPath(supportDirectory: supportDirectory), manager: manager, log: log)
        hooks.start()
        self.hooks = hooks
        #endif

        #if canImport(Network)
        // Re-derive the LAN address (and the pairing URL) when the network changes.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in self?.refreshPairing() }
        monitor.start(queue: monitorQueue)
        pathMonitor = monitor
        #endif

        writePairingImage()
        refreshClaudeStatusInBackground()
        // A shared Codex server must be up before the Codex app looks for it.
        if config.codexPort != nil { Task { await manager.warmUpCodex() } }
    }

    private func startRelayIfNeeded() {
        guard config.relayEnabled, let relayURLString = config.relayURL, let relayURL = URL(string: relayURLString),
              let room, let secret = config.relaySecret else { return }
        guard lock.withLock({ relay == nil && started }) else { return }
        let client = RelayClient(base: relayURL, room: room, secret: secret, fingerprint: config.relayFingerprint,
                                 manager: manager, tokenStore: tokenStore, daemonVersion: Daemon.version, log: log,
                                 onAuthenticated: { [weak self] link in self?.phoneAuthenticated(link) },
                                 onPhoneClosed: { [weak self] id in self?.phoneClosed(id) })
        client.onState = { [weak self] state in
            self?.update { s in
                switch state {
                case .connecting: s.relay = .connecting
                case .connected: s.relay = .connected
                case .waiting(let why): s.relay = .waiting(why)
                case .failed(let why): s.relay = .failed(why)
                case .stopped: s.relay = .off
                }
            }
        }
        let raced: Bool = lock.withLock {
            if relay != nil { return true }
            relay = client
            return false
        }
        if !raced { client.start() }
    }

    private func stopRelay() {
        let client: RelayClient? = lock.withLock {
            defer { relay = nil }
            return relay
        }
        client?.stop()
    }

    /// Stops listening, drops phones, ends hosted CLI sessions (transcripts stay on disk).
    public func stop() async {
        lock.withLock { started = false }   // a late listener callback must not start the relay again
        #if canImport(Network)
        pathMonitor?.cancel()
        pathMonitor = nil
        #endif
        stopRelay()
        server?.stop()
        server = nil
        #if os(macOS)
        hooks?.stop()
        hooks = nil
        #endif
        await manager.shutdown()
        update { s in
            s.listener = .stopped
            s.relay = .off
            s.phones = []
        }
    }

    // MARK: phones

    private func phoneAuthenticated(_ link: PhoneLink) {
        let paired = registry.recordConnection(link)
        update { s in
            s.phones.removeAll { $0.id == link.id }
            s.phones.append(link)
            s.paired = paired
        }
    }

    private func phoneClosed(_ id: UUID) {
        let link = lock.withLock { _status.phones.first { $0.id == id } }
        let paired = link.map { registry.touch($0) }
        update { s in
            s.phones.removeAll { $0.id == id }
            if let paired { s.paired = paired }
        }
    }

    /// Blocks (or unblocks) a paired phone by its device id; a blocked phone that is connected is
    /// dropped and refused at its next `hello`.
    public func setDeviceBlocked(_ deviceId: String, _ blocked: Bool) {
        let paired = registry.setBlocked(deviceId, blocked)
        tokenStore.blockedDeviceIds = registry.blockedIds
        if blocked {
            let links = lock.withLock { _status.phones.filter { ($0.deviceId ?? "client:\($0.client)") == deviceId } }
            for link in links {
                server?.close(phone: link.id)
                lock.withLock { relay }?.close(phone: link.id)
            }
            log("device \(deviceId.prefix(8)) blocked (\(links.count) connection(s) dropped)")
        }
        update { s in s.paired = paired }
    }

    /// Drops a phone from the paired list (it may pair again with the token).
    public func forgetDevice(_ deviceId: String) {
        let paired = registry.remove(deviceId)
        tokenStore.blockedDeviceIds = registry.blockedIds
        update { s in s.paired = paired }
    }

    /// Where every decision made from a phone is recorded, one JSON line each.
    public var approvalLogPath: String { SessionManager.approvalLogPath(supportDirectory: supportDirectory) }

    // MARK: pairing token

    /// Generates a new token: current phones are disconnected and every saved pairing is
    /// forgotten — each phone must scan the new QR.
    public func rotateToken() {
        let fresh = Daemon.loadOrCreateToken(directory: supportDirectory, override: nil, rotate: true)
        tokenStore.current = fresh
        registry.removeAll()
        let open = lock.withLock { _status.phones }
        server?.closeAll()
        lock.withLock { relay }?.closeAll()
        log("pairing token rotated (\(open.count) phone(s) disconnected)")
        update { s in
            s.phones = []
            s.paired = []
        }
        refreshPairing()
        writePairingImage()
    }

    private static func loadOrCreateToken(directory: String, override: String?, rotate: Bool) -> String {
        if let override, !override.isEmpty { return override }
        let fm = FileManager.default
        let path = directory + "/token"
        if !rotate, let data = fm.contents(atPath: path),
           let t = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), t.count >= 16 {
            return t
        }
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let bytes = (0..<16).map { _ in UInt8.random(in: 0...255, using: &SecureRandom.generator) }
        let t = bytes.map { String(format: "%02x", $0) }.joined()
        fm.createFile(atPath: path, contents: Data(t.utf8), attributes: [.posixPermissions: 0o600])
        return t
    }

    /// A stable room id per Mac (so the pairing URL stays valid across restarts).
    private static func loadOrCreateRoom(directory: String) -> String {
        let path = directory + "/relay-room"
        let fm = FileManager.default
        if let data = fm.contents(atPath: path), let r = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty {
            return r
        }
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let bytes = (0..<8).map { _ in UInt8.random(in: 0...255, using: &SecureRandom.generator) }
        let r = bytes.map { String(format: "%02x", $0) }.joined()
        fm.createFile(atPath: path, contents: Data(r.utf8), attributes: [.posixPermissions: 0o600])
        return r
    }

    /// Path of the scannable QR PNG the daemon keeps up to date in the support directory.
    public var pairingImagePath: String { supportDirectory + "/pairing-qr.png" }

    @discardableResult
    public func writePairingImage() -> Bool {
        let ok = QRImage.write(pairing.absoluteString, to: pairingImagePath)
        if ok { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pairingImagePath) }
        return ok
    }

    // MARK: claude

    /// The command that logs the CLI in (Claude Desktop feeds credentials to its bundled CLI
    /// itself, so a standalone launch needs this once).
    public var loginCommand: String { "\"\(cli.path)\" auth login" }

    /// Runs `claude --version` / `claude auth status` off the calling thread and publishes the result.
    public func refreshClaudeStatusInBackground() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let version = self.cli.version()
            let auth = self.cli.authStatus()
            let codexVersion = self.codex?.version()
            Task { await self.manager.refreshAuth() }
            self.update { s in
                s.claude = ClaudeStatus(path: self.cli.path, version: version, loggedIn: auth?.loggedIn ?? false, email: auth?.email)
                s.codex = self.codex.map { CodexStatus(path: $0.path, version: codexVersion, loggedIn: CodexCLI.hasCredentials()) }
            }
        }
    }
}
#endif
