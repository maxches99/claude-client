import Foundation

/// A session open in Claude Desktop whose browser tool has gone quiet. The desktop app asks whether a
/// site may be used in its own window — outside the CLI, so no permission hook sees it — and the turn
/// just stops until someone answers on that Mac. The phone can't answer it, but it can say so.
public enum BrowserWait {
    /// Tools whose site prompts come from the app hosting the browser (the desktop app's pane, Chrome).
    public static let toolPrefixes = ["mcp__Claude_Browser__", "mcp__claude-in-chrome__"]

    public struct Stall: Equatable, Sendable {
        public let toolUseId: String
        public let toolName: String
        public let since: Date
    }

    /// The latest browser tool call, if it has no result yet, nothing came after it, and it started more
    /// than `threshold` seconds before `now`.
    public static func stalled(in items: [TranscriptItem], now: Date = Date(), threshold: TimeInterval = 60) -> Stall? {
        guard let last = items.last, case .toolUse(let id, let name, _, _, let streaming) = last.kind,
              !streaming, toolPrefixes.contains(where: name.hasPrefix), let since = last.timestamp,
              now.timeIntervalSince(since) >= threshold else { return nil }
        return Stall(toolUseId: id, toolName: name, since: since)
    }

    /// "javascript_tool" from "mcp__Claude_Browser__javascript_tool".
    public static func shortName(_ toolName: String) -> String {
        for prefix in toolPrefixes where toolName.hasPrefix(prefix) { return String(toolName.dropFirst(prefix.count)) }
        return toolName
    }
}

/// The buttons of Claude Desktop's "allow this site?" card.
public enum SitePromptAnswer: String, Codable, CaseIterable, Sendable {
    case allowOnce
    case alwaysAllow
    case cancel
}
