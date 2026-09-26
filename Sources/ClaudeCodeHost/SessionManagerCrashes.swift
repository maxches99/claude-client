#if os(macOS) || os(Linux)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ClaudeRemoteCore

/// Crashes as tasks: every 15 minutes the host asks each crash reporter (Sentry) for the project's
/// unresolved issues. A crash it has not seen before goes to the feed with a notification, and one tap
/// on the phone — or nothing at all, with auto-fix — starts a task that fixes it in a worktree and opens
/// a draft pull request, the latest event's stack trace in its prompt.
extension SessionManager {
    static let crashCheckInterval: UInt64 = 15 * 60

    /// `crashes.json` next to `tasks.json`. It holds the reporters' tokens, so only the owner reads it.
    var crashStorePath: String? {
        taskStorePath.map { (($0 as NSString).deletingLastPathComponent as NSString).appendingPathComponent("crashes.json") }
    }

    public func crashReport(error: String? = nil) -> ServerMessage {
        let items = crashIssues.sorted { ($0.lastSeen ?? $0.noticedAt) > ($1.lastSeen ?? $1.noticedAt) }
        return .crashes(sources: crashSources.map(\.forPhone), items: items, error: error)
    }

    public func setCrashSource(_ source: CrashSource) async throws {
        var source = source
        source.organization = source.organization.trimmingCharacters(in: .whitespaces)
        source.project = source.project.trimmingCharacters(in: .whitespaces)
        source.baseURL = source.baseURL.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !source.organization.isEmpty, !source.project.isEmpty else { throw GitError.refused("Give the Sentry organization and project slugs.") }
        guard URL(string: source.baseURL)?.scheme?.hasPrefix("http") == true else { throw GitError.refused("The Sentry address should start with https://.") }
        guard FileManager.default.fileExists(atPath: source.cwd) else { throw ManagerError.cwdMissing(source.cwd) }
        let existing = crashSources.first { $0.id == source.id }
        if source.token?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { source.token = existing?.token }
        guard let token = source.token, !token.isEmpty else { throw GitError.refused("Paste a Sentry auth token with the event:read scope.") }
        source.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        source.hasToken = true
        // A changed project starts over: what it already has is not "new".
        if let existing, existing.organization != source.organization || existing.project != source.project || existing.baseURL != source.baseURL {
            crashIssues.removeAll { $0.sourceId == source.id }
            source.lastCheckedAt = nil
        } else {
            source.lastCheckedAt = existing?.lastCheckedAt
        }
        source.lastError = nil
        if let i = crashSources.firstIndex(where: { $0.id == source.id }) { crashSources[i] = source } else { crashSources.append(source) }
        saveCrashes()
        log("crashes: watching \(source.label)")
        await checkCrashes(sourceId: source.id)
    }

    public func removeCrashSource(id: String) {
        crashSources.removeAll { $0.id == id }
        crashIssues.removeAll { $0.sourceId == id }
        saveCrashes()
        broadcast(crashReport())
    }

    public func ignoreCrash(id: String) {
        guard let i = crashIssues.firstIndex(where: { $0.id == id }) else { return }
        crashIssues[i].ignored = true
        saveCrashes()
        broadcast(crashReport())
    }

    /// Starts the task that fixes a crash; a crash already being fixed keeps its task.
    public func fixCrash(id: String) async throws {
        guard let i = crashIssues.firstIndex(where: { $0.id == id }) else { throw GitError.refused("That crash is gone.") }
        if let taskId = crashIssues[i].taskId, let task = tasks.first(where: { $0.id == taskId }), !task.status.isFinished { return }
        let issue = crashIssues[i]
        guard let source = crashSources.first(where: { $0.id == issue.sourceId }), let token = source.token else {
            throw GitError.refused("Its crash reporter was removed.")
        }
        let stack = try? await latestStack(issue: issue, source: source, token: token)
        var task = AgentTask(title: "Fix crash · \(issue.shortId ?? String(issue.title.prefix(60)))", prompt: issue.fixPrompt(stack: stack),
                             cwd: source.cwd, permissionMode: PermissionMode.acceptEdits.rawValue, inWorktree: true,
                             openPullRequest: SessionManager.locateGh() != nil)
        if !hasClaude { task.agent = .codex; task.permissionMode = CodexApprovalPolicy.never.rawValue }
        crashIssues[i].taskId = task.id
        saveCrashes()
        await addTask(task)
        broadcast(crashReport())
    }

