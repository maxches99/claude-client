#if os(macOS) || os(Linux)
import Foundation
import ClaudeRemoteCore

/// GitHub issues as tasks, CI that repairs itself, prompt templates, the audit of what agents did, and the
/// host's own GitHub login — the pieces that let a host (the Linux hub included) work from GitHub alone.
extension SessionManager {
    // MARK: issues

    /// Open issues of the repository `cwd` belongs to.
    public func listIssues(cwd: String) async throws -> [GitHubIssue] {
        guard FileManager.default.fileExists(atPath: cwd) else { throw ManagerError.cwdMissing(cwd) }
        let result: Result<[GitHubIssue], Error> = await offActor { [self] in
            do {
                let r = try runGh(["issue", "list", "--state", "open", "--limit", "60",
                                   "--json", "number,title,body,url,labels,author,updatedAt"], cwd: cwd, timeout: 40)
                guard r.code == 0 else {
                    let why = (r.err + r.out).trimmingCharacters(in: .whitespacesAndNewlines)
                    throw GitError.refused(why.contains("auth login") ? "gh is not logged in on this host." : "gh could not list issues: \(why.prefix(300))")
                }
                return .success(SessionManager.parseIssues(r.out))
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
    }

    static func parseIssues(_ json: String) -> [GitHubIssue] {
        guard let value = try? JSONValue.parse(Data(json.utf8)) else { return [] }
        let iso = ISO8601DateFormatter()
        return (value.array ?? []).compactMap { item in
            guard let number = item["number"]?.int, let title = item["title"]?.string, let url = item["url"]?.string else { return nil }
            return GitHubIssue(number: number, title: title, body: item["body"]?.string ?? "", url: url,
                               labels: (item["labels"]?.array ?? []).compactMap { $0["name"]?.string },
                               author: item["author"]?["login"]?.string,
                               updatedAt: item["updatedAt"]?.string.flatMap { iso.date(from: $0) })
        }
    }

    // MARK: templates

    /// The project's templates (`.ccremote.json` → `"templates"`), then the host's (`templates.json`
    /// in the support directory).
    public func templates(cwd: String) -> [PromptTemplate] {
        var out: [PromptTemplate] = []
        let project = (cwd as NSString).appendingPathComponent(".ccremote.json")
        if let data = FileManager.default.contents(atPath: project), let json = try? JSONValue.parse(data) {
            out += PromptTemplate.parse(json["templates"], scope: .project)
        }
        if let dir = taskStorePath.map({ ($0 as NSString).deletingLastPathComponent }),
           let data = FileManager.default.contents(atPath: dir + "/templates.json"), let json = try? JSONValue.parse(data) {
            out += PromptTemplate.parse(json.array != nil ? json : json["templates"], scope: .host)
        }
        return out
    }

    // MARK: audit

    /// Commands, writes, fetches and tool calls of every session touched since `since` (one project
    /// when `cwd` is given), newest first.
    public func audit(since: Date, cwd: String?, limit: Int = 2000) -> AuditReport {
        let codexById = Dictionary(codexThreads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var events: [AuditEvent] = []
        for summary in listSessions() where summary.updatedAt > since && summary.kind != .chat {
            if let cwd, summary.cwd != cwd, !summary.cwd.hasPrefix(cwd + "-") { continue }
            let entries: [JSONValue]
            if summary.agent == .codex {
                entries = codexById[summary.id]?.path.map { SessionManager.digestEntries(rollout: $0) } ?? []
            } else {
                entries = store.session(id: summary.id).map { SessionManager.digestEntries(transcript: $0.path) } ?? []
            }
            events += AuditBuilder.events(entries: entries, since: since, sessionId: summary.id, title: summary.title,
                                          agent: summary.agent, cwd: summary.cwd)
        }
        events.sort { $0.date > $1.date }
        return AuditReport(since: since, events: Array(events.prefix(limit)), truncated: events.count > limit)
    }

    // MARK: CI repair

    func startCIWatch() {
        ciTimer?.cancel()
        ciTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 180_000_000_000)
                guard let self else { return }
                await self.checkCI()
            }
        }
    }

