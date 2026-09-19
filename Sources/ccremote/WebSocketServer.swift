import Foundation
import Network
import ClaudeRemoteCore
import ClaudeCodeHost

/// Accepts phones over WebSocket on the LAN and hands each to a PhoneSession.
final class WebSocketServer: @unchecked Sendable {
    static let serviceType = "_ccremote._tcp"

    private let port: UInt16
    private let token: String
    private let serviceName: String
    private let manager: SessionManager
    private let daemonVersion: String
    private let tls: TLSRole
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "ccremote.server")
    private var listener: NWListener?
    private var sessions: [UUID: PhoneSession] = [:]
    private let lock = NSLock()

    init(port: UInt16, token: String, serviceName: String, manager: SessionManager, daemonVersion: String, tls: TLSRole = .none, log: @escaping @Sendable (String) -> Void) {
        self.port = port
        self.token = token
        self.serviceName = serviceName
        self.manager = manager
        self.daemonVersion = daemonVersion
        self.tls = tls
        self.log = log
    }

    func start() throws {
        let listener = try NWListener(using: WebSocketChannel.parameters(tls: tls), on: NWEndpoint.Port(rawValue: port)!)
        listener.service = NWListener.Service(name: serviceName, type: WebSocketServer.serviceType)
        listener.stateUpdateHandler = { [log] state in
            switch state {
            case .ready: log("listening on port \(listener.port?.rawValue ?? 0)")
            case .failed(let error): log("listener failed: \(error)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        log("connection from \(connection.endpoint)")
        let channel = WebSocketChannel(connection: connection, queue: queue)
        let session = PhoneSession(channel: channel, manager: manager, token: token, daemonVersion: daemonVersion, log: log,
                                   onClose: { [weak self] id in self?.lock.withLock { self?.sessions[id] = nil } })
        lock.withLock { sessions[session.id] = session }
        session.start()
    }
}
