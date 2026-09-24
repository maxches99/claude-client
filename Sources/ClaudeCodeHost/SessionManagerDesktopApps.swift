#if os(macOS) || os(Linux)
#if os(macOS)
import AppKit
import CryptoKit
#else
import Crypto
#endif
import Foundation
import ClaudeRemoteCore

/// A session started from the phone, remembered so the Mac can offer it to Claude Desktop / the
/// Codex app afterwards (the daemon's own list forgets a session once its process ends).
public struct PhoneSessionRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var agent: AgentKind
    public var cwd: String
    public var title: String?
    public var createdAt: Date
    public var updatedAt: Date
    /// Imported into Claude Desktop through `claude://resume` (it keeps its own record from then on).
    public var openedInDesktop: Bool?
    /// The `local_…` record written into Claude Desktop's session list (experimental mirroring).
    public var desktopRecordId: String?
    /// The thread was filed under its project in the Codex app's state (experimental mirroring).
    public var codexProjectAssigned: Bool?

    public var projectName: String { (cwd as NSString).lastPathComponent }
}

/// The Codex app keeps its sidebar — projects and which thread sits under which — in one JSON file
/// it owns. Reading it is safe any time; writing only while the app is not running, because the
/// app holds the whole file in memory and saves it back over anything written meanwhile.
enum CodexAppState {
    static let bundleId = "com.openai.codex"
    static var path: String { NSHomeDirectory() + "/.codex/.codex-global-state.json" }

    static func load(from file: String = path) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: file) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Root folders of the app's projects.
    static func projectRoots(_ state: [String: Any]? = load()) -> [String] {
        guard let state else { return [] }
        var roots: [String] = []
        for case let project as [String: Any] in (state["local-projects"] as? [String: Any] ?? [:]).values {
            roots += project["rootPaths"] as? [String] ?? []
        }
        for root in state["electron-saved-workspace-roots"] as? [String] ?? [] where !roots.contains(root) { roots.append(root) }
        return roots
    }

    static func contains(_ cwd: String, roots: [String]) -> Bool {
        roots.contains { cwd == $0 || cwd.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    static var isAppRunning: Bool {
        #if os(macOS)
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
        #else
        false   // no desktop apps on the hub
        #endif
    }

    /// The id the app itself gives a folder it opens as a project: `local-` + the first 32 hex digits
    /// of the path's SHA-256.
    static func localProjectId(for path: String) -> String {
        "local-" + SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32)
    }

    /// Files each thread under the project for its folder, creating the project when there is none.
    /// Returns the threads it filed. Call only while the app is not running.
    static func assign(threads: [(id: String, cwd: String)], file: String = path) throws -> Set<String> {
        guard var state = load(from: file) else { return [] }
        var projects = state["local-projects"] as? [String: Any] ?? [:]
        var assignments = state["thread-project-assignments"] as? [String: Any] ?? [:]
        var order = state["project-order"] as? [String] ?? []
        var saved = state["electron-saved-workspace-roots"] as? [String] ?? []
        let now = Int(Date().timeIntervalSince1970 * 1000)
        var done = Set<String>()
        for thread in threads {
            // The project whose root holds the folder (deepest root wins), else a new one for the folder itself.
            let match = projects.compactMap { id, value -> (id: String, root: String)? in
                guard let roots = (value as? [String: Any])?["rootPaths"] as? [String],
                      let root = roots.filter({ contains(thread.cwd, roots: [$0]) }).max(by: { $0.count < $1.count }) else { return nil }
                return (id, root)
            }.max { $0.root.count < $1.root.count }
            let projectId: String
            if let match {
                projectId = match.id
            } else {
                projectId = localProjectId(for: thread.cwd)
                projects[projectId] = ["id": projectId, "name": (thread.cwd as NSString).lastPathComponent,
                                       "rootPaths": [thread.cwd], "createdAt": now, "updatedAt": now]
                if !order.contains(projectId) { order.insert(projectId, at: 0) }
                if !saved.contains(thread.cwd) { saved.insert(thread.cwd, at: 0) }
            }
            if assignments[thread.id] == nil { assignments[thread.id] = ["projectKind": "local", "projectId": projectId] }
            done.insert(thread.id)
        }
        guard !done.isEmpty else { return done }
        state["local-projects"] = projects
        state["thread-project-assignments"] = assignments
        state["project-order"] = order
        state["electron-saved-workspace-roots"] = saved
        let backup = file + ".ccremote-backup"
        if !FileManager.default.fileExists(atPath: backup) { try? FileManager.default.copyItem(atPath: file, toPath: backup) }
        let data = try JSONSerialization.data(withJSONObject: state, options: [.withoutEscapingSlashes])
        try data.write(to: URL(fileURLWithPath: file), options: .atomic)
        return done
    }
}

