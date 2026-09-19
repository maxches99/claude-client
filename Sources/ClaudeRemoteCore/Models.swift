import Foundation

/// Wire-protocol version. Bump when messages change incompatibly.
public let protocolVersion = 2

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

    public init(hostName: String, daemonVersion: String, cliVersion: String?, cliPath: String, loggedIn: Bool?,
                protocolVersion: Int = ClaudeRemoteCore.protocolVersion, codex: CodexInfo? = nil) {
        self.hostName = hostName
        self.daemonVersion = daemonVersion
        self.cliVersion = cliVersion
        self.cliPath = cliPath
        self.loggedIn = loggedIn
        self.protocolVersion = protocolVersion
        self.codex = codex
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

    public init(id: String, origin: SessionOrigin, status: SessionStatus, cwd: String, model: String? = nil, permissionMode: String? = nil,
                pendingPermissions: [PermissionRequest] = [], lastError: String? = nil, agent: AgentKind = .claude, kind: SessionKind = .agent,
                effort: String? = nil, sandbox: String? = nil) {
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
    }
}

public struct ProjectInfo: Codable, Equatable, Identifiable, Sendable {
    public var path: String
    public var lastUsed: Date
    public var sessionCount: Int
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    public init(path: String, lastUsed: Date, sessionCount: Int) {
        self.path = path
        self.lastUsed = lastUsed
        self.sessionCount = sessionCount
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

/// A booted iOS Simulator on the Mac, as listed by `simctl`.
public struct SimulatorInfo: Codable, Equatable, Identifiable, Sendable {
    public var udid: String
    public var name: String
    /// Human-readable runtime, e.g. "iOS 26.2".
    public var runtime: String
    public var state: String

    public var id: String { udid }

    public init(udid: String, name: String, runtime: String, state: String) {
        self.udid = udid
        self.name = name
        self.runtime = runtime
        self.state = state
    }
}

/// One frame of a simulator live view. `jpegBase64 == nil` is a heartbeat: the screen has not
/// changed since the previous frame, so nothing was re-sent.
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
