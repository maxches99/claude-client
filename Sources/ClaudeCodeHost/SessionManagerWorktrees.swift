#if os(macOS)
import Foundation
import ClaudeRemoteCore

extension SessionManager {
    /// The repo's worktrees — the main working tree first, then the extra checkouts.
    public func worktrees(sessionId: String) throws -> [Worktree] {
        let cwd = try gitCwd(sessionId)
        return try worktrees(repo: cwd)
    }

    func worktrees(repo: String) throws -> [Worktree] {
        let r = runGit(["-C", repo, "worktree", "list", "--porcelain"])
        guard r.code == 0 else { throw GitError.refused(r.err.isEmpty ? "git worktree list failed" : r.err) }
        return Worktree.parse(porcelain: r.out)
    }

    public func worktreeAction(sessionId: String, action: WorktreeAction) throws -> [Worktree] {
        let cwd = try gitCwd(sessionId)
        switch action {
        case .add(let name, let branch, let base):
            _ = try addWorktree(repo: cwd, name: name, branch: branch, base: base)
        case .remove(let path, let force):
            guard !path.isEmpty else { throw GitError.refused("No worktree given.") }
            let main = try worktrees(repo: cwd).first
            guard main?.path != (path as NSString).standardizingPath else {
                throw GitError.refused("That is the repository's own working tree.")
            }
            var args = ["-C", cwd, "worktree", "remove"]
            if force { args.append("--force") }
            args.append(path)
            let r = runGit(args, timeout: 60)
            guard r.code == 0 else { throw GitError.refused(r.err.isEmpty ? r.out : r.err) }
            log("worktree removed: \(path)")
        case .prune:
            _ = runGit(["-C", cwd, "worktree", "prune"], timeout: 30)
        }
        return try worktrees(repo: cwd)
    }

    /// Creates `<repo>-<name>` next to the repository on `branch`, making the branch from `base`
    /// (or the current HEAD) when it does not exist yet. Returns the new worktree's path.
    @discardableResult
    func addWorktree(repo: String, name: String, branch: String, base: String?) throws -> String {
        let root = runGit(["-C", repo, "rev-parse", "--show-toplevel"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { throw GitError.refused("Not a git repository.") }
        let safeName = SessionManager.worktreeSlug(name)
        guard !safeName.isEmpty else { throw GitError.refused("Give the worktree a name.") }
        let parent = (root as NSString).deletingLastPathComponent
        let base0 = (root as NSString).lastPathComponent + "-" + safeName
        var path = (parent as NSString).appendingPathComponent(base0)
        var n = 2
        while FileManager.default.fileExists(atPath: path) {
            path = (parent as NSString).appendingPathComponent("\(base0)-\(n)")
            n += 1
        }
        let branchName = branch.isEmpty ? safeName : branch
        let exists = runGit(["-C", root, "rev-parse", "--verify", "--quiet", "refs/heads/\(branchName)"]).code == 0
        var args = ["-C", root, "worktree", "add"]
        if exists {
            args += [path, branchName]
        } else {
            args += ["-b", branchName, path]
            if let base, !base.isEmpty { args.append(base) }
        }
        let r = runGit(args, timeout: 120)
        guard r.code == 0 else { throw GitError.refused(r.err.isEmpty ? r.out : r.err) }
        log("worktree added: \(path) on \(branchName)")
        return path
    }

    /// A branch/directory-safe version of what was typed.
    static func worktreeSlug(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        var slug = String(mapped)
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return String(slug.prefix(40))
    }
}
#endif
