import Foundation
import Observation
import ClaudeRemoteCore

@MainActor
@Observable
final class AppModel {
    let connection = HostConnection()
    let imageCache = ImageCache()

    var pairing: PairingInfo?
    var sessions: [SessionSummary] = []
    var projects: [ProjectInfo] = []
    var states: [String: SessionState] = [:]
    var transcripts: [String: Transcript] = [:]
    var permissions: [PermissionRequest] = []
    var errorBanner: String?
    /// Session ids pushed onto the navigation stack.
    var path: [String] = []

    private var awaitingCreatedSession = false

    init() {
        connection.onMessage = { [weak self] message in self?.handle(message) }
        connection.onLearnedFingerprint = { [weak self] fp in
            guard let self, var p = self.pairing, p.fingerprint == nil else { return }
            p.fingerprint = fp
            p.save()
            self.pairing = p
        }
        if let saved = PairingInfo.load() {
            pairing = saved
            connection.connect(saved)
        }
    }

    // MARK: pairing

    func pair(_ info: PairingInfo) {
        info.save()
        pairing = info
        connection.connect(info)
    }

    func unpair() {
        connection.disconnect()
        PairingInfo.clear()
        pairing = nil
        sessions = []
        states = [:]
        transcripts = [:]
        permissions = []
        path = []
    }

    // MARK: queries

    var isConnected: Bool { connection.status == .connected }

    func summary(for id: String) -> SessionSummary? { sessions.first { $0.id == id } }

    func pendingPermission(for sessionId: String) -> PermissionRequest? {
        permissions.first { $0.sessionId == sessionId }
    }

    // MARK: actions

    func refresh() {
        connection.send(.listSessions)
        connection.send(.listProjects)
    }

    func open(_ sessionId: String) {
        if transcripts[sessionId] == nil { transcripts[sessionId] = Transcript() }
        connection.send(.open(sessionId: sessionId))
    }

    /// Attach once per visit; a reload is explicit (menu) so re-entering a chat doesn't flash.
    func openIfNeeded(_ sessionId: String) {
        guard transcripts[sessionId] == nil else { return }
        open(sessionId)
    }

    func fork(_ sessionId: String) {
        awaitingCreatedSession = true
        connection.send(.fork(sessionId: sessionId))
    }

    func create(_ options: NewSessionOptions) {
        awaitingCreatedSession = true
        connection.send(.create(options: options))
    }

    func prompt(_ sessionId: String, text: String) {
        connection.send(.prompt(sessionId: sessionId, text: text))
    }

    func decide(_ request: PermissionRequest, allow: Bool, reason: String? = nil) {
        connection.send(.permission(sessionId: request.sessionId, requestId: request.id, allow: allow, message: reason))
        permissions.removeAll { $0.id == request.id }
    }

    func interrupt(_ sessionId: String) {
        connection.send(.interrupt(sessionId: sessionId))
    }

    func setModel(_ sessionId: String, model: String) {
        connection.send(.setModel(sessionId: sessionId, model: model))
    }

    func setPermissionMode(_ sessionId: String, mode: String) {
        connection.send(.setPermissionMode(sessionId: sessionId, mode: mode))
    }

    func close(_ sessionId: String) {
        connection.send(.close(sessionId: sessionId))
    }

    private var requestedFiles: Set<String> = []

    /// Image files referenced from the transcript (SendUserFile) are fetched from the Mac on demand.
    func requestFile(_ path: String) {
        guard !requestedFiles.contains(path) else { return }
        requestedFiles.insert(path)
        connection.send(.fetchFile(path: path))
    }

    // MARK: inbound

    private func handle(_ message: ServerMessage) {
        switch message {
        case .welcome:
            errorBanner = nil
            refresh()
            // Re-attach to everything we were looking at before the reconnect.
            for id in path { connection.send(.open(sessionId: id)) }
        case .error(let text, _):
            errorBanner = text
        case .sessions(let items):
            sessions = items
        case .projects(let items):
            projects = items
        case .history(let sessionId, let entries):
            var transcript = Transcript()
            transcript.apply(entries: entries)
            transcripts[sessionId] = transcript
            if awaitingCreatedSession {
                awaitingCreatedSession = false
                if !path.contains(sessionId) { path.append(sessionId) }
            }
        case .event(let sessionId, let payload):
            guard transcripts[sessionId] != nil else { return }
            transcripts[sessionId]?.apply(payload)
        case .permissionRequest(let request):
            if !permissions.contains(where: { $0.id == request.id }) { permissions.append(request) }
        case .permissionResolved(_, let requestId):
            permissions.removeAll { $0.id == requestId }
        case .state(let state):
            states[state.id] = state
            for p in state.pendingPermissions where !permissions.contains(where: { $0.id == p.id }) { permissions.append(p) }
            if let idx = sessions.firstIndex(where: { $0.id == state.id }) {
                sessions[idx].status = state.status
                sessions[idx].origin = state.origin
            }
        case .file(let path, _, let base64, let error):
            if let base64, error == nil {
                imageCache.store(key: "file:\(path)", base64: base64)
            } else {
                imageCache.fail(key: "file:\(path)")
            }
        case .pong:
            break
        }
    }
}
