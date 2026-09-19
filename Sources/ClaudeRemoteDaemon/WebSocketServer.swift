#if os(macOS) || os(Linux)
import Foundation
#if canImport(Network)
import Network
#endif
import ClaudeRemoteCore
import ClaudeCodeHost

/// Accepts phones over WebSocket on the LAN and hands each to a PhoneSession.
/// macOS listens with Network.framework and advertises over Bonjour; Linux listens with SwiftNIO.
final class WebSocketServer: @unchecked Sendable {
    static let serviceType = "_ccremote._tcp"

    enum State: Equatable, Sendable {
        case starting
        case listening(port: UInt16)
        case failed(String)
        case stopped
    }

    private let port: UInt16
    private let listenHost: String?
    private let tokenStore: TokenStore
    private let serviceName: String
    private let manager: SessionManager
    private let daemonVersion: String
    private let tls: TLSRole
    private let log: @Sendable (String) -> Void
    private let onAuthenticated: @Sendable (PhoneLink) -> Void
    private let onPhoneClosed: @Sendable (UUID) -> Void
    private let queue = DispatchQueue(label: "ccremote.server")
    #if canImport(Network)
    private var listener: NWListener?
    #else
    private var listener: NIOWebSocketListener?
    #endif
    private var sessions: [UUID: PhoneSession] = [:]
    private let lock = NSLock()

    /// Listener state changes, on the server queue.
    var onState: (@Sendable (State) -> Void)?

    init(port: UInt16, listenHost: String? = nil, tokenStore: TokenStore, serviceName: String, manager: SessionManager, daemonVersion: String,
         tls: TLSRole = .none,
         log: @escaping @Sendable (String) -> Void,
         onAuthenticated: @escaping @Sendable (PhoneLink) -> Void = { _ in },
         onPhoneClosed: @escaping @Sendable (UUID) -> Void = { _ in }) {
        self.port = port
        self.listenHost = listenHost
        self.tokenStore = tokenStore
        self.serviceName = serviceName
        self.manager = manager
        self.daemonVersion = daemonVersion
        self.tls = tls
        self.log = log
        self.onAuthenticated = onAuthenticated
        self.onPhoneClosed = onPhoneClosed
    }

    #if canImport(Network)
    func start() throws {
        let parameters = WebSocketChannel.parameters(tls: tls)
        if let listenHost, !listenHost.isEmpty {
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(listenHost), port: NWEndpoint.Port(rawValue: port)!)
        }
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
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
            guard let self else { return }
            self.accept(WebSocketChannel(connection: connection, queue: self.queue), remote: "\(connection.endpoint)")
        }
        onState?(.starting)
        listener.start(queue: queue)
        self.listener = listener
    }

    /// "Address already in use" is the one people hit (another ccremote is running) — say so.
    static func describe(_ error: NWError) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return "Port is already in use — is another ccremote (or the LaunchAgent) running?"
        }
        return "\(error)"
    }
    #else
    func start() throws {
        let listener = NIOWebSocketListener()
        onState?(.starting)
        listener.start(host: listenHost ?? "0.0.0.0", port: port) { [weak self] channel, remote in
            self?.accept(channel, remote: remote)
        }.whenComplete { [weak self, log] result in
            switch result {
            case .success(let p):
                log("listening on port \(p)")
                self?.onState?(.listening(port: p))
            case .failure(let error):
                log("listener failed: \(error)")
                self?.onState?(.failed(WebSocketServer.describe(error)))
            }
        }
        self.listener = listener
    }

    static func describe(_ error: Error) -> String {
        let text = "\(error)"
        if text.contains("EADDRINUSE") || text.contains("Address already in use") || text.contains("errno: 98") {
            return "Port is already in use — is another ccremote running?"
        }
        return text
    }
    #endif

    /// Stops accepting and closes every phone connection.
    func stop() {
        #if canImport(Network)
        listener?.cancel()
        #else
        listener?.stop()
        onState?(.stopped)
        #endif
        listener = nil
        closeAll()
    }

    /// Drops every phone (they must re-authenticate — used on token rotation).
    func closeAll() {
        let open = lock.withLock { Array(sessions.values) }
        for s in open { s.close() }
    }

    func close(phone id: UUID) {
        lock.withLock { sessions[id] }?.close()
    }

    private func accept(_ channel: WebSocketChannel, remote: String) {
        log("connection from \(remote)")
        let session = PhoneSession(channel: channel, route: .lan, remote: remote, manager: manager, tokenStore: tokenStore,
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