    /// Looks at the checks of every watched pull request and starts a repair where they fail.
    func checkCI() async {
        let watched = tasks.filter { $0.fixCI && $0.pullRequestURL != nil && $0.worktreePath != nil && $0.repairOf == nil }
        for task in watched {
            guard let url = task.pullRequestURL, let worktree = task.worktreePath else { continue }
            if let state = task.ci?.state, state == .repairing || state == .fixReady { continue }
            let seen: CIReading? = await offActor { [self] in
                guard let r = try? runGh(["pr", "view", url, "--json", "state,headRefOid,statusCheckRollup"], cwd: worktree, timeout: 40),
                      r.code == 0, let json = try? JSONValue.parse(Data(r.out.utf8)) else { return nil }
                return SessionManager.readCI(json)
            }
            guard let seen, let idx = tasks.firstIndex(where: { $0.id == task.id }) else { continue }
            guard seen.open else {
                // Merged or closed: nothing left to watch.
                tasks[idx].fixCI = false
                saveTasks(); broadcastTasks()
                continue
            }
            var ci = tasks[idx].ci ?? TaskCI(state: .pending)
            let alreadyTried = ci.headSha == seen.head && ci.attempts > 0
            ci.checkedAt = Date()
            ci.failing = seen.failing.map(\.name)
            switch seen.state {
            case .failing where !alreadyTried && ci.attempts < TaskCI.maxAttempts:
                ci.headSha = seen.head
                tasks[idx].ci = ci
                await startRepair(taskId: task.id, failing: seen.failing)
                continue
            case .failing:
                ci.state = ci.attempts >= TaskCI.maxAttempts ? .gaveUp : .failing
            default:
                ci.state = seen.state
            }
            if tasks[idx].ci != ci {
                tasks[idx].ci = ci
                saveTasks(); broadcastTasks()
            }
        }
    }

    struct CIReading: Sendable {
        var open: Bool
        var head: String
        var state: TaskCI.State
        var failing: [(name: String, url: String?)]
    }

    /// `gh pr view --json state,headRefOid,statusCheckRollup` → pending / passing / failing.
    static func readCI(_ json: JSONValue) -> CIReading {
        let failed: Set<String> = ["FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED", "ERROR"]
        var failing: [(String, String?)] = []
        var pending = false
        for check in json["statusCheckRollup"]?.array ?? [] {
            let name = check["name"]?.string ?? check["context"]?.string ?? "check"
            let link = check["detailsUrl"]?.string ?? check["targetUrl"]?.string
            if check["__typename"]?.string == "StatusContext" {
                let state = check["state"]?.string ?? ""
                if failed.contains(state) { failing.append((name, link)) } else if state != "SUCCESS" { pending = true }
            } else if check["status"]?.string != "COMPLETED" {
                pending = true
            } else if failed.contains(check["conclusion"]?.string ?? "") {
                failing.append((name, link))
            }
        }
        let state: TaskCI.State = !failing.isEmpty ? .failing : (pending ? .pending : .passing)
        return CIReading(open: (json["state"]?.string ?? "OPEN") == "OPEN", head: json["headRefOid"]?.string ?? "",
                         state: state, failing: failing.map { (name: $0.0, url: $0.1) })
    }

