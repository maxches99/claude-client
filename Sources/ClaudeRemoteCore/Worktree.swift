import Foundation

/// One entry of `git worktree list` — a checkout of the repo in its own directory, so several
/// agents can work on different branches without fighting over one working tree.
public struct Worktree: Codable, Equatable, Identifiable, Sendable {
    public var path: String
    public var branch: String?
    /// Short commit when the worktree is detached.
    public var head: String?
    /// The repository's own working tree (it cannot be removed).
    public var isMain: Bool
    public var locked: Bool
    public var prunable: Bool

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    public init(path: String, branch: String? = nil, head: String? = nil, isMain: Bool = false, locked: Bool = false, prunable: Bool = false) {
        self.path = path
        self.branch = branch
        self.head = head
        self.isMain = isMain
        self.locked = locked
        self.prunable = prunable
    }

    /// Parses `git worktree list --porcelain`. The first record is the main working tree.
    public static func parse(porcelain text: String) -> [Worktree] {
        var result: [Worktree] = []
        var current: Worktree?
        func flush() {
            if var w = current {
                w.isMain = result.isEmpty
                result.append(w)
            }
            current = nil
        }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty { flush(); continue }
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts.first ?? "")
            let value = parts.count > 1 ? String(parts[1]) : ""
            switch key {
            case "worktree":
                flush()
                current = Worktree(path: value)
            case "HEAD":
                current?.head = String(value.prefix(7))
            case "branch":
                // refs/heads/feature → feature
                current?.branch = value.hasPrefix("refs/heads/") ? String(value.dropFirst("refs/heads/".count)) : value
            case "detached":
                current?.branch = nil
            case "locked":
                current?.locked = true
            case "prunable":
                current?.prunable = true
            default:
                break
            }
        }
        flush()
        return result
    }
}

/// What the phone asks the Mac to do with worktrees.
public enum WorktreeAction: Codable, Equatable, Sendable {
    /// Create `<repo>-<name>` next to the repo, on `branch` (created from `base` when it is new).
    case add(name: String, branch: String, base: String?)
    case remove(path: String, force: Bool)
    /// Drop administrative files for worktrees whose directory is gone.
    case prune

    public var label: String {
        switch self {
        case .add(let name, _, _): return "New worktree \(name)"
        case .remove(let path, _): return "Remove \((path as NSString).lastPathComponent)"
        case .prune: return "Prune worktrees"
        }
    }
}
