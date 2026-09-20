import Foundation
import Observation
import UIKit
import ClaudeRemoteCore

@MainActor
@Observable
final class AppModel {
    /// The one model the app runs; Live Activity intents (performed in this process) reach it here.
    static private(set) weak var shared: AppModel?

    let connection = HostConnection()
    let imageCache = ImageCache()
    let simulatorFeed = SimulatorFeed()
    let liveActivities = LiveActivityController()

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
        didSet {
            UserDefaults.standard.set(requireBiometricsForApproval, forKey: "ccremote.faceid.approval")
            // The activity's Allow button depends on this; tell the Mac and refresh what's showing.
            for id in liveActivities.activeSessionIds {
                registerActivityToken(id, token: liveActivities.pushToken(for: id))
                syncActivity(id)
            }
        }
    }
    /// Require Face ID to open the app (after it goes to the background). Default off.
    var lockAppWithBiometrics: Bool {
        didSet { UserDefaults.standard.set(lockAppWithBiometrics, forKey: "ccremote.faceid.applock") }
    }
    /// The app is currently covered by the lock screen.
    var locked = false
    /// Show busy sessions as Live Activities (lock screen / Dynamic Island). Default on.
    var liveActivitiesEnabled: Bool {
        didSet {
            UserDefaults.standard.set(liveActivitiesEnabled, forKey: "ccremote.liveactivities")
            if !liveActivitiesEnabled { liveActivities.endAll() } else { for id in states.keys { syncActivity(id) } }
        }
    }

    private var awaitingCreatedSession = false
    /// Which tab the session being created belongs to.
    private var awaitingKind: SessionKind = .agent

    init() {
        let defaults = UserDefaults.standard
        requireBiometricsForApproval = defaults.object(forKey: "ccremote.faceid.approval") as? Bool ?? true
        lockAppWithBiometrics = defaults.bool(forKey: "ccremote.faceid.applock")
        liveActivitiesEnabled = defaults.object(forKey: "ccremote.liveactivities") as? Bool ?? true
        locked = lockAppWithBiometrics
        AppModel.shared = self
        liveActivities.onPushToken = { [weak self] sessionId, token in self?.registerActivityToken(sessionId, token: token) }
        liveActivities.adoptExisting()
        LiveActivityDecisions.shared.handler = { sessionId, requestId, allow in
            await AppModel.shared?.decideFromActivity(sessionId: sessionId, requestId: requestId, allow: allow)
        }
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
        remoteFiles = [:]
        remoteFileErrors = [:]
        gitDiffs = [:]
        gitFileDiffs = [:]
        gitStatuses = [:]
        gitErrors = [:]
        gitBusy = []
        gitResults = [:]
        activityTrackers = [:]
        liveActivities.endAll()
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
        activityTrackers[sessionId, default: ActivityTracker()].turnStartedAt = Date()
        activityTrackers[sessionId]?.lastTool = nil
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

    /// Non-image files from the Mac (SendUserFile), by path, once fetched — Markdown, text, PDF, anything
    /// the viewer can show or the share sheet can save.
    var remoteFiles: [String: RemoteFile] = [:]
    var remoteFileErrors: [String: String] = [:]

    struct RemoteFile: Equatable {
        let path: String
        let mediaType: String
        let data: Data
        var name: String { (path as NSString).lastPathComponent }
    }

    /// Files referenced from the transcript (SendUserFile) are fetched from the Mac on demand; images
    /// land in the image cache, everything else in `remoteFiles`. `force` refetches after a failure.
    func requestFile(_ path: String, force: Bool = false) {
        if force { requestedFiles.remove(path); remoteFileErrors[path] = nil; imageCache.retry(key: "file:\(path)") }
        guard !requestedFiles.contains(path) else { return }
        requestedFiles.insert(path)
        connection.send(.fetchFile(path: path))
    }

    /// Latest `git status`+`diff` per session, for reviewing changes before approving.
    var gitDiffs: [String: String] = [:]

    func requestGitDiff(_ sessionId: String) {
        connection.send(.gitDiff(sessionId: sessionId))
    }

    // MARK: git

    /// Per-file diffs keyed by `GitFileKey`, for the Git screen's file view.
    var gitFileDiffs: [GitFileKey: String] = [:]
    var gitStatuses: [String: GitStatus] = [:]
    var gitErrors: [String: String] = [:]
    /// Sessions with a git action in flight (one at a time per repo).
    var gitBusy: Set<String> = []
    /// Outcome of the last git action per session, shown as a banner on the Git screen.
    var gitResults: [String: GitResult] = [:]

    struct GitFileKey: Hashable {
        let sessionId: String
        let path: String
        let staged: Bool
    }

    struct GitResult: Equatable {
        let action: GitAction
        let output: String
        let error: String?
        let at: Date
    }

    func requestGitStatus(_ sessionId: String) {
        connection.send(.gitStatus(sessionId: sessionId))
    }

    /// The file diff last asked for; the reply carries the path but not which side, so it lands here.
    private var pendingFileDiff: GitFileKey?

    func requestGitFileDiff(_ sessionId: String, path: String, staged: Bool) {
        let key = GitFileKey(sessionId: sessionId, path: path, staged: staged)
        gitFileDiffs[key] = nil
        pendingFileDiff = key
        connection.send(.gitDiff(sessionId: sessionId, path: path, staged: staged))
    }

    func runGit(_ sessionId: String, _ action: GitAction) {
        guard !gitBusy.contains(sessionId) else { return }
        gitBusy.insert(sessionId)
        gitResults[sessionId] = nil
        connection.send(.gitAction(sessionId: sessionId, action: action))
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
            for id in liveActivities.activeSessionIds { registerActivityToken(id, token: liveActivities.pushToken(for: id)) }
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
            if payload["type"]?.string != "stream_event" {
                activityTrackers[sessionId, default: ActivityTracker()].apply(payload)
                syncActivity(sessionId)
            }
        case .permissionRequest(let request):
            if !permissions.contains(where: { $0.id == request.id }) { permissions.append(request) }
            syncActivity(request.sessionId)
        case .permissionResolved(let sessionId, let requestId):
            permissions.removeAll { $0.id == requestId }
            syncActivity(sessionId)
        case .state(let state):
            let wasRunning = states[state.id]?.status == .running || states[state.id]?.status == .awaitingPermission
            states[state.id] = state
            for p in state.pendingPermissions where !permissions.contains(where: { $0.id == p.id }) { permissions.append(p) }
            if let idx = sessions.firstIndex(where: { $0.id == state.id }) {
                sessions[idx].status = state.status
                sessions[idx].origin = state.origin
            }
            // A turn we didn't start from this phone (another device, the Watch) still gets a timer.
            if state.status == .running, !wasRunning, activityTrackers[state.id]?.turnStartedAt == nil {
                activityTrackers[state.id, default: ActivityTracker()].turnStartedAt = Date()
            }
            if state.status != .running, state.status != .awaitingPermission { activityTrackers[state.id]?.turnStartedAt = nil }
            syncActivity(state.id)
        case .models(let agent, let items):
            if agent == .codex { codexModels = items }
        case .file(let path, let mediaType, let base64, let error):
            let type = mediaType ?? "application/octet-stream"
            if let base64, error == nil {
                if type.hasPrefix("image/") {
                    imageCache.store(key: "file:\(path)", base64: base64)
                } else if let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) {
                    remoteFiles[path] = RemoteFile(path: path, mediaType: type, data: data)
                } else {
                    remoteFileErrors[path] = "Could not decode the file"
                }
            } else {
                imageCache.fail(key: "file:\(path)")
                remoteFileErrors[path] = error ?? "Could not load from the Mac"
            }
        case .gitDiff(let sessionId, let diff, let error, let path):
            if let path {
                let key = pendingFileDiff.flatMap { $0.sessionId == sessionId && $0.path == path ? $0 : nil }
                    ?? GitFileKey(sessionId: sessionId, path: path, staged: false)
                gitFileDiffs[key] = error.map { "⚠️ \($0)" } ?? diff
            } else {
                gitDiffs[sessionId] = error.map { "⚠️ \($0)" } ?? diff
            }
        case .gitStatus(let sessionId, let status, let error):
            gitStatuses[sessionId] = status
            gitErrors[sessionId] = error
            gitBusy.remove(sessionId)
        case .gitResult(let sessionId, let action, let output, let error):
            gitResults[sessionId] = GitResult(action: action, output: output, error: error, at: Date())
            // A successful action invalidates every cached file diff for the repo.
            if error == nil { gitFileDiffs = gitFileDiffs.filter { $0.key.sessionId != sessionId } }
        case .fileList(_, let paths):
            fileMatches = paths
        case .usage(_, let data, let error):
            usageReport = data
            usageError = error
        case .simulators(let items):
            simulatorFeed.devices = items
        case .simulatorFrame(let frame):
            simulatorFeed.receive(frame)
        case .simulatorVideo(let frame):
            simulatorFeed.receiveVideo(frame)
        case .simulatorInputFailed(let udid, let message):
            if udid == simulatorFeed.watching { simulatorFeed.show(message, error: true) }
        case .simulatorActionResult(let udid, let action, let error):
            if simulatorFeed.pendingAction?.udid == udid { simulatorFeed.pendingAction = nil }
            if let error { simulatorFeed.show("\(action.label): \(error)", error: true) }
        case .simulatorApps(let udid, let items, let error):
            simulatorFeed.apps = (udid, items, error)
        case .simulatorScreenshot(let udid, let jpegBase64, _, _, let error):
            guard udid == simulatorFeed.watching, let waiter = simulatorFeed.screenshotWaiter else { break }
            simulatorFeed.screenshotWaiter = nil
            let image = jpegBase64.flatMap { Data(base64Encoded: $0) }.flatMap { UIImage(data: $0) }
            waiter(image, image == nil ? (error ?? "The Mac sent no image") : nil)
        case .pong:
            break
        }
    }

    // MARK: Live Activities

    /// Per-session bookkeeping for the activity headline (running tool, thinking, turn start).
    private var activityTrackers: [String: ActivityTracker] = [:]

    /// Which sessions get an activity: hosted ones (they can be approved from here) and anything
    /// currently open on screen — never a session that is merely idle on disk.
    private func syncActivity(_ sessionId: String) {
        guard liveActivitiesEnabled, let state = states[sessionId] else { return }
        let onScreen = openSessionIds.contains(sessionId)
        let busy = state.status == .running || state.status == .awaitingPermission
        guard state.origin == .host || onScreen || liveActivities.activeSessionIds.contains(sessionId) else { return }
        guard busy || liveActivities.activeSessionIds.contains(sessionId) else { return }
        let summary = summary(for: sessionId)
        let info = SessionActivityInfo(sessionId: sessionId,
                                       title: summary?.title ?? (state.kind == .chat ? "Chat" : "Session"),
                                       project: state.kind == .chat ? "" : (summary?.projectName ?? (state.cwd as NSString).lastPathComponent),
                                       agent: state.agent)
        let tracker = activityTrackers[sessionId] ?? ActivityTracker()
        let pending = pendingPermission(for: sessionId) ?? state.pendingPermissions.first
        let activityState = SessionActivityState.make(status: state.status, pending: pending, lastTool: tracker.lastTool,
                                                      thinking: tracker.thinking, turnStartedAt: tracker.turnStartedAt,
                                                      lastError: state.status == .idle ? nil : state.lastError,
                                                      approvalNeedsApp: requireBiometricsForApproval)
        liveActivities.sync(info, state: activityState)
    }

    private func registerActivityToken(_ sessionId: String, token: String?) {
        connection.send(.liveActivity(sessionId: sessionId, pushToken: token, approvalNeedsApp: requireBiometricsForApproval))
    }

    /// A decision made from the Dynamic Island / lock screen. The intent may have launched the app in
    /// the background, so wait for the connection to come up before sending.
    func decideFromActivity(sessionId: String, requestId: String, allow: Bool) async {
        let task = UIApplication.shared.beginBackgroundTask(withName: "ccremote.activity.decide")
        defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
        for _ in 0..<60 where !isConnected {   // up to ~15 s
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard isConnected else { return }
        // Allow arrives here only when the phone doesn't require Face ID (the widget opens the app otherwise).
        connection.send(.permission(sessionId: sessionId, requestId: requestId, allow: allow, message: allow ? nil : "Denied from the Live Activity", remember: nil))
        permissions.removeAll { $0.id == requestId }
        // Give the Mac a moment to answer with the new state so the activity flips before we suspend.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
    }

    /// `ccremote://session/<id>` from a Live Activity or the Watch: open that session.
    func openDeepLink(sessionId: String) {
        let kind = summary(for: sessionId)?.kind ?? states[sessionId]?.kind ?? .agent
        present(sessionId, kind: kind)
    }

    /// Keep the socket a little longer after the app leaves the foreground while an activity is
    /// showing, so the last few updates land before iOS suspends us.
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    func enteredBackground() {
        guard !liveActivities.activeSessionIds.isEmpty, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ccremote.activity.linger") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    func enteredForeground() { endBackgroundTask() }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
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
                                         fps: enabled ? SimulatorFeed.fps : nil,
                                         codec: enabled ? "h264" : nil))
    }

    /// Send a touch / key / button to the simulator being watched.
    func sendSimulatorInput(_ event: SimulatorInputEvent) {
        guard let udid = simulatorFeed.watching else { return }
        simulatorFeed.notice = nil
        connection.send(.simulatorInput(udid: udid, event: event))
    }

    func sendSimulatorAction(_ action: SimulatorAction, udid: String) {
        simulatorFeed.pendingAction = (udid, action)
        simulatorFeed.notice = nil
        connection.send(.simulatorAction(udid: udid, action: action))
    }

    func requestSimulatorApps(_ udid: String) {
        if simulatorFeed.apps?.udid != udid { simulatorFeed.apps = nil }
        connection.send(.listSimulatorApps(udid: udid))
    }

    /// Ask the Mac for a full-resolution still of the simulator being watched.
    func requestSimulatorScreenshot(_ completion: @escaping (UIImage?, String?) -> Void) {
        guard let udid = simulatorFeed.watching else { return completion(nil, "No simulator selected") }
        simulatorFeed.screenshotWaiter?(nil, "Superseded")
        simulatorFeed.screenshotWaiter = completion
        connection.send(.simulatorScreenshot(udid: udid))
    }

}
