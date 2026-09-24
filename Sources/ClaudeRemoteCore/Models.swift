import Foundation

/// Wire-protocol version. Bump when messages change incompatibly.
/// 4: rewind, palette, worktrees, the task queue and background processes.
/// 5: the digest, terminals, handoff to the Mac and share links.
/// 6: pull requests from tasks, branch review, cloning into the workspace, duels, the scheduled digest.
public let protocolVersion = 8

/// Which coding agent runs a session. Claude Code is the default everywhere a field is missing,
/// so messages from an older build still decode.
public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    public var label: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

/// What a session is for. A `chat` runs the same agent with no tools and no project context —
/// a quick question, not work on a codebase.
public enum SessionKind: String, Codable, Sendable {
    case agent
    case chat
}

/// The Codex CLI on the Mac, when one was found (bundled with the Codex app or on PATH).
public struct CodexInfo: Codable, Equatable, Sendable {
    public var path: String
    public var version: String?
    /// Best effort: `~/.codex/auth.json` exists, refined by `account/read` once the app-server runs.
    public var loggedIn: Bool?

    public init(path: String, version: String?, loggedIn: Bool?) {
        self.path = path
        self.version = version
        self.loggedIn = loggedIn
    }
}

public struct HostInfo: Codable, Equatable, Sendable {
    public var hostName: String
    public var daemonVersion: String
    public var cliVersion: String?
    public var cliPath: String
    public var loggedIn: Bool?
    public var protocolVersion: Int
    /// `nil` when no Codex CLI is installed on the Mac.
    public var codex: CodexInfo?
    /// The Mac can push Live Activity updates through APNs (a key is configured).
    public var livePush: Bool?
    /// The Mac has a relay to publish share links through.
    public var canShare: Bool?
    /// Where cloned repositories go (`~/work` unless configured).
    public var workspaceRoot: String?
    /// GitHub's `gh` is installed (pull requests, repository list).
    public var hasGitHubCLI: Bool?
    /// `false` on a Mac with Codex and no Claude CLI. Absent from hosts that always had it.
    public var hasClaude: Bool?
    /// The Mac adds sessions started from the phone to Claude Desktop's and the Codex app's own lists.
    public var mirrorsToDesktopApps: Bool?
    /// How phones reach this host through the relay; a phone updates its pairing from it.
    public var relay: RelayRoute?
    /// The version of the Host app / hub binary, when it knows it.
    public var appVersion: String?
    /// The host can download a newer release and restart into it.
    public var canUpdate: Bool?

    /// Claude sessions can be started here.
    public var claudeInstalled: Bool { hasClaude ?? true }

    public init(hostName: String, daemonVersion: String, cliVersion: String?, cliPath: String, loggedIn: Bool?,
                protocolVersion: Int = ClaudeRemoteCore.protocolVersion, codex: CodexInfo? = nil, livePush: Bool? = nil,
                canShare: Bool? = nil, workspaceRoot: String? = nil, hasGitHubCLI: Bool? = nil,
                hasClaude: Bool? = nil, mirrorsToDesktopApps: Bool? = nil, relay: RelayRoute? = nil,
                appVersion: String? = nil, canUpdate: Bool? = nil) {
        self.hostName = hostName
        self.daemonVersion = daemonVersion
        self.cliVersion = cliVersion
        self.cliPath = cliPath
        self.loggedIn = loggedIn
        self.protocolVersion = protocolVersion
        self.codex = codex
        self.livePush = livePush
        self.canShare = canShare
        self.workspaceRoot = workspaceRoot
        self.hasGitHubCLI = hasGitHubCLI
        self.hasClaude = hasClaude
        self.mirrorsToDesktopApps = mirrorsToDesktopApps
        self.relay = relay
        self.appVersion = appVersion
        self.canUpdate = canUpdate
    }
}

