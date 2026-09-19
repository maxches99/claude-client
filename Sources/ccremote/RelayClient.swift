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
    private let base: URL
    private let room: String
    private let secret: String
    private let fingerprint: String?
    private let manager: SessionManager
    private let token: String
    private let daemonVersion: String
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "ccremote.relay")

    private var control: WebSocketChannel?
    private var sessions: [UUID: PhoneSession] = [:]
    private let lock = NSLock()
    private var retryDelay: TimeInterval = 1
    private var running = true

    init(base: URL, room: String, secret: String, fingerprint: String?, manager: SessionManager,
         token: String, daemonVersion: String, log: @escaping @Sendable (String) -> Void) {
        self.base = base
        self.room = room
        self.secret = secret
        self.fingerprint = fingerprint
        self.manager = manager
        self.token = token
        self.daemonVersion = daemonVersion
        self.log = log
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
        control?.close()
        lock.withLock {
            for s in sessions.values { _ = s }
            sessions.removeAll()
        }
    }

    private func connectControl() {
        guard running else { return }
        let url = endpoint("agent", query: [.init(name: "room", value: room), .init(name: "secret", value: secret)])
        log("relay: connecting control → \(url.host ?? "?")")
        let connection = NWConnection(to: .url(url), using: WebSocketChannel.parameters(tls: tlsRole))
        let channel = WebSocketChannel(connection: connection, queue: queue)
        control = channel
        channel.onState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.retryDelay = 1
                self.log("relay: control connected (room \(self.room))")
            case .failed(let error):
                self.log("relay: control failed: \(error)")
                self.scheduleReconnect()
            case .cancelled:
                self.scheduleReconnect()
            case .waiting(let error):
                self.log("relay: waiting (\(error))")
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
        let session = PhoneSession(channel: channel, manager: manager, token: token, daemonVersion: daemonVersion, log: log,
                                   onClose: { [weak self] id in self?.lock.withLock { self?.sessions[id] = nil } })
        lock.withLock { sessions[session.id] = session }
        log("relay: bridging phone \(connId.prefix(8))")
        session.start()
    }
}
