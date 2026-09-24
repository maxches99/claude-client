import Foundation
import ClaudeRemoteCore

/// Open issues of a project, as last fetched.
struct IssueList: Equatable {
    var items: [GitHubIssue] = []
    var error: String?
    var loading = true
}

/// A Mac's relay setup fetched to hand to another Mac.
struct RelayFetch: Equatable {
    var setup: RelaySetup?
    var error: String?
    var loading = true
}

/// Where "join this relay" stands for a Mac.
struct RelayJoin: Equatable {
    enum State { case sending, restarting, joined, failed }
    var state: State
    var message: String?
}

/// A Mac's GitHub login and git identity, and a login in progress.
struct GitHubPanel: Equatable {
    var account: GitHubAccount?
    var login: GitHubLoginState?
    var error: String?
    var loading = true
}

extension AppModel {
    /// Sends to one paired Mac, whichever is on screen.
    func send(_ message: ClientMessage, toMac macId: String) {
        connections[macId]?.send(message)
    }

    func supportsAutomation(mac macId: String) -> Bool {
        (hostByMac[macId]?.protocolVersion ?? 1) >= 7
    }

    // MARK: issues, templates, audit

    func requestIssues(cwd: String) {
        issuesByCwd[cwd] = IssueList(items: issuesByCwd[cwd]?.items ?? [], loading: true)
        sendMessage(.listIssues(cwd: cwd))
    }

    func requestTemplates(cwd: String) {
        sendMessage(.listTemplates(cwd: cwd))
    }

    func requestAudit(since: Date, cwd: String? = nil) {
        auditLoading = true
        sendMessage(.audit(since: since, cwd: cwd))
    }

    // MARK: relay

    func requestRelaySetup(from macId: String) {
        relaySetups[macId] = RelayFetch()
        send(.getRelaySetup, toMac: macId)
    }

    /// Puts `macId` on the relay: it saves the setting and restarts; the next welcome carries the route.
    func joinRelay(_ setup: RelaySetup, mac macId: String) {
        relayJoins[macId] = RelayJoin(state: .sending)
        send(.setRelay(setup: setup), toMac: macId)
    }

    // MARK: GitHub on a host

    func requestGitHub(mac macId: String) {
        var panel = githubByMac[macId] ?? GitHubPanel()
        panel.loading = true
        githubByMac[macId] = panel
        send(.githubStatus, toMac: macId)
    }

    func startGitHubLogin(mac macId: String) {
        githubByMac[macId, default: GitHubPanel()].login = GitHubLoginState(status: .starting)
        githubByMac[macId, default: GitHubPanel()].error = nil
        send(.githubLogin, toMac: macId)
    }

    func cancelGitHubLogin(mac macId: String) {
        githubByMac[macId, default: GitHubPanel()].login = nil
        send(.githubCancelLogin, toMac: macId)
    }

    func setGitIdentity(name: String, email: String, mac macId: String) {
        githubByMac[macId, default: GitHubPanel()].loading = true
        send(.setGitIdentity(name: name, email: email), toMac: macId)
    }

    // MARK: host updates

    func checkHostUpdate(mac macId: String) {
        send(.checkHostUpdate, toMac: macId)
    }

    func updateHost(mac macId: String) {
        let current = hostUpdates[macId]
        hostUpdates[macId] = HostUpdate(state: .updating, current: current?.current ?? hostByMac[macId]?.appVersion ?? "",
                                        latest: current?.latest, message: "Asking the host to update…")
        send(.updateHost, toMac: macId)
    }

    // MARK: receiving

    func receiveAutomation(_ message: ServerMessage, from macId: String, isActive: Bool) {
        switch message {
        case .issues(let cwd, let items, let error):
            guard isActive else { return }
            issuesByCwd[cwd] = IssueList(items: items, error: error, loading: false)
        case .templates(let cwd, let items):
            guard isActive else { return }
            templatesByCwd[cwd] = items
        case .audit(let report):
            guard isActive else { return }
            auditReport = report
            auditLoading = false
        case .relaySetup(let setup, let error):
            relaySetups[macId] = RelayFetch(setup: setup, error: error, loading: false)
        case .relayConfigured(let error):
            relayJoins[macId] = error.map { RelayJoin(state: .failed, message: $0) } ?? RelayJoin(state: .restarting)
        case .github(let account, let login, let error):
            var panel = githubByMac[macId] ?? GitHubPanel()
            panel.account = account
            panel.login = login
            panel.error = error
            panel.loading = false
            githubByMac[macId] = panel
        case .hostUpdate(let update):
            hostUpdates[macId] = update
        default:
            break
        }
    }
}
