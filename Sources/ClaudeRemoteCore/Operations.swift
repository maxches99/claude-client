import Foundation

// MARK: - Before / after preview

/// Screenshots of the app as it was when a task started and as the task left it: the project's
/// `.ccremote.json` `"preview"` command builds and launches it in the Simulator, the host takes a still.
public struct TaskPreview: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case before, after, done, failed }

    public var state: State
    /// JPEGs on the host, fetched with `fetchFile`.
    public var beforePath: String?
    public var afterPath: String?
    public var error: String?

    public init(state: State, beforePath: String? = nil, afterPath: String? = nil, error: String? = nil) {
        self.state = state
        self.beforePath = beforePath
        self.afterPath = afterPath
        self.error = error
    }
}

/// `"preview": "command"` or `"preview": {"command": …, "device": "iPhone 17 Pro", "settle": 4}`.
public struct PreviewConfig: Equatable, Sendable {
    public var command: String
    /// Simulator name or UDID; nil = the booted one.
    public var device: String?
    /// Seconds to wait after the command before the screenshot (the app needs to draw).
    public var settle: Double

    public init(command: String, device: String? = nil, settle: Double = 4) {
        self.command = command
        self.device = device
        self.settle = settle
    }

    public static func parse(_ json: JSONValue?) -> PreviewConfig? {
        if let command = json?.string, !command.isEmpty { return PreviewConfig(command: command) }
        guard let command = json?["command"]?.string, !command.isEmpty else { return nil }
        return PreviewConfig(command: command, device: json?["device"]?.string, settle: json?["settle"]?.double ?? 4)
    }
}

// MARK: - Snapshots

/// The working tree as it was before a task ran in it (tracked and untracked files, not ignored ones),
/// kept as a commit under `refs/ccremote/snapshots/…` — nothing in the tree or the index is touched.
public struct TaskSnapshot: Codable, Equatable, Sendable {
    public var commit: String
    /// The branch head then (a task that committed is rolled back past its commits too).
    public var head: String
    public var branch: String?
    public var createdAt: Date
    /// Restored already (the snapshot stays until the task is deleted).
    public var restoredAt: Date?

    public init(commit: String, head: String, branch: String?, createdAt: Date = Date(), restoredAt: Date? = nil) {
        self.commit = commit
        self.head = head
        self.branch = branch
        self.createdAt = createdAt
        self.restoredAt = restoredAt
    }
}

// MARK: - Event feed

/// One thing that happened on a host, for the feed that merges every Mac and the hub.
public struct HostEvent: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case session, permission, task, ci, duel, process, host, phone

        public var label: String {
            switch self {
            case .session: return "Sessions"
            case .permission: return "Approvals"
            case .task: return "Tasks"
            case .ci: return "CI"
            case .duel: return "Duels"
            case .process: return "Processes"
            case .host: return "Host"
            case .phone: return "Phones"
            }
        }

        public var systemImage: String {
            switch self {
            case .session: return "bubble.left.and.text.bubble.right"
            case .permission: return "hand.raised"
            case .task: return "list.bullet.rectangle"
            case .ci: return "checkmark.seal"
            case .duel: return "figure.fencing"
            case .process: return "bolt.horizontal"
            case .host: return "desktopcomputer"
            case .phone: return "iphone"
            }
        }
    }

    public enum Severity: String, Codable, Sendable { case info, success, warning, error }

    public var id: String
    public var date: Date
    public var kind: Kind
    public var severity: Severity
    public var title: String
    public var detail: String?
    public var sessionId: String?
    public var taskId: String?
    public var url: String?

    public init(id: String = UUID().uuidString.lowercased(), date: Date = Date(), kind: Kind, severity: Severity = .info, title: String,
                detail: String? = nil, sessionId: String? = nil, taskId: String? = nil, url: String? = nil) {
        self.id = id
        self.date = date
        self.kind = kind
        self.severity = severity
        self.title = title
        self.detail = detail
        self.sessionId = sessionId
        self.taskId = taskId
        self.url = url
    }
}

// MARK: - Host health

