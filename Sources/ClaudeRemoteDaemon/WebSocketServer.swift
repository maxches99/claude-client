#if os(macOS)
import Foundation
import Network
import ClaudeRemoteCore
import ClaudeCodeHost

/// Accepts phones over WebSocket on the LAN and hands each to a PhoneSession.
final class WebSocketServer: @unchecked Sendable {
    static let serviceType = "_ccremote._tcp"

    enum State: Equatable, Sendable {
        case starting
        case listening(port: UInt16)
        case failed(String)
        case stopped
    }

    private let port: UInt16
    private let tokenStore: TokenStore
    private let serviceName: String
    private let manager: SessionManager
    private let daemonVersion: String
    private let tls: TLSRole
    private let log: @Sendable (String) -> Void
    private let onAuthenticated: @Sendable (PhoneLink) -> Void
    private let onPhoneClosed: @Sendable (UUID) -> Void
    private let queue = DispatchQueue(label: "ccremote.server")
    private var listener: NWListener?
    private var sessions: [UUID: PhoneSession] = [:]
    private let lock = NSLock()

    /// Listener state changes, on the server queue.
    var onState: (@Sendable (State) -> Void)?

    init(port: UInt16, tokenStore: TokenStore, serviceName: String, manager: SessionManager, daemonVersion: String, tls: TLSRole = .none,
         log: @escaping @Sendable (String) -> Void,
         onAuthenticated: @escaping @Sendable (PhoneLink) -> Void = { _ in },
         onPhoneClosed: @escaping @Sendable (UUID) -> Void = { _ in }) {
        self.port = port
        self.tokenStore = tokenStore
        self.serviceName = serviceName
        self.manager = manager
        self.daemonVersion = daemonVersion
        self.tls = tls
        self.log = log
        self.onAuthenticated = onAuthenticated
        self.onPhoneClosed = onPhoneClosed
    }

    func start() throws {
        let listener = try NWListener(using: WebSocketChannel.parameters(tls: tls), on: NWEndpoint.Port(rawValue: port)!)
        listener.service = NWListener.Service(name: serviceName, type: WebSocketServer.serviceType)
        listener.stateUpdateHandler = { [weak self, log] state in
            switch state {
            case .ready:
                let p = listener.port?.rawValue ?? 0
                log("listening on port \(p)")
                self?.onState?(.listening(port: p))
            case .failed(let error):
                log("listener failed: \(error)")
                self?.onState?(.failed(WebSocketServer.describe(error)))
            case .cancelled:
                self?.onState?(.stopped)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        onState?(.starting)
        listener.start(queue: queue)
        self.listener = listener
    }

    /// Stops accepting and closes every phone connection.
    func stop() {
        listener?.cancel()
        listener = nil
        closeAll()
    }

    /// Drops every phone (they must re-authenticate — used on token rotation).
    func closeAll() {
        let open = lock.withLock { Array(sessions.values) }
        for s in open { s.close() }
    }

    /// "Address already in use" is the one people hit (another ccremote is running) — say so.
    static func describe(_ error: NWError) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return "Port is already in use — is another ccremote (or the LaunchAgent) running?"
        }
        return "\(error)"
    }

    private func accept(_ connection: NWConnection) {
        log("connection from \(connection.endpoint)")
        let channel = WebSocketChannel(connection: connection, queue: queue)
        let session = PhoneSession(channel: channel, route: .lan, remote: "\(connection.endpoint)", manager: manager, tokenStore: tokenStore,
                                   daemonVersion: daemonVersion, log: log,
                                   onAuthenticated: onAuthenticated,
                                   onClose: { [weak self] id in
                                       self?.lock.withLock { self?.sessions[id] = nil }
                                       self?.onPhoneClosed(id)
                                   })
        lock.withLock { sessions[session.id] = session }
        session.start()
    }
}
#endif