/// A model an agent can run, as advertised by the host (Codex: `model/list`; Claude: a fixed list).
public struct ModelOption: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var description: String?
    public var isDefault: Bool
    /// Reasoning efforts the model accepts, in the agent's own vocabulary; empty when not selectable.
    public var efforts: [String]
    public var defaultEffort: String?

    public init(id: String, label: String, description: String? = nil, isDefault: Bool = false, efforts: [String] = [], defaultEffort: String? = nil) {
        self.id = id
        self.label = label
        self.description = description
        self.isDefault = isDefault
        self.efforts = efforts
        self.defaultEffort = defaultEffort
    }
}

/// Where a session currently "lives".
public enum SessionOrigin: String, Codable, Sendable {
    /// A CLI process owned by the daemon (started or resumed from the phone).
    case host
    /// Currently open in Claude Desktop / a terminal on the Mac. Can be watched, not driven.
    case desktop
    /// Only a transcript on disk. Opening it resumes it under the daemon.
    case stored
}

public enum SessionStatus: String, Codable, Sendable {
    case idle
    case running
    case awaitingPermission
    case exited
    case unknown
}

public struct SessionSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String            // Claude session id (UUID string)
    public var title: String
    public var cwd: String
    public var updatedAt: Date
    public var origin: SessionOrigin
    public var status: SessionStatus
    public var desktopName: String?  // name from ~/.claude/sessions when open elsewhere
    public var entrypoint: String?   // "claude-desktop" | "cli" | "sdk-cli" | … for `.desktop` sessions
    public var agent: AgentKind
    public var kind: SessionKind

    public init(id: String, title: String, cwd: String, updatedAt: Date, origin: SessionOrigin, status: SessionStatus, desktopName: String? = nil,
                entrypoint: String? = nil, agent: AgentKind = .claude, kind: SessionKind = .agent) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.updatedAt = updatedAt
        self.origin = origin
        self.status = status
        self.desktopName = desktopName
        self.entrypoint = entrypoint
        self.agent = agent
        self.kind = kind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        cwd = try c.decode(String.self, forKey: .cwd)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        origin = try c.decode(SessionOrigin.self, forKey: .origin)
        status = try c.decode(SessionStatus.self, forKey: .status)
        desktopName = try c.decodeIfPresent(String.self, forKey: .desktopName)
        entrypoint = try c.decodeIfPresent(String.self, forKey: .entrypoint)
        agent = try c.decodeIfPresent(AgentKind.self, forKey: .agent) ?? .claude
        kind = try c.decodeIfPresent(SessionKind.self, forKey: .kind) ?? .agent
    }

    public var projectName: String { (cwd as NSString).lastPathComponent }

    /// Short label for where a `.desktop` session is running.
    public var sourceLabel: String {
        switch entrypoint {
        case "claude-desktop": return "Desktop"
        case "cli": return "Terminal"
        case "sdk-cli", "sdk-ts", "sdk-py": return "SDK"
        case "codex-app": return "Codex app"
        default: return "External"
        }
    }
}

public struct PermissionRequest: Codable, Equatable, Identifiable, Sendable {
    public var id: String            // control request id
    public var sessionId: String
    public var toolName: String
    public var input: JSONValue
    public var title: String?
    public var description: String?
    public var displayName: String?
    public var decisionReason: String?
    public var toolUseId: String?
    public var suggestions: JSONValue?   // permission_suggestions passthrough
    public var createdAt: Date

    public init(id: String, sessionId: String, toolName: String, input: JSONValue, title: String? = nil, description: String? = nil,
                displayName: String? = nil, decisionReason: String? = nil, toolUseId: String? = nil, suggestions: JSONValue? = nil, createdAt: Date = Date()) {
        self.id = id
        self.sessionId = sessionId
        self.toolName = toolName
        self.input = input
        self.title = title
        self.description = description
        self.displayName = displayName
        self.decisionReason = decisionReason
        self.toolUseId = toolUseId
        self.suggestions = suggestions
        self.createdAt = createdAt
    }
}

public extension PermissionRequest {
    /// True when the CLI offered a permission rule we can persist ("Allow & remember").
    var canRemember: Bool { suggestions?.array?.isEmpty == false }
}

