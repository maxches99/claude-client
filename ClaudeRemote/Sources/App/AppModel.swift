import Foundation
import Observation
import ClaudeRemoteCore

@MainActor
@Observable
final class AppModel {
    let connection = HostConnection()
    let imageCache = ImageCache()
    let simulatorFeed = SimulatorFeed()

    /// Every Mac this phone has paired with; `activeMacId` is the one the app is connected to.
    private(set) var macs: [PairingInfo] = []
    private(set) var activeMacId: String?
    var activeMac: PairingInfo? { macs.first { $0.id == activeMacId } }

    /// What the connected Mac told us in `welcome` (CLI versions, whether Codex is installed).
    var host: HostInfo? { connection.host }
    var hasCodex: Bool { host?.codex != nil }
    /// Chats (and everything else added in protocol 2) need a Mac app new enough to understand them;
    /// an older daemon would just reject the request with a confusing error.
    var supportsChats: Bool { (host?.protocolVersion ?? 1) >= 2 }
    /// The Mac is paired but running an older ClaudeRemote Host than this app expects.
    var hostNeedsUpdate: Bool { host != nil && !supportsChats }
    /// Models Codex on the Mac can run, fetched once per connection.
    var codexModels: [ModelOption] = []
    var sessions: [SessionSummary] = []
    var projects: [ProjectInfo] = []
    var states: [String: SessionState] = [:]
    var transcripts: [String: Transcript] = [:]
    var permissions: [PermissionRequest] = []
    var errorBanner: String?
    /// Sessions and chats are separate tabs, each with its own navigation stack.
    var tab: AppTab = .sessions
    var sessionPath: [String] = []
    var chatPath: [String] = []
    /// Everything currently on screen, for re-attaching after a reconnect.
    var openSessionIds: [String] { sessionPath + chatPath }

    // MARK: Face ID / biometrics
    /// Require Face ID before approving a tool (each Allow runs code on the Mac). Default on.
    var requireBiometricsForApproval: Bool {
        didSet { UserDefaults.standard.set(requireBiometricsForApproval, forKey: "ccremote.faceid.approval") }
    }
    /// Require Face ID to open the app (after it goes to the background). Default off.
    var lockAppWithBiometrics: Bool {
        didSet { UserDefaults.standard.set(lockAppWithBiometrics, forKey: "ccremote.faceid.applock") }
    }
    /// The app is currently covered by the lock screen.
    var locked = false

    private var awaitingCreatedSession = false
    /// Which tab the session being created belongs to.
    private var awaitingKind: SessionKind = .agent

    init() {
        let defaults = UserDefaults.standard
        requireBiometricsForApproval = defaults.object(forKey: "ccremote.faceid.approval") as? Bool ?? true
        lockAppWithBiometrics = defaults.bool(forKey: "ccremote.faceid.applock")
        locked = lockAppWithBiometrics
        connection.onMessage = { [weak self] message in self?.handle(message) }
        connection.onLearnedFingerprint = { [weak self] fp in
            self?.updateActiveMac { if $0.fingerprint == nil { $0.fingerprint = fp } }
        }
        let saved = PairedMacs.load()
        macs = saved.macs
        activeMacId = saved.activeId ?? saved.macs.first?.id
        if let mac = activeMac { connection.connect(mac) }
    }

    // MARK: paired Macs

    /// Adds a Mac and switches to it. Scanning the QR of an already-paired Mac (new token, IP or
    /// cert) refreshes that entry instead of adding a second one.
    func pair(_ info: PairingInfo) {
        var info = info
        if let idx = macs.firstIndex(where: { $0.isSameMac(as: info) }) {
            let existing = macs[idx]
            info.id = existing.id
            info.hostName = existing.hostName
            info.lastConnectedAt = existing.lastConnectedAt
            // A QR printed without --relay carries no relay route; keep the one we already know.
            if !info.hasRelay {
                info.relayURL = existing.relayURL
                info.room = existing.room
            }
            macs[idx] = info
        } else {
            macs.append(info)
        }
        activate(info.id)
    }

