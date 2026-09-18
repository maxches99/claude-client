import Foundation
import Network
import Observation
import ClaudeRemoteCore

/// WebSocket link to the daemon with automatic reconnection.
@MainActor
@Observable
final class HostConnection {
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)

        var label: String {
            switch self {
            case .disconnected: return "Disconnected"
            case .connecting: return "Connecting…"
            case .connected: return "Connected"
            case .failed(let why): return why
            }
        }
    }

    private(set) var status: Status = .disconnected
    private(set) var host: HostInfo?
    var onMessage: ((ServerMessage) -> Void)?

    private var pairing: PairingInfo?
    private var channel: WebSocketChannel?
    private var generation = 0
    private var wantConnected = false
    private var retryDelay: TimeInterval = 1
    private let queue = DispatchQueue(label: "ccremote.client")

    func connect(_ pairing: PairingInfo) {
        self.pairing = pairing
        wantConnected = true
        retryDelay = 1
        openConnection()
    }

    func disconnect() {
        wantConnected = false
        generation += 1
        channel?.close()
        channel = nil
        status = .disconnected
        host = nil
    }

    func send(_ message: ClientMessage) {
        guard let channel, status == .connected || isHello(message) else { return }
        guard let text = try? ProtocolCoding.encode(message) else { return }
        channel.send(text: text)
    }

    private func isHello(_ message: ClientMessage) -> Bool {
        if case .hello = message { return true }
        return false
    }

    private func openConnection() {
        guard let pairing, wantConnected else { return }
        generation += 1
        let gen = generation
        status = .connecting
        Task { @MainActor [weak self] in
            guard let self else { return }
            // NWConnection's WebSocket client needs a URL endpoint (it builds the HTTP upgrade from it),
            // so Bonjour pairings are resolved to an address first.
            var url = pairing.directURL
            if url == nil { url = await self.resolve(pairing) }
            guard gen == self.generation, self.wantConnected else { return }
            guard let url else {
                self.status = .failed("Could not find \(pairing.name) on the network")
                self.scheduleRetry()
                return
            }
            self.openWebSocket(url: url, pairing: pairing, gen: gen)
        }
    }

    private func resolve(_ pairing: PairingInfo) async -> URL? {
        let queue = self.queue
        return await withCheckedContinuation { continuation in
            let probe = NWConnection(to: pairing.serviceEndpoint, using: .tcp)
            let done = Locked(false)
            probe.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard done.take() else { return }
                    var url: URL?
                    if case .hostPort(let host, let port)? = probe.currentPath?.remoteEndpoint {
                        url = PairingInfo.webSocketURL(host: "\(host)", port: port.rawValue)
                    }
                    continuation.resume(returning: url)
                    probe.cancel()
                case .failed, .cancelled:
                    guard done.take() else { return }
                    continuation.resume(returning: nil)
                default:
                    break
                }
            }
            probe.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 8) {
                guard done.take() else { return }
                continuation.resume(returning: nil)
                probe.cancel()
            }
        }
    }

    private func openWebSocket(url: URL, pairing: PairingInfo, gen: Int) {
        let connection = NWConnection(to: .url(url), using: WebSocketChannel.parameters())
        let channel = WebSocketChannel(connection: connection, queue: queue)
        self.channel = channel
        channel.onState = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, gen == self.generation else { return }
                switch state {
                case .ready:
                    self.retryDelay = 1
                    self.channel?.send(text: (try? ProtocolCoding.encode(ClientMessage.hello(token: pairing.token, client: "ios"))) ?? "")
                case .failed(let error):
                    self.status = .failed(error.localizedDescription)
                    self.scheduleRetry()
                case .cancelled:
                    if self.status != .disconnected { self.status = .disconnected }
                    self.scheduleRetry()
                case .waiting(let error):
                    self.status = .failed(error.localizedDescription)
                default:
                    break
                }
            }
        }
        channel.onText = { [weak self] text in
            guard let message = try? ProtocolCoding.decode(ServerMessage.self, from: text) else { return }
            Task { @MainActor [weak self] in
                guard let self, gen == self.generation else { return }
                if case .welcome(let info) = message {
                    self.host = info
                    self.status = .connected
                }
                self.onMessage?(message)
            }
        }
        channel.start()
    }

    /// One-shot flag shared between Network callbacks.
    private final class Locked: @unchecked Sendable {
        private var value: Bool
        private let lock = NSLock()
        init(_ value: Bool) { self.value = value }
        /// Returns true the first time only.
        func take() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if value { return false }
            value = true
            return true
        }
    }

    private func scheduleRetry() {
        guard wantConnected else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 15)
        let gen = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.wantConnected, gen == self.generation else { return }
            self.openConnection()
        }
    }
}
