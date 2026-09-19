import Foundation

/// Wire-protocol version. Bump when messages change incompatibly.
public let protocolVersion = 1

public struct HostInfo: Codable, Equatable, Sendable {
    public var hostName: String
    public var daemonVersion: String
    public var cliVersion: String?
    public var cliPath: String
    public var loggedIn: Bool?
    public var protocolVersion: Int

    public init(hostName: String, daemonVersion: String, cliVersion: String?, cliPath: String, loggedIn: Bool?, protocolVersion: Int = ClaudeRemoteCore.protocolVersion) {
        self.hostName = hostName
        self.daemonVersion = daemonVersion
        self.cliVersion = cliVersion
        self.cliPath = cliPath
        self.loggedIn = loggedIn
        self.protocolVersion = protocolVersion
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

    public init(id: String, title: String, cwd: String, updatedAt: Date, origin: SessionOrigin, status: SessionStatus, desktopName: String? = nil, entrypoint: String? = nil) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.updatedAt = updatedAt
        self.origin = origin
        self.status = status
        self.desktopName = desktopName
        self.entrypoint = entrypoint
    }

    public var projectName: String { (cwd as NSString).lastPathComponent }

    /// Short label for where a `.desktop` session is running.
    public var sourceLabel: String {
        switch entrypoint {
        case "claude-desktop": return "Desktop"
        case "cli": return "Terminal"
        case "sdk-cli", "sdk-ts", "sdk-py": return "SDK"
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

public struct SessionState: Codable, Equatable, Sendable {
    public var id: String
    public var origin: SessionOrigin
    public var status: SessionStatus
    public var cwd: String
    public var model: String?
    public var permissionMode: String?
    public var pendingPermissions: [PermissionRequest]
    public var lastError: String?

    public init(id: String, origin: SessionOrigin, status: SessionStatus, cwd: String, model: String? = nil, permissionMode: String? = nil,
                pendingPermissions: [PermissionRequest] = [], lastError: String? = nil) {
        self.id = id
        self.origin = origin
        self.status = status
        self.cwd = cwd
        self.model = model
        self.permissionMode = permissionMode
        self.pendingPermissions = pendingPermissions
        self.lastError = lastError
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
    public var permissionMode: String?
    public var effort: String?

    public init(cwd: String, model: String? = nil, permissionMode: String? = nil, effort: String? = nil) {
        self.cwd = cwd
        self.model = model
        self.permissionMode = permissionMode
        self.effort = effort
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