    // MARK: checking

    func loadCrashes() {
        if let path = crashStorePath, let data = FileManager.default.contents(atPath: path),
           let stored = try? ProtocolCoding.decoder.decode(StoredCrashes.self, from: data) {
            crashSources = stored.sources
            crashIssues = stored.issues
        }
        crashTimer?.cancel()
        crashTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: SessionManager.crashCheckInterval * 1_000_000_000)
                await self?.checkCrashes()
            }
        }
    }

    func saveCrashes() {
        guard let path = crashStorePath,
              let data = try? ProtocolCoding.encoder.encode(StoredCrashes(sources: crashSources, issues: crashIssues)) else { return }
        FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    /// Asks every reporter (or one) for its unresolved issues and announces the new ones.
    public func checkCrashes(sourceId: String? = nil) async {
        for source in crashSources where sourceId == nil || source.id == sourceId {
            guard let token = source.token else { continue }
            let firstLook = source.lastCheckedAt == nil
            var failure: String?
            do {
                let found = try await fetchIssues(source: source, token: token)
                mergeCrashes(found, from: source, announce: !firstLook)
            } catch {
                failure = "\(error)"
                log("crashes: \(source.label): \(error)")
            }
            if let i = crashSources.firstIndex(where: { $0.id == source.id }) {
                // Only a check that got an answer counts: until the first one does, nothing is "new".
                if failure == nil { crashSources[i].lastCheckedAt = Date() }
                crashSources[i].lastError = failure
            }
        }
        // Old, quiet crashes drop off so the file doesn't grow forever.
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        crashIssues.removeAll { ($0.lastSeen ?? $0.noticedAt) < cutoff && $0.taskId == nil }
        saveCrashes()
        broadcast(crashReport())
    }

    /// Folds a fresh list into what is known: counts are updated, unknown ones are new. On the first
    /// look at a project nothing is announced — what it already had is the baseline, not news.
    func mergeCrashes(_ found: [CrashIssue], from source: CrashSource, announce: Bool) {
        for issue in found {
            if let i = crashIssues.firstIndex(where: { $0.id == issue.id }) {
                crashIssues[i].count = issue.count
                crashIssues[i].userCount = issue.userCount
                crashIssues[i].lastSeen = issue.lastSeen
                crashIssues[i].title = issue.title
                crashIssues[i].culprit = issue.culprit
                continue
            }
            crashIssues.append(issue)
            guard announce else { continue }
            self.announce(.task, .error, "New crash in \(source.project): \(issue.title)", detail: [issue.culprit, issue.impactLabel].compactMap { $0 }.joined(separator: " · "),
                          url: issue.permalink, notify: .error)
            if source.autoFix {
                let id = issue.id
                Task { try? await self.fixCrash(id: id) }
            }
        }
    }

    private func fetchIssues(source: CrashSource, token: String) async throws -> [CrashIssue] {
        let org = source.organization.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? source.organization
        let project = source.project.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? source.project
        let data = try await sentryGET("\(source.baseURL)/api/0/projects/\(org)/\(project)/issues/?query=is%3Aunresolved&statsPeriod=14d&sort=date&limit=25", token: token)
        return try SentryAPI.parseIssues(data, sourceId: source.id)
    }

    private func latestStack(issue: CrashIssue, source: CrashSource, token: String) async throws -> String? {
        let data = try await sentryGET("\(source.baseURL)/api/0/issues/\(issue.issueId)/events/latest/", token: token)
        return SentryAPI.stackSummary(data)
    }

    /// One authorized GET. Errors say what Sentry said, never the token or the full URL.
    private func sentryGET(_ address: String, token: String) async throws -> Data {
        guard let url = URL(string: address) else { throw GitError.refused("That Sentry address is not a URL.") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw GitError.refused("Sentry could not be reached (\(error.code.rawValue)).")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 401: throw GitError.refused("Sentry refused the token — make a new one with the event:read scope.")
        case 403: throw GitError.refused("The token may not read this project.")
        case 404: throw GitError.refused("Sentry has no such organization or project.")
        default:
            let detail = (try? JSONDecoder().decode(JSONValue.self, from: data))?["detail"]?.string
            throw GitError.refused("Sentry answered \(status)\(detail.map { ": \($0)" } ?? "").")
        }
    }
}

struct StoredCrashes: Codable {
    var sources: [CrashSource]
    var issues: [CrashIssue]
}
#endif
