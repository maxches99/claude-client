import Foundation

/// A crash reporter the host watches for a project (protocol 11). Sentry for now; its REST API lists
/// a project's issues and the latest event of each, stack trace included.
public struct CrashSource: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case sentry
    }

    public var id: String
    public var kind: Kind
    /// `https://sentry.io`, or a self-hosted Sentry.
    public var baseURL: String
    public var organization: String
    public var project: String
    /// The local repository a fix goes into.
    public var cwd: String
    /// Start a fix task by itself for every new crash (otherwise the phone offers a button).
    public var autoFix: Bool
    /// Host → phone: a token is stored. The token itself never goes back to a phone.
    public var hasToken: Bool
    /// Phone → host only, when it is set or changed; nil keeps the stored one.
    public var token: String?
    public var lastCheckedAt: Date?
    public var lastError: String?

    public init(id: String = UUID().uuidString.lowercased(), kind: Kind = .sentry, baseURL: String = "https://sentry.io",
                organization: String, project: String, cwd: String, autoFix: Bool = false, hasToken: Bool = false,
                token: String? = nil, lastCheckedAt: Date? = nil, lastError: String? = nil) {
        self.id = id
        self.kind = kind
        self.baseURL = baseURL
        self.organization = organization
        self.project = project
        self.cwd = cwd
        self.autoFix = autoFix
        self.hasToken = hasToken
        self.token = token
        self.lastCheckedAt = lastCheckedAt
        self.lastError = lastError
    }

    /// "acme / ios-app".
    public var label: String { "\(organization) / \(project)" }

    /// The copy a phone may see: no token.
    public var forPhone: CrashSource {
        var copy = self
        copy.token = nil
        return copy
    }
}

/// One crash group (a Sentry issue) the host has seen.
public struct CrashIssue: Codable, Equatable, Identifiable, Sendable {
    /// `<source id>:<Sentry issue id>`, unique across sources.
    public var id: String
    public var sourceId: String
    /// The reporter's own id.
    public var issueId: String
    /// "IOS-APP-3F".
    public var shortId: String?
    public var title: String
    /// Where it happened ("ChatView.send()").
    public var culprit: String?
    public var level: String?
    public var count: Int
    public var userCount: Int
    public var firstSeen: Date?
    public var lastSeen: Date?
    public var permalink: String?
    /// When the host first noticed it (what "new" is measured by).
    public var noticedAt: Date
    /// The fix task started for it.
    public var taskId: String?
    /// Dismissed on the phone: no button, no auto-fix.
    public var ignored: Bool

    public init(sourceId: String, issueId: String, shortId: String? = nil, title: String, culprit: String? = nil, level: String? = nil,
                count: Int = 0, userCount: Int = 0, firstSeen: Date? = nil, lastSeen: Date? = nil, permalink: String? = nil,
                noticedAt: Date = Date(), taskId: String? = nil, ignored: Bool = false) {
        self.id = "\(sourceId):\(issueId)"
        self.sourceId = sourceId
        self.issueId = issueId
        self.shortId = shortId
        self.title = title
        self.culprit = culprit
        self.level = level
        self.count = count
        self.userCount = userCount
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.permalink = permalink
        self.noticedAt = noticedAt
        self.taskId = taskId
        self.ignored = ignored
    }

    /// "12 events · 4 users".
    public var impactLabel: String {
        let events = count == 1 ? "1 event" : "\(count) events"
        guard userCount > 0 else { return events }
        return events + " · " + (userCount == 1 ? "1 user" : "\(userCount) users")
    }

    /// The prompt of the task that fixes it.
    public func fixPrompt(stack: String?) -> String {
        var lines = ["A crash reported by Sentry needs fixing.", "", "Crash: \(title)"]
        if let culprit, !culprit.isEmpty { lines.append("Where: \(culprit)") }
        lines.append("Seen: \(impactLabel)")
        if let permalink { lines.append("Report: \(permalink)") }
        if let stack, !stack.isEmpty { lines += ["", "Latest event:", stack] }
        lines += ["",
                  "Find the cause in this repository and fix it at the root, not by hiding the symptom.",
                  "Add a test that reproduces it when the code allows one.",
                  "If the stack trace points outside this repository or the cause can't be found, say so instead of guessing."]
        return lines.joined(separator: "\n")
    }
}

/// Reading Sentry's REST API answers.
public enum SentryAPI {
    /// `GET /api/0/projects/{org}/{project}/issues/` → issues.
    public static func parseIssues(_ data: Data, sourceId: String, now: Date = Date()) throws -> [CrashIssue] {
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .array(let items) = json else {
            throw ParseError.unexpected(json["detail"]?.string ?? "Sentry answered with something that is not a list of issues.")
        }
        return items.compactMap { item in
            guard let id = item["id"]?.string, let title = item["title"]?.string else { return nil }
            return CrashIssue(sourceId: sourceId, issueId: id, shortId: item["shortId"]?.string, title: title,
                              culprit: item["culprit"]?.string, level: item["level"]?.string,
                              count: number(item["count"]), userCount: number(item["userCount"]),
                              firstSeen: date(item["firstSeen"]), lastSeen: date(item["lastSeen"]),
                              permalink: item["permalink"]?.string, noticedAt: now)
        }
    }

    /// `GET /api/0/issues/{id}/events/latest/` → the exception and its stack, crashing frame first,
    /// the app's own frames only when there are any (at most `maxFrames`), plus release and device.
    public static func stackSummary(_ data: Data, maxFrames: Int = 25) -> String? {
        guard let event = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        var lines: [String] = []
        for entry in event["entries"]?.array ?? [] where entry["type"]?.string == "exception" {
            for exception in (entry["data"]?["values"]?.array ?? []).reversed() {
                let type = exception["type"]?.string ?? "Exception"
                let value = exception["value"]?.string.map { ": \($0)" } ?? ""
                lines.append(type + value)
                let frames = (exception["stacktrace"]?["frames"]?.array ?? []).reversed()
                let own = frames.filter { $0["inApp"]?.bool == true }
                for frame in (own.isEmpty ? Array(frames) : own).prefix(maxFrames) {
                    lines.append("  at " + frameLine(frame))
                }
            }
        }
        if lines.isEmpty, let message = event["message"]?.string ?? event["title"]?.string { lines.append(message) }
        var tags: [String] = []
        for tag in event["tags"]?.array ?? [] {
            guard let key = tag["key"]?.string, let value = tag["value"]?.string else { continue }
            if ["release", "os", "device", "device.family"].contains(key) { tags.append("\(key)=\(value)") }
        }
        if !tags.isEmpty { lines.append("Tags: " + tags.joined(separator: ", ")) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static func frameLine(_ frame: JSONValue) -> String {
        let function = frame["function"]?.string ?? "?"
        let file = frame["filename"]?.string ?? frame["absPath"]?.string ?? frame["package"]?.string ?? frame["module"]?.string
        guard let file else { return function }
        let line = frame["lineNo"]?.double.map { ":\(Int($0))" } ?? ""
        return "\(function) (\(file)\(line))"
    }

    public enum ParseError: Error, CustomStringConvertible {
        case unexpected(String)
        public var description: String {
            switch self { case .unexpected(let why): return why }
        }
    }

    /// Sentry sends `count` as a string and `userCount` as a number.
    private static func number(_ value: JSONValue?) -> Int {
        if let d = value?.double { return Int(d) }
        if let s = value?.string, let i = Int(s) { return i }
        return 0
    }

    private static func date(_ value: JSONValue?) -> Date? {
        guard let s = value?.string else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