/// Claude Desktop lists Code sessions from one JSON file each under
/// `claude-code-sessions/<account>/<organization>/local_<uuid>.json`, pointing at the CLI session
/// by `cliSessionId`. The format is the app's own and undocumented, so only the fields it needs to
/// show and resume a session are written, and a record is never rewritten wholesale. Desktop reads the
/// folder when it starts, not while it runs: a record written now shows up after its next launch.
enum ClaudeDesktopSessions {
    static var root: String { NSHomeDirectory() + "/Library/Application Support/Claude/claude-code-sessions" }

    /// The account/organization folder in use: the one with the most recently touched record.
    static func activeDirectory(root: String = root) -> String? {
        let fm = FileManager.default
        var best: (dir: String, date: Date)?
        for account in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let accountDir = root + "/" + account
            for org in (try? fm.contentsOfDirectory(atPath: accountDir)) ?? [] {
                let dir = accountDir + "/" + org
                for file in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where file.hasPrefix("local_") && file.hasSuffix(".json") {
                    guard let date = (try? fm.attributesOfItem(atPath: dir + "/" + file))?[.modificationDate] as? Date else { continue }
                    if date > best?.date ?? .distantPast { best = (dir, date) }
                }
            }
        }
        return best?.dir
    }

    struct Session {
        var cliSessionId: String
        var cwd: String
        var title: String?
        var model: String?
        var effort: String?
        var permissionMode: String?
        var createdAt: Date
        var lastActivityAt: Date
    }

    /// Writes a new record, or refreshes title and activity of the one written before. Returns its id.
    static func upsert(_ session: Session, recordId: String?, in dir: String) throws -> String {
        let id = recordId ?? "local_" + UUID().uuidString.lowercased()
        let path = "\(dir)/\(id).json"
        let ms = { (d: Date) in Int(d.timeIntervalSince1970 * 1000) }
        var record: [String: Any]
        if recordId != nil, let data = FileManager.default.contents(atPath: path),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            record = existing
            // A title the user gave it in Desktop stays.
            if let title = session.title, record["titleSource"] as? String != "user" { record["title"] = title }
        } else if recordId != nil {
            // Deleted or archived away in Desktop: leave it gone.
            return id
        } else {
            record = [
                "sessionId": id, "cliSessionId": session.cliSessionId, "cwd": session.cwd, "originCwd": session.cwd,
                "createdAt": ms(session.createdAt), "lastFocusedAt": ms(session.createdAt), "isArchived": false,
                "title": session.title ?? "Session from iPhone", "titleSource": "auto",
                "permissionMode": session.permissionMode ?? "default",
                "completedTurns": 1, "alwaysAllowedReasons": [Any](), "sessionPermissionUpdates": [Any](),
            ]
            if let model = session.model { record["model"] = model }
            if let effort = session.effort { record["effort"] = effort }
        }
        record["lastActivityAt"] = ms(session.lastActivityAt)
        let data = try JSONSerialization.data(withJSONObject: record, options: [.withoutEscapingSlashes])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return id
    }
}

extension SessionManager {
    static let phoneSessionLimit = 50

    var phoneSessionStorePath: String? {
        taskStorePath.map { (($0 as NSString).deletingLastPathComponent as NSString).appendingPathComponent("phone-sessions.json") }
    }

