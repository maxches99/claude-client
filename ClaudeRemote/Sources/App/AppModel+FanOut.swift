import Foundation
import Observation
import ClaudeRemoteCore

/// One place a fan-out prompt goes: a project on a paired Mac, run by one agent and model.
struct FanOutTarget: Codable, Equatable, Hashable, Identifiable {
    var id = UUID().uuidString
    var macId: String
    var cwd: String
    var agent: AgentKind
    /// Nil = the agent's own default.
    var model: String?
    /// The session the host made for it, once it did.
    var sessionId: String?
    /// Why no session could be started.
    var error: String?

    var projectName: String { (cwd as NSString).lastPathComponent }

    /// "Opus 5.5", "Codex · gpt-5.6".
    var modelLabel: String {
        switch agent {
        case .claude: return NewSessionView.models.first { $0.id == model }?.label ?? model ?? "Claude"
        case .codex: return model.map { "Codex · \($0)" } ?? "Codex"
        }
    }
}

/// One prompt sent to several targets at once, to compare the answers side by side.
struct FanOutRun: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var prompt: String
    var createdAt = Date()
    var targets: [FanOutTarget]
}

/// Fan-out runs (the last 20 are kept on the phone) and what is live about their sessions. The
/// sessions may sit on Macs other than the active one, whose transcripts the app otherwise drops,
/// so the replies are followed here on every link.
@MainActor
@Observable
final class FanOutCenter {
    private static let key = "ccremote.fanOut.runs"
    private static let limit = 20

    private(set) var runs: [FanOutRun] = []
    /// Live transcripts of fan-out sessions, from whichever Mac they run on.
    var transcripts: [String: Transcript] = [:]
    var states: [String: SessionState] = [:]
    /// Project folders per Mac (the app keeps only the active Mac's).
    var projectsByMac: [String: [ProjectInfo]] = [:]
    /// Sessions whose history was asked for on this launch.
    var attached: Set<String> = []

