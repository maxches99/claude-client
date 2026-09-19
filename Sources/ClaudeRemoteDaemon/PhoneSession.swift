#if os(macOS)
import Foundation
import Network
import ClaudeRemoteCore
import ClaudeCodeHost

/// One phone connection, regardless of how it arrived — accepted by the LAN listener
/// (WebSocketServer) or dialed out through a relay (RelayClient). Checks the pairing token,
/// then routes messages to the SessionManager and streams events back.
final class PhoneSession: @unchecked Sendable {
    let id = UUID()
    let route: PhoneRoute
    let remote: String?
    private let channel: WebSocketChannel
    private let manager: SessionManager
    private let tokenStore: TokenStore
    private let daemonVersion: String
    private let log: @Sendable (String) -> Void
    private let onAuthenticated: @Sendable (PhoneLink) -> Void
    private let onClose: @Sendable (UUID) -> Void
    private var authenticated = false
    private var closed = false

    init(channel: WebSocketChannel, route: PhoneRoute, remote: String?, manager: SessionManager, tokenStore: TokenStore, daemonVersion: String,
         log: @escaping @Sendable (String) -> Void,
         onAuthenticated: @escaping @Sendable (PhoneLink) -> Void = { _ in },
         onClose: @escaping @Sendable (UUID) -> Void) {
        self.channel = channel
        self.route = route
        self.remote = remote
        self.manager = manager
        self.tokenStore = tokenStore
        self.daemonVersion = daemonVersion
        self.log = log
        self.onAuthenticated = onAuthenticated
        self.onClose = onClose
    }

    func start() {
        channel.onState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.teardown(reason: "\(state)")
            default:
                break
            }
        }
        channel.onText = { [weak self] text in self?.handle(text) }
        channel.start()
    }

    /// Closes the connection from our side (daemon shutdown, token rotation).
    func close() {
        channel.close()
    }

    private func teardown(reason: String) {
        guard !closed else { return }
        closed = true
        log("client \(id.uuidString.prefix(8)) gone (\(reason))")
        onClose(id)
        Task { [manager, id] in
            await manager.unsubscribe(id)
            await SimulatorStreamer.shared.detach(id)
        }
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
            if case .hello(let token, let client, let device, let deviceId) = message, token == tokenStore.current {
                authenticated = true
                log("client \(id.uuidString.prefix(8)) authenticated (\(device ?? client), \(route.rawValue))")
                onAuthenticated(PhoneLink(id: id, client: client, device: device, deviceId: deviceId, route: route, remote: remote))
                Task { [weak self] in
                    guard let self else { return }
                    await self.manager.subscribe(self.id) { [weak self] msg in self?.send(msg) }
                    let info = await self.manager.hostInfo(daemonVersion: self.daemonVersion)
                    self.send(.welcome(host: info))
                    await self.manager.refreshSources()
                    self.send(.sessions(items: await self.manager.listSessions()))
                    await SimulatorStreamer.shared.attach(self.id) { [weak self] msg in self?.send(msg) }
                }
            } else {
                log("client \(id.uuidString.prefix(8)) rejected: bad token")
                send(.error(message: "Not paired: wrong token", sessionId: nil))
                channel.close()
            }
            return
        }
        Task { [weak self] in await self?.dispatch(message) }
    }

    private func dispatch(_ message: ClientMessage) async {
        do {
            switch message {
            case .hello:
                break
            case .ping:
                send(.pong)
            case .listSessions:
                await manager.refreshSources()
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
            case .prompt(let sessionId, let text, let images):
                try await manager.prompt(sessionId: sessionId, text: text, images: images)
            case .permission(let sessionId, let requestId, let allow, let reason):
                await manager.resolvePermission(sessionId: sessionId, requestId: requestId, allow: allow, message: reason)
            case .interrupt(let sessionId):
                try await manager.interrupt(sessionId: sessionId)
            case .setModel(let sessionId, let model):
                try await manager.setModel(sessionId: sessionId, model: model)
            case .setPermissionMode(let sessionId, let mode):
                try await manager.setPermissionMode(sessionId: sessionId, mode: mode)
            case .setEffort(let sessionId, let effort):
                try await manager.setEffort(sessionId: sessionId, effort: effort)
            case .setSandbox(let sessionId, let mode):
                try await manager.setSandbox(sessionId: sessionId, mode: mode)
            case .listModels(let agent):
                send(.models(agent: agent, items: try await manager.listModels(agent: agent)))
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
            case .listSimulators:
                send(.simulators(items: await SimulatorStreamer.shared.list()))
            case .simulatorStream(let udid, let enabled, let maxPixelSize, let fps):
                if enabled {
                    await SimulatorStreamer.shared.watch(udid: udid, id: id, maxPixelSize: maxPixelSize, fps: fps) { [weak self] msg in self?.send(msg) }
                } else {
                    await SimulatorStreamer.shared.unwatch(udid: udid, id: id)
                }
            }
        } catch {
            send(.error(message: "\(error)", sessionId: message.sessionId))
        }
    }
}

extension ClientMessage {
    var sessionId: String? {
        switch self {
        case .open(let id), .fork(let id), .prompt(let id, _, _), .permission(let id, _, _, _), .interrupt(let id),
             .setModel(let id, _), .setPermissionMode(let id, _), .setEffort(let id, _), .setSandbox(let id, _), .close(let id):
            return id
        default:
            return nil
        }
    }
}
#endif
