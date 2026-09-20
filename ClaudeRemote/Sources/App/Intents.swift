import AppIntents
import CoreSpotlight
import Foundation
import ClaudeRemoteCore

// MARK: - App Intents (Shortcuts, Siri)

enum AgentChoice: String, AppEnum {
    case claude, codex
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Agent")
    static let caseDisplayRepresentations: [AgentChoice: DisplayRepresentation] = [.claude: "Claude", .codex: "Codex"]
    var kind: AgentKind { self == .codex ? .codex : .claude }
}

/// "Ask Claude …" — a tool-less chat on the Mac answers, and the reply comes back to the shortcut.
struct AskAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask the agent"
    static let description = IntentDescription("Sends a question to a quick chat on your Mac (no tools, no project) and returns the reply.")
    static let openAppWhenRun = false

    @Parameter(title: "Question") var question: String
    @Parameter(title: "Agent", default: .claude) var agent: AgentChoice

    static var parameterSummary: some ParameterSummary {
        Summary("Ask \(\.$agent) \(\.$question)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let model = AppModel.shared else { throw IntentFailure.noApp }
        let reply = try await model.askChat(question, agent: agent.kind)
        return .result(value: reply, dialog: IntentDialog(stringLiteral: reply))
    }
}

/// How many sessions wait for an approval, and which.
struct PendingApprovalsIntent: AppIntent {
    static let title: LocalizedStringResource = "Pending approvals"
    static let description = IntentDescription("How many sessions on the Mac are waiting for you to approve a tool.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        guard let model = AppModel.shared else { throw IntentFailure.noApp }
        try await model.ensureConnected()
        let pending = model.permissions
        let names = pending.map { "\(model.summary(for: $0.sessionId)?.projectName ?? "session"): \($0.toolName)" }
        let text = pending.isEmpty ? "Nothing is waiting for approval." : "\(pending.count) waiting — " + names.joined(separator: ", ")
        return .result(value: pending.count, dialog: IntentDialog(stringLiteral: text))
    }
}

/// Approves everything that is waiting — unless Face ID is required, in which case the app must be opened.
struct ApprovePendingIntent: AppIntent {
    static let title: LocalizedStringResource = "Approve pending"
    static let description = IntentDescription("Allows every tool call currently waiting for approval.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        guard let model = AppModel.shared else { throw IntentFailure.noApp }
        try await model.ensureConnected()
        guard !model.requireBiometricsForApproval else { throw IntentFailure.needsFaceID }
        let pending = model.permissions
        for request in pending { model.decide(request, allow: true) }
        let text = pending.isEmpty ? "Nothing was waiting." : "Approved \(pending.count)."
        return .result(value: pending.count, dialog: IntentDialog(stringLiteral: text))
    }
}

struct DenyPendingIntent: AppIntent {
    static let title: LocalizedStringResource = "Deny pending"
    static let description = IntentDescription("Denies every tool call currently waiting for approval.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        guard let model = AppModel.shared else { throw IntentFailure.noApp }
        try await model.ensureConnected()
        let pending = model.permissions
        for request in pending { model.decide(request, allow: false, reason: "Denied from a shortcut") }
        return .result(value: pending.count, dialog: IntentDialog(stringLiteral: pending.isEmpty ? "Nothing was waiting." : "Denied \(pending.count)."))
    }
}

/// A session as Shortcuts sees it (picker, Spotlight-style search by title).
struct SessionEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Session")
    static let defaultQuery = SessionQuery()

    let id: String
    let title: String
    let project: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: title), subtitle: LocalizedStringResource(stringLiteral: project))
    }

    init(_ summary: SessionSummary) {
        id = summary.id
        title = summary.title
        project = summary.projectName
    }
}

struct SessionQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [SessionEntity] {
        (AppModel.shared?.sessions ?? []).filter { identifiers.contains($0.id) }.map(SessionEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [SessionEntity] {
        let q = string.lowercased()
        return (AppModel.shared?.sessions ?? []).filter { $0.title.lowercased().contains(q) || $0.projectName.lowercased().contains(q) }
            .prefix(20).map(SessionEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [SessionEntity] {
        (AppModel.shared?.sessions ?? []).filter { $0.status != .unknown }.prefix(10).map(SessionEntity.init)
    }
}

struct OpenSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Open session"
    static let description = IntentDescription("Opens a session in ClaudeRemote.")
    static let openAppWhenRun = true

    @Parameter(title: "Session") var session: SessionEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared?.openDeepLink(sessionId: session.id)
        return .result()
    }
}

/// Sends a prompt to a session that already exists (no reply is awaited: agent turns take a while).
struct SendPromptIntent: AppIntent {
    static let title: LocalizedStringResource = "Send to session"
    static let description = IntentDescription("Sends a prompt to a session on the Mac and returns right away.")
    static let openAppWhenRun = false

    @Parameter(title: "Session") var session: SessionEntity
    @Parameter(title: "Prompt") var prompt: String

    static var parameterSummary: some ParameterSummary { Summary("Send \(\.$prompt) to \(\.$session)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppModel.shared else { throw IntentFailure.noApp }
        try await model.ensureConnected()
        model.open(session.id)
        model.prompt(session.id, text: prompt)
        return .result(dialog: "Sent.")
    }
}

enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case noApp, notConnected, needsFaceID, timeout

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noApp: return "ClaudeRemote is not ready."
        case .notConnected: return "The Mac is not reachable."
        case .needsFaceID: return "Face ID is required to approve — open ClaudeRemote."
        case .timeout: return "The agent did not answer in time."
        }
    }
}

struct ClaudeRemoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskAgentIntent(), phrases: [
            "Ask \(.applicationName)",
            "Ask a question in \(.applicationName)",
        ], shortTitle: "Ask", systemImageName: "bubble.left.and.text.bubble.right")
        AppShortcut(intent: PendingApprovalsIntent(), phrases: [
            "What's waiting in \(.applicationName)",
            "Pending approvals in \(.applicationName)",
        ], shortTitle: "Pending", systemImageName: "bell.badge")
        AppShortcut(intent: ApprovePendingIntent(), phrases: [
            "Approve in \(.applicationName)",
            "Approve everything in \(.applicationName)",
        ], shortTitle: "Approve", systemImageName: "checkmark.seal")
    }
}

// MARK: - Spotlight

/// Sessions in the phone's Spotlight index, so a title or project name found from the home
/// screen opens the session (`onContinueUserActivity(CSSearchableItemActionType)` in RootView).
enum SpotlightIndex {
    static let domain = "sessions"

    static func sessionId(from activity: NSUserActivity) -> String? {
        guard activity.activityType == CSSearchableItemActionType,
              let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String, id.hasPrefix("session:") else { return nil }
        return String(id.dropFirst("session:".count))
    }

    static func update(_ sessions: [SessionSummary], hostName: String) {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let items = sessions.prefix(300).map { session -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .text)
            attributes.title = session.title
            attributes.contentDescription = "\(session.projectName) · \(session.agent.label) · \(hostName)"
            attributes.keywords = [session.projectName, session.agent.label, "Claude", "session"]
            attributes.contentModificationDate = session.updatedAt
            let item = CSSearchableItem(uniqueIdentifier: "session:\(session.id)", domainIdentifier: domain, attributeSet: attributes)
            item.expirationDate = Date().addingTimeInterval(60 * 24 * 3600)
            return item
        }
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            index.indexSearchableItems(items) { _ in }
        }
    }
}
