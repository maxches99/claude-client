import Foundation

/// Phone → Mac.
public enum ClientMessage: Codable, Sendable {
    /// Must be the first frame. `token` is the pairing secret shown by the daemon. `device` is a
    /// human-readable device name and `deviceId` a stable per-device id — both optional, shown on
    /// the Mac as "paired with …".
    case hello(token: String, client: String, device: String? = nil, deviceId: String? = nil)
    case listSessions
    case listProjects
    /// Attach to a session: resumes it under the daemon if needed, or tails it when it is open in desktop.
    /// With `since` (the last event `seq` the phone applied) a reconnecting phone gets just what it
    /// missed as `catchUp` when the host still has it, instead of the whole history again.
    case open(sessionId: String, since: Int? = nil)
    case create(options: NewSessionOptions)
    /// Copy a session (including one open in Claude Desktop) into a new daemon-hosted session and continue there.
    case fork(sessionId: String)
    /// `attachments` are non-image files (documents, video, voice memos); the host stages them to disk
    /// and references them by path in the prompt. Images should travel in `images` for direct vision.
    case prompt(sessionId: String, text: String, images: [InlineImage] = [], attachments: [Attachment]? = nil)
    /// `remember: true` also persists the CLI's suggested permission rule (from `permission_suggestions`),
    /// so matching tool calls are auto-approved later ("Allow & remember"). Nil/false = one-off allow.
    /// `updatedInput` replaces the tool input the CLI proceeds with — how a question card answers an
    /// AskUserQuestion (`{questions, answers}`); nil keeps the input as requested.
    case permission(sessionId: String, requestId: String, allow: Bool, message: String?, remember: Bool? = nil, updatedInput: JSONValue? = nil)
    /// Drop a prompt that is still waiting in the session's queue (see `SessionState.queued`).
    case dequeue(sessionId: String, promptId: String)
    case interrupt(sessionId: String)
    case setModel(sessionId: String, model: String)
    /// Claude: permission mode. Codex: approval policy.
    case setPermissionMode(sessionId: String, mode: String)
    /// Reasoning effort for the following turns (Codex).
    case setEffort(sessionId: String, effort: String)
    /// Codex sandbox mode for the following turns.
    case setSandbox(sessionId: String, mode: String)
    /// Models the host can run for an agent; answered with `models`.
    case listModels(agent: AgentKind)
    /// Stop the daemon's CLI process for this session (transcript stays on disk).
    case close(sessionId: String)
    /// Read a file from the Mac (one referenced by a SendUserFile tool call): images, Markdown, text,
    /// PDF — anything up to 12 MB; the reply carries its media type.
    case fetchFile(path: String)
    /// Ask for the session repo's uncommitted changes (git status + diff) to review before approving.
    /// With `path`, only that file's diff (`staged` picks the index side); untracked files are shown whole.
    case gitDiff(sessionId: String, path: String? = nil, staged: Bool? = nil)
    /// Ask for the repo's branch / sync state and changed files; answered with `gitStatus`.
    case gitStatus(sessionId: String)
    /// Run a git action in the session repo; answered with `gitResult` followed by a fresh `gitStatus`.
    case gitAction(sessionId: String, action: GitAction)
    /// Fuzzy-search files under the session's cwd for the composer's "@" mention picker. Empty query
    /// returns a first page of files.
    case listFiles(sessionId: String, query: String)
    /// Ask for the `/usage` data (session cost + plan rate-limit windows) for the limits screen.
    case getUsage(sessionId: String)
    /// A directory of the session's project (relative to its cwd; nil or empty = the root); answered with `directory`.
    case listDirectory(sessionId: String, path: String?)
    /// Search file contents under the project (`git grep`); answered with `searchResults`.
    case searchProject(sessionId: String, query: String)
    /// The project's quick commands (`.ccremote.json` or guessed); answered with `commands`.
    case listCommands(sessionId: String)
    /// Run a shell command in the project's directory; output streams back as `commandOutput` frames
    /// tagged with `runId` (chosen by the phone), the last one carrying `done` and the exit code.
    case runCommand(sessionId: String, runId: String, command: String)
    case cancelCommand(sessionId: String, runId: String)
    /// The pull request of the session's current branch (via `gh`); answered with `pullRequest`.
    case pullRequest(sessionId: String)
    /// Give a session a title (Claude: a `custom-title` entry in its transcript; Codex: `thread/name/set`).
    case renameSession(sessionId: String, title: String)
    /// Full-text search over every transcript on the Mac; answered with `sessionSearchResults`.
    case searchSessions(query: String)
    /// iOS Simulators on the Mac, booted or not (also pushed as `simulators` whenever the set changes).
    case listSimulators
    /// Boot / shut down a simulator, launch or quit an app in it, open a URL; answered with `simulatorActionResult`.
    case simulatorAction(udid: String, action: SimulatorAction)
    /// Apps installed on a simulator; answered with `simulatorApps`.
    case listSimulatorApps(udid: String)
    /// Start / stop receiving live frames of a booted simulator. `maxPixelSize` bounds the frame's
    /// longer side, `fps` the capture rate (capped by the daemon). `codec: "h264"` asks for a video
    /// stream (`simulatorVideo`); without it, or when the Mac cannot read the simulator's framebuffer,
    /// JPEG `simulatorFrame`s come instead. Frames stop when the phone disconnects.
    case simulatorStream(udid: String, enabled: Bool, maxPixelSize: Int?, fps: Double?, codec: String? = nil)
    /// Inject a touch / key / button into a booted simulator. Failures come back as `simulatorInputFailed`.
    case simulatorInput(udid: String, event: SimulatorInputEvent)
    /// A full-resolution still of the simulator's screen (to attach to a prompt); answered with `simulatorScreenshot`.
    case simulatorScreenshot(udid: String)
    /// Cut the conversation back to just before `uuid` (an entry of the transcript) and continue from
    /// there in a new session: the entries after it are left out of the copy. Files on disk are not
    /// touched — that is what the turn review is for. Answered with `rewound`.
    case rewind(sessionId: String, uuid: String)
    /// Slash commands, skills and sub-agents available in the session's project; answered with `palette`.
    case listPalette(sessionId: String)
    /// The repo's `git worktree list`; answered with `worktrees`.
    case listWorktrees(sessionId: String)
    /// Add / remove a worktree of the session's repo; answered with a fresh `worktrees`.
    case worktreeAction(sessionId: String, action: WorktreeAction)
    /// The Mac's task queue and its settings; answered with `tasks`. Every change to the queue is
    /// broadcast to every phone as another `tasks`.
    case listTasks
    /// Put a task in the queue (it starts when a slot frees up, or at its scheduled time).
    case addTask(task: AgentTask)
    /// Replace a queued task (prompt, schedule, project…). Running tasks keep what they started with.
    case updateTask(task: AgentTask)
    case taskAction(id: String, action: TaskAction)
    case setTaskSettings(settings: TaskQueueSettings)
    /// Commands still running on the Mac (and the recently finished ones); answered with `processes`.
    case listProcesses
    /// Start a command that keeps running when the phone goes away. Output streams as `commandOutput`
    /// frames tagged with `runId` to every phone attached to it.
    case startProcess(sessionId: String?, runId: String, command: String, label: String?)
    /// Start receiving a background process's output (the buffered tail first), or stop.
    case attachProcess(runId: String, attached: Bool)
    case killProcess(runId: String)
    /// What happened on the Mac since `since` (sessions, finished tasks, stopped processes); answered with `digest`.
    case digest(since: Date)
    /// Where on the Mac this session can be continued; answered with `handoffTargets`.
    case listHandoffTargets(sessionId: String)
    /// Continue the session (or open its project) there; answered with `handoffResult`.
    case handoff(sessionId: String, targetId: String)
    /// Publish a sealed transcript page through the relay; answered with `shared`.
    case shareTranscript(sessionId: String, title: String, payload: SharePayload)
    case revokeShare(shareId: String)
    /// Start a shell in a pseudo-terminal on the Mac (in the session's project, or home). Output
    /// streams as `terminalOutput` to every phone attached to it; it keeps running when phones leave.
    case terminalOpen(sessionId: String?, terminalId: String, cols: Int, rows: Int)
    /// Follow a terminal (its screen so far is replayed first), or stop following it.
    case terminalAttach(terminalId: String, attached: Bool)
    /// Keystrokes, base64 (control bytes and partial UTF-8 survive the trip).
    case terminalInput(terminalId: String, dataBase64: String)
    case terminalResize(terminalId: String, cols: Int, rows: Int)
    /// Hang up the shell (SIGHUP) and forget the terminal.
    case terminalClose(terminalId: String)
    case listTerminals
    /// Everything that changed on the session's branch against `base` (nil = the default branch, or for
    /// a task's worktree the commit it started from), per file with diffs; answered with `reviewDiff`.
    case reviewDiff(sessionId: String, base: String?)
    /// Repositories the host's GitHub account can clone (`gh repo list`); answered with `remoteRepositories`.
    case listRemoteRepositories
    /// Clone a repository (URL or owner/name) into the host's workspace; answered with `cloneResult`.
    case cloneRepository(source: String)
    /// Pit Claude and Codex against each other on one prompt; the duel shows up in `duels`. With
    /// `contestants` (protocol 7) the sides are any two agent/model/effort combinations instead.
    case startDuel(title: String, prompt: String, cwd: String, claudeMode: String?, codexPolicy: String?, judge: AgentKind,
                   contestants: [DuelContestant]? = nil)
    case duelAction(id: String, action: DuelAction)
    /// When the daily digest goes out (nil = off); answered with `digestSchedule`.
    case setDigestSchedule(minutes: Int?)
    /// Send the digest now (since the last one); answered with `digestSchedule`.
    case sendDigestNow
    case getDigestSchedule
    /// Open issues of the project's GitHub repository; answered with `issues`.
    case listIssues(cwd: String)
    /// Prompt templates for a project (its `.ccremote.json` and the host's own); answered with `templates`.
    case listTemplates(cwd: String)
    /// What agents did on the machine since `since` (one project, or all); answered with `audit`.
    case audit(since: Date, cwd: String?)
    /// This host's relay URL and secret, to hand to another Mac; answered with `relaySetup`.
    case getRelaySetup
    /// Join the relay: the host saves the setting and restarts; answered with `relayConfigured` first.
    case setRelay(setup: RelaySetup)
    /// The host's GitHub login and git identity; answered with `github`.
    case githubStatus
    /// Start `gh auth login --web`; the one-time code comes back in `github`, then the result.
    case githubLogin
    case githubCancelLogin
    case setGitIdentity(name: String, email: String)
    /// Whether a newer release exists; answered with `hostUpdate`.
    case checkHostUpdate
    /// Download the newest release and restart into it; progress and errors come as `hostUpdate`.
    case updateHost
    /// Register (or, with `pushToken == nil`, drop) this phone's Live Activity for a session. When the
    /// Mac has APNs configured it pushes `SessionActivityState` updates to the token, so the activity
    /// keeps moving while the app is in the background. `approvalNeedsApp` mirrors the phone's Face ID
    /// setting into the pushed state.
    case liveActivity(sessionId: String, pushToken: String?, approvalNeedsApp: Bool)
    case ping
}