/// How the machine behind a host is doing: room on disk, memory, load, power, and whether the agents
/// and GitHub are still logged in. `warnings` says what needs attention, in words.
public struct HostHealth: Codable, Equatable, Sendable {
    public var checkedAt: Date
    public var diskFree: Int64?
    public var diskTotal: Int64?
    public var memoryUsed: Int64?
    public var memoryTotal: Int64?
    public var load1: Double?
    public var cpuCount: Int
    /// Percent; nil on a machine without a battery.
    public var battery: Int?
    public var charging: Bool?
    public var onAC: Bool?
    public var uptime: TimeInterval?
    public var claudeLoggedIn: Bool?
    public var codexLoggedIn: Bool?
    public var githubLogin: String?
    public var githubInstalled: Bool
    public var warnings: [String]

    public init(checkedAt: Date = Date(), diskFree: Int64? = nil, diskTotal: Int64? = nil, memoryUsed: Int64? = nil, memoryTotal: Int64? = nil,
                load1: Double? = nil, cpuCount: Int = 1, battery: Int? = nil, charging: Bool? = nil, onAC: Bool? = nil,
                uptime: TimeInterval? = nil, claudeLoggedIn: Bool? = nil, codexLoggedIn: Bool? = nil, githubLogin: String? = nil,
                githubInstalled: Bool = false, warnings: [String] = []) {
        self.checkedAt = checkedAt
        self.diskFree = diskFree
        self.diskTotal = diskTotal
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.load1 = load1
        self.cpuCount = cpuCount
        self.battery = battery
        self.charging = charging
        self.onAC = onAC
        self.uptime = uptime
        self.claudeLoggedIn = claudeLoggedIn
        self.codexLoggedIn = codexLoggedIn
        self.githubLogin = githubLogin
        self.githubInstalled = githubInstalled
        self.warnings = warnings
    }

    /// Fills `warnings` from the numbers: little disk left, memory nearly full, a battery running down,
    /// an agent that logged out.
    public mutating func assess() {
        var out: [String] = []
        if let free = diskFree, let total = diskTotal, total > 0 {
            if free < 5 * 1_073_741_824 || Double(free) / Double(total) < 0.05 {
                out.append("Disk almost full — \(HostHealth.bytes(free)) left")
            }
        }
        if let used = memoryUsed, let total = memoryTotal, total > 0, Double(used) / Double(total) > 0.92 {
            out.append("Memory nearly full (\(Int(Double(used) / Double(total) * 100))%)")
        }
        if let load = load1, load > Double(max(cpuCount, 1)) * 1.5 { out.append(String(format: "Heavy load (%.1f)", load)) }
        if let battery, charging != true, onAC != true, battery < 20 { out.append("Battery at \(battery)% and not charging") }
        if claudeLoggedIn == false { out.append("The Claude CLI is logged out") }
        if codexLoggedIn == false { out.append("Codex is logged out") }
        warnings = out
    }

    public static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// `MemTotal:` / `MemAvailable:` of `/proc/meminfo` → (used, total) in bytes.
    public static func parseMeminfo(_ text: String) -> (used: Int64, total: Int64)? {
        var values: [String: Int64] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == ":" || $0 == " " }).map(String.init)
            if parts.count >= 2, let kb = Int64(parts[1]) { values[parts[0]] = kb * 1024 }
        }
        guard let total = values["MemTotal"], let available = values["MemAvailable"] else { return nil }
        return (total - available, total)
    }

    /// `pmset -g batt`: "Now drawing from 'AC Power'" / "-InternalBattery-0 (id=…)	87%; charging; …".
    public static func parsePmset(_ text: String) -> (battery: Int?, charging: Bool?, onAC: Bool?) {
        let onAC = text.contains("'AC Power'") ? true : (text.contains("'Battery Power'") ? false : nil)
        guard let r = text.range(of: #"(\d{1,3})%;\s*([a-zA-Z ]+);"#, options: .regularExpression) else { return (nil, nil, onAC) }
        let match = String(text[r])
        let percent = Int(match.prefix { $0.isNumber })
        let state = match.lowercased()
        let charging = state.contains("discharging") ? false : (state.contains("charging") || state.contains("charged"))
        return (percent, charging, onAC)
    }
}
