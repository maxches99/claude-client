#if os(macOS)
import Foundation
import ClaudeRemoteCore

/// The host's event feed, snapshots before a task, before/after screenshots and the machine's health.
extension SessionManager {
    // MARK: events

    static let eventLimit = 1500

    var eventsPath: String? {
        taskStorePath.map { (($0 as NSString).deletingLastPathComponent as NSString).appendingPathComponent("events.json") }
    }

    func loadEvents() {
        guard let path = eventsPath, let data = FileManager.default.contents(atPath: path),
              let stored = try? ProtocolCoding.decoder.decode([HostEvent].self, from: data) else { return }
        events = stored
    }

    private func saveEvents() {
        guard let path = eventsPath, let data = try? ProtocolCoding.encoder.encode(events) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Adds an event to the feed and sends it to every phone.
    public func recordEvent(_ event: HostEvent) {
        events.append(event)
        if events.count > SessionManager.eventLimit { events.removeFirst(events.count - SessionManager.eventLimit) }
        saveEvents()
        broadcast(.events(items: [event], live: true))
    }

    public func eventList(since: Date?) -> [HostEvent] {
        guard let since else { return events }
        return events.filter { $0.date > since }
    }

    /// A notification and the matching event in one go.
    func announce(_ kind: HostEvent.Kind, _ severity: HostEvent.Severity, _ title: String, detail: String? = nil,
                  sessionId: String? = nil, taskId: String? = nil, url: String? = nil, notify: Notifier.Event? = nil) {
        recordEvent(HostEvent(kind: kind, severity: severity, title: title, detail: detail, sessionId: sessionId, taskId: taskId, url: url))
        if let notify { notifier?.notify(notify, body: detail.map { "\(title) · \($0)" } ?? title) }
    }

    // MARK: snapshots

    /// The working tree of `repo` as a commit under `refs/ccremote/snapshots/<id>`: tracked and untracked
    /// files (ignored ones left out), without touching the tree, the index or the branch.
    nonisolated func takeSnapshot(repo: String, id: String) -> TaskSnapshot? {
        guard runGit(["-C", repo, "rev-parse", "--is-inside-work-tree"]).code == 0 else { return nil }
        let head = runGit(["-C", repo, "rev-parse", "HEAD"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty else { return nil }
        let branch = runGit(["-C", repo, "rev-parse", "--abbrev-ref", "HEAD"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let index = NSTemporaryDirectory() + "ccremote-snapshot-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: index) }
        let env = ["GIT_INDEX_FILE": index]
        guard runGit(["-C", repo, "read-tree", head], env: env).code == 0,
              runGit(["-C", repo, "add", "-A"], timeout: 120, env: env).code == 0 else { return nil }
        let tree = runGit(["-C", repo, "write-tree"], env: env).out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tree.isEmpty else { return nil }
        let commit = runGit(["-C", repo, "-c", "user.name=ccremote", "-c", "user.email=ccremote@localhost",
                             "commit-tree", tree, "-p", head, "-m", "Before task \(id)"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commit.isEmpty, runGit(["-C", repo, "update-ref", "refs/ccremote/snapshots/\(id)", commit]).code == 0 else { return nil }
        return TaskSnapshot(commit: commit, head: head, branch: branch == "HEAD" ? nil : branch)
    }

    /// Puts `repo` back as the snapshot has it: the branch where it was, every file as it was, and
    /// files that appeared since removed. Ignored files are left alone.
    nonisolated func restoreSnapshot(_ snapshot: TaskSnapshot, repo: String) throws {
        func git(_ args: [String]) throws {
            let r = runGit(["-C", repo] + args, timeout: 120)
            guard r.code == 0 else { throw GitError.refused("git \(args.first ?? "") failed: \((r.err + r.out).trimmingCharacters(in: .whitespacesAndNewlines))") }
        }
        let current = runGit(["-C", repo, "rev-parse", "--abbrev-ref", "HEAD"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        if let branch = snapshot.branch, current != branch { try git(["checkout", "-q", branch]) }
        // What is in the tree now but not in the snapshot goes (new files of the task).
        let now = Set(runGit(["-C", repo, "ls-files", "--cached", "--others", "--exclude-standard"], timeout: 60).out.split(separator: "\n").map(String.init))
        let then = Set(runGit(["-C", repo, "ls-tree", "-r", "--name-only", snapshot.commit], timeout: 60).out.split(separator: "\n").map(String.init))
        try git(["reset", "-q", "--mixed", snapshot.head])
        for path in now.subtracting(then) where !path.isEmpty {
            try? FileManager.default.removeItem(atPath: (repo as NSString).appendingPathComponent(path))
        }
        try git(["checkout", "-q", snapshot.commit, "--", "."])
        // The checkout staged the snapshot's files; the index goes back to the branch head.
        try git(["reset", "-q"])
    }

    func restoreTaskSnapshot(taskId: String) async throws {
        guard let task = tasks.first(where: { $0.id == taskId }), let snapshot = task.snapshot else {
            throw GitError.refused("That task has no snapshot.")
        }
        if let sessionId = task.sessionId, hosted[sessionId]?.state.status == .running {
            throw GitError.refused("The task's session is still working — stop it first.")
        }
        let repo = task.cwd
        let result: Result<Void, Error> = await offActor { [self] in
            Result { try restoreSnapshot(snapshot, repo: repo) }
        }
        try result.get()
        if let i = tasks.firstIndex(where: { $0.id == taskId }) { tasks[i].snapshot?.restoredAt = Date() }
        announce(.task, .info, "Rolled back \"\(task.title)\"", detail: (repo as NSString).lastPathComponent, taskId: taskId)
    }

    // MARK: before / after screenshots

    nonisolated static func previewConfig(cwd: String) -> PreviewConfig? {
        let path = (cwd as NSString).appendingPathComponent(".ccremote.json")
        guard let data = FileManager.default.contents(atPath: path), let json = try? JSONValue.parse(data) else { return nil }
        return PreviewConfig.parse(json["preview"])
    }

    var previewDirectory: String? {
        taskStorePath.map { (($0 as NSString).deletingLastPathComponent as NSString).appendingPathComponent("previews") }
    }

    /// Runs the project's preview command in `dir` and takes a still of the Simulator. Returns the JPEG's path.
    nonisolated func capturePreview(_ config: PreviewConfig, dir: String, output: String) -> Result<String, Error> {
        let run = runTool("/bin/zsh", ["-lc", config.command], cwd: dir, timeout: 900)
        guard run.code == 0 else {
            return .failure(GitError.refused("The preview command failed: \((run.err + run.out).suffix(400).trimmingCharacters(in: .whitespacesAndNewlines))"))
        }
        Thread.sleep(forTimeInterval: max(0, config.settle))
        try? FileManager.default.createDirectory(atPath: (output as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let shot = runTool("/usr/bin/xcrun", ["simctl", "io", config.device ?? "booted", "screenshot", "--type=jpeg", output], timeout: 60)
        guard shot.code == 0, FileManager.default.fileExists(atPath: output) else {
            return .failure(GitError.refused("No screenshot: \((shot.err + shot.out).trimmingCharacters(in: .whitespacesAndNewlines))"))
        }
        return .success(output)
    }

    /// "before" when a task starts, "after" when it ends; failures land on the task, never stop it.
    func takePreview(taskId: String, phase: TaskPreview.State) async {
        guard let task = tasks.first(where: { $0.id == taskId }), task.wantsPreview, let dir = previewDirectory else { return }
        let cwd = task.worktreePath ?? task.cwd
        guard let config = SessionManager.previewConfig(cwd: cwd) else {
            setPreview(taskId) { $0 = TaskPreview(state: .failed, error: "The project has no \"preview\" command in .ccremote.json.") }
            return
        }
        setPreview(taskId) { preview in
            if preview == nil { preview = TaskPreview(state: phase) } else { preview?.state = phase }
        }
        let output = "\(dir)/\(taskId)-\(phase == .before ? "before" : "after").jpg"
        let result = await offActor { [self] in capturePreview(config, dir: cwd, output: output) }
        setPreview(taskId) { preview in
            switch result {
            case .success(let path):
                if phase == .before { preview?.beforePath = path } else { preview?.afterPath = path; preview?.state = .done }
            case .failure(let error):
                preview?.state = .failed
                preview?.error = "\(error)"
            }
        }
    }

    private func setPreview(_ taskId: String, _ change: (inout TaskPreview?) -> Void) {
        guard let i = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        change(&tasks[i].preview)
        saveTasks()
        broadcastTasks()
    }

    // MARK: health

    func startHealthWatch() {
        healthTimer?.cancel()
        healthTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self else { return }
                await self.checkHealth()
                try? await Task.sleep(nanoseconds: 540_000_000_000)
            }
        }
    }

    /// Measures, and announces a warning the first time it shows up.
    func checkHealth() async {
        let report = await health()
        let current = Set(report.warnings)
        for warning in current.subtracting(announcedHealth) {
            announce(.host, .warning, warning, notify: .error)
        }
        announcedHealth = current
    }

    public func health() async -> HostHealth {
        let codexLoggedIn: Bool? = codex == nil ? nil : await codex?.loggedIn
        let claudeLoggedIn: Bool? = hasClaude ? cli.authStatus()?.loggedIn : nil
        var report = await offActor { [self] in SessionManager.measure() }
        report.claudeLoggedIn = claudeLoggedIn
        report.codexLoggedIn = codexLoggedIn
        let account = await githubAccount()
        report.githubInstalled = account.ghInstalled
        report.githubLogin = account.login
        report.assess()
        return report
    }

    /// Disk, memory, load, power and uptime of this machine.
    nonisolated static func measure() -> HostHealth {
        var report = HostHealth(cpuCount: ProcessInfo.processInfo.activeProcessorCount)
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()) {
            report.diskFree = (attrs[.systemFreeSize] as? NSNumber)?.int64Value
            report.diskTotal = (attrs[.systemSize] as? NSNumber)?.int64Value
        }
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) > 0 { report.load1 = load[0] }
        report.uptime = ProcessInfo.processInfo.systemUptime
        report.memoryTotal = Int64(ProcessInfo.processInfo.physicalMemory)
        #if os(macOS)
        // Free + inactive + purgeable pages count as available, as Activity Monitor does.
        if let stat = runStatic("/usr/bin/vm_stat", []), let page = stat.firstMatch(#"page size of (\d+)"#).flatMap(Int64.init) {
            func pages(_ label: String) -> Int64 { stat.firstMatch(label + #":\s+(\d+)"#).flatMap(Int64.init) ?? 0 }
            let available = (pages("Pages free") + pages("Pages inactive") + pages("Pages purgeable")) * page
            if let total = report.memoryTotal { report.memoryUsed = max(0, total - available) }
        }
        if let batt = runStatic("/usr/bin/pmset", ["-g", "batt"]) {
            let parsed = HostHealth.parsePmset(batt)
            report.battery = parsed.battery
            report.charging = parsed.charging
            report.onAC = parsed.onAC
        }
        #else
        if let info = try? String(contentsOfFile: "/proc/meminfo", encoding: .utf8), let mem = HostHealth.parseMeminfo(info) {
            report.memoryUsed = mem.used
            report.memoryTotal = mem.total
        }
        #endif
        return report
    }

    nonisolated private static func runStatic(_ tool: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

extension String {
    /// The first capture group of `pattern`.
    func firstMatch(_ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: self, range: NSRange(startIndex..., in: self)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: self) else { return nil }
        return String(self[r])
    }
}
#endif
