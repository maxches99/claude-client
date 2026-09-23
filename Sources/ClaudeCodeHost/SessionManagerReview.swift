#if os(macOS) || os(Linux)
import Foundation
import ClaudeRemoteCore

extension SessionManager {
    /// What the session's branch changed against `base` — for a task's worktree the commit it started
    /// from, otherwise where the branch left the default branch — with the working tree included.
    public func reviewDiff(sessionId: String, base: String?) async throws -> (base: String, files: [ReviewFile]) {
        let cwd = try gitCwd(sessionId)
        let taskBase = tasks.first { $0.worktreePath.map { ($0 as NSString).standardizingPath } == (cwd as NSString).standardizingPath }?.baseCommit
        let requested = base?.trimmingCharacters(in: .whitespaces)
        let result: Result<(String, [ReviewFile]), Error> = await offActor { [self] in
            let target: String
            if let requested, !requested.isEmpty {
                target = requested
            } else if let taskBase {
                target = taskBase
            } else {
                target = defaultBranch(in: cwd) ?? "HEAD"
            }
            let mergeBase = runGit(["-C", cwd, "merge-base", "HEAD", target]).out.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !mergeBase.isEmpty else { return .failure(GitError.refused("No common history with \(target).")) }
            let files = changes(in: cwd, against: mergeBase).files
            return .success((target, files))
        }
        return try result.get()
    }

    /// `origin/HEAD`'s branch, else a local main / master.
    nonisolated func defaultBranch(in cwd: String) -> String? {
        let remote = runGit(["-C", cwd, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remote.isEmpty { return remote }
        for name in ["main", "master"] where runGit(["-C", cwd, "rev-parse", "--verify", "--quiet", "refs/heads/\(name)"]).code == 0 { return name }
        return nil
    }
}
#endif