public struct SessionState: Codable, Equatable, Sendable {
    public var id: String
    public var origin: SessionOrigin
    public var status: SessionStatus
    public var cwd: String
    public var model: String?
    /// Claude: `--permission-mode`. Codex: the approval policy (`CodexApprovalPolicy`).
    public var permissionMode: String?
    public var pendingPermissions: [PermissionRequest]
    public var lastError: String?
    public var agent: AgentKind
    public var kind: SessionKind
    /// Reasoning effort, in the agent's vocabulary (Codex only for now).
    public var effort: String?
    /// Codex sandbox mode (`CodexSandboxMode`).
    public var sandbox: String?
    /// Slash commands the CLI advertised in its init message, for the composer's "/" menu.
    public var slashCommands: [String]
    /// Prompts sent while the agent was mid-turn, in the order they will go out once it finishes.
    public var queued: [QueuedPrompt]

    public init(id: String, origin: SessionOrigin, status: SessionStatus, cwd: String, model: String? = nil, permissionMode: String? = nil,
                pendingPermissions: [PermissionRequest] = [], lastError: String? = nil, agent: AgentKind = .claude, kind: SessionKind = .agent,
                effort: String? = nil, sandbox: String? = nil, slashCommands: [String] = [], queued: [QueuedPrompt] = []) {
        self.id = id
        self.origin = origin
        self.status = status
        self.cwd = cwd
        self.model = model
        self.permissionMode = permissionMode
        self.pendingPermissions = pendingPermissions
        self.lastError = lastError
        self.agent = agent
        self.kind = kind
        self.effort = effort
        self.sandbox = sandbox
        self.slashCommands = slashCommands
        self.queued = queued
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        origin = try c.decode(SessionOrigin.self, forKey: .origin)
        status = try c.decode(SessionStatus.self, forKey: .status)
        cwd = try c.decode(String.self, forKey: .cwd)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode)
        pendingPermissions = try c.decodeIfPresent([PermissionRequest].self, forKey: .pendingPermissions) ?? []
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        agent = try c.decodeIfPresent(AgentKind.self, forKey: .agent) ?? .claude
        kind = try c.decodeIfPresent(SessionKind.self, forKey: .kind) ?? .agent
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        sandbox = try c.decodeIfPresent(String.self, forKey: .sandbox)
        slashCommands = try c.decodeIfPresent([String].self, forKey: .slashCommands) ?? []
        queued = try c.decodeIfPresent([QueuedPrompt].self, forKey: .queued) ?? []
    }
}

/// A prompt waiting for the current turn to end. The host keeps the images / attachments; the phone
/// only needs to show what was typed and let the user pull it back out of the queue.
public struct QueuedPrompt: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public var attachmentCount: Int
    public var queuedAt: Date

    public init(id: String = UUID().uuidString.lowercased(), text: String, attachmentCount: Int = 0, queuedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.attachmentCount = attachmentCount
        self.queuedAt = queuedAt
    }
}

public struct ProjectInfo: Codable, Equatable, Identifiable, Sendable {
    public var path: String
    public var lastUsed: Date
    public var sessionCount: Int
    /// The folder is a project in the Codex app on the Mac, so Codex threads started in it show up in
    /// the app's sidebar. `nil` from hosts that do not know.
    public var inCodexApp: Bool?
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    public init(path: String, lastUsed: Date, sessionCount: Int, inCodexApp: Bool? = nil) {
        self.path = path
        self.lastUsed = lastUsed
        self.sessionCount = sessionCount
        self.inCodexApp = inCodexApp
    }
}

/// Options for starting a brand-new session from the phone.
public struct NewSessionOptions: Codable, Equatable, Sendable {
    public var cwd: String
    public var model: String?
    /// Claude: permission mode. Codex: approval policy.
    public var permissionMode: String?
    public var effort: String?
    public var agent: AgentKind
    /// Codex sandbox mode.
    public var sandbox: String?
    /// `.chat` ignores `cwd`, `permissionMode` and `sandbox`: the host runs the agent with no tools
    /// in its own scratch directory.
    public var kind: SessionKind