    /// Shows another paired Mac. Everything on screen belongs to one Mac, so switching drops the
    /// current connection and the sessions, transcripts and approvals loaded from it.
    func switchTo(_ id: String) {
        guard id != activeMacId else { return }
        activate(id)
    }

    /// Removes a paired Mac. Forgetting the active one moves to the next, or back to pairing when none is left.
    func forget(_ id: String) {
        macs.removeAll { $0.id == id }
        guard id == activeMacId else { persistMacs(); return }
        connection.disconnect()
        resetHostState()
        activeMacId = nil
        if let next = macs.first { activate(next.id) } else { persistMacs() }
    }

    private func activate(_ id: String) {
        guard let mac = macs.first(where: { $0.id == id }) else { return }
        connection.disconnect()
        resetHostState()
        activeMacId = id
        persistMacs()
        connection.connect(mac)
    }

    private func persistMacs() {
        PairedMacs(macs: macs, activeId: activeMacId).save()
    }

    private func updateActiveMac(_ change: (inout PairingInfo) -> Void) {
        guard let idx = macs.firstIndex(where: { $0.id == activeMacId }) else { return }
        change(&macs[idx])
        persistMacs()
    }

    /// Clears everything that came from the Mac we're leaving.
    private func resetHostState() {
        codexModels = []
        sessions = []
        projects = []
        states = [:]
        transcripts = [:]
        permissions = []
        errorBanner = nil
        sessionPath = []
        chatPath = []
        awaitingCreatedSession = false
        requestedFiles = []
        imageCache.reset()
        simulatorFeed.stopWatching()
        simulatorFeed.devices = []
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
        awaitingKind = summary(for: sessionId)?.kind ?? .agent
        connection.send(.fork(sessionId: sessionId))
    }

    func create(_ options: NewSessionOptions) {
        awaitingCreatedSession = true
        awaitingKind = options.kind
        connection.send(.create(options: options))
    }

    /// Opens a session on its own tab (chats and work sessions never share a stack).
    func present(_ sessionId: String, kind: SessionKind) {
        tab = kind == .chat ? .chats : .sessions
        if kind == .chat {
            if !chatPath.contains(sessionId) { chatPath.append(sessionId) }
        } else if !sessionPath.contains(sessionId) {
            sessionPath.append(sessionId)
        }
    }

    func dismiss(_ sessionId: String) {
        sessionPath.removeAll { $0 == sessionId }
        chatPath.removeAll { $0 == sessionId }
    }

    /// A quick question: no project, no tools — the Mac picks the scratch directory and the model.
    func startChat(_ agent: AgentKind) {
        create(.chat(agent: agent))
    }

    func prompt(_ sessionId: String, text: String, images: [InlineImage] = [], attachments: [Attachment]? = nil) {
        connection.send(.prompt(sessionId: sessionId, text: text, images: images, attachments: attachments))
    }

    func decide(_ request: PermissionRequest, allow: Bool, reason: String? = nil, remember: Bool = false) {
        // Approving runs a tool on the Mac — gate Allow behind Face ID when enabled. Deny is never gated.
        if allow && requireBiometricsForApproval {
            Task { @MainActor in
                let ok = await Biometrics.authenticate(reason: "Approve \(request.toolName)")
                guard ok else { return }   // failed/cancelled → leave the request pending to retry
                self.sendDecision(request, allow: true, reason: reason, remember: remember)
            }
            return
        }
        sendDecision(request, allow: allow, reason: reason, remember: remember)
    }

    private func sendDecision(_ request: PermissionRequest, allow: Bool, reason: String?, remember: Bool = false) {
        connection.send(.permission(sessionId: request.sessionId, requestId: request.id, allow: allow, message: reason, remember: remember ? true : nil))
        permissions.removeAll { $0.id == request.id }
    }

    // MARK: app lock

    func lockOnBackground() {
        if lockAppWithBiometrics {
            locked = true
            Biometrics.resetReuse()   // require a fresh check after the app was away
        }
    }

