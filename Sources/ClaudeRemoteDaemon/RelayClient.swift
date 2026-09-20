#if os(macOS)
import Foundation
import Network
import ClaudeRemoteCore
import ClaudeCodeHost

/// Reaches phones that aren't on the LAN by dialing OUT to a relay you run (e.g. on a VPS).
///
/// The daemon keeps one control connection to `<relay>/agent`. When a phone connects to
/// `<relay>/client`, the relay signals `{"t":"new","conn":"<id>"}`; the daemon dials
/// `<relay>/agent-conn?conn=<id>`, the relay glues that to the phone's socket, and the daemon
/// runs a normal PhoneSession over it. The pairing token still authenticates the phone to the
/// daemon end-to-end; the relay only forwards frames (it can read them, so run your own).
final class RelayClient: @unchecked Sendable {
    enum State: Equatable, Sendable {
        case connecting
        case connected
        case waiting(String)
        case failed(String)
        case stopped
    }

    private let base: URL
    private let room: String
    private let secret: String
    private let fingerprint: String?
    private let manager: SessionManager
    private let tokenStore: TokenStore
    private let daemonVersion: String
    private let log: @Sendable (String) -> Void
    private let onAuthenticated: @Sendable (PhoneLink) -> Void
    private let onPhoneClosed: @Sendable (UUID) -> Void
    private let queue = DispatchQueue(label: "ccremote.relay")

    private var control: WebSocketChannel?
    private var sessions: [UUID: PhoneSession] = [:]
    private let lock = NSLock()
    private var retryDelay: TimeInterval = 1
    private var running = true
    private var keepalive: DispatchSourceTimer?

    /// Control-link state changes, on the relay queue.
    var onState: (@Sendable (State) -> Void)?

    init(base: URL, room: String, secret: String, fingerprint: String?, manager: SessionManager,
         tokenStore: TokenStore, daemonVersion: String, log: @escaping @Sendable (String) -> Void,
         onAuthenticated: @escaping @Sendable (PhoneLink) -> Void = { _ in },
         onPhoneClosed: @escaping @Sendable (UUID) -> Void = { _ in }) {
        self.base = base
        self.room = room
        self.secret = secret
        self.fingerprint = fingerprint
        self.manager = manager
        self.tokenStore = tokenStore
        self.daemonVersion = daemonVersion
        self.log = log
        self.onAuthenticated = onAuthenticated
        self.onPhoneClosed = onPhoneClosed
    }

    private var tlsRole: TLSRole {
        guard base.scheme == "wss" else { return .none }
        if let fingerprint { return .clientPinned(expected: fingerprint, learned: nil) }
        return .clientDefault
    }

    private func endpoint(_ path: String, query: [URLQueryItem]) -> URL {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        c.queryItems = query
        return c.url!
    }

    func start() {
        connectControl()
    }

    func stop() {
        running = false
        keepalive?.cancel(); keepalive = nil
        control?.close()
        closeAll()
        onState?(.stopped)
    }

    /// Drops every bridged phone (they must re-authenticate — used on token rotation).
    func closeAll() {
        let open = lock.withLock { Array(sessions.values) }
        for s in open { s.close() }
    }

    func close(phone id: UUID) {
        lock.withLock { sessions[id] }?.close()
    }

    /// Keeps the idle control connection warm so a reverse proxy (Caddy) doesn't drop it.
    private func startKeepalive() {
        keepalive?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 45, repeating: 45)
        timer.setEventHandler { [weak self] in
            self?.control?.send(text: "{\"t\":\"ping\"}")
        }
        timer.resume()
        keepalive = timer
    }

    private func connectControl() {
        guard running else { return }
        let url = endpoint("agent", query: [.init(name: "room", value: room), .init(name: "secret", value: secret)])
        log("relay: connecting control → \(url.host ?? "?")")
        onState?(.connecting)
        let connection = NWConnection(to: .url(url), using: WebSocketChannel.parameters(tls: tlsRole))
        let channel = WebSocketChannel(connection: connection, queue: queue)
        control = channel
        channel.onState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.retryDelay = 1
                self.log("relay: control connected (room \(self.room))")
                self.onState?(.connected)
                self.startKeepalive()
            case .failed(let error):
                self.log("relay: control failed: \(error)")
                self.keepalive?.cancel(); self.keepalive = nil
                if self.running { self.onState?(.failed("\(error)")) }
                self.scheduleReconnect()
            case .cancelled:
                self.keepalive?.cancel(); self.keepalive = nil
                if self.running { self.onState?(.connecting) }
                self.scheduleReconnect()
            case .waiting(let error):
                self.log("relay: waiting (\(error))")
                self.onState?(.waiting("\(error)"))
            default:
                break
            }
        }
        channel.onText = { [weak self] text in self?.handleControl(text) }
        channel.start()
    }

    private func scheduleReconnect() {
        guard running else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 15)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.running else { return }
            self.connectControl()
        }
    }

    private func handleControl(_ text: String) {
        guard let data = text.data(using: .utf8), let obj = try? JSONValue.parse(data), obj["t"]?.string == "new",
              let connId = obj["conn"]?.string else { return }
        openBridge(connId: connId)
    }

    private func openBridge(connId: String) {
        let url = endpoint("agent-conn", query: [.init(name: "room", value: room), .init(name: "secret", value: secret), .init(name: "conn", value: connId)])
        let connection = NWConnection(to: .url(url), using: WebSocketChannel.parameters(tls: tlsRole))
        let channel = WebSocketChannel(connection: connection, queue: queue)
        let session = PhoneSession(channel: channel, route: .relay, remote: nil, manager: manager, tokenStore: tokenStore, daemonVersion: daemonVersion, log: log,
                                   onAuthenticated: onAuthenticated,
                                   onClose: { [weak self] id in
                                       self?.lock.withLock { self?.sessions[id] = nil }
                                       self?.onPhoneClosed(id)
                                   })
        lock.withLock { sessions[session.id] = session }
        log("relay: bridging phone \(connId.prefix(8))")
        session.start()
    }
}
#endif
