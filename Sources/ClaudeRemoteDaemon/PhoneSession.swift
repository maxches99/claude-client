#if os(macOS) || os(Linux)
import Foundation
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
    /// Who this is, for the approval log.
    private var deviceLabel = "phone"

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
        let runs = commandRuns
        Task { [manager, id] in
            await manager.unsubscribe(id)
            #if os(macOS)
            await SimulatorStreamer.shared.detach(id)
            #endif
            // Nobody is reading the output any more.
            for run in runs { await manager.cancelCommand(runId: run) }
        }
    }

    /// Commands this phone started and has not seen finish (touched from the output thread too).
    private var commandRuns: Set<String> {
        get { runsLock.withLock { _commandRuns } }
        set { runsLock.withLock { _commandRuns = newValue } }
    }
    private var _commandRuns: Set<String> = []
    private let runsLock = NSLock()

    func send(_ message: ServerMessage) {
        guard let text = try? ProtocolCoding.encode(message) else { return }
        channel.send(text: text)
    }

    private func handle(_ text: String) {
        // A phone may open with an encryption handshake (it does through the relay): answer it and
        // switch the channel to sealed frames; everything after, hello included, is encrypted.
        if !authenticated, channel.secure == nil, text.hasPrefix("{\"e2e\"") {
            let link = E2ELink(token: tokenStore.current, role: .responder)
            do {
                guard try link.accept(text) else { return }
            } catch {
                send(.error(message: "\(error)", sessionId: nil))
                return
            }
            channel.send(text: link.handshakeMessage())   // still plaintext: `secure` is set after
            channel.secure = link
            log("client \(id.uuidString.prefix(8)) end-to-end encryption on (\(route.rawValue))")
            return
        }
        let message: ClientMessage
        do {
            message = try ProtocolCoding.decode(ClientMessage.self, from: text)
        } catch {
            send(.error(message: "Malformed message: \(error)", sessionId: nil))
            return
        }
        guard authenticated else {
            if case .hello(_, _, _, let deviceId) = message, tokenStore.isBlocked(deviceId) {
                log("client \(id.uuidString.prefix(8)) refused: device \(deviceId?.prefix(8) ?? "?") is blocked")
                send(.error(message: "This phone was removed from the Mac. Pair again with a new QR code.", sessionId: nil))
                channel.close()
                return
            }
            if case .hello(let token, let client, let device, let deviceId) = message, token == tokenStore.current {
                authenticated = true
                log("client \(id.uuidString.prefix(8)) authenticated (\(device ?? client), \(route.rawValue))")
                deviceLabel = device ?? client
                onAuthenticated(PhoneLink(id: id, client: client, device: device, deviceId: deviceId, route: route, remote: remote))
                Task { [weak self] in
                    guard let self else { return }
                    await self.manager.subscribe(self.id) { [weak self] msg in self?.send(msg) }
                    let info = await self.manager.hostInfo(daemonVersion: self.daemonVersion)
                    self.send(.welcome(host: info))
                    await self.manager.refreshSources()
                    self.send(.sessions(items: await self.manager.listSessions()))
                    #if os(macOS)
                    await SimulatorStreamer.shared.attach(self.id) { [weak self] msg in self?.send(msg) }
                    #endif
                }
            } else {
                log("client \(id.uuidString.prefix(8)) rejected: bad token")
                send(.error(message: "Not paired: wrong token", sessionId: nil))
                channel.close()
            }
            return
        }
        if case .simulatorInput = message {
            // Touch phases must reach the simulator in the order the finger produced them.
            let previous = inputChain
            inputChain = Task { [weak self] in
                await previous?.value
                await self?.dispatch(message)
            }
        } else {
            Task { [weak self] in await self?.dispatch(message) }
        }
    }

    /// Serializes `simulatorInput` handling; other messages are dispatched concurrently.
    private var inputChain: Task<Void, Never>?

    private func sendGitStatus(_ sessionId: String) async {
        do {
            send(.gitStatus(sessionId: sessionId, status: try await manager.gitStatus(sessionId: sessionId), error: nil))
        } catch {
            send(.gitStatus(sessionId: sessionId, status: nil, error: "\(error)"))
        }
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
            case .open(let sessionId, let since):
                try await manager.open(sessionId: sessionId, since: since) { [weak self] msg in self?.send(msg) }
            case .create(let options):
                let state = try await manager.create(options)
                send(.history(sessionId: state.id, entries: []))
                send(.state(state: state))
            case .fork(let sessionId):
                let state = try await manager.fork(sessionId: sessionId)
                try await manager.open(sessionId: state.id) { [weak self] msg in self?.send(msg) }
            case .prompt(let sessionId, let text, let images, let attachments):
                try await manager.prompt(sessionId: sessionId, text: text, images: images, attachments: attachments)
            case .permission(let sessionId, let requestId, let allow, let reason, let remember, let updatedInput):
                await manager.resolvePermission(sessionId: sessionId, requestId: requestId, allow: allow, message: reason,
                                                remember: remember ?? false, updatedInput: updatedInput, by: deviceLabel)
            case .dequeue(let sessionId, let promptId):
                await manager.dequeue(sessionId: sessionId, promptId: promptId)
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
                    let file = try await manager.readFile(path: path)
                    send(.file(path: path, mediaType: file.mediaType, base64: file.data.base64EncodedString(), error: nil))
                } catch {
                    send(.file(path: path, mediaType: nil, base64: nil, error: "\(error)"))
                }
            case .gitDiff(let sessionId, let path, let staged):
                do {
                    let diff = try await manager.gitDiff(sessionId: sessionId, path: path, staged: staged ?? false)
                    send(.gitDiff(sessionId: sessionId, diff: diff, error: nil, path: path))
                } catch {
                    send(.gitDiff(sessionId: sessionId, diff: "", error: "\(error)", path: path))
                }
            case .gitStatus(let sessionId):
                await sendGitStatus(sessionId)
            case .gitAction(let sessionId, let action):
                do {
                    let output = try await manager.gitAction(sessionId: sessionId, action: action)
                    send(.gitResult(sessionId: sessionId, action: action, output: output, error: nil))
                } catch {
                    send(.gitResult(sessionId: sessionId, action: action, output: "", error: "\(error)"))
                }
                await sendGitStatus(sessionId)
            case .listFiles(let sessionId, let query):
                send(.fileList(sessionId: sessionId, paths: await manager.listFiles(sessionId: sessionId, query: query)))
            case .getUsage(let sessionId):
                do {
                    send(.usage(sessionId: sessionId, data: try await manager.usage(sessionId: sessionId), error: nil))
                } catch {
                    send(.usage(sessionId: sessionId, data: nil, error: "\(error)"))
                }
            case .listDirectory(let sessionId, let path):
                do {
                    let listing = try await manager.listDirectory(sessionId: sessionId, path: path)
                    send(.directory(sessionId: sessionId, path: listing.path, entries: listing.entries, error: nil))
                } catch {
                    send(.directory(sessionId: sessionId, path: path ?? "", entries: [], error: "\(error)"))
                }
            case .searchProject(let sessionId, let query):
                do {
                    let result = try await manager.searchProject(sessionId: sessionId, query: query)
                    send(.searchResults(sessionId: sessionId, query: query, matches: result.matches, truncated: result.truncated, error: nil))
                } catch {
                    send(.searchResults(sessionId: sessionId, query: query, matches: [], truncated: false, error: "\(error)"))
                }
            case .listCommands(let sessionId):
                send(.commands(sessionId: sessionId, items: await manager.projectCommands(sessionId: sessionId)))
            case .runCommand(let sessionId, let runId, let command):
                do {
                    commandRuns.insert(runId)
                    try await manager.runCommand(sessionId: sessionId, runId: runId, command: command) { [weak self] chunk, done, code in
                        self?.send(.commandOutput(sessionId: sessionId, runId: runId, chunk: chunk, done: done, exitCode: code))
                        if done { self?.commandRuns.remove(runId) }
                    }
                } catch {
                    send(.commandOutput(sessionId: sessionId, runId: runId, chunk: "\(error)\n", done: true, exitCode: -1))
                }
            case .cancelCommand(_, let runId):
                await manager.cancelCommand(runId: runId)
            case .pullRequest(let sessionId):
                do {
                    send(.pullRequest(sessionId: sessionId, info: try await manager.pullRequest(sessionId: sessionId), error: nil))
                } catch {
                    send(.pullRequest(sessionId: sessionId, info: nil, error: "\(error)"))
                }
            case .renameSession(let sessionId, let title):
                try await manager.renameSession(sessionId: sessionId, title: title)
            case .searchSessions(let query):
                send(.sessionSearchResults(query: query, hits: await manager.searchSessions(query: query), error: nil))
            case .liveActivity(let sessionId, let pushToken, let approvalNeedsApp):
                await manager.registerLiveActivity(sessionId: sessionId, phone: id, token: pushToken, approvalNeedsApp: approvalNeedsApp)
            case .rewind(let sessionId, let uuid):
                do {
                    let result = try await manager.rewind(sessionId: sessionId, uuid: uuid)
                    send(.rewound(sessionId: sessionId, newSessionId: result.newSessionId, dropped: result.dropped, error: nil))
                    try await manager.open(sessionId: result.newSessionId) { [weak self] msg in self?.send(msg) }
                } catch {
                    send(.rewound(sessionId: sessionId, newSessionId: "", dropped: 0, error: "\(error)"))
                }
            case .listPalette(let sessionId):
                send(.palette(sessionId: sessionId, items: await manager.paletteItems(sessionId: sessionId)))
            case .listWorktrees(let sessionId):
                do {
                    send(.worktrees(sessionId: sessionId, items: try await manager.worktrees(sessionId: sessionId), error: nil))
                } catch {
                    send(.worktrees(sessionId: sessionId, items: [], error: "\(error)"))
                }
            case .worktreeAction(let sessionId, let action):
                do {
                    send(.worktrees(sessionId: sessionId, items: try await manager.worktreeAction(sessionId: sessionId, action: action), error: nil))
                } catch {
                    let existing = (try? await manager.worktrees(sessionId: sessionId)) ?? []
                    send(.worktrees(sessionId: sessionId, items: existing, error: "\(error)"))
                }
            case .listTasks:
                let list = await manager.taskList()
                send(.tasks(items: list.items, settings: list.settings))
                send(.duels(items: await manager.duelList()))
            case .addTask(let task):
                await manager.addTask(task)
            case .updateTask(let task):
                await manager.updateTask(task)
            case .taskAction(let id, let action):
                await manager.performTaskAction(id: id, action: action)
            case .setTaskSettings(let settings):
                await manager.setTaskSettings(settings)
            case .listProcesses:
                send(.processes(items: await manager.listProcesses()))
            case .startProcess(let sessionId, let runId, let command, let label):
                do {
                    try await manager.startProcess(sessionId: sessionId, runId: runId, command: command, label: label, phone: id)
                } catch {
                    send(.commandOutput(sessionId: sessionId ?? "", runId: runId, chunk: "\(error)\n", done: true, exitCode: -1))
                }
            case .attachProcess(let runId, let attached):
                await manager.attachProcess(runId: runId, phone: id, attached: attached)
            case .killProcess(let runId):
                await manager.killProcess(runId: runId)
            case .digest(let since):
                send(.digest(report: await manager.digest(since: since)))
            case .listHandoffTargets(let sessionId):
                send(.handoffTargets(sessionId: sessionId, items: await manager.handoffTargets(sessionId: sessionId)))
            case .handoff(let sessionId, let targetId):
                do {
                    try await manager.handoff(sessionId: sessionId, targetId: targetId)
                    send(.handoffResult(sessionId: sessionId, targetId: targetId, error: nil))
                } catch {
                    send(.handoffResult(sessionId: sessionId, targetId: targetId, error: "\(error)"))
                }
            case .shareTranscript(let sessionId, let title, let payload):
                do {
                    send(.shared(sessionId: sessionId, share: try await manager.shareTranscript(sessionId: sessionId, title: title, payload: payload), error: nil))
                } catch {
                    send(.shared(sessionId: sessionId, share: nil, error: "\(error)"))
                }
            case .revokeShare(let shareId):
                try await manager.revokeShare(shareId: shareId)
            case .terminalOpen(let sessionId, let terminalId, let cols, let rows):
                do {
                    try await manager.openTerminal(sessionId: sessionId, terminalId: terminalId, cols: cols, rows: rows, phone: id)
                } catch {
                    let text = "\r\n\(error)\r\n"
                    send(.terminalOutput(terminalId: terminalId, dataBase64: Data(text.utf8).base64EncodedString()))
                    send(.terminalExited(terminalId: terminalId, exitCode: nil))
                }
            case .terminalAttach(let terminalId, let attached):
                await manager.attachTerminal(terminalId: terminalId, phone: id, attached: attached)
            case .terminalInput(let terminalId, let dataBase64):
                if let data = Data(base64Encoded: dataBase64) { await manager.terminalInput(terminalId: terminalId, data: [UInt8](data)) }
            case .terminalResize(let terminalId, let cols, let rows):
                await manager.resizeTerminal(terminalId: terminalId, cols: cols, rows: rows)
            case .terminalClose(let terminalId):
                await manager.closeTerminal(terminalId: terminalId)
            case .listTerminals:
                send(.terminals(items: await manager.listTerminals()))
            case .reviewDiff(let sessionId, let base):
                do {
                    let review = try await manager.reviewDiff(sessionId: sessionId, base: base)
                    send(.reviewDiff(sessionId: sessionId, base: review.base, files: review.files, error: nil))
                } catch {
                    send(.reviewDiff(sessionId: sessionId, base: base ?? "", files: [], error: "\(error)"))
                }
            case .listRemoteRepositories:
                do {
                    send(.remoteRepositories(items: try await manager.listRemoteRepositories(), error: nil))
                } catch {
                    send(.remoteRepositories(items: [], error: "\(error)"))
                }
            case .cloneRepository(let source):
                do {
                    send(.cloneResult(source: source, path: try await manager.cloneRepository(source: source), error: nil))
                } catch {
                    send(.cloneResult(source: source, path: nil, error: "\(error)"))
                }
            case .startDuel(let title, let prompt, let cwd, let claudeMode, let codexPolicy, let judge):
                _ = try await manager.startDuel(title: title, prompt: prompt, cwd: cwd, claudeMode: claudeMode, codexPolicy: codexPolicy, judge: judge)
            case .duelAction(let duelId, let action):
                try await manager.duelAction(id: duelId, action: action)
            case .setDigestSchedule(let minutes):
                send(.digestSchedule(schedule: await manager.setDigestSchedule(minutes: minutes), error: nil))
            case .sendDigestNow:
                do {
                    send(.digestSchedule(schedule: try await manager.sendDigestNow(), error: nil))
                } catch {
                    send(.digestSchedule(schedule: await manager.currentDigestSchedule(), error: "\(error)"))
                }
            case .getDigestSchedule:
                send(.digestSchedule(schedule: await manager.currentDigestSchedule(), error: nil))
            #if os(macOS)
            case .listSimulators:
                send(.simulators(items: await SimulatorStreamer.shared.list()))
            case .simulatorStream(let udid, let enabled, let maxPixelSize, let fps, let codec):
                if enabled {
                    await SimulatorStreamer.shared.watch(udid: udid, id: id, maxPixelSize: maxPixelSize, fps: fps, codec: codec) { [weak self] msg in self?.send(msg) }
                } else {
                    await SimulatorStreamer.shared.unwatch(udid: udid, id: id)
                }
            case .simulatorAction(let udid, let action):
                do {
                    try await SimulatorStreamer.shared.perform(action, udid: udid)
                    send(.simulatorActionResult(udid: udid, action: action, error: nil))
                } catch {
                    log("simulator: \(action.label) \(udid.prefix(8)) failed: \(error.localizedDescription)")
                    send(.simulatorActionResult(udid: udid, action: action, error: error.localizedDescription))
                }
            case .listSimulatorApps(let udid):
                do {
                    send(.simulatorApps(udid: udid, items: try await SimulatorStreamer.shared.apps(udid: udid), error: nil))
                } catch {
                    send(.simulatorApps(udid: udid, items: [], error: error.localizedDescription))
                }
            case .simulatorScreenshot(let udid):
                do {
                    let shot = try await SimulatorStreamer.shared.screenshot(udid: udid)
                    send(.simulatorScreenshot(udid: udid, jpegBase64: shot.jpeg.base64EncodedString(), width: shot.width, height: shot.height, error: nil))
                } catch {
                    send(.simulatorScreenshot(udid: udid, jpegBase64: nil, width: 0, height: 0, error: error.localizedDescription))
                }
            case .simulatorInput(let udid, let event):
                do {
                    try await SimulatorInput.shared.perform(event, udid: udid)
                } catch {
                    log("simulator: input to \(udid.prefix(8)) failed: \(error.localizedDescription)")
                    send(.simulatorInputFailed(udid: udid, message: error.localizedDescription))
                }
            #else
            // No iOS Simulator on Linux: answer the queries with nothing and ignore the rest.
            case .listSimulators:
                send(.simulators(items: []))
            case .listSimulatorApps(let udid):
                send(.simulatorApps(udid: udid, items: [], error: "No Simulator on this host"))
            case .simulatorScreenshot(let udid):
                send(.simulatorScreenshot(udid: udid, jpegBase64: nil, width: 0, height: 0, error: "No Simulator on this host"))
            case .simulatorAction(let udid, let action):
                send(.simulatorActionResult(udid: udid, action: action, error: "No Simulator on this host"))
            case .simulatorStream, .simulatorInput:
                break
            #endif
            }
        } catch {
            send(.error(message: "\(error)", sessionId: message.sessionId))
        }
    }
}

extension ClientMessage {
    var sessionId: String? {
        switch self {
        case .open(let id, _), .fork(let id), .prompt(let id, _, _, _), .permission(let id, _, _, _, _, _), .dequeue(let id, _), .interrupt(let id), .gitDiff(let id, _, _),
             .gitStatus(let id), .gitAction(let id, _), .liveActivity(let id, _, _),
             .listFiles(let id, _), .getUsage(let id), .listDirectory(let id, _), .searchProject(let id, _), .listCommands(let id),
             .runCommand(let id, _, _), .cancelCommand(let id, _), .pullRequest(let id), .renameSession(let id, _),
             .setModel(let id, _), .setPermissionMode(let id, _), .setEffort(let id, _), .setSandbox(let id, _), .close(let id),
             .rewind(let id, _), .listPalette(let id), .listWorktrees(let id), .worktreeAction(let id, _),
             .listHandoffTargets(let id), .handoff(let id, _), .shareTranscript(let id, _, _), .reviewDiff(let id, _):
            return id
        default:
            return nil
        }
    }
}
#endif
