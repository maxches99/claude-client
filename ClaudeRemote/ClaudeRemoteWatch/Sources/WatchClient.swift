import Foundation
import Network
import Observation
import WatchKit
import WidgetKit
import ClaudeRemoteCore

/// Slim connection to the daemon for the Watch — reuses ClaudeRemoteCore's WebSocket channel and
/// wire protocol, but not the phone's HostConnection. Tries the relay first, then a direct address.
@MainActor
@Observable
final class WatchClient {
    enum Status: Equatable { case noPairing, connecting, connected, offline }

    private(set) var status: Status = .noPairing
    private(set) var hostName: String = "Mac"
    private(set) var sessions: [SessionSummary] = []
    private(set) var states: [String: SessionState] = [:]
    private(set) var permissions: [PermissionRequest] = []
    private var transcripts: [String: Transcript] = [:]
    /// Sessions opened on the wrist — their finished turns tap the wrist.
    private var followed: Set<String> = []
    /// A question dictated for a new chat, sent as soon as the Mac has created the chat.
    private var pendingChatPrompt: String?
    /// The chat just started from the wrist, for the view to navigate to.
    var startedChatId: String?

    private var pairing: WatchPairing?
    private var channel: WebSocketChannel?     // the winning connection once the race is decided
    private var racers: [WebSocketChannel] = []
    private var raceDecided = false
    private var reconnectScheduled = false
    private var generation = 0
    private var retryDelay: TimeInterval = 1
    private let queue = DispatchQueue(label: "ccremote.watch")

    var isConnected: Bool { status == .connected }

    // MARK: pairing

    func configure(_ pairing: WatchPairing) {
        if self.pairing == pairing, isConnected { return }
        self.pairing = pairing
        WatchStore.save(pairing)
        retryDelay = 1
        connect()
    }

    func loadStoredPairing() {
        if pairing == nil, let saved = WatchStore.load() {
            pairing = saved
            connect()
        }
    }

    // MARK: queries

    func pendingPermission(for sessionId: String) -> PermissionRequest? {
        permissions.first { $0.sessionId == sessionId }
    }

    func latestAssistantText(for sessionId: String) -> String? {
        guard let items = transcripts[sessionId]?.items else { return nil }
        for item in items.reversed() {
            if case .assistantText(let text, _) = item.kind, !text.isEmpty { return text }
        }
        return nil
    }

    func status(for sessionId: String) -> SessionStatus {
        states[sessionId]?.status ?? sessions.first { $0.id == sessionId }?.status ?? .unknown
    }

    // MARK: actions

    func refresh() { send(.listSessions) }

    func open(_ sessionId: String) {
        if transcripts[sessionId] == nil { transcripts[sessionId] = Transcript() }
        followed.insert(sessionId)
        send(.open(sessionId: sessionId))
    }

    func decide(_ request: PermissionRequest, allow: Bool, reason: String? = nil, updatedInput: JSONValue? = nil) {
        send(.permission(sessionId: request.sessionId, requestId: request.id, allow: allow,
                         message: allow ? nil : (reason ?? "Denied from Watch"), updatedInput: updatedInput))
        permissions.removeAll { $0.id == request.id }
        WKInterfaceDevice.current().play(allow ? .success : .directionDown)
    }

    /// Answers an AskUserQuestion with the picked option labels per question.
    func answer(_ request: PermissionRequest, answers: [String: [String]]) {
        decide(request, allow: true, updatedInput: AskUserQuestion.answeredInput(request.input, answers: answers))
    }

