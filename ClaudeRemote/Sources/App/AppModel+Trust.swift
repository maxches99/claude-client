import Foundation
import ClaudeRemoteCore

/// Trust grants: "allow everything here for a while", kept and applied by the host (protocol 12).
@MainActor
extension AppModel {
    func supportsTrust(_ macId: String?) -> Bool {
        guard let macId else { return false }
        return (hostByMac[macId]?.protocolVersion ?? 1) >= 12 && hostByMac[macId]?.me?.isOwner != false
    }

    func loadTrust(mac macId: String) {
        guard supportsTrust(macId) else { return }
        send(.listTrust, toMac: macId)
    }

    /// Trusts `tool` (nil = everything) in this session, or in its whole project when `projectWide`,
    /// for `minutes`. Requests already waiting that it covers are answered by the host straight away.
    func trust(_ request: PermissionRequest, tool: String?, projectWide: Bool, minutes: Int) {
        // A grant approves more than one tool call: always behind Face ID when approvals are.
        if requireBiometricsForApproval {
            Task { @MainActor in
                guard await Biometrics.authenticate(reason: "Trust \(tool ?? "everything") for \(minutes) minutes") else { return }
                self.sendTrust(request, tool: tool, projectWide: projectWide, minutes: minutes)
            }
            return
        }
        sendTrust(request, tool: tool, projectWide: projectWide, minutes: minutes)
    }

    private func sendTrust(_ request: PermissionRequest, tool: String?, projectWide: Bool, minutes: Int) {
        guard let macId = macId(forSession: request.sessionId) else { return }
        let cwd = (sessionsByMac[macId] ?? sessions).first { $0.id == request.sessionId }?.cwd ?? states[request.sessionId]?.cwd
        let grant = TrustGrant(sessionId: projectWide ? nil : request.sessionId, cwd: cwd, tool: tool,
                               expiresAt: Date().addingTimeInterval(TimeInterval(minutes * 60)))
        send(.addTrust(grant: grant), toMac: macId)
        permissionsByMac[macId]?.removeAll { grant.covers(sessionId: $0.sessionId, sessionCwd: cwd, toolName: $0.toolName, input: $0.input) && $0.sessionId == request.sessionId }
    }

    func revokeTrust(_ grant: TrustGrant, mac macId: String) {
        trustByMac[macId]?.removeAll { $0.id == grant.id }
        send(.removeTrust(id: grant.id), toMac: macId)
    }

    /// Live grants on every host, soonest to expire first.
    var allTrust: [(macId: String, grant: TrustGrant)] {
        trustByMac.flatMap { macId, grants in grants.filter { !$0.isExpired() }.map { (macId, $0) } }
            .sorted { $0.grant.expiresAt < $1.grant.expiresAt }
    }
}

@MainActor
extension AppModel {
    /// Asks a host for Claude Desktop's sidebar layout (owner only, protocol 12).
    func loadDesktopLayout(mac macId: String) {
        guard supportsTrust(macId), hostByMac[macId]?.hasClaude != false else { return }
        send(.desktopLayout, toMac: macId)
    }
}

@MainActor
extension AppModel {
    /// Asks a host what Claude Desktop's built-in browser shows (owner only, protocol 12).
    func loadDesktopBrowser(mac macId: String) {
        guard supportsTrust(macId) else { return }
        send(.desktopBrowser, toMac: macId)
    }
}
