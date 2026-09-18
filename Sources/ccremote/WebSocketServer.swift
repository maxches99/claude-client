import Foundation
import Network
import ClaudeRemoteCore
import ClaudeCodeHost

/// Accepts phones over WebSocket, checks the pairing token, and routes messages to the SessionManager.
final class WebSocketServer: @unchecked Sendable {
    static let serviceType = "_ccremote._tcp"

    private let port: UInt16
    private let token: String
    private let serviceName: String
    private let manager: SessionManager
    private let daemonVersion: String
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "ccremote.server")
    private var listener: NWListener?
    private var clients: [UUID: Client] = [:]
    private let lock = NSLock()

    init(port: UInt16, token: String, serviceName: String, manager: SessionManager, daemonVersion: String, log: @escaping @Sendable (String) -> Void) {
        self.port = port
        self.token = token
        self.serviceName = serviceName
        self.manager = manager
        self.daemonVersion = daemonVersion
        self.log = log
    }

    func start() throws {
        let listener = try NWListener(using: WebSocketChannel.parameters(), on: NWEndpoint.Port(rawValue: port)!)
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
        let id = UUID()
        let client = Client(id: id, channel: WebSocketChannel(connection: connection, queue: queue), server: self)
        lock.withLock { clients[id] = client }
        log("connection from \(connection.endpoint)")
        client.start()
    }

    fileprivate func remove(_ id: UUID) {
        lock.withLock { clients[id] = nil }
        Task { await manager.unsubscribe(id) }
    }

    // MARK: per-client

    final class Client: @unchecked Sendable {
        let id: UUID
        let channel: WebSocketChannel
        unowned let server: WebSocketServer
        private var authenticated = false
        private let name: String = "phone"

        init(id: UUID, channel: WebSocketChannel, server: WebSocketServer) {
            self.id = id
            self.channel = channel
            self.server = server
        }

        func start() {
            channel.onState = { [weak self] state in
                guard let self else { return }
                switch state {
                case .failed, .cancelled:
                    self.server.log("client \(self.id.uuidString.prefix(8)) gone (\(state))")
                    self.server.remove(self.id)
                default:
                    break
                }
            }
            channel.onText = { [weak self] text in
                self?.handle(text)
            }
            channel.start()
        }

        func send(_ message: ServerMessage) {
            guard let text = try? ProtocolCoding.encode(message) else { return }
            channel.send(text: text)
        }

        private func handle(_ text: String) {
            let message: ClientMessage
            do {
                message = try ProtocolCoding.decode(ClientMessage.self, from: text)
            } catch {
                send(.error(message: "Malformed message: \(error)", sessionId: nil))
                return
            }
            guard authenticated else {
                if case .hello(let token, let client) = message, token == server.token {
                    authenticated = true
                    server.log("client \(id.uuidString.prefix(8)) authenticated (\(client))")
                    let manager = server.manager, id = id, version = server.daemonVersion
                    Task { [weak self] in
                        guard let self else { return }
                        await manager.subscribe(id) { [weak self] msg in self?.send(msg) }
                        let info = await manager.hostInfo(daemonVersion: version)
                        self.send(.welcome(host: info))
                        self.send(.sessions(items: await manager.listSessions()))
                    }
                } else {
                    server.log("client \(id.uuidString.prefix(8)) rejected: bad token")
                    send(.error(message: "Not paired: wrong token", sessionId: nil))
                    channel.close()
                }
                return
            }
            let manager = server.manager
            Task { [weak self] in
                guard let self else { return }
                await self.dispatch(message, manager: manager)
            }
        }

        private func dispatch(_ message: ClientMessage, manager: SessionManager) async {
            do {
                switch message {
                case .hello:
                    break
                case .ping:
                    send(.pong)
                case .listSessions:
                    send(.sessions(items: await manager.listSessions()))
                case .listProjects:
                    send(.projects(items: await manager.listProjects()))
                case .open(let sessionId):
                    try await manager.open(sessionId: sessionId) { [weak self] msg in self?.send(msg) }
                case .create(let options):
                    let state = try await manager.create(options)
                    send(.history(sessionId: state.id, entries: []))
                    send(.state(state: state))
                case .fork(let sessionId):
                    let state = try await manager.fork(sessionId: sessionId)
                    try await manager.open(sessionId: state.id) { [weak self] msg in self?.send(msg) }
                case .prompt(let sessionId, let text):
                    try await manager.prompt(sessionId: sessionId, text: text)
                case .permission(let sessionId, let requestId, let allow, let reason):
                    await manager.resolvePermission(sessionId: sessionId, requestId: requestId, allow: allow, message: reason)
                case .interrupt(let sessionId):
                    try await manager.interrupt(sessionId: sessionId)
                case .setModel(let sessionId, let model):
                    try await manager.setModel(sessionId: sessionId, model: model)
                case .setPermissionMode(let sessionId, let mode):
                    try await manager.setPermissionMode(sessionId: sessionId, mode: mode)
                case .close(let sessionId):
                    await manager.close(sessionId: sessionId)
                    send(.sessions(items: await manager.listSessions()))
                case .fetchFile(let path):
                    do {
                        let file = try await manager.readImage(path: path)
                        send(.file(path: path, mediaType: file.mediaType, base64: file.data.base64EncodedString(), error: nil))
                    } catch {
                        send(.file(path: path, mediaType: nil, base64: nil, error: "\(error)"))
                    }
                }
            } catch {
                send(.error(message: "\(error)", sessionId: message.sessionId))
            }
        }
    }
}

private extension ClientMessage {
    var sessionId: String? {
        switch self {
        case .open(let id), .fork(let id), .prompt(let id, _), .permission(let id, _, _, _), .interrupt(let id),
             .setModel(let id, _), .setPermissionMode(let id, _), .close(let id):
            return id
        default:
            return nil
        }
    }
}