    public init(cwd: String, model: String? = nil, permissionMode: String? = nil, effort: String? = nil, agent: AgentKind = .claude,
                sandbox: String? = nil, kind: SessionKind = .agent) {
        self.cwd = cwd
        self.model = model
        self.permissionMode = permissionMode
        self.effort = effort
        self.agent = agent
        self.sandbox = sandbox
        self.kind = kind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cwd = try c.decode(String.self, forKey: .cwd)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        agent = try c.decodeIfPresent(AgentKind.self, forKey: .agent) ?? .claude
        sandbox = try c.decodeIfPresent(String.self, forKey: .sandbox)
        kind = try c.decodeIfPresent(SessionKind.self, forKey: .kind) ?? .agent
    }

    /// A quick question: no project, no tools.
    public static func chat(agent: AgentKind, model: String? = nil, effort: String? = nil) -> NewSessionOptions {
        NewSessionOptions(cwd: "", model: model, effort: effort, agent: agent, kind: .chat)
    }
}

/// Permission modes accepted by `claude --permission-mode`.
public enum PermissionMode: String, CaseIterable, Codable, Sendable {
    case manual, acceptEdits, plan, auto, dontAsk, bypassPermissions

    public var label: String {
        switch self {
        case .manual: return "Ask every time"
        case .acceptEdits: return "Accept edits"
        case .plan: return "Plan"
        case .auto: return "Auto"
        case .dontAsk: return "Don't ask"
        case .bypassPermissions: return "Bypass permissions"
        }
    }
}

/// Codex `approvalPolicy`: when the agent stops to ask before acting.
public enum CodexApprovalPolicy: String, CaseIterable, Codable, Sendable {
    case onRequest = "on-request"
    case untrusted
    case never

    public var label: String {
        switch self {
        case .onRequest: return "Ask when needed"
        case .untrusted: return "Ask for untrusted commands"
        case .never: return "Never ask"
        }
    }

    public var hint: String {
        switch self {
        case .onRequest: return "Codex asks when a command needs to escape the sandbox or looks risky."
        case .untrusted: return "Only known-safe commands run unasked; everything else comes to you."
        case .never: return "Nothing is asked; blocked actions fail instead."
        }
    }
}

/// Codex `sandbox`: what the agent's commands may touch without asking.
public enum CodexSandboxMode: String, CaseIterable, Codable, Sendable {
    case workspaceWrite = "workspace-write"
    case readOnly = "read-only"
    case dangerFullAccess = "danger-full-access"

    public var label: String {
        switch self {
        case .workspaceWrite: return "Workspace write"
        case .readOnly: return "Read only"
        case .dangerFullAccess: return "Full access"
        }
    }
}

/// An iOS Simulator on the Mac, as listed by `simctl` (booted or not; unavailable runtimes are left out).
public struct SimulatorInfo: Codable, Equatable, Identifiable, Sendable {
    public var udid: String
    public var name: String
    /// Human-readable runtime, e.g. "iOS 26.2".
    public var runtime: String
    /// `Booted`, `Shutdown`, or `Booting` while the daemon waits for a boot it started to finish.
    public var state: String

    public var id: String { udid }
    public var isBooted: Bool { state == "Booted" }
    public var isBooting: Bool { state == "Booting" }

    /// Runtime ordering for lists: iOS first, then the other platforms, newest version first.
    public static func runtimePrecedes(_ a: String, _ b: String) -> Bool {
        let platforms = ["iOS", "iPadOS", "watchOS", "tvOS", "visionOS", "xrOS"]
        func rank(_ s: String) -> Int { platforms.firstIndex { s.hasPrefix($0) } ?? platforms.count }
        if rank(a) != rank(b) { return rank(a) < rank(b) }
        return a.compare(b, options: .numeric) == .orderedDescending
    }

    public init(udid: String, name: String, runtime: String, state: String) {
        self.udid = udid
        self.name = name
        self.runtime = runtime
        self.state = state
    }
}