    func unlock() {
        Task { @MainActor in
            if await Biometrics.authenticate(reason: "Unlock ClaudeRemote") { locked = false }
        }
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

    func setEffort(_ sessionId: String, effort: String) {
        connection.send(.setEffort(sessionId: sessionId, effort: effort))
    }

    func setSandbox(_ sessionId: String, mode: String) {
        connection.send(.setSandbox(sessionId: sessionId, mode: mode))
    }

    func requestCodexModels() {
        guard hasCodex else { return }
        connection.send(.listModels(agent: .codex))
    }

    /// Display name for a model id: Codex models come from the Mac, Claude's from the fixed list.
    func modelLabel(_ id: String?, agent: AgentKind) -> String {
        guard let id else { return "Model" }
        if agent == .codex {
            return codexModels.first { $0.id == id }?.label ?? id.replacingOccurrences(of: "-", with: " ").uppercased()
        }
        if let known = NewSessionView.models.first(where: { id.hasPrefix($0.id) }) { return known.label }
        return id.replacingOccurrences(of: "claude-", with: "").replacingOccurrences(of: "-", with: " ").capitalized
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

    /// Latest `git status`+`diff` per session, for reviewing changes before approving.
    var gitDiffs: [String: String] = [:]

    func requestGitDiff(_ sessionId: String) {
        connection.send(.gitDiff(sessionId: sessionId))
    }

    /// Latest file-search results for the composer's "@" mention picker.
    var fileMatches: [String] = []

    func requestFiles(_ sessionId: String, query: String) {
        connection.send(.listFiles(sessionId: sessionId, query: query))
    }

    /// Latest `/usage` payload (cost + plan rate-limit windows) and any error, for the limits screen.
    var usageReport: JSONValue?
    var usageError: String?

    func requestUsage(_ sessionId: String) {
        usageReport = nil
        usageError = nil
        connection.send(.getUsage(sessionId: sessionId))
    }

    // MARK: inbound

    private func handle(_ message: ServerMessage) {
        switch message {
        case .welcome(let host):
            errorBanner = nil
            updateActiveMac { $0.hostName = host.hostName; $0.lastConnectedAt = Date() }
            refresh()
            if codexModels.isEmpty { requestCodexModels() }
            // Re-attach to everything we were looking at before the reconnect.
            for id in openSessionIds { connection.send(.open(sessionId: id)) }
            if let udid = simulatorFeed.watching { sendSimulatorStream(udid, enabled: true) }
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
                present(sessionId, kind: awaitingKind)
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
        case .models(let agent, let items):
            if agent == .codex { codexModels = items }
        case .file(let path, _, let base64, let error):
            if let base64, error == nil {
                imageCache.store(key: "file:\(path)", base64: base64)
            } else {
                imageCache.fail(key: "file:\(path)")
            }
        case .gitDiff(let sessionId, let diff, let error):
            gitDiffs[sessionId] = error.map { "⚠️ \($0)" } ?? diff
        case .fileList(_, let paths):
            fileMatches = paths
        case .usage(_, let data, let error):
            usageReport = data
            usageError = error
        case .simulators(let items):
            simulatorFeed.devices = items
        case .simulatorFrame(let frame):
            simulatorFeed.receive(frame)
        case .pong:
            break
        }
    }

    // MARK: simulator live view

    func watchSimulator(_ udid: String) {
        if let current = simulatorFeed.watching, current != udid { sendSimulatorStream(current, enabled: false) }
        simulatorFeed.startWatching(udid)
        sendSimulatorStream(udid, enabled: true)
    }

    func stopWatchingSimulator() {
        if let udid = simulatorFeed.watching { sendSimulatorStream(udid, enabled: false) }
        simulatorFeed.stopWatching()
    }

    private func sendSimulatorStream(_ udid: String, enabled: Bool) {
        connection.send(.simulatorStream(udid: udid, enabled: enabled,
                                         maxPixelSize: enabled ? SimulatorFeed.maxPixelSize : nil,
                                         fps: enabled ? SimulatorFeed.fps : nil))
    }
}