    func loadPhoneSessions() {
        guard let path = phoneSessionStorePath, let data = FileManager.default.contents(atPath: path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        phoneSessions = (try? decoder.decode([PhoneSessionRecord].self, from: data)) ?? []
    }

    private func savePhoneSessions() {
        guard let path = phoneSessionStorePath else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(phoneSessions).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Recent work sessions started from the phone, newest first.
    public func recentPhoneSessions() -> [PhoneSessionRecord] {
        phoneSessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Turns on writing phone sessions into Claude Desktop's and the Codex app's own lists.
    public func setMirrorsToDesktopApps(_ on: Bool) {
        mirrorsToDesktopApps = on
        guard on else { return }
        #if os(macOS)
        codexAppQuitObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == CodexAppState.bundleId, let self else { return }
            // The app saves its state on the way out; file the threads after that.
            Task {
                try? await Task.sleep(for: .seconds(2))
                await self.fileCodexThreads()
            }
        }
        #endif
        fileCodexThreads()
    }

    /// Remembers a work session the phone just started.
    public func notePhoneSession(_ state: SessionState) {
        guard state.kind == .agent else { return }
        phoneSessions.removeAll { $0.id == state.id }
        phoneSessions.append(PhoneSessionRecord(id: state.id, agent: state.agent, cwd: state.cwd, title: nil,
                                                createdAt: Date(), updatedAt: Date()))
        if phoneSessions.count > SessionManager.phoneSessionLimit {
            phoneSessions = Array(recentPhoneSessions().prefix(SessionManager.phoneSessionLimit))
        }
        savePhoneSessions()
        if state.agent == .codex { fileCodexThreads() }
    }

    /// After each turn of a phone session: keep the record's title fresh and, when mirroring, the
    /// desktop apps' copies too.
    func phoneTurnFinished(sessionId: String) {
        guard let i = phoneSessions.firstIndex(where: { $0.id == sessionId }) else { return }
        let h = hosted[sessionId]
        phoneSessions[i].updatedAt = Date()
        if let title = h?.title ?? store.session(id: sessionId)?.title ?? codexThreads.first(where: { $0.id == sessionId })?.title {
            phoneSessions[i].title = title
        }
        #if os(macOS)
        let hasDesktop = SessionManager.applicationPath("Claude") != nil
        #else
        let hasDesktop = false
        #endif
        if mirrorsToDesktopApps, phoneSessions[i].agent == .claude, phoneSessions[i].openedInDesktop != true,
           hasDesktop, let dir = ClaudeDesktopSessions.activeDirectory() {
            let r = phoneSessions[i]
            let session = ClaudeDesktopSessions.Session(
                cliSessionId: r.id, cwd: r.cwd, title: r.title, model: h?.state.model, effort: h?.state.effort,
                permissionMode: h?.state.permissionMode, createdAt: r.createdAt, lastActivityAt: r.updatedAt)
            do {
                phoneSessions[i].desktopRecordId = try ClaudeDesktopSessions.upsert(session, recordId: r.desktopRecordId, in: dir)
            } catch {
                log("[\(sessionId.prefix(8))] could not add it to Claude Desktop: \(error)")
            }
        }
        savePhoneSessions()
    }

    /// Files phone-started Codex threads under their projects in the Codex app — only while the app
    /// is closed; otherwise they wait for it to quit.
    func fileCodexThreads() {
        guard mirrorsToDesktopApps, !CodexAppState.isAppRunning else { return }
        let pending = phoneSessions.filter { $0.agent == .codex && $0.codexProjectAssigned != true }
        guard !pending.isEmpty else { return }
        do {
            let done = try CodexAppState.assign(threads: pending.map { ($0.id, $0.cwd) })
            for i in phoneSessions.indices where done.contains(phoneSessions[i].id) { phoneSessions[i].codexProjectAssigned = true }
            savePhoneSessions()
            if !done.isEmpty { log("filed \(done.count) phone thread(s) under their Codex app projects") }
        } catch {
            log("could not update the Codex app's projects: \(error)")
        }
    }

    #if os(macOS)
    /// Imports a phone session into Claude Desktop and opens it there (the daemon lets go of it).
    public func openInClaudeDesktop(sessionId: String) async throws {
        try await handoff(sessionId: sessionId, targetId: "desktop")
        if let i = phoneSessions.firstIndex(where: { $0.id == sessionId }) {
            phoneSessions[i].openedInDesktop = true
            savePhoneSessions()
        }
    }
    #endif

    /// When Claude Desktop opens a session we still run (possible once it is in Desktop's list), two
    /// processes would write one transcript: an idle one of ours steps aside.
    func yieldSessionsOpenedInDesktop() async {
        let ownPids = Set(hosted.values.compactMap { $0.process?.pid })
        for live in registry.liveSessions() where !ownPids.contains(live.pid) {
            guard let h = hosted[live.sessionId], h.process != nil, h.state.status == .idle else { continue }
            log("[\(live.sessionId.prefix(8))] opened on the Mac (\(live.entrypoint ?? "desktop")) — letting go of it")
            await close(sessionId: live.sessionId)
        }
    }

    /// Folders the Codex app has as projects, read fresh (the file is small).
    func codexAppProjectRoots() -> [String] {
        codex == nil ? [] : CodexAppState.projectRoots()
    }
}
#endif