    /// One create in flight per Mac: the host answers it with an empty history, then the state.
    struct Creating {
        var agent: AgentKind
        var token = UUID()
        var newId: String?
        var continuation: CheckedContinuation<Result<String, FanOutFailure>, Never>
    }
    var creating: [String: Creating] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([FanOutRun].self, from: data) {
            runs = saved
        }
    }

    func run(_ id: String) -> FanOutRun? { runs.first { $0.id == id } }

    func add(_ run: FanOutRun) {
        runs.insert(run, at: 0)
        if runs.count > Self.limit { runs.removeLast(runs.count - Self.limit) }
        save()
    }

    func update(_ runId: String, target targetId: String, _ change: (inout FanOutTarget) -> Void) {
        guard let r = runs.firstIndex(where: { $0.id == runId }),
              let t = runs[r].targets.firstIndex(where: { $0.id == targetId }) else { return }
        change(&runs[r].targets[t])
        save()
    }

    func remove(_ runId: String) {
        runs.removeAll { $0.id == runId }
        save()
    }

    /// Every session some run started, with the Mac it is on.
    var trackedSessions: [String: String] {
        var out: [String: String] = [:]
        for run in runs { for t in run.targets { if let id = t.sessionId { out[id] = t.macId } } }
        return out
    }

    private func save() {
        if let data = try? JSONEncoder().encode(runs) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

struct FanOutFailure: Error { let message: String }

extension AppModel {
    /// Sends `prompt` to every target as the first message of a new session; returns the run's id.
    @discardableResult
    func startFanOut(prompt: String, targets: [FanOutTarget], claudeMode: PermissionMode) -> String {
        let run = FanOutRun(prompt: prompt, targets: targets)
        fanOut.add(run)
        // A Mac takes its creates one at a time (the reply carries no request id); Macs run in parallel.
        for (macId, group) in Dictionary(grouping: run.targets, by: \.macId) {
            Task { @MainActor in
                for target in group {
                    let options: NewSessionOptions
                    switch target.agent {
                    case .claude:
                        options = NewSessionOptions(cwd: target.cwd, model: target.model, permissionMode: claudeMode.rawValue)
                    case .codex:
                        options = NewSessionOptions(cwd: target.cwd, model: target.model, permissionMode: CodexApprovalPolicy.onRequest.rawValue,
                                                    agent: .codex, sandbox: CodexSandboxMode.workspaceWrite.rawValue)
                    }
                    switch await createQuietly(options, onMac: macId) {
                    case .success(let sessionId):
                        fanOut.update(run.id, target: target.id) { $0.sessionId = sessionId }
                        fanOut.attached.insert(sessionId)
                        if fanOut.transcripts[sessionId] == nil { fanOut.transcripts[sessionId] = Transcript() }
                        send(.prompt(sessionId: sessionId, text: prompt), toMac: macId)
                    case .failure(let failure):
                        fanOut.update(run.id, target: target.id) { $0.error = failure.message }
                    }
                }
            }
        }
        return run.id
    }

    /// `createQuietly` for any paired Mac, not just the active one: starts a session there without
    /// showing it and returns its id, or why it could not.
    func createQuietly(_ options: NewSessionOptions, onMac macId: String, timeout: TimeInterval = 20) async -> Result<String, FanOutFailure> {
        let deadline = Date().addingTimeInterval(timeout)
        // Wait for the link (it reconnects on its own) and for any create already in flight there.
        while connections[macId]?.status != .connected || fanOut.creating[macId] != nil {
            guard Date() < deadline, connections[macId] != nil else {
                return .failure(FanOutFailure(message: connections[macId] == nil ? "Not connected to \(macName(macId))."
                                                                               : "\(macName(macId)) is not reachable."))
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let result: Result<String, FanOutFailure> = await withCheckedContinuation { continuation in
            let pending = FanOutCenter.Creating(agent: options.agent, continuation: continuation)
            fanOut.creating[macId] = pending
            send(.create(options: options), toMac: macId)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(1, deadline.timeIntervalSinceNow) * 1_000_000_000))
                guard let self, fanOut.creating[macId]?.token == pending.token else { return }
                finishFanOutCreate(macId, .failure(FanOutFailure(message: "\(macName(macId)) did not answer.")))
            }
        }
        return result
    }

    private func finishFanOutCreate(_ macId: String, _ result: Result<String, FanOutFailure>) {
        guard let pending = fanOut.creating.removeValue(forKey: macId) else { return }
        pending.continuation.resume(returning: result)
    }

    /// Asks for the history of a run's sessions this launch has not followed yet, and every Mac's projects.
    func attachFanOut(_ runId: String) {
        guard let run = fanOut.run(runId) else { return }
        for target in run.targets {
            guard let id = target.sessionId, !fanOut.attached.contains(id),
                  connections[target.macId]?.status == .connected else { continue }
            fanOut.attached.insert(id)
            send(.open(sessionId: id), toMac: target.macId)
        }
    }

    func requestFanOutProjects() {
        for link in connections.values where link.status == .connected { link.send(.listProjects) }
    }

    /// Project folders a target on `macId` can use.
    func fanOutProjects(_ macId: String) -> [ProjectInfo] {
        if macId == activeMacId, !projects.isEmpty { return projects }
        return fanOut.projectsByMac[macId] ?? []
    }

    func hasAgent(_ agent: AgentKind, mac macId: String) -> Bool {
        let host = hostByMac[macId]
        switch agent {
        case .claude: return host?.claudeInstalled ?? true
        case .codex: return host?.codex != nil
        }
    }

    // MARK: what a column shows

    func fanOutTranscript(_ target: FanOutTarget) -> Transcript? {
        guard let id = target.sessionId else { return nil }
        return fanOut.transcripts[id] ?? (target.macId == activeMacId ? transcripts[id] : nil)
    }

    func fanOutStatus(_ target: FanOutTarget) -> SessionStatus {
        guard let id = target.sessionId else { return target.error == nil ? .running : .exited }
        if permissionsByMac[target.macId]?.contains(where: { $0.sessionId == id }) == true { return .awaitingPermission }
        return fanOut.states[id]?.status
            ?? sessionsByMac[target.macId]?.first { $0.id == id }?.status
            ?? (target.macId == activeMacId ? states[id]?.status : nil)
            ?? .unknown
    }

    func fanOutError(_ target: FanOutTarget) -> String? {
        target.error ?? target.sessionId.flatMap { fanOut.states[$0]?.lastError }
    }

    /// Opens a fan-out session the ordinary way (switching to its Mac first).
    func openFanOut(_ target: FanOutTarget) {
        guard let id = target.sessionId else { return }
        if target.macId != activeMacId { switchTo(target.macId) }
        present(id, kind: .agent)
    }

    // MARK: inbound (every link)

    /// Called for every message from every Mac before the app's own handling.
    func fanOutReceive(_ message: ServerMessage, from macId: String) {
        switch message {
        case .welcome:
            // A new link has no subscriptions: follow this Mac's fan-out sessions again.
            for (id, mac) in fanOut.trackedSessions where mac == macId && fanOut.attached.contains(id) {
                connections[macId]?.send(.open(sessionId: id))
            }
        case .projects(let items):
            fanOut.projectsByMac[macId] = items
        case .history(let sessionId, let entries):
            if entries.isEmpty, fanOut.creating[macId] != nil, fanOut.creating[macId]?.newId == nil {
                fanOut.creating[macId]?.newId = sessionId
            }
            guard fanOut.attached.contains(sessionId) || fanOut.creating[macId]?.newId == sessionId else { return }
            var transcript = Transcript()
            transcript.apply(entries: entries)
            fanOut.transcripts[sessionId] = transcript
        case .catchUp(let sessionId, let entries, _):
            guard fanOut.transcripts[sessionId] != nil else { return }
            fanOut.transcripts[sessionId]?.apply(entries: entries)
        case .event(let sessionId, let payload, _):
            guard fanOut.transcripts[sessionId] != nil else { return }
            fanOut.transcripts[sessionId]?.apply(payload)
        case .state(let state):
            if let pending = fanOut.creating[macId], pending.newId == state.id, pending.agent == state.agent {
                fanOut.states[state.id] = state
                finishFanOutCreate(macId, .success(state.id))
            } else if fanOut.transcripts[state.id] != nil {
                fanOut.states[state.id] = state
            }
        case .error(let text, let sessionId):
            if sessionId == nil, fanOut.creating[macId]?.newId == nil { finishFanOutCreate(macId, .failure(FanOutFailure(message: text))) }
        default:
            break
        }
    }
}
