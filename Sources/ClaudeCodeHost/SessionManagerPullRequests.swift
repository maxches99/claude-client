#if os(macOS)
import Foundation
import ClaudeRemoteCore

/// A change measured against a base commit, and the step from a finished task to a draft pull request.
extension SessionManager {
    /// Runs slow, self-contained work (git over the network, test suites) off the actor, so the daemon
    /// keeps answering phones meanwhile.
    func offActor<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .utility) { body() }.value
    }

    /// Everything in `dir` against `base`: commits since, staged, unstaged and untracked files.
    nonisolated func changes(in dir: String, against base: String) -> (diff: String, stat: DiffStat, files: [ReviewFile]) {
        var files: [ReviewFile] = []
        let numstat = runGit(["-C", dir, "diff", "--numstat", base], timeout: 60).out
        let nameStatus = runGit(["-C", dir, "diff", "--name-status", base], timeout: 60).out
        var statuses: [String: String] = [:]
        for line in nameStatus.split(separator: "\n") {
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count >= 2 else { continue }
            statuses[parts.last!] = String(parts[0].prefix(1))
        }
        var fullDiff = ""
        var totals = DiffStat(files: 0, insertions: 0, deletions: 0)
        for line in numstat.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            // Renames come as "old => new" (or "dir/{old => new}"); the diff is keyed by the new path.
            var path = parts[2]
            if path.contains(" => ") { path = SessionManager.renamedPath(path) }
            let add = Int(parts[0]) ?? 0, del = Int(parts[1]) ?? 0
            let diff = runGit(["-C", dir, "diff", base, "--", path], timeout: 60).out
            files.append(SessionManager.reviewFile(path: path, status: statuses[path] ?? "M", additions: add, deletions: del, diff: diff))
            fullDiff += diff
            totals.files += 1; totals.insertions += add; totals.deletions += del
        }
        let untracked = runGit(["-C", dir, "ls-files", "--others", "--exclude-standard"], timeout: 30).out
        for path in untracked.split(separator: "\n").map(String.init) where !path.isEmpty {
            let diff = runGit(["-C", dir, "diff", "--no-index", "--", "/dev/null", path], timeout: 30).out
            let added = diff.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
            files.append(SessionManager.reviewFile(path: path, status: "?", additions: added, deletions: 0, diff: diff))
            fullDiff += diff
            totals.files += 1; totals.insertions += added
        }
        return (fullDiff, totals, files.sorted { $0.path < $1.path })
    }

    static let reviewFileLimit = 200_000

    static func reviewFile(path: String, status: String, additions: Int, deletions: Int, diff: String) -> ReviewFile {
        guard diff.utf8.count > reviewFileLimit else { return ReviewFile(path: path, status: status, additions: additions, deletions: deletions, diff: diff) }
        return ReviewFile(path: path, status: status, additions: additions, deletions: deletions,
                          diff: String(diff.prefix(reviewFileLimit)) + "\n… (diff cut here)", truncated: true)
    }

    /// `a/{old => new}/b` → `a/new/b`; `old => new` → `new`.
    static func renamedPath(_ s: String) -> String {
        if let open = s.firstIndex(of: "{"), let close = s.firstIndex(of: "}"), open < close {
            let inner = s[s.index(after: open)..<close]
            let newPart = inner.components(separatedBy: " => ").last ?? String(inner)
            return (String(s[..<open]) + newPart + String(s[s.index(after: close)...])).replacingOccurrences(of: "//", with: "/")
        }
        return s.components(separatedBy: " => ").last ?? s
    }

    /// Commits what a finished worktree task changed, pushes its branch and opens a draft pull request.
    /// Returns the pull request's URL.
    func openPullRequest(forTask taskId: String) async throws -> String {
        guard let task = tasks.first(where: { $0.id == taskId }) else { throw GitError.refused("That task is gone.") }
        guard let worktree = task.worktreePath, FileManager.default.fileExists(atPath: worktree) else {
            throw GitError.refused("Only a task that ran in its own worktree can become a pull request.")
        }
        guard SessionManager.locateGh() != nil else { throw GitError.refused("GitHub CLI (gh) is not installed on this host.") }
        let title = task.title
        var text = "## Task\n\n" + task.prompt
        if let summary = task.resultSummary, !summary.isEmpty { text += "\n\n## Summary\n\n" + summary }
        if let stat = task.diffStat { text += "\n\n" + stat.label }
        if let issue = task.issue { text += "\n\nFixes #\(issue.number)" }
        let body = text
        let prompt = task.prompt
        let base = task.baseCommit
        let result: Result<String, Error> = await offActor { [self] in
            do {
                let branch = runGit(["-C", worktree, "rev-parse", "--abbrev-ref", "HEAD"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !branch.isEmpty, branch != "HEAD" else { throw GitError.refused("The worktree is not on a branch.") }
                _ = runGit(["-C", worktree, "add", "-A"], timeout: 60)
                if runGit(["-C", worktree, "diff", "--cached", "--quiet"]).code != 0 {
                    let excerpt = prompt.count > 1500 ? String(prompt.prefix(1500)) + "…" : prompt
                    let commit = runGit(["-C", worktree, "commit", "-q", "-m", title, "-m", excerpt], timeout: 60)
                    guard commit.code == 0 else {
                        let why = (commit.err + commit.out).trimmingCharacters(in: .whitespacesAndNewlines)
                        throw GitError.refused(why.contains("tell me who you are") || why.contains("user.email")
                                               ? "git has no author on this host — set user.name and user.email, then try again."
                                               : "Commit failed: \(why)")
                    }
                }
                if let base {
                    let ahead = Int(runGit(["-C", worktree, "rev-list", "--count", "\(base)..HEAD"]).out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                    guard ahead > 0 else { throw GitError.refused("The task changed nothing — no pull request to open.") }
                }
                let push = runGit(["-C", worktree, "push", "-u", "origin", branch], timeout: 180)
                guard push.code == 0 else { throw GitError.refused("Push failed: \((push.err + push.out).trimmingCharacters(in: .whitespacesAndNewlines))") }
                let pr = try runGh(["pr", "create", "--draft", "--head", branch, "--title", title, "--body", body], cwd: worktree, timeout: 120)
                let text = (pr.out + "\n" + pr.err)
                guard let url = text.split(whereSeparator: \.isWhitespace).map(String.init).last(where: { $0.hasPrefix("https://") && $0.contains("/pull/") }) else {
                    throw GitError.refused("gh did not open the pull request: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
                return .success(url)
            } catch {
                return .failure(error)
            }
        }
        let url = try result.get()
        if let idx = tasks.firstIndex(where: { $0.id == taskId }) {
            tasks[idx].pullRequestURL = url
            saveTasks()
            broadcastTasks()
        }
        log("task \(taskId.prefix(6)) → \(url)")
        return url
    }
}
#endif