/// Mac → Phone.
public enum ServerMessage: Codable, Sendable {
    case welcome(host: HostInfo)
    case error(message: String, sessionId: String?)
    case sessions(items: [SessionSummary])
    case projects(items: [ProjectInfo])
    /// Transcript entries loaded from disk (same shape as live `event` payloads).
    case history(sessionId: String, entries: [JSONValue])
    /// A raw stream-json message from the CLI (assistant / user / stream_event / result / system).
    /// `seq` numbers the durable events of a session (partial `stream_event`s carry none), so a
    /// phone can ask for what it missed after a reconnect.
    case event(sessionId: String, payload: JSONValue, seq: Int? = nil)
    /// The events after the `since` a phone asked for in `open`, applied on top of what it has.
    case catchUp(sessionId: String, entries: [JSONValue], lastSeq: Int)
    case permissionRequest(request: PermissionRequest)
    case permissionResolved(sessionId: String, requestId: String)
    case state(state: SessionState)
    case models(agent: AgentKind, items: [ModelOption])
    case file(path: String, mediaType: String?, base64: String?, error: String?)
    case gitDiff(sessionId: String, diff: String, error: String?, path: String? = nil)
    case gitStatus(sessionId: String, status: GitStatus?, error: String?)
    /// Output of a `gitAction` (stdout+stderr, trimmed); `error` when git failed or the action was refused.
    case gitResult(sessionId: String, action: GitAction, output: String, error: String?)
    /// Files matching a `listFiles` query, as paths relative to the session's cwd.
    case fileList(sessionId: String, paths: [String])
    /// The `/usage` payload (raw, as the CLI returns it) or an error when limits are unavailable.
    case usage(sessionId: String, data: JSONValue?, error: String?)
    case directory(sessionId: String, path: String, entries: [DirectoryEntry], error: String?)
    case searchResults(sessionId: String, query: String, matches: [SearchMatch], truncated: Bool, error: String?)
    case commands(sessionId: String, items: [ProjectCommand])
    /// A slice of a running command's output (stdout and stderr interleaved). `done` closes the run.
    case commandOutput(sessionId: String, runId: String, chunk: String, done: Bool, exitCode: Int32?)
    case pullRequest(sessionId: String, info: PullRequestInfo?, error: String?)
    case sessionSearchResults(query: String, hits: [SessionSearchHit], error: String?)
    /// The rewound copy of a session: `newSessionId` is a fresh session with the history up to the
    /// chosen point. The phone opens it; the original is left exactly as it was.
    case rewound(sessionId: String, newSessionId: String, dropped: Int, error: String?)
    case palette(sessionId: String, items: [PaletteItem])
    case worktrees(sessionId: String, items: [Worktree], error: String?)
    /// The whole queue, every time anything in it changes.
    case tasks(items: [AgentTask], settings: TaskQueueSettings)
    case processes(items: [BackgroundProcess])
    case digest(report: DigestReport)
    case handoffTargets(sessionId: String, items: [HandoffTarget])
    case handoffResult(sessionId: String, targetId: String, error: String?)
    /// The published link (without its key), or why it could not be.
    case shared(sessionId: String, share: ShareInfo?, error: String?)
    case terminals(items: [TerminalInfo])
    /// Output of a terminal, base64 (a read may split a UTF-8 character).
    case terminalOutput(terminalId: String, dataBase64: String)
    case terminalExited(terminalId: String, exitCode: Int32?)
    case reviewDiff(sessionId: String, base: String, files: [ReviewFile], error: String?)
    case remoteRepositories(items: [RemoteRepository], error: String?)
    case cloneResult(source: String, path: String?, error: String?)
    /// Every duel, whenever one changes.
    case duels(items: [Duel])
    case digestSchedule(schedule: DigestSchedule, error: String?)
    case issues(cwd: String, items: [GitHubIssue], error: String?)
    case templates(cwd: String, items: [PromptTemplate])
    case audit(report: AuditReport)
    case relaySetup(setup: RelaySetup?, error: String?)
    /// The host saved the relay and is restarting (`error` when it could not).
    case relayConfigured(error: String?)
    case github(account: GitHubAccount, login: GitHubLoginState?, error: String?)
    case hostUpdate(update: HostUpdate)
    case simulators(items: [SimulatorInfo])
    case simulatorActionResult(udid: String, action: SimulatorAction, error: String?)
    case simulatorApps(udid: String, items: [SimulatorApp], error: String?)
    case simulatorFrame(frame: SimulatorFrame)
    case simulatorVideo(frame: SimulatorVideoFrame)
    /// A `simulatorInput` the Mac could not deliver (device gone, SimulatorKit missing, …).
    case simulatorInputFailed(udid: String, message: String)
    /// The still asked for with `simulatorScreenshot` (JPEG), or why there is none.
    case simulatorScreenshot(udid: String, jpegBase64: String?, width: Int, height: Int, error: String?)
    case pong
}

public enum ProtocolCoding {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    public static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        try decoder.decode(type, from: Data(text.utf8))
    }
}
