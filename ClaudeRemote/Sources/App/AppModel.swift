import Foundation
import Observation
import UIKit
import WidgetKit
import ClaudeRemoteCore

@MainActor
@Observable
final class AppModel {
    /// The one model the app runs; Live Activity intents (performed in this process) reach it here.
    static private(set) weak var shared: AppModel?

    /// One link per paired Mac. The active one drives the app; the others stay connected so their
    /// sessions and pending approvals keep arriving — that is what makes one list and one approvals
    /// inbox across every Mac possible.
    private(set) var connections: [String: HostConnection] = [:]
    /// Stands in for "no Mac": views read `connection.status` before anything is paired.
    private let idleConnection = HostConnection()
    var connection: HostConnection { activeMacId.flatMap { connections[$0] } ?? idleConnection }

    let imageCache = ImageCache()
    let simulatorFeed = SimulatorFeed()
    let liveActivities = LiveActivityController()
    let narrator = Narrator()

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
    /// The queue, the palette, worktrees, rewind and background processes need protocol 4 — an older
    /// daemon would answer them with "malformed message", so they stay out of the way instead.
    var supportsQueue: Bool { (host?.protocolVersion ?? 1) >= 4 }
    /// The digest, terminals, handoff and share links need protocol 5.
    var supportsMacTools: Bool { (host?.protocolVersion ?? 1) >= 5 }
    func supportsMacTools(_ macId: String) -> Bool { (hostByMac[macId]?.protocolVersion ?? 1) >= 5 }
    /// Models Codex on the Mac can run, fetched once per connection.
    var codexModels: [ModelOption] = []
    /// Sessions per Mac, so the unified list can show them all at once.
    var sessionsByMac: [String: [SessionSummary]] = [:]
    /// Approvals waiting per Mac — the inbox reads across every entry.
    var permissionsByMac: [String: [PermissionRequest]] = [:]
    /// What each Mac said about itself in `welcome`.
    var hostByMac: [String: HostInfo] = [:]

