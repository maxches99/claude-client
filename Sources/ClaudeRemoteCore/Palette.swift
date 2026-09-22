import Foundation

/// Something the composer can launch: a slash command the CLI advertises, a skill or a sub-agent
/// found in `.claude/` (project or home). The phone shows them in one palette and inserts
/// `insert` into the composer.
public struct PaletteItem: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case command
        case skill
        case agent

        public var label: String {
            switch self {
            case .command: return "Commands"
            case .skill: return "Skills"
            case .agent: return "Sub-agents"
            }
        }

        public var systemImage: String {
            switch self {
            case .command: return "slash.circle"
            case .skill: return "sparkles"
            case .agent: return "person.2"
            }
        }
    }

    /// Where the definition lives.
    public enum Scope: String, Codable, Sendable {
        case project
        case user
        case builtin

        public var label: String {
            switch self {
            case .project: return "Project"
            case .user: return "You"
            case .builtin: return "Built in"
            }
        }
    }

    public var kind: Kind
    public var name: String
    public var detail: String?
    public var scope: Scope
    /// What goes into the composer when it is picked.
    public var insert: String

    public var id: String { "\(kind.rawValue):\(scope.rawValue):\(name)" }

    public init(kind: Kind, name: String, detail: String? = nil, scope: Scope, insert: String? = nil) {
        self.kind = kind
        self.name = name
        self.detail = detail
        self.scope = scope
        self.insert = insert ?? PaletteItem.defaultInsert(kind: kind, name: name)
    }

    public static func defaultInsert(kind: Kind, name: String) -> String {
        switch kind {
        case .command, .skill: return "/\(name) "
        case .agent: return "Use the \(name) sub-agent to "
        }
    }
}
