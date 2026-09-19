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
    private var channel: WebSocketChannel?     // the winning connection once the race is decided
    private var racers: [WebSocketChannel] = []
    private var raceDecided = false
    private var pendingRacers = 0
    private var generation = 0
    private var wantConnected = false
    private var retryDelay: TimeInterval = 1
    private let queue = DispatchQueue(label: "ccremote.client")

    /// A connection route. Direct and relay race in parallel (happy-eyeballs).
    private enum Target {
        case direct        // host:port (or Bonjour), self-signed cert pinned/TOFU
        case relay         // <relay>/client?room=…, real cert
    }

    private var keepalive: Task<Void, Never>?

    func connect(_ pairing: PairingInfo) {
        self.pairing = pairing
        wantConnected = true
        retryDelay = 1
        openConnection()
        startKeepalive()
    }

    func disconnect() {
        wantConnected = false
        generation += 1
        keepalive?.cancel(); keepalive = nil
        closeAll()
        status = .disconnected
        host = nil
    }

    /// Sends a ping every 45s while connected — keeps the link warm through a relay/proxy and
    /// surfaces a dead connection quickly (a dropped socket then triggers a reconnect).
    private func startKeepalive() {
        keepalive?.cancel()
        keepalive = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                guard let self, self.wantConnected else { return }
                if self.status == .connected { self.send(.ping) }
            }
        }
    }

    private func closeAll() {
        channel = nil
        for c in racers { c.close() }
        racers = []
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
        let gen = generation
        status = .connecting
        raceDecided = false
        closeAll()
        // Race direct and relay in parallel (happy-eyeballs): whichever delivers `welcome`
        // first wins, the other is cancelled. Direct wins at home (local); on cellular the
        // LAN route fails fast and relay wins.
        var targets: [Target] = []
        if pairing.hasDirect { targets.append(.direct) }
        if pairing.hasRelay { targets.append(.relay) }
        guard !targets.isEmpty else { status = .failed("No route configured"); return }
        pendingRacers = targets.count
        for target in targets { startRacer(target, gen: gen, pairing: pairing) }
        // Overall watchdog: if nothing comes up, back off and start a new race.
        queue.asyncAfter(deadline: .now() + 12) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, gen == self.generation, !self.raceDecided else { return }
                self.closeAll()
                self.scheduleRetry()
            }
        }
    }

    private func startRacer(_ target: Target, gen: Int, pairing: PairingInfo) {
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
            guard gen == self.generation, self.wantConnected, !self.raceDecided else { return }
            guard let url else { self.racerFinished(gen: gen); return }

            let token = pairing.token
            var settled = false   // this racer reached a terminal state (won or lost)
            let channel = WebSocketChannel(connection: NWConnection(to: .url(url), using: WebSocketChannel.parameters(tls: tls)), queue: self.queue)
            self.racers.append(channel)
            channel.onState = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, gen == self.generation else { return }
                    switch state {
                    case .ready:
                        // Send hello; the winner is decided when `welcome` comes back.
                        channel.send(text: (try? ProtocolCoding.encode(ClientMessage.hello(token: token, client: "ios"))) ?? "")
                    case .failed, .cancelled, .waiting:
                        if self.channel === channel {
                            // The winning connection dropped — restart the race with backoff.
                            self.channel = nil
                            if self.status != .disconnected { self.status = .disconnected }
                            self.scheduleRetry()
                        } else if !settled {
                            settled = true
                            self.racerFinished(gen: gen)
                        }
                    default:
                        break
                    }
                }
            }
            channel.onText = { [weak self] text in
                guard let message = try? ProtocolCoding.decode(ServerMessage.self, from: text) else { return }
                Task { @MainActor [weak self] in
                    guard let self, gen == self.generation else { return }
                    if !self.raceDecided {
                        // First route to answer wins; cancel the losers.
                        self.raceDecided = true
                        settled = true
                        self.channel = channel
                        self.retryDelay = 1
                        for c in self.racers where c !== channel { c.close() }
                        self.racers = [channel]
                    }
                    guard self.channel === channel else { return }   // ignore late frames from a losing racer
                    if case .welcome(let info) = message {
                        self.host = info
                        self.status = .connected
                    }
                    self.onMessage?(message)
                }
            }
            channel.start()
        }
    }

    private func racerFinished(gen: Int) {
        guard gen == generation, !raceDecided else { return }
        pendingRacers -= 1
        if pendingRacers <= 0 { scheduleRetry() }   // every route failed → back off, race again
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