    /// The active Mac's sessions (the rest of the app is written against one Mac at a time).
    var sessions: [SessionSummary] {
        get { activeMacId.flatMap { sessionsByMac[$0] } ?? [] }
        set { if let id = activeMacId { sessionsByMac[id] = newValue } }
    }
    var projects: [ProjectInfo] = []
    var states: [String: SessionState] = [:]
    var transcripts: [String: Transcript] = [:]
    /// The last numbered event applied per session, for a resume after reconnecting.
    var lastSeq: [String: Int] = [:]
    /// Raw transcript entries per open session (history + durable events), what the offline cache stores.
    private var rawEntries: [String: [JSONValue]] = [:]
    private var cacheDirty: Set<String> = []
    private var cacheSaveTask: Task<Void, Never>?
    private var cache: OfflineCache? { activeMacId.map(OfflineCache.init(macId:)) }
    /// Sessions shown while disconnected come from the cache; the transcript is read-only then.
    var showingCachedSessions = false
    var permissions: [PermissionRequest] {
        get { activeMacId.flatMap { permissionsByMac[$0] } ?? [] }
        set { if let id = activeMacId { permissionsByMac[id] = newValue } }
    }
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
        watchAllMacs = defaults.object(forKey: "ccremote.watchAllMacs") as? Bool ?? true
        showAllMacs = defaults.bool(forKey: "ccremote.showAllMacs")
        locked = lockAppWithBiometrics
        AppModel.shared = self
        liveActivities.onPushToken = { [weak self] sessionId, token in self?.registerActivityToken(sessionId, token: token) }
        liveActivities.adoptExisting()
        LiveActivityDecisions.shared.handler = { sessionId, requestId, allow in
            await AppModel.shared?.decideFromActivity(sessionId: sessionId, requestId: requestId, allow: allow)
        }
        let saved = PairedMacs.load()
        macs = saved.macs
        activeMacId = saved.activeId ?? saved.macs.first?.id
        loadCachedSessions()
        loadSessionFlags()
        syncConnections()
    }

    // MARK: connections

    /// Stay connected to every paired Mac, not just the one on screen. Off, only the active Mac is
    /// linked (and the unified list falls back to it).
    var watchAllMacs: Bool {
        didSet {
            UserDefaults.standard.set(watchAllMacs, forKey: "ccremote.watchAllMacs")
            if !watchAllMacs { showAllMacs = false }
            syncConnections()
        }
    }

    /// The session list shows every Mac at once.
    var showAllMacs: Bool {
        didSet { UserDefaults.standard.set(showAllMacs, forKey: "ccremote.showAllMacs") }
    }

    /// Opens links for the Macs we want connected and drops the ones we don't.
    private func syncConnections() {
        let wanted = Set(watchAllMacs ? macs.map(\.id) : [activeMacId].compactMap { $0 })
        for (id, link) in connections where !wanted.contains(id) {
            link.disconnect()
            connections[id] = nil
            sessionsByMac[id] = nil
            permissionsByMac[id] = nil
            hostByMac[id] = nil
        }
        for mac in macs where wanted.contains(mac.id) {
            if let existing = connections[mac.id] {
                if existing.status == .disconnected { existing.connect(mac) }
                continue
            }
            let link = HostConnection()
            let macId = mac.id
            link.onMessage = { [weak self] message in self?.handle(message, from: macId) }
            link.onLearnedFingerprint = { [weak self] fp in
                self?.updateMac(macId) { if $0.fingerprint == nil { $0.fingerprint = fp } }
            }
            connections[macId] = link
            link.connect(mac)
        }
    }

    /// Reconnects one Mac after its pairing details changed.
    private func reconnect(_ macId: String) {
        guard let mac = macs.first(where: { $0.id == macId }) else { return }
        connections[macId]?.disconnect()
        connections[macId] = nil
        syncConnections()
        _ = mac
    }

    func link(for macId: String) -> HostConnection? { connections[macId] }

    func macName(_ macId: String) -> String {
        macs.first { $0.id == macId }?.displayName ?? "Mac"
    }

    /// Which Mac a session belongs to (the active one unless another Mac lists it).
    func macId(forSession sessionId: String) -> String? {
        if let active = activeMacId, sessionsByMac[active]?.contains(where: { $0.id == sessionId }) == true { return active }
        return sessionsByMac.first { $0.value.contains { $0.id == sessionId } }?.key ?? activeMacId
    }

    private func macId(forPermission requestId: String) -> String? {
        permissionsByMac.first { $0.value.contains { $0.id == requestId } }?.key ?? activeMacId
    }

    /// Sends on the link that owns `sessionId` — the active Mac for everything else.
    func sendMessage(_ message: ClientMessage, session sessionId: String? = nil) {
        let macId = sessionId.flatMap { self.macId(forSession: $0) } ?? activeMacId
        guard let macId, let link = connections[macId] else { return }
        link.send(message)
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
            persistMacs()
            reconnect(info.id)
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
        connections[id]?.disconnect()
        connections[id] = nil
        sessionsByMac[id] = nil
        permissionsByMac[id] = nil
        hostByMac[id] = nil
        guard id == activeMacId else { persistMacs(); return }
        resetHostState()
        activeMacId = nil
        if let next = macs.first { activate(next.id) } else { persistMacs(); syncConnections() }
    }

    private func activate(_ id: String) {
        guard macs.contains(where: { $0.id == id }) else { return }
        if activeMacId != id { resetHostState() }
        activeMacId = id
        persistMacs()
        loadCachedSessions()
        loadSessionFlags()
        syncConnections()
        if isConnected { refresh() }
    }

    // MARK: shortcuts (App Intents)

    private var createdSessionWaiter: CheckedContinuation<String, Error>?
    private var replyWaiters: [String: CheckedContinuation<String, Error>] = [:]
    /// Sessions created for a shortcut are not pushed onto a navigation stack.
    private var quietCreate = false

    /// Waits for the Mac connection (it reconnects on its own), up to `timeout`.
    func ensureConnected(timeout: TimeInterval = 15) async throws {
        if isConnected { return }
        if let mac = activeMac, connection.status == .disconnected { connection.connect(mac) }
        let deadline = Date().addingTimeInterval(timeout)
        while !isConnected, Date() < deadline { try? await Task.sleep(nanoseconds: 200_000_000) }
        guard isConnected else { throw IntentFailure.notConnected }
    }

    /// Runs one tool-less chat turn on the Mac and returns the reply's text.
    func askChat(_ question: String, agent: AgentKind, timeout: TimeInterval = 25) async throws -> String {
        try await ensureConnected()
        let sessionId: String = try await withTimeout(timeout) { [self] in
            try await withCheckedThrowingContinuation { continuation in
                createdSessionWaiter = continuation
                quietCreate = true
                create(.chat(agent: agent))
            }
        }
        let reply: String = try await withTimeout(timeout) { [self] in
            try await withCheckedThrowingContinuation { continuation in
                replyWaiters[sessionId] = continuation
                prompt(sessionId, text: question)
            }
        }
        return reply
    }

    private func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @MainActor () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { @MainActor in try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw IntentFailure.timeout
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    // MARK: session management (rename / pin / archive / search)

    func renameSession(_ sessionId: String, title: String) {
        sendMessage(.renameSession(sessionId: sessionId, title: title))
        if let i = sessions.firstIndex(where: { $0.id == sessionId }) { sessions[i].title = title }
    }

    /// Pinned and archived sessions are the phone's own bookkeeping, kept per Mac.
    var pinnedSessions: Set<String> = []
    var archivedSessions: Set<String> = []

    private func sessionFlagsKey(_ kind: String) -> String { "ccremote.\(kind).\(activeMacId ?? "-")" }

    private func loadSessionFlags() {
        pinnedSessions = Set(UserDefaults.standard.stringArray(forKey: sessionFlagsKey("pinned")) ?? [])
        archivedSessions = Set(UserDefaults.standard.stringArray(forKey: sessionFlagsKey("archived")) ?? [])
    }

    func setPinned(_ sessionId: String, _ pinned: Bool) {
        if pinned { pinnedSessions.insert(sessionId) } else { pinnedSessions.remove(sessionId) }
        UserDefaults.standard.set(Array(pinnedSessions), forKey: sessionFlagsKey("pinned"))
    }

    func setArchived(_ sessionId: String, _ archived: Bool) {
        if archived { archivedSessions.insert(sessionId); pinnedSessions.remove(sessionId) } else { archivedSessions.remove(sessionId) }
        UserDefaults.standard.set(Array(archivedSessions), forKey: sessionFlagsKey("archived"))
        UserDefaults.standard.set(Array(pinnedSessions), forKey: sessionFlagsKey("pinned"))
    }

    struct SessionSearch: Equatable {
        let query: String
        let hits: [SessionSearchHit]
        let error: String?
    }
    var sessionSearch: SessionSearch?
    var sessionSearchInFlight = false

    func searchSessions(_ query: String) {
        sessionSearchInFlight = true
        sendMessage(.searchSessions(query: query))
    }

    /// A find-in-transcript the chat should open with once it appears (from a search hit).
    var pendingFind: [String: String] = [:]

    // MARK: Spotlight

    private var spotlightTask: Task<Void, Never>?

    private func scheduleSpotlightUpdate() {
        guard spotlightTask == nil else { return }
        spotlightTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self else { return }
            self.spotlightTask = nil
            SpotlightIndex.update(self.sessions, hostName: self.activeMac?.displayName ?? "Mac")
        }
    }

    // MARK: home-screen widget

    private var widgetTask: Task<Void, Never>?

    /// Writes the widget's summary (coalesced: sessions change a lot while an agent works).
    private func scheduleWidgetUpdate() {
        guard widgetTask == nil else { return }
        widgetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.widgetTask = nil
            self?.updateWidget()
        }
    }

    private func updateWidget() {
        let pendingIds = Set(permissionsByMac.values.flatMap { $0 }.map(\.sessionId))
        let rows = sessions
            .filter { $0.status != .unknown || $0.origin != .stored }
            .sorted { a, b in
                func rank(_ s: SessionSummary) -> Int {
                    if pendingIds.contains(s.id) || s.status == .awaitingPermission { return 0 }
                    if s.status == .running { return 1 }
                    return 2
                }
                return rank(a) != rank(b) ? rank(a) < rank(b) : a.updatedAt > b.updatedAt
            }
            .prefix(4)
            .map { WidgetSummary.Row(id: $0.id, title: $0.title, project: $0.projectName,
                                     status: pendingIds.contains($0.id) ? .awaitingPermission : $0.status, agent: $0.agent) }
        let everySession = sessionsByMac.values.flatMap { $0 }
        let pending = Set(pendingIds).union(everySession.filter { $0.status == .awaitingPermission }.map(\.id)).count
        let running = everySession.filter { $0.status == .running }.count
        WidgetSummary.save(WidgetSummary(pending: pending, running: running, hostName: activeMac?.displayName ?? "",
                                         connected: isConnected, rows: Array(rows)))
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSummary.kind)
    }

    // MARK: offline cache

    private func loadCachedSessions() {
        guard let cache, sessions.isEmpty else { return }
        let cached = cache.loadSessions()
        if !cached.isEmpty {
            sessions = cached
            showingCachedSessions = true
        }
    }

    /// Remembers an entry for the cache and schedules a save.
    private func remember(_ sessionId: String, entries: [JSONValue], replace: Bool) {
        let durable = entries.filter { $0["type"]?.string != "stream_event" }
        if replace { rawEntries[sessionId] = durable } else { rawEntries[sessionId, default: []] += durable }
        if let list = rawEntries[sessionId], list.count > 600 { rawEntries[sessionId] = Array(list.suffix(600)) }
        cacheDirty.insert(sessionId)
        scheduleCacheSave()
    }

    private func scheduleCacheSave() {
        guard cacheSaveTask == nil else { return }
        cacheSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.cacheSaveTask = nil
            self?.flushCache()
        }
    }

    func flushCache() {
        guard let cache else { return }
        cacheSaveTask?.cancel(); cacheSaveTask = nil
        if !showingCachedSessions, !sessions.isEmpty { cache.saveSessions(sessions) }
        for id in cacheDirty { if let entries = rawEntries[id] { cache.saveTranscript(id, entries: entries) } }
        cacheDirty = []
        cache.prune()
    }

    /// Opens a session from the cache when the Mac cannot be reached; the live open replaces it later.
    private func openFromCache(_ sessionId: String) -> Bool {
        guard let cache, let entries = cache.loadTranscript(sessionId) else { return false }
        var transcript = Transcript()
        transcript.apply(entries: entries)
        transcripts[sessionId] = transcript
        rawEntries[sessionId] = entries
        return true
    }

    private func persistMacs() {
        PairedMacs(macs: macs, activeId: activeMacId).save()
    }

    private func updateActiveMac(_ change: (inout PairingInfo) -> Void) {
        guard let id = activeMacId else { return }
        updateMac(id, change)
    }

    private func updateMac(_ macId: String, _ change: (inout PairingInfo) -> Void) {
        guard let idx = macs.firstIndex(where: { $0.id == macId }) else { return }
        change(&macs[idx])
        persistMacs()
    }

    /// Clears everything scoped to the Mac we're leaving. Per-Mac session lists and approvals stay:
    /// their links are still up, and the unified list and the inbox read them.
    private func resetHostState() {
        codexModels = []
        projects = []
        states = [:]
        transcripts = [:]
        lastSeq = [:]
        rawEntries = [:]
        cacheDirty = []
        showingCachedSessions = false
        errorBanner = nil
        sessionPath = []
        chatPath = []
        awaitingCreatedSession = false
        requestedFiles = []
        remoteFiles = [:]
        directories = [:]; directoryErrors = [:]; searchResults = [:]; projectCommands = [:]; commandRuns = [:]; pullRequests = [:]
        remoteFileErrors = [:]
        gitDiffs = [:]
        gitFileDiffs = [:]
        gitStatuses = [:]
        gitErrors = [:]
        gitBusy = []
        gitResults = [:]
        worktrees = [:]
        worktreeErrors = [:]
        palettes = [:]
        tasks = []
        taskSettings = TaskQueueSettings()
        backgroundProcesses = []
        attachedProcesses = []
        handoffTargets = [:]
        terminals = []
        terminalScreens = [:]
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
        sendMessage(.listSessions)
        sendMessage(.listProjects)
    }

    func open(_ sessionId: String) {
        if transcripts[sessionId] == nil { transcripts[sessionId] = Transcript() }
        if !isConnected { _ = openFromCache(sessionId) }
        sendMessage(.open(sessionId: sessionId))
    }

    /// Attach once per visit; a reload is explicit (menu) so re-entering a chat doesn't flash.
    func openIfNeeded(_ sessionId: String) {
        guard transcripts[sessionId] == nil else { return }
        open(sessionId)
    }

    func fork(_ sessionId: String) {
        awaitingCreatedSession = true
        awaitingKind = summary(for: sessionId)?.kind ?? .agent
        sendMessage(.fork(sessionId: sessionId))
    }

    func create(_ options: NewSessionOptions) {
        awaitingCreatedSession = true
        awaitingKind = options.kind
        sendMessage(.create(options: options))
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
        sendMessage(.prompt(sessionId: sessionId, text: text, images: images, attachments: attachments))
        // Mid-turn the host queues it; the turn that is running keeps its own timer.
        let status = states[sessionId]?.status
        guard status != .running, status != .awaitingPermission else { return }
        activityTrackers[sessionId, default: ActivityTracker()].turnStartedAt = Date()
        activityTrackers[sessionId]?.lastTool = nil
    }

    func decide(_ request: PermissionRequest, allow: Bool, reason: String? = nil, remember: Bool = false, updatedInput: JSONValue? = nil) {
        // Approving runs a tool on the Mac — gate Allow behind Face ID when enabled. Deny is never
        // gated, and neither is answering a question or approving a plan (nothing runs yet).
        if allow && requireBiometricsForApproval && request.runsCode {
            Task { @MainActor in
                let ok = await Biometrics.authenticate(reason: "Approve \(request.toolName)")
                guard ok else { return }   // failed/cancelled → leave the request pending to retry
                self.sendDecision(request, allow: true, reason: reason, remember: remember, updatedInput: updatedInput)
            }
            return
        }
        sendDecision(request, allow: allow, reason: reason, remember: remember, updatedInput: updatedInput)
    }

    /// Answers an AskUserQuestion: the picked labels per question (a typed "other" is just a label
    /// no option has), plus optional notes.
    func answer(_ request: PermissionRequest, answers: [String: [String]], notes: [String: String] = [:]) {
        decide(request, allow: true, updatedInput: AskUserQuestion.answeredInput(request.input, answers: answers, notes: notes))
    }

    private func sendDecision(_ request: PermissionRequest, allow: Bool, reason: String?, remember: Bool = false, updatedInput: JSONValue? = nil) {
        // The request may have come from another paired Mac (the inbox shows them all), so answer on
        // the link it arrived on rather than the active one.
        let macId = self.macId(forPermission: request.id)
        macId.flatMap { connections[$0] }?.send(.permission(sessionId: request.sessionId, requestId: request.id, allow: allow, message: reason,
                                                            remember: remember ? true : nil, updatedInput: updatedInput))
        if let macId { permissionsByMac[macId]?.removeAll { $0.id == request.id } }
    }

    func dequeue(_ sessionId: String, promptId: String) {
        sendMessage(.dequeue(sessionId: sessionId, promptId: promptId))
        states[sessionId]?.queued.removeAll { $0.id == promptId }
    }

    // MARK: composer hand-offs

    /// Text another screen wants in a session's composer (a quoted diff selection from the Git
    /// screen or the permission sheet). The chat view takes it and clears it.
    var composerInsert: ComposerInsert?

    struct ComposerInsert: Equatable {
        let sessionId: String
        let text: String
        let token = UUID()
    }

    func insertIntoComposer(_ sessionId: String, text: String) {
        composerInsert = ComposerInsert(sessionId: sessionId, text: text)
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
        sendMessage(.interrupt(sessionId: sessionId))
    }

    func setModel(_ sessionId: String, model: String) {
        sendMessage(.setModel(sessionId: sessionId, model: model))
    }

    func setPermissionMode(_ sessionId: String, mode: String) {
        sendMessage(.setPermissionMode(sessionId: sessionId, mode: mode))
    }

    func setEffort(_ sessionId: String, effort: String) {
        sendMessage(.setEffort(sessionId: sessionId, effort: effort))
    }

    func setSandbox(_ sessionId: String, mode: String) {
        sendMessage(.setSandbox(sessionId: sessionId, mode: mode))
    }

    func requestCodexModels() {
        guard hasCodex else { return }
        sendMessage(.listModels(agent: .codex))
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
        sendMessage(.close(sessionId: sessionId))
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
        sendMessage(.fetchFile(path: path))
    }

    /// Latest `git status`+`diff` per session, for reviewing changes before approving.
    var gitDiffs: [String: String] = [:]

    func requestGitDiff(_ sessionId: String) {
        sendMessage(.gitDiff(sessionId: sessionId))
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
        sendMessage(.gitStatus(sessionId: sessionId))
    }

    // MARK: pull requests

    struct PullRequestState: Equatable {
        var info: PullRequestInfo?
        var error: String?
        var fetchedAt: Date
        var loading: Bool
    }
    var pullRequests: [String: PullRequestState] = [:]

    /// Fetches the branch's PR (one network call on the Mac); cached for a few minutes unless forced.
    func requestPullRequest(_ sessionId: String, force: Bool = false) {
        if !force, let cached = pullRequests[sessionId], cached.loading || Date().timeIntervalSince(cached.fetchedAt) < 180 { return }
        pullRequests[sessionId] = PullRequestState(info: pullRequests[sessionId]?.info, error: nil, fetchedAt: Date(), loading: true)
        sendMessage(.pullRequest(sessionId: sessionId))
    }

    // MARK: project browser & search

    struct DirectoryKey: Hashable { let sessionId: String; let path: String }
    var directories: [DirectoryKey: [DirectoryEntry]] = [:]
    var directoryErrors: [DirectoryKey: String] = [:]

    func requestDirectory(_ sessionId: String, path: String) {
        directoryErrors[DirectoryKey(sessionId: sessionId, path: path)] = nil
        sendMessage(.listDirectory(sessionId: sessionId, path: path))
    }

    struct SearchResult: Equatable {
        let query: String
        let matches: [SearchMatch]
        let truncated: Bool
        let error: String?
    }
    var searchResults: [String: SearchResult] = [:]
    var searchInFlight: Set<String> = []

    func searchProject(_ sessionId: String, query: String) {
        searchInFlight.insert(sessionId)
        sendMessage(.searchProject(sessionId: sessionId, query: query))
    }

    /// A Mac file another screen wants attached to the session's next prompt (an @-mention chip).
    var macFileInsert: (sessionId: String, path: String, token: UUID)?

    func attachMacFile(_ sessionId: String, path: String) {
        macFileInsert = (sessionId, path, UUID())
    }

    // MARK: quick commands

    var projectCommands: [String: [ProjectCommand]] = [:]

    func requestCommands(_ sessionId: String) {
        sendMessage(.listCommands(sessionId: sessionId))
    }

    @Observable
    final class CommandRun: Identifiable {
        let id: String
        let sessionId: String
        let command: String
        let startedAt = Date()
        var output = ""
        var done = false
        var exitCode: Int32?
        init(id: String, sessionId: String, command: String) {
            self.id = id
            self.sessionId = sessionId
            self.command = command
        }
    }
    var commandRuns: [String: CommandRun] = [:]

    /// Starts a command on the Mac (Face ID-gated like an approval: it runs code there).
    func runCommand(_ sessionId: String, command: String, completion: @escaping (CommandRun?) -> Void) {
        let start = { [self] in
            let run = CommandRun(id: UUID().uuidString.lowercased(), sessionId: sessionId, command: command)
            commandRuns[run.id] = run
            sendMessage(.runCommand(sessionId: sessionId, runId: run.id, command: command))
            completion(run)
        }
        if requireBiometricsForApproval {
            Task { @MainActor in
                guard await Biometrics.authenticate(reason: "Run a command on the Mac") else { completion(nil); return }
                start()
            }
        } else {
            start()
        }
    }

    func cancelCommand(_ run: CommandRun) {
        sendMessage(.cancelCommand(sessionId: run.sessionId, runId: run.id))
    }

    /// The file diff last asked for; the reply carries the path but not which side, so it lands here.
    private var pendingFileDiff: GitFileKey?

    func requestGitFileDiff(_ sessionId: String, path: String, staged: Bool) {
        let key = GitFileKey(sessionId: sessionId, path: path, staged: staged)
        gitFileDiffs[key] = nil
        pendingFileDiff = key
        sendMessage(.gitDiff(sessionId: sessionId, path: path, staged: staged))
    }

    func runGit(_ sessionId: String, _ action: GitAction) {
        guard !gitBusy.contains(sessionId) else { return }
        gitBusy.insert(sessionId)
        gitResults[sessionId] = nil
        sendMessage(.gitAction(sessionId: sessionId, action: action))
    }

    /// Latest file-search results for the composer's "@" mention picker.
    var fileMatches: [String] = []

    func requestFiles(_ sessionId: String, query: String) {
        sendMessage(.listFiles(sessionId: sessionId, query: query))
    }

    /// Latest `/usage` payload (cost + plan rate-limit windows) and any error, for the limits screen.
    var usageReport: JSONValue?
    var usageError: String?

    func requestUsage(_ sessionId: String) {
        usageReport = nil
        usageError = nil
        sendMessage(.getUsage(sessionId: sessionId))
    }

    // MARK: palette, worktrees, tasks, processes (actions in AppModel+Features.swift)

    /// Slash commands, skills and sub-agents of a session's project, once asked for.
    var palettes: [String: [PaletteItem]] = [:]
    /// Reusable prompts, kept on the phone (they belong to you, not to a Mac).
    var snippets: [PromptSnippet] = PromptSnippet.load()
    var worktrees: [String: [Worktree]] = [:]
    var worktreeErrors: [String: String] = [:]
    var worktreeBusy = false
    /// The Mac's task queue.
    var tasks: [AgentTask] = []
    var taskSettings = TaskQueueSettings()
    /// Commands still running on the Mac.
    var backgroundProcesses: [BackgroundProcess] = []
    /// Processes whose output this phone is following.
    var attachedProcesses: Set<String> = []
    /// The session a rewind is in flight for, and why the last one failed.
    var rewindingSession: String?
    var rewindError: String?
    /// Set right after a rewind so the chat can say what happened in the new session.
    var rewindNotice: RewindNotice?

    struct RewindNotice: Equatable {
        let sessionId: String
        let dropped: Int
    }

    // MARK: digest, handoff, share links, terminals (actions in AppModel+MacTools.swift)

    /// "While you were away", per Mac, until dismissed.
    var digests: [String: DigestReport] = [:]
    var handoffTargets: [String: [HandoffTarget]] = [:]
    /// The outcome of the last handoff, for a banner.
    var handoffMessage: Banner?

    struct Banner: Equatable {
        let text: String
        let isError: Bool
    }
    /// Links this phone published (with their keys — the only copy), newest first.
    var shares: [ShareRecord] = ShareRecord.load()
    var shareWaiters: [String: CheckedContinuation<ShareInfo, Error>] = [:]
    /// Shells running on the active Mac, and the screens this phone is showing.
    var terminals: [TerminalInfo] = []
    var terminalScreens: [String: TerminalModel] = [:]

    // MARK: inbound

    private func handle(_ message: ServerMessage, from macId: String) {
        // A Mac we only monitor keeps its session list and its approvals flowing; everything else
        // (transcripts, git, simulators…) belongs to the Mac on screen.
        let isActive = macId == activeMacId
        switch message {
        case .digest(let report):
            receiveDigest(report, from: macId)
            return
        case .welcome(let host):
            hostByMac[macId] = host
            requestDigestIfAway(macId)
            updateMac(macId) { $0.hostName = host.hostName; $0.lastConnectedAt = Date() }
            guard isActive else {
                connections[macId]?.send(.listSessions)
                return
            }
            errorBanner = nil
            refresh()
            if codexModels.isEmpty { requestCodexModels() }
            // Re-attach to everything we were looking at before the reconnect — asking only for the
            // events missed where the transcript is still here.
            for id in openSessionIds { sendMessage(.open(sessionId: id, since: transcripts[id] != nil ? lastSeq[id] : nil)) }
            if let udid = simulatorFeed.watching { sendSimulatorStream(udid, enabled: true) }
            for id in liveActivities.activeSessionIds { registerActivityToken(id, token: liveActivities.pushToken(for: id)) }
        case .error(let text, _):
            if isActive { errorBanner = text }
        case .sessions(let items):
            sessionsByMac[macId] = items
            guard isActive else { scheduleWidgetUpdate(); return }
            showingCachedSessions = false
            scheduleCacheSave()
            scheduleWidgetUpdate()
            scheduleSpotlightUpdate()
        case .projects(let items):
            guard isActive else { return }
            projects = items
        case .history(let sessionId, let entries):
            guard isActive else { return }
            var transcript = Transcript()
            transcript.apply(entries: entries)
            transcripts[sessionId] = transcript
            lastSeq[sessionId] = nil
            remember(sessionId, entries: entries, replace: true)
            if awaitingCreatedSession {
                awaitingCreatedSession = false
                if let waiter = createdSessionWaiter {
                    createdSessionWaiter = nil
                    waiter.resume(returning: sessionId)
                }
                if quietCreate { quietCreate = false } else { present(sessionId, kind: awaitingKind) }
            }
        case .catchUp(let sessionId, let entries, let seq):
            guard isActive else { return }
            guard transcripts[sessionId] != nil else { return }
            transcripts[sessionId]?.apply(entries: entries)
            lastSeq[sessionId] = seq
            remember(sessionId, entries: entries, replace: false)
            for entry in entries where entry["type"]?.string != "stream_event" {
                activityTrackers[sessionId, default: ActivityTracker()].apply(entry)
            }
            syncActivity(sessionId)
        case .event(let sessionId, let payload, let seq):
            guard isActive else { return }
            guard transcripts[sessionId] != nil else { return }
            if let seq { lastSeq[sessionId] = seq }
            transcripts[sessionId]?.apply(payload)
            if payload["type"]?.string != "stream_event" { remember(sessionId, entries: [payload], replace: false) }
            if payload["type"]?.string == "result", let waiter = replyWaiters.removeValue(forKey: sessionId) {
                let text = TranscriptExport.lastReply(items: transcripts[sessionId]?.items ?? [])
                waiter.resume(returning: text.isEmpty ? (payload["result"]?.string ?? "") : text)
            }
            if payload["type"]?.string != "stream_event" {
                activityTrackers[sessionId, default: ActivityTracker()].apply(payload)
                syncActivity(sessionId)
            }
        case .permissionRequest(let request):
            if permissionsByMac[macId]?.contains(where: { $0.id == request.id }) != true {
                permissionsByMac[macId, default: []].append(request)
            }
            if isActive { syncActivity(request.sessionId) }
            updateWidget()
        case .permissionResolved(let sessionId, let requestId):
            permissionsByMac[macId]?.removeAll { $0.id == requestId }
            if isActive { syncActivity(sessionId) }
            scheduleWidgetUpdate()
        case .state(let state):
            let wasRunning = states[state.id]?.status == .running || states[state.id]?.status == .awaitingPermission
            states[state.id] = state
            for p in state.pendingPermissions where !permissions.contains(where: { $0.id == p.id }) { permissions.append(p) }
            if let idx = sessionsByMac[macId]?.firstIndex(where: { $0.id == state.id }) {
                sessionsByMac[macId]?[idx].status = state.status
                sessionsByMac[macId]?[idx].origin = state.origin
            }
            guard isActive else { scheduleWidgetUpdate(); return }
            // A turn we didn't start from this phone (another device, the Watch) still gets a timer.
            if state.status == .running, !wasRunning, activityTrackers[state.id]?.turnStartedAt == nil {
                activityTrackers[state.id, default: ActivityTracker()].turnStartedAt = Date()
            }
            if state.status != .running, state.status != .awaitingPermission { activityTrackers[state.id]?.turnStartedAt = nil }
            syncActivity(state.id)
        case .models(let agent, let items):
            guard isActive else { return }
            if agent == .codex { codexModels = items }
        case .file(let path, let mediaType, let base64, let error):
            guard isActive else { return }
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
            guard isActive else { return }
            if let path {
                let key = pendingFileDiff.flatMap { $0.sessionId == sessionId && $0.path == path ? $0 : nil }
                    ?? GitFileKey(sessionId: sessionId, path: path, staged: false)
                gitFileDiffs[key] = error.map { "⚠️ \($0)" } ?? diff
            } else {
                gitDiffs[sessionId] = error.map { "⚠️ \($0)" } ?? diff
            }
        case .gitStatus(let sessionId, let status, let error):
            guard isActive else { return }
            gitStatuses[sessionId] = status
            gitErrors[sessionId] = error
            gitBusy.remove(sessionId)
        case .gitResult(let sessionId, let action, let output, let error):
            guard isActive else { return }
            gitResults[sessionId] = GitResult(action: action, output: output, error: error, at: Date())
            // A successful action invalidates every cached file diff for the repo.
            if error == nil { gitFileDiffs = gitFileDiffs.filter { $0.key.sessionId != sessionId } }
        case .fileList(_, let paths):
            guard isActive else { return }
            fileMatches = paths
        case .usage(_, let data, let error):
            guard isActive else { return }
            usageReport = data
            usageError = error
        case .directory(let sessionId, let path, let entries, let error):
            guard isActive else { return }
            let key = DirectoryKey(sessionId: sessionId, path: path)
            if let error { directoryErrors[key] = error } else { directories[key] = entries }
        case .searchResults(let sessionId, let query, let matches, let truncated, let error):
            guard isActive else { return }
            searchInFlight.remove(sessionId)
            searchResults[sessionId] = SearchResult(query: query, matches: matches, truncated: truncated, error: error)
        case .commands(let sessionId, let items):
            guard isActive else { return }
            projectCommands[sessionId] = items
        case .commandOutput(_, let runId, let chunk, let done, let exitCode):
            guard isActive else { return }
            guard let run = commandRuns[runId] else { break }
            if !chunk.isEmpty { run.output += chunk }
            if done { run.done = true; run.exitCode = exitCode }
        case .pullRequest(let sessionId, let info, let error):
            guard isActive else { return }
            pullRequests[sessionId] = PullRequestState(info: info, error: error, fetchedAt: Date(), loading: false)
        case .sessionSearchResults(let query, let hits, let error):
            guard isActive else { return }
            sessionSearchInFlight = false
            sessionSearch = SessionSearch(query: query, hits: hits, error: error)
        case .simulators(let items):
            guard isActive else { return }
            simulatorFeed.devices = items
        case .simulatorFrame(let frame):
            guard isActive else { return }
            simulatorFeed.receive(frame)
        case .simulatorVideo(let frame):
            guard isActive else { return }
            simulatorFeed.receiveVideo(frame)
        case .simulatorInputFailed(let udid, let message):
            guard isActive else { return }
            if udid == simulatorFeed.watching { simulatorFeed.show(message, error: true) }
        case .simulatorActionResult(let udid, let action, let error):
            guard isActive else { return }
            if simulatorFeed.pendingAction?.udid == udid { simulatorFeed.pendingAction = nil }
            if let error { simulatorFeed.show("\(action.label): \(error)", error: true) }
        case .simulatorApps(let udid, let items, let error):
            guard isActive else { return }
            simulatorFeed.apps = (udid, items, error)
        case .simulatorScreenshot(let udid, let jpegBase64, _, _, let error):
            guard isActive else { return }
            guard udid == simulatorFeed.watching, let waiter = simulatorFeed.screenshotWaiter else { break }
            simulatorFeed.screenshotWaiter = nil
            let image = jpegBase64.flatMap { Data(base64Encoded: $0) }.flatMap { UIImage(data: $0) }
            waiter(image, image == nil ? (error ?? "The Mac sent no image") : nil)
        case .rewound(let sessionId, let newSessionId, let dropped, let error):
            guard isActive else { return }
            handleRewound(sessionId: sessionId, newSessionId: newSessionId, dropped: dropped, error: error)
        case .palette(let sessionId, let items):
            guard isActive else { return }
            palettes[sessionId] = items
        case .worktrees(let sessionId, let items, let error):
            guard isActive else { return }
            worktrees[sessionId] = items
            worktreeErrors[sessionId] = error
            worktreeBusy = false
        case .tasks(let items, let settings):
            guard isActive else { return }
            tasks = items
            taskSettings = settings
            scheduleWidgetUpdate()
        case .processes(let items):
            guard isActive else { return }
            backgroundProcesses = items
        case .handoffTargets(let sessionId, let items):
            guard isActive else { return }
            handoffTargets[sessionId] = items
        case .handoffResult(_, let targetId, let error):
            guard isActive else { return }
            let label = handoffTargets.values.flatMap { $0 }.first { $0.id == targetId }?.label ?? "Opened on the Mac"
            handoffMessage = error.map { Banner(text: $0, isError: true) } ?? Banner(text: "\(label) — done on the Mac.", isError: false)
        case .shared(let sessionId, let share, let error):
            guard isActive else { return }
            if let waiter = shareWaiters.removeValue(forKey: sessionId) {
                if let share { waiter.resume(returning: share) } else { waiter.resume(throwing: ShareFailure.mac(error ?? "The Mac could not publish the link.")) }
            }
        case .terminals(let items):
            guard isActive else { return }
            terminals = items
        case .terminalOutput(let terminalId, let dataBase64):
            guard isActive, let screen = terminalScreens[terminalId], let data = Data(base64Encoded: dataBase64) else { return }
            let replies = screen.feed([UInt8](data))
            if !replies.isEmpty { sendMessage(.terminalInput(terminalId: terminalId, dataBase64: Data(replies).base64EncodedString())) }
        case .terminalExited(let terminalId, let exitCode):
            guard isActive else { return }
            terminalScreens[terminalId]?.exited = true
            terminalScreens[terminalId]?.exitCode = exitCode
            terminals.removeAll { $0.id == terminalId }
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
        sendMessage(.liveActivity(sessionId: sessionId, pushToken: token, approvalNeedsApp: requireBiometricsForApproval))
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
        sendMessage(.permission(sessionId: sessionId, requestId: requestId, allow: allow, message: allow ? nil : "Denied from the Live Activity", remember: nil))
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
        markSeen()
        flushCache()
        updateWidget()
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
        simulatorFeed.player.onRehost = { [weak self] in
            // Same request again: the Mac answers a (re)watch with a forced key frame.
            guard let self, let udid = self.simulatorFeed.watching else { return }
            self.sendSimulatorStream(udid, enabled: true)
        }
        if let current = simulatorFeed.watching, current != udid { sendSimulatorStream(current, enabled: false) }
        simulatorFeed.startWatching(udid)
        sendSimulatorStream(udid, enabled: true)
    }

    func stopWatchingSimulator() {
        if let udid = simulatorFeed.watching { sendSimulatorStream(udid, enabled: false) }
        simulatorFeed.stopWatching()
    }

    private func sendSimulatorStream(_ udid: String, enabled: Bool) {
        sendMessage(.simulatorStream(udid: udid, enabled: enabled,
                                         maxPixelSize: enabled ? SimulatorFeed.maxPixelSize : nil,
                                         fps: enabled ? SimulatorFeed.fps : nil,
                                         codec: enabled ? "h264" : nil))
    }

    /// The session whose agent is currently inside a simulator tool call (`mcp__…iOS_Simulator__control`),
    /// so the live view can say "hands off" instead of fighting over the screen. Nil when none is.
    var simulatorDriver: String? {
        for (id, transcript) in transcripts where states[id]?.status == .running {
            let driving = transcript.items.contains {
                if case .toolUse(_, let name, _, _, let streaming) = $0.kind { return streaming && name.contains("iOS_Simulator") }
                return false
            }
            if driving { return sessions.first { $0.id == id }?.title ?? "The agent" }
        }
        return nil
    }

    /// Send a touch / key / button to the simulator being watched.
    func sendSimulatorInput(_ event: SimulatorInputEvent) {
        guard let udid = simulatorFeed.watching else { return }
        simulatorFeed.notice = nil
        sendMessage(.simulatorInput(udid: udid, event: event))
    }

    func sendSimulatorAction(_ action: SimulatorAction, udid: String) {
        simulatorFeed.pendingAction = (udid, action)
        simulatorFeed.notice = nil
        sendMessage(.simulatorAction(udid: udid, action: action))
    }

    func requestSimulatorApps(_ udid: String) {
        if simulatorFeed.apps?.udid != udid { simulatorFeed.apps = nil }
        sendMessage(.listSimulatorApps(udid: udid))
    }

    /// Ask the Mac for a full-resolution still of the simulator being watched.
    func requestSimulatorScreenshot(_ completion: @escaping (UIImage?, String?) -> Void) {
        guard let udid = simulatorFeed.watching else { return completion(nil, "No simulator selected") }
        simulatorFeed.screenshotWaiter?(nil, "Superseded")
        simulatorFeed.screenshotWaiter = completion
        sendMessage(.simulatorScreenshot(udid: udid))
    }

}

extension AppModel.CommandRun: Hashable {
    static func == (a: AppModel.CommandRun, b: AppModel.CommandRun) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
