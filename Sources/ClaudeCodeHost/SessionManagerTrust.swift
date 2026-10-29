import Foundation
import ClaudeRemoteCore

/// Trust grants: "allow everything in this session / project for N minutes", answered on the host
/// before a request reaches any phone. Kept in `trust.json` beside the task store so a restart doesn't
/// drop them; expired ones are pruned whenever the list is read.
extension SessionManager {
    var trustStorePath: String? {
        taskStorePath.map { (($0 as NSString).deletingLastPathComponent as NSString).appendingPathComponent("trust.json") }
    }

    func loadTrust() {
        guard let path = trustStorePath, let data = FileManager.default.contents(atPath: path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        trustGrants = ((try? decoder.decode([TrustGrant].self, from: data)) ?? []).filter { !$0.isExpired() }
    }

    private func saveTrust() {
        guard let path = trustStorePath else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(trustGrants).write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    /// Live grants, soonest to expire first.
    public func activeTrust() -> [TrustGrant] {
        let before = trustGrants.count
        trustGrants.removeAll { $0.isExpired() }
        if trustGrants.count != before { saveTrust() }
        return trustGrants.sorted { $0.expiresAt < $1.expiresAt }
    }

    public func addTrust(_ grant: TrustGrant) {
        var grant = grant
        // At most a working day; a grant is meant to cover a stretch of work, not to switch prompts off.
        grant.expiresAt = min(grant.expiresAt, Date().addingTimeInterval(12 * 3600))
        if grant.sessionId != nil, grant.cwd == nil { grant.cwd = grant.sessionId.flatMap(cwdFor) }
        trustGrants.append(grant)
        saveTrust()
        recordEvent(HostEvent(kind: .permission, severity: .warning, title: "Trusted \(grant.toolLabel) until \(Self.clock(grant.expiresAt))",
                              detail: [grant.cwd.map { ($0 as NSString).lastPathComponent }, grant.by].compactMap { $0 }.joined(separator: " · "),
                              sessionId: grant.sessionId))
        // Requests already waiting that the new grant covers are answered now.
        for (sessionId, h) in hosted {
            for request in h.pending.values where grant.covers(sessionId: sessionId, sessionCwd: h.state.cwd, toolName: request.toolName, input: request.input) {
                Task { await self.resolvePermission(sessionId: sessionId, requestId: request.id, allow: true, message: nil, by: grant.by) }
            }
        }
        for request in pendingHookRequests() {
            if grant.covers(sessionId: request.sessionId, sessionCwd: cwdFor(request.sessionId), toolName: request.toolName, input: request.input) {
                Task { await self.resolvePermission(sessionId: request.sessionId, requestId: request.id, allow: true, message: nil, by: grant.by) }
            }
        }
    }

    public func removeTrust(id: String) {
        trustGrants.removeAll { $0.id == id }
        saveTrust()
    }

    func trustGrant(covering request: PermissionRequest, cwd: String?) -> TrustGrant? {
        guard !trustGrants.isEmpty else { return nil }
        let sessionCwd = cwd ?? cwdFor(request.sessionId)
        return trustGrants.first { $0.covers(sessionId: request.sessionId, sessionCwd: sessionCwd, toolName: request.toolName, input: request.input) }
    }

    private static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
