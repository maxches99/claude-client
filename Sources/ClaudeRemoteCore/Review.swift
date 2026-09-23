import Foundation

/// One file of a branch review: what changed against the base, and its diff.
public struct ReviewFile: Codable, Equatable, Identifiable, Sendable {
    public var path: String
    /// `A` added, `M` modified, `D` deleted, `R` renamed, `?` untracked (new, not yet added).
    public var status: String
    public var additions: Int
    public var deletions: Int
    public var diff: String
    /// The diff was too long to send whole.
    public var truncated: Bool

    public var id: String { path }
    public var fileName: String { (path as NSString).lastPathComponent }

    public init(path: String, status: String, additions: Int, deletions: Int, diff: String, truncated: Bool = false) {
        self.path = path
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.diff = diff
        self.truncated = truncated
    }
}

/// A remark on a range of lines (or on the change as a whole), collected on the phone.
public struct ReviewComment: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var path: String?
    /// The quoted lines (a fenced diff from `DiffLines.quote`), when the remark is about lines.
    public var quote: String?
    public var text: String

    public init(id: String = UUID().uuidString, path: String?, quote: String?, text: String) {
        self.id = id
        self.path = path
        self.quote = quote
        self.text = text
    }
}

public enum ReviewPrompt {
    /// All remarks as one message the agent can work through, numbered, each with its lines.
    public static func compose(comments: [ReviewComment], base: String?) -> String {
        var out = "Review of the changes" + (base.map { " against `\($0)`" } ?? "") + ". Please address each point:\n"
        for (i, comment) in comments.enumerated() {
            out += "\n\(i + 1). "
            if let quote = comment.quote, !quote.isEmpty {
                out += quote.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n   " + comment.text.replacingOccurrences(of: "\n", with: "\n   ") + "\n"
            } else if let path = comment.path {
                out += "`\(path)`: " + comment.text + "\n"
            } else {
                out += comment.text + "\n"
            }
        }
        return out
    }
}

/// A repository the host's GitHub account can clone (`gh repo list`).
public struct RemoteRepository: Codable, Equatable, Identifiable, Sendable {
    public var nameWithOwner: String
    public var description: String?
    public var isPrivate: Bool
    public var updatedAt: Date?
    /// Already cloned into the workspace, at this path.
    public var localPath: String?

    public var id: String { nameWithOwner }
    public var name: String { nameWithOwner.split(separator: "/").last.map(String.init) ?? nameWithOwner }

    public init(nameWithOwner: String, description: String? = nil, isPrivate: Bool = false, updatedAt: Date? = nil, localPath: String? = nil) {
        self.nameWithOwner = nameWithOwner
        self.description = description
        self.isPrivate = isPrivate
        self.updatedAt = updatedAt
        self.localPath = localPath
    }
}

/// When the Mac sends its daily digest, and whether it can.
public struct DigestSchedule: Codable, Equatable, Sendable {
    /// Minutes after local midnight; nil = off.
    public var minutes: Int?
    public var lastSentAt: Date?
    /// A Telegram bot and chat are configured on the host.
    public var canSend: Bool

    public init(minutes: Int? = nil, lastSentAt: Date? = nil, canSend: Bool = false) {
        self.minutes = minutes
        self.lastSentAt = lastSentAt
        self.canSend = canSend
    }

    public var timeLabel: String? { minutes.map { String(format: "%02d:%02d", $0 / 60, $0 % 60) } }
}
