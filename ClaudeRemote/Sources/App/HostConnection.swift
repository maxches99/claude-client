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
    /// Fired once when a cert fingerprint is learned via trust-on-first-use, so it can be persisted.
    var onLearnedFingerprint: ((String) -> Void)?

    private var pairing: PairingInfo?
    private var channel: WebSocketChannel?
    private var generation = 0
    private var attemptToken = 0
    private var wantConnected = false
    private var retryDelay: TimeInterval = 1
    private let queue = DispatchQueue(label: "ccremote.client")

    /// One connection route to try, in order.
    private enum Target {
        case direct        // host:port (or Bonjour), self-signed cert pinned/TOFU
        case relay         // <relay>/client?room=…, real cert
    }

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

    private func learnedFingerprint(_ fp: String) {
        guard pairing?.fingerprint == nil else { return }
        pairing?.fingerprint = fp
        onLearnedFingerprint?(fp)
    }

    private func openConnection() {
        guard let pairing, wantConnected else { return }
        generation += 1
        status = .connecting
        // Try direct (fast, on the LAN / VPN) first, then the relay (works anywhere).
        var targets: [Target] = []
        if pairing.hasDirect { targets.append(.direct) }
        if pairing.hasRelay { targets.append(.relay) }
        if targets.isEmpty { status = .failed("No route configured"); return }
        tryTargets(targets, index: 0, gen: generation)
    }

    private func tryTargets(_ targets: [Target], index: Int, gen: Int) {
        guard gen == generation, wantConnected, let pairing else { return }
        guard index < targets.count else { scheduleRetry(); return }   // all failed → back off, start over
        let target = targets[index]
        attemptToken += 1
        let token = attemptToken
        let next: @MainActor () -> Void = { [weak self] in self?.tryTargets(targets, index: index + 1, gen: gen) }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let url: URL?
            let tls: TLSRole
            switch target {
            case .direct:
                // NWConnection's WebSocket client needs a URL endpoint, so resolve Bonjour to an address first.
                if let direct = pairing.directURL { url = direct } else { url = await self.resolve(pairing) }
                let expected = pairing.fingerprint
                tls = pairing.useTLS ? .clientPinned(expected: expected, learned: { [weak self] fp in
                    guard expected == nil else { return }
                    Task { @MainActor [weak self] in self?.learnedFingerprint(fp) }
                }) : .none
            case .relay:
                url = pairing.relayClientURL
                tls = (pairing.relayClientURL?.scheme == "wss") ? .clientDefault : .none
            }
            guard gen == self.generation, token == self.attemptToken, self.wantConnected else { return }
            guard let url else { next(); return }
            self.openWebSocket(url: url, token: pairing.token, tls: tls, gen: gen, attempt: token, onFailure: next)
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
                        url = pairing.webSocketURL(host: "\(host)", port: port.rawValue)
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

    private func openWebSocket(url: URL, token: String, tls: TLSRole, gen: Int, attempt: Int, onFailure: @escaping @MainActor () -> Void) {
        var settled = false   // this attempt has reached ready or been abandoned
        let connection = NWConnection(to: .url(url), using: WebSocketChannel.parameters(tls: tls))
        let channel = WebSocketChannel(connection: connection, queue: queue)
        self.channel = channel
        channel.onState = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, gen == self.generation, attempt == self.attemptToken else { return }
                switch state {
                case .ready:
                    settled = true
                    self.retryDelay = 1
                    self.channel?.send(text: (try? ProtocolCoding.encode(ClientMessage.hello(token: token, client: "ios"))) ?? "")
                case .failed, .cancelled, .waiting:
                    guard !settled else {
                        // A live connection dropped — restart the whole search with backoff.
                        if self.status != .disconnected { self.status = .disconnected }
                        self.scheduleRetry()
                        return
                    }
                    settled = true
                    onFailure()   // this route didn't come up; try the next one
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
        // Watchdog: if this route hasn't come up in time, move on to the next.
        queue.asyncAfter(deadline: .now() + 7) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, gen == self.generation, attempt == self.attemptToken, !settled else { return }
                settled = true
                channel.close()
                onFailure()
            }
        }
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