    /// A repair task in the pull request's worktree, told what failed and how.
    private func startRepair(taskId: String, failing: [(name: String, url: String?)]) async {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }), let worktree = tasks[idx].worktreePath,
              let url = tasks[idx].pullRequestURL else { return }
        let runIds = failing.compactMap { $0.url.flatMap(SessionManager.actionsRunId) }
        let logText: String = await offActor { [self] in
            var text = ""
            for id in Array(Set(runIds)).prefix(2) {
                if let r = try? runGh(["run", "view", id, "--log-failed"], cwd: worktree, timeout: 90), r.code == 0 {
                    text += String(r.out.suffix(8000)) + "\n"
                }
            }
            return text
        }
        let original = tasks[idx]
        var repair = AgentTask(title: "Fix CI · \(original.title)",
                               prompt: TaskCI.repairPrompt(pullRequest: url, failing: failing.map(\.name), log: logText),
                               cwd: worktree, agent: original.agent, model: original.model, permissionMode: original.permissionMode,
                               effort: original.effort, repairOf: original.id)
        if repair.agent == .claude, !hasClaude { repair.agent = .codex; repair.permissionMode = CodexApprovalPolicy.never.rawValue }
        tasks[idx].ci?.state = .repairing
        tasks[idx].ci?.attempts += 1
        tasks[idx].ci?.repairTaskId = repair.id
        notifier?.notify(.error, body: "CI failed on \"\(original.title)\" — starting a repair")
        log("ci: \(original.id.prefix(6)) failing (\(failing.map(\.name).joined(separator: ", "))) → repair \(repair.id.prefix(6))")
        await addTask(repair)
    }

    /// `…/actions/runs/123/job/456` → `123`.
    static func actionsRunId(_ url: String) -> String? {
        guard let r = url.range(of: #"/actions/runs/(\d+)"#, options: .regularExpression) else { return nil }
        return String(url[r]).components(separatedBy: "/").last
    }

    /// A repair finished: commit what it changed in the pull request's worktree and wait for "Push the fix".
    func repairFinished(_ repair: AgentTask, succeeded: Bool) async {
        guard let originalId = repair.repairOf, let idx = tasks.firstIndex(where: { $0.id == originalId }) else { return }
        let worktree = repair.cwd
        let message = "Fix CI" + ((tasks[idx].ci?.failing.isEmpty ?? true) ? "" : ": " + (tasks[idx].ci?.failing.joined(separator: ", ") ?? ""))
        let committed: Bool = succeeded ? await offActor { [self] in
            _ = runGit(["-C", worktree, "add", "-A"], timeout: 60)
            guard runGit(["-C", worktree, "diff", "--cached", "--quiet"]).code != 0 else { return false }
            return runGit(["-C", worktree, "commit", "-q", "-m", message], timeout: 60).code == 0
        } : false
        guard let i = tasks.firstIndex(where: { $0.id == originalId }) else { return }
        tasks[i].ci?.repairTaskId = nil
        if committed {
            tasks[i].ci?.state = .fixReady
            notifier?.notify(.done, body: "CI fix for \"\(tasks[i].title)\" is ready — push it from the phone")
        } else {
            let attempts = tasks[i].ci?.attempts ?? 0
            tasks[i].ci?.state = attempts >= TaskCI.maxAttempts ? .gaveUp : .failing
            notifier?.notify(.error, body: "The CI repair for \"\(tasks[i].title)\" changed nothing")
        }
        saveTasks()
        broadcastTasks()
    }

    /// Pushes the committed repair to the pull request's branch.
    func pushFix(taskId: String) async throws {
        guard let task = tasks.first(where: { $0.id == taskId }), let worktree = task.worktreePath else {
            throw GitError.refused("That task has no worktree any more.")
        }
        guard task.ci?.state == .fixReady else { throw GitError.refused("There is no CI fix waiting to be pushed.") }
        let push = await offActor { [self] in runGit(["-C", worktree, "push"], timeout: 180) }
        guard push.code == 0 else { throw GitError.refused("Push failed: \((push.err + push.out).trimmingCharacters(in: .whitespacesAndNewlines))") }
        if let i = tasks.firstIndex(where: { $0.id == taskId }) {
            tasks[i].ci?.state = .pending
            tasks[i].ci?.checkedAt = Date()
        }
        log("ci: pushed the fix for \(taskId.prefix(6))")
    }

    // MARK: GitHub login on the host

    public func githubAccount() async -> GitHubAccount {
        await offActor { [self] in
            let gh = SessionManager.locateGh() != nil
            var login: String?
            if gh, let r = try? runGh(["api", "user", "--jq", ".login"], cwd: NSHomeDirectory(), timeout: 20), r.code == 0 {
                login = r.out.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            }
            let name = runGit(["config", "--global", "--get", "user.name"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
            let email = runGit(["config", "--global", "--get", "user.email"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
            return GitHubAccount(ghInstalled: gh, login: login, gitName: name.nilIfEmpty, gitEmail: email.nilIfEmpty)
        }
    }

    public var currentGitHubLogin: GitHubLoginState? { githubLoginState }

    /// `gh auth login --web`: the one-time code is sent to phones; the person types it at
    /// github.com/login/device on any device, and gh finishes by itself.
    public func startGitHubLogin() throws {
        guard let gh = SessionManager.locateGh() else { throw GitError.refused("GitHub CLI (gh) is not installed on this host.") }
        githubLoginRun?.terminate()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gh)
        p.arguments = ["auth", "login", "--hostname", "github.com", "--git-protocol", "https", "--web"]
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        var env = ClaudeCLI.childEnvironment()
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["BROWSER"] = "true"   // nothing to open here; the phone shows the code
        p.environment = env
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = output
        let buffer = LockedText()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let text = buffer.append(String(decoding: data, as: UTF8.self))
            if let code = GitHubLoginState.oneTimeCode(in: text) {
                Task { await self?.githubLoginProgress(GitHubLoginState(status: .waiting, code: code, url: "https://github.com/login/device")) }
            }
        }
        p.terminationHandler = { [weak self] process in
            let ok = process.terminationStatus == 0
            let tail = buffer.text.trimmingCharacters(in: .whitespacesAndNewlines)
            Task { await self?.githubLoginEnded(ok: ok, output: tail) }
        }
        try p.run()
        // "Press Enter to open github.com in your browser…"
        input.fileHandleForWriting.write(Data("\n".utf8))
        githubLoginRun = p
        githubLoginProgress(GitHubLoginState(status: .starting))
        log("github: login started")
    }

    public func cancelGitHubLogin() {
        githubLoginRun?.terminate()
        githubLoginRun = nil
        githubLoginState = nil
    }

    private func githubLoginProgress(_ state: GitHubLoginState) {
        githubLoginState = state
        Task { broadcast(.github(account: await githubAccount(), login: state, error: nil)) }
    }

    private func githubLoginEnded(ok: Bool, output: String) async {
        githubLoginRun = nil
        if ok {
            // git over https uses gh's token from now on (push, clone of private repositories).
            _ = await offActor { [self] in try? runGh(["auth", "setup-git"], cwd: NSHomeDirectory(), timeout: 30) }
            githubLoginState = GitHubLoginState(status: .done)
            log("github: logged in")
        } else if githubLoginState != nil {
            let why = output.split(separator: "\n").last.map(String.init) ?? "gh stopped"
            githubLoginState = GitHubLoginState(status: .failed, message: why)
            log("github: login failed: \(why)")
        }
        broadcast(.github(account: await githubAccount(), login: githubLoginState, error: nil))
    }

    public func setGitIdentity(name: String, email: String) async throws {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines), e = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, e.contains("@") else { throw GitError.refused("A name and an email address are both needed.") }
        let r = await offActor { [self] in
            (runGit(["config", "--global", "user.name", n]), runGit(["config", "--global", "user.email", e]))
        }
        guard r.0.code == 0, r.1.code == 0 else { throw GitError.refused("git config failed: \(r.0.err)\(r.1.err)") }
    }
}

/// Output collected from a process's reader thread.
final class LockedText: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func append(_ s: String) -> String { lock.lock(); defer { lock.unlock() }; value += s; if value.count > 20_000 { value = String(value.suffix(20_000)) }; return value }
    var text: String { lock.lock(); defer { lock.unlock() }; return value }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
#endif
