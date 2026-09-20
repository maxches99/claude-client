import Foundation

/// One entry of `git status --porcelain=v2`: a file with changes in the index, the working tree, or both.
public struct GitFile: Codable, Equatable, Identifiable, Hashable, Sendable {
    /// Path relative to the repository root (the new path for a rename).
    public var path: String
    /// Index (staged) status letter: M A D R C, or "." when nothing is staged for this path.
    public var indexStatus: String
    /// Working-tree status letter: M D, or "." when the working tree matches the index.
    public var workStatus: String
    public var untracked: Bool
    public var conflicted: Bool

    public var id: String { path }

    public init(path: String, indexStatus: String, workStatus: String, untracked: Bool = false, conflicted: Bool = false) {
        self.path = path
        self.indexStatus = indexStatus
        self.workStatus = workStatus
        self.untracked = untracked
        self.conflicted = conflicted
    }

    public var isStaged: Bool { indexStatus != "." && !untracked && !conflicted }
    public var hasWorkChanges: Bool { workStatus != "." || untracked }
    public var fileName: String { (path as NSString).lastPathComponent }

    /// The letter shown in the file list: staged status when only staged, else the working-tree one.
    public var badge: String {
        if untracked { return "U" }
        if conflicted { return "!" }
        return workStatus != "." ? workStatus : indexStatus
    }
}

/// A snapshot of the session repo: branch, sync state with the upstream, and the changed files.
public struct GitStatus: Codable, Equatable, Sendable {
    public var branch: String?           // nil when detached
    public var detachedAt: String?       // short commit when detached
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var files: [GitFile]
    public var branches: [String]
    public var lastCommit: String?       // "abc1234 Subject"

    public init(branch: String?, detachedAt: String? = nil, upstream: String? = nil, ahead: Int = 0, behind: Int = 0,
                files: [GitFile] = [], branches: [String] = [], lastCommit: String? = nil) {
        self.branch = branch
        self.detachedAt = detachedAt
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.files = files
        self.branches = branches
        self.lastCommit = lastCommit
    }

    public var staged: [GitFile] { files.filter(\.isStaged) }
    public var unstaged: [GitFile] { files.filter { $0.hasWorkChanges && !$0.untracked } }
    public var untracked: [GitFile] { files.filter(\.untracked) }
    public var isClean: Bool { files.isEmpty }
}

/// Something the phone asks the Mac to do in the session's repo. Every action answers with a
/// `gitResult` and a fresh `gitStatus`.
public enum GitAction: Codable, Equatable, Sendable {
    case stage(paths: [String])          // empty = everything (`git add -A`)
    case unstage(paths: [String])        // empty = everything
    /// Throws away working-tree changes for the paths (and deletes untracked ones). Empty = everything.
    case discard(paths: [String])
    /// `all` stages every tracked change first (`git commit -a`).
    case commit(message: String, all: Bool)
    case push(setUpstream: Bool)
    case pull
    case fetch
    case checkout(branch: String)
    case createBranch(name: String)
    /// `gh pr create` for the current branch (pushing it with an upstream first when it has none).
    case createPullRequest(title: String, body: String, draft: Bool)

    public var label: String {
        switch self {
        case .stage: return "Stage"
        case .unstage: return "Unstage"
        case .discard: return "Discard"
        case .commit: return "Commit"
        case .push: return "Push"
        case .pull: return "Pull"
        case .fetch: return "Fetch"
        case .checkout(let b): return "Checkout \(b)"
        case .createBranch(let n): return "New branch \(n)"
        case .createPullRequest: return "Create pull request"
        }
    }
}

public extension GitStatus {
    /// Parses `git status --porcelain=v2 --branch` output.
    public static func parse(porcelain text: String) -> GitStatus {
        var status = GitStatus(branch: nil)
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: false)
            guard let kind = parts.first else { continue }
            switch kind {
            case "#":
                guard parts.count >= 3 else { continue }
                let value = parts[2...].joined(separator: " ")
                switch parts[1] {
                case "branch.head": status.branch = value == "(detached)" ? nil : value
                case "branch.oid": if status.branch == nil { status.detachedAt = String(value.prefix(7)) }
                case "branch.upstream": status.upstream = value
                case "branch.ab":
                    // "+N -M"
                    for token in parts[2...] {
                        if token.hasPrefix("+") { status.ahead = Int(token.dropFirst()) ?? 0 }
                        if token.hasPrefix("-") { status.behind = Int(token.dropFirst()) ?? 0 }
                    }
                default: break
                }
            case "1":
                // 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
                guard parts.count >= 9 else { continue }
                let xy = parts[1]
                let path = parts[8...].joined(separator: " ")
                status.files.append(GitFile(path: path, indexStatus: String(xy.prefix(1)), workStatus: String(xy.suffix(1))))
            case "2":
                // 2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path><tab><origPath>
                guard parts.count >= 10 else { continue }
                let xy = parts[1]
                let paths = parts[9...].joined(separator: " ").split(separator: "\t")
                let path = paths.first.map(String.init) ?? ""
                status.files.append(GitFile(path: path, indexStatus: String(xy.prefix(1)), workStatus: String(xy.suffix(1))))
            case "u":
                guard parts.count >= 11 else { continue }
                let path = parts[10...].joined(separator: " ")
                status.files.append(GitFile(path: path, indexStatus: "U", workStatus: "U", conflicted: true))
            case "?":
                let path = parts[1...].joined(separator: " ")
                status.files.append(GitFile(path: path, indexStatus: ".", workStatus: ".", untracked: true))
            default:
                break
            }
        }
        // The .ccremote-attachments staging dir is ours; keep it out of the user's change list.
        status.files.removeAll { $0.path.hasPrefix(".ccremote-attachments/") }
        return status
    }
}