    /// Starts a tool-less chat and sends it `text` — a question asked by voice from the wrist.
    func startChat(_ text: String, agent: AgentKind = .claude) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        pendingChatPrompt = t
        startedChatId = nil
        send(.create(options: .chat(agent: agent)))
    }

    /// What the agent is doing right now, when it is inside a tool call.
    func livePhase(for sessionId: String) -> String? {
        guard status(for: sessionId) == .running, let items = transcripts[sessionId]?.items else { return nil }
        for item in items.reversed() {
            switch item.kind {
            case .toolUse(_, let name, let input, _, true):
                let line = ToolSummary.line(name: name, input: input)
                return line.isEmpty ? ToolSummary.displayName(name) : "\(ToolSummary.displayName(name)) · \(line)"
            case .thinking(_, true): return "Thinking…"
            case .assistantText(_, true): return "Writing…"
            case .user: return "Working…"
            default: continue
            }
        }
        return "Working…"
    }

    func prompt(_ sessionId: String, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        send(.prompt(sessionId: sessionId, text: t, images: []))
    }

    func interrupt(_ sessionId: String) { send(.interrupt(sessionId: sessionId)) }

    private func send(_ message: ClientMessage) {
        guard let channel, isConnected || isHello(message), let text = try? ProtocolCoding.encode(message) else { return }
        channel.send(text: text)
    }

    private func isHello(_ m: ClientMessage) -> Bool { if case .hello = m { return true }; return false }

    // MARK: connection

    private func connect() {
        guard let pairing else { status = .noPairing; return }
        let routes = pairing.routes()
        guard !routes.isEmpty else { status = .offline; return }
        generation += 1
        let gen = generation
        status = .connecting
        raceDecided = false
        for c in racers { c.close() }
        racers = []
        channel = nil

        // Happy-eyeballs: open every route at once and keep the first that answers with `welcome`.
        // Direct wins on the same Wi-Fi as the Mac; the relay wins on cellular / away from home — so the
        // Watch no longer waits out one route's timeout before trying the other.
        for route in routes {
            let connection = NWConnection(to: .url(route.url), using: WebSocketChannel.parameters(tls: route.tls))
            let ch = WebSocketChannel(connection: connection, queue: queue)
            let e2e: E2ELink? = route.relay ? E2ELink(token: pairing.token, role: .initiator) : nil
            let hello = { (try? ProtocolCoding.encode(ClientMessage.hello(token: pairing.token, client: "watch"))) ?? "" }
            racers.append(ch)
            ch.onState = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, gen == self.generation else { return }
                    switch state {
                    case .ready:
                        if let e2e { ch.send(text: e2e.handshakeMessage()) } else { ch.send(text: hello()) }
                    case .failed, .cancelled:
                        if self.channel === ch {                 // the winning connection dropped
                            self.channel = nil
                            self.status = .offline; self.updateSummary()
                            self.scheduleReconnect()
                        } else {                                  // a losing racer gave up
                            self.racers.removeAll { $0 === ch }
                            if !self.raceDecided, self.racers.isEmpty { self.scheduleReconnect() }
                        }
                    case .waiting:
                        // On the Watch the radio is often asleep, so a fresh connection sits in `.waiting`
                        // for a moment before it can reach the network. Keep racers waiting — NWConnection
                        // turns `.waiting` into `.ready` once the route comes up (or `.failed` at the 10s
                        // connectionTimeout). Only a live connection dropping to `.waiting` is a real drop.
                        if self.channel === ch {
                            self.channel = nil
                            self.status = .offline; self.updateSummary()
                            self.scheduleReconnect()
                        }
                    default:
                        break
                    }
                }
            }
            ch.onText = { [weak self] text in
                if let e2e, !e2e.isEstablished {
                    guard (try? e2e.accept(text)) == true else { ch.close(); return }
                    ch.secure = e2e
                    ch.send(text: hello())
                    return
                }
                guard let message = try? ProtocolCoding.decode(ServerMessage.self, from: text) else { return }
                Task { @MainActor [weak self] in
                    guard let self, gen == self.generation else { return }
                    if !self.raceDecided {                        // first route to answer wins the race
                        self.raceDecided = true
                        self.retryDelay = 1
                        self.channel = ch
                        for other in self.racers where other !== ch { other.close() }
                        self.racers = [ch]
                    }
                    guard self.channel === ch else { return }     // ignore late frames from losing racers
                    self.handle(message)
                }
            }
            ch.start()
        }

        // Watchdog: if no route comes up, tear the race down and back off before trying again.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard let self, gen == self.generation, !self.raceDecided else { return }
            for c in self.racers { c.close() }
            self.racers = []
            self.scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        guard pairing != nil, !reconnectScheduled else { return }
        reconnectScheduled = true
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 15)
        let gen = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.pairing != nil else { return }
            self.reconnectScheduled = false
            guard gen == self.generation else { return }   // a newer race already started
            self.connect()
        }
    }

    // MARK: inbound

    private func handle(_ message: ServerMessage) {
        switch message {
        case .welcome(let host):
            hostName = host.hostName
            status = .connected
            send(.listSessions)
        case .sessions(let items):
            sessions = items
        case .state(let state):
            let was = states[state.id]?.status
            states[state.id] = state
            for p in state.pendingPermissions where !permissions.contains(where: { $0.id == p.id }) { permissions.append(p) }
            // A turn the wrist was following just ended.
            if was == .running, state.status == .idle, followed.contains(state.id) {
                WKInterfaceDevice.current().play(state.lastError == nil ? .success : .failure)
            }
        case .permissionRequest(let request):
            if !permissions.contains(where: { $0.id == request.id }) {
                permissions.append(request)
                WKInterfaceDevice.current().play(.notification)
            }
        case .permissionResolved(_, let requestId):
            permissions.removeAll { $0.id == requestId }
        case .history(let sessionId, let entries):
            var t = Transcript(); t.apply(entries: entries); transcripts[sessionId] = t
            // A brand-new chat (empty history) right after we asked for one: send the dictated question.
            if entries.isEmpty, let prompt = pendingChatPrompt {
                pendingChatPrompt = nil
                followed.insert(sessionId)
                send(.prompt(sessionId: sessionId, text: prompt, images: []))
                startedChatId = sessionId
                send(.listSessions)
            }
        case .event(let sessionId, let payload, _):
            transcripts[sessionId]?.apply(payload)
        case .catchUp(let sessionId, let entries, _):
            transcripts[sessionId]?.apply(entries: entries)
        default:
            break   // projects/models/file/simulators/etc. — not shown on the Watch
        }
        updateSummary()
    }

    /// Publish a compact snapshot for the complication and refresh it.
    private func updateSummary() {
        let running = sessions.filter { (states[$0.id]?.status ?? $0.status) == .running }.count
        let summary = WatchSummary(pending: permissions.count, running: running, total: sessions.count,
                                   hostName: hostName, connected: isConnected,
                                   pendingSessionId: permissions.first?.sessionId)
        WatchSummary.save(summary)
        WidgetCenter.shared.reloadTimelines(ofKind: "PendingApprovals")
    }
}

/// Persists the pairing the Watch last received from the phone, so it reconnects on launch.
enum WatchStore {
    private static let key = "ccremote.watch.pairing"
    static func save(_ p: WatchPairing) {
        if let data = try? JSONEncoder().encode(p) { UserDefaults.standard.set(data, forKey: key) }
    }
    static func load() -> WatchPairing? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WatchPairing.self, from: data)
    }
}