/// One H.264 access unit of a simulator live view (AVCC layout: 4-byte length-prefixed NAL units, as
/// VideoToolbox emits them). Key frames carry the SPS/PPS a decoder needs to start; a viewer joining
/// mid-stream waits for the next one. `width`/`height` are the coded size.
public struct SimulatorVideoFrame: Codable, Equatable, Sendable {
    public var udid: String
    public var seq: Int
    public var width: Int
    public var height: Int
    public var keyframe: Bool
    public var spsBase64: String?
    public var ppsBase64: String?
    public var dataBase64: String
    /// Presentation time in milliseconds since the stream started.
    public var ptsMillis: Int

    public init(udid: String, seq: Int, width: Int, height: Int, keyframe: Bool, spsBase64: String?, ppsBase64: String?, dataBase64: String, ptsMillis: Int) {
        self.udid = udid
        self.seq = seq
        self.width = width
        self.height = height
        self.keyframe = keyframe
        self.spsBase64 = spsBase64
        self.ppsBase64 = ppsBase64
        self.dataBase64 = dataBase64
        self.ptsMillis = ptsMillis
    }
}

/// One JPEG frame of a simulator live view (the fallback when the Mac cannot stream video).
/// `jpegBase64 == nil` is a heartbeat: the screen has not changed since the previous frame, so
/// nothing was re-sent.
public struct SimulatorFrame: Codable, Equatable, Sendable {
    public var udid: String
    public var seq: Int
    public var width: Int
    public var height: Int
    public var jpegBase64: String?
    public var capturedAt: Date

    public init(udid: String, seq: Int, width: Int, height: Int, jpegBase64: String?, capturedAt: Date) {
        self.udid = udid
        self.seq = seq
        self.width = width
        self.height = height
        self.jpegBase64 = jpegBase64
        self.capturedAt = capturedAt
    }
}

/// Input injected into a booted simulator from the phone. Points are unit coordinates of the
/// simulator screen — `0…1` from the top-left, the same for every frame size — so the phone never
/// needs to know the device's point size or scale.
public enum SimulatorInputEvent: Codable, Equatable, Sendable {
    /// Finger down and up at one point; `holdSeconds` > ~0.5 is a long press.
    case tap(x: Double, y: Double, holdSeconds: Double? = nil)
    /// One finger tracked live: `began` puts it down, `moved` drags it, `ended` lifts it. Sent as the
    /// phone's gesture progresses, so swipes and scrolls happen under the finger rather than after it.
    case touch(phase: SimulatorTouchPhase, x: Double, y: Double)
    /// Text entered into the focused field (pasted via the simulator pasteboard; newlines press Return).
    case text(text: String)
    /// A single named key of the hardware keyboard.
    case key(key: SimulatorKey)
    /// A hardware button press.
    case button(button: SimulatorHardwareButton)
}

public enum SimulatorTouchPhase: String, Codable, Sendable {
    case began, moved, ended
}

public enum SimulatorKey: String, Codable, CaseIterable, Sendable {
    case `return`, backspace, delete, tab, escape, space, up, down, left, right
}

public enum SimulatorHardwareButton: String, Codable, CaseIterable, Sendable {
    case home, lock, siri
}

/// Something the phone can do to a simulator besides watching it.
public enum SimulatorAction: Codable, Equatable, Sendable {
    /// Boot headless (no Simulator.app window; the phone's live view is the window).
    case boot
    case shutdown
    case launch(bundleId: String)
    case terminate(bundleId: String)
    /// `simctl openurl` — deep links, universal links, http(s).
    case openURL(url: String)

    public var label: String {
        switch self {
        case .boot: return "Boot"
        case .shutdown: return "Shut down"
        case .launch: return "Launch"
        case .terminate: return "Quit"
        case .openURL: return "Open URL"
        }
    }
}

/// An app installed on a simulator (`simctl listapps`).
public struct SimulatorApp: Codable, Equatable, Identifiable, Sendable {
    public var bundleId: String
    public var name: String
    /// `User` for apps installed by a developer, `System` for Apple's.
    public var kind: String

    public var id: String { bundleId }
    public var isUserApp: Bool { kind == "User" }

    public init(bundleId: String, name: String, kind: String) {
        self.bundleId = bundleId
        self.name = name
        self.kind = kind
    }
}
