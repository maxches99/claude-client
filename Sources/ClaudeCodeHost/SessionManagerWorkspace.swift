#if os(macOS) || os(Linux)
import Foundation
import ClaudeRemoteCore

/// Repositories cloned onto the host — how a machine with no projects of its own (the VPS hub) gets
/// something for its agents to work on.
extension SessionManager {
    /// Git repositories directly under the workspace, as projects.
    func workspaceRepositories() -> [ProjectInfo] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: workspaceRoot) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.compactMap { name in
            let path = (workspaceRoot as NSString).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) else { return nil }
            let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
            return ProjectInfo(path: path, lastUsed: mtime, sessionCount: 0)
        }
    }

    public func listRemoteRepositories() async throws -> [RemoteRepository] {
        guard SessionManager.locateGh() != nil else { throw GitError.refused("GitHub CLI (gh) is not installed on this host.") }
        let root = workspaceRoot
        let result: Result<[RemoteRepository], Error> = await offActor { [self] in
            do {
                let r = try runGh(["repo", "list", "--limit", "100", "--json", "nameWithOwner,description,isPrivate,updatedAt"], cwd: NSHomeDirectory(), timeout: 60)
                guard r.code == 0 else {
                    let why = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
                    throw GitError.refused(why.contains("auth login") ? "gh is not logged in on this host — run `gh auth login` there." : why)
                }
                let json = try JSONValue.parse(Data(r.out.utf8))
                let iso = ISO8601DateFormatter()
                return .success((json.array ?? []).compactMap { item in
                    guard let name = item["nameWithOwner"]?.string else { return nil }
                    let short = name.split(separator: "/").last.map(String.init) ?? name
                    let local = (root as NSString).appendingPathComponent(short)
                    return RemoteRepository(nameWithOwner: name, description: item["description"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                                            isPrivate: item["isPrivate"]?.bool ?? false,
                                            updatedAt: item["updatedAt"]?.string.flatMap { iso.date(from: $0) },
                                            localPath: FileManager.default.fileExists(atPath: local) ? local : nil)
                })
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
    }

    /// Clones `source` — a URL, or `owner/name` on GitHub — into the workspace. A repository already
    /// there is not cloned again; its path is returned.
    public func cloneRepository(source: String) async throws -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let plan = SessionManager.clonePlan(trimmed) else { throw GitError.refused("Give a repository URL or owner/name.") }
        let dest = (workspaceRoot as NSString).appendingPathComponent(plan.name)
        if FileManager.default.fileExists(atPath: (dest as NSString).appendingPathComponent(".git")) { return dest }
        guard !FileManager.default.fileExists(atPath: dest) else { throw GitError.refused("\(dest) already exists and is not a repository.") }
        try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)
        let root = workspaceRoot
        let result: Result<Void, Error> = await offActor { [self] in
            let r: (code: Int32, out: String, err: String)
            if let shorthand = plan.shorthand, SessionManager.locateGh() != nil {
                // gh knows how this host is logged in to GitHub (https token or ssh).
                guard let gh = try? runGh(["repo", "clone", shorthand, dest], cwd: root, timeout: 900) else { return .failure(GitError.refused("gh failed to start")) }
                r = gh
            } else {
                r = runGit(["clone", plan.url, dest], timeout: 900)
            }
            guard r.code == 0 else {
                try? FileManager.default.removeItem(atPath: dest)
                return .failure(GitError.refused("Clone failed: \((r.err + r.out).trimmingCharacters(in: .whitespacesAndNewlines).suffix(600))"))
            }
            return .success(())
        }
        try result.get()
        log("cloned \(trimmed) into \(dest)")
        broadcast(.projects(items: listProjects()))
        return dest
    }

    /// How to clone what was typed: the URL to use, the folder name, and `owner/name` for gh.
    static func clonePlan(_ source: String) -> (url: String, name: String, shorthand: String?)? {
        guard !source.isEmpty, !source.contains(" ") else { return nil }
        let shorthandPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
        if shorthandPattern.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil {
            let name = String(source.split(separator: "/").last!).replacingOccurrences(of: ".git", with: "")
            return ("https://github.com/\(source).git", name, source.hasSuffix(".git") ? String(source.dropLast(4)) : source)
        }
        guard ["https://", "http://", "git@", "ssh://", "file://"].contains(where: source.hasPrefix) else { return nil }
        var last = source.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
        if last.hasSuffix(".git") { last = String(last.dropLast(4)) }
        guard !last.isEmpty, !last.hasPrefix(".") else { return nil }
        var shorthand: String?
        if source.contains("github.com") {
            let parts = source.replacingOccurrences(of: ".git", with: "").split(whereSeparator: { $0 == "/" || $0 == ":" })
            if parts.count >= 2 { shorthand = "\(parts[parts.count - 2])/\(parts[parts.count - 1])" }
        }
        return (source, last, shorthand)
    }
}
#endif
