#if os(macOS)
import Foundation
import ClaudeRemoteCore

/// A member of the host as the manager needs them: where they work and, when they signed in their own
/// Claude account, the token their Claude processes run with.
public struct MemberAccess: Sendable, Equatable {
    public var id: String
    public var name: String
    public var claudeToken: String?

    public init(id: String, name: String, claudeToken: String?) {
        self.id = id
        self.name = name
        self.claudeToken = claudeToken
    }
}

/// Several people on one host: who owns which session, what a member's phone may see, and the folder each
/// member works in. The owner (no user id) sees and does everything, as before.
extension SessionManager {
    var sessionOwnersPath: String? {
        taskStorePath.map { (($0 as NSString).deletingLastPathComponent as NSString).appendingPathComponent("session-owners.json") }
    }

    func loadSessionOwners() {
        guard let path = sessionOwnersPath, let data = FileManager.default.contents(atPath: path),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        sessionOwners = map
    }

    private func saveSessionOwners() {
        guard let path = sessionOwnersPath, let data = try? JSONEncoder().encode(sessionOwners) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public func setMembers(_ list: [MemberAccess]) {
        members = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    public func subscribe(_ id: UUID, user: String?, send: @escaping Sender) {
        subscribers[id] = send
        subscriberUsers[id] = user
    }

    /// Marks a session as someone's (nil = the owner's again).
    public func claim(_ sessionId: String, for user: String?) {
        if let user { sessionOwners[sessionId] = user } else { sessionOwners[sessionId] = nil }
        saveSessionOwners()
    }

    public func owner(of sessionId: String) -> String? { sessionOwners[sessionId] }

    public func canAccess(_ sessionId: String, user: String?) -> Bool {
        guard let user else { return true }
        return sessionOwners[sessionId] == user
    }

    /// A member's folder in the workspace (created on first use).
    public func memberWorkspace(_ user: String) -> String {
        let name = members[user].map { SessionManager.worktreeSlug($0.name) }.flatMap { $0.isEmpty ? nil : $0 } ?? user
        let dir = (workspaceRoot as NSString).appendingPathComponent(name)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Paths a member may read from (their folder, the chats) — the owner may read anything.
    public func mayRead(_ path: String, user: String?) -> Bool {
        guard let user else { return true }
        let full = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        return [memberWorkspace(user), SessionManager.chatDirectory].contains { full == $0 || full.hasPrefix($0 + "/") }
    }

    /// Whether `cwd` is inside the member's folder (where their sessions and tasks may run).
    public func inMemberWorkspace(_ cwd: String, user: String) -> Bool {
        let full = (cwd as NSString).standardizingPath, root = memberWorkspace(user)
        return full == root || full.hasPrefix(root + "/")
    }

    /// The child environment for a session's Claude process: the member's own login when they set one.
    func environment(forSession sessionId: String) -> [String: String] {
        guard let user = sessionOwners[sessionId], let token = members[user]?.claudeToken, !token.isEmpty else { return [:] }
        return ["CLAUDE_CODE_OAUTH_TOKEN": token]
    }

    public func sessions(for user: String?) -> [SessionSummary] {
        let all = listSessions()
        guard let user else { return all }
        return all.filter { sessionOwners[$0.id] == user }
    }

    public func projects(for user: String?) -> [ProjectInfo] {
        guard let user else { return listProjects() }
        let root = memberWorkspace(user)
        var out = [ProjectInfo(path: root, lastUsed: Date(), sessionCount: 0)]
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: root) {
            for name in entries.sorted() where !name.hasPrefix(".") {
                let path = (root as NSString).appendingPathComponent(name)
                var dir: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &dir), dir.boolValue {
                    let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
                    out.append(ProjectInfo(path: path, lastUsed: mtime, sessionCount: sessions(for: user).filter { $0.cwd == path }.count))
                }
            }
        }
        return out
    }

    public func tasks(for user: String?) -> [AgentTask] {
        guard let user else { return tasks }
        return tasks.filter { $0.ownerId == user }
    }

    /// Hands a session to another person on the host (or back to the owner).
    public func give(sessionId: String, to user: String?) {
        claim(sessionId, for: user)
        broadcast(.sessions(items: listSessions()))
    }

    /// What of `message` a member's phone gets: their own sessions, tasks and events only; host-wide
    /// lists (processes, terminals, duels, digests) not at all.
    public func filtered(_ message: ServerMessage, for user: String) -> ServerMessage? {
        func mine(_ id: String?) -> Bool { id.map { sessionOwners[$0] == user } ?? false }
        switch message {
        case .sessions(let items): return .sessions(items: items.filter { sessionOwners[$0.id] == user })
        case .state(let state): return mine(state.id) ? message : nil
        case .event(let id, _, _), .catchUp(let id, _, _), .history(let id, _), .permissionResolved(let id, _),
             .commandOutput(let id, _, _, _, _):
            return mine(id) ? message : nil
        case .permissionRequest(let request): return mine(request.sessionId) ? message : nil
        case .tasks(let items, let settings): return .tasks(items: items.filter { $0.ownerId == user }, settings: settings)
        case .events(let items, let live):
            let own = items.filter { mine($0.sessionId) || ($0.taskId.map { id in tasks.first { $0.id == id }?.ownerId == user } ?? false) }
            return own.isEmpty && live ? nil : .events(items: own, live: live)
        case .projects: return .projects(items: projects(for: user))
        case .duels, .processes, .terminals, .terminalOutput, .terminalExited, .digest, .simulators, .simulatorFrame, .simulatorVideo:
            return nil
        default:
            return message
        }
    }
}
#endif
