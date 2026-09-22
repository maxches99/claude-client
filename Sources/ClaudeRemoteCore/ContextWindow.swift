import Foundation

/// How full the model's context window is — the number behind `/context`, worked out from the token
/// counts the CLI reports with every assistant message.
public enum ContextWindow {
    /// Tokens the model can hold. Claude models are 200k unless the id asks for the 1M beta.
    ///
    /// `observed` is what the session is already carrying: a transcript we only watch reports the
    /// plain model id even when the 1M window is on, and a context cannot be larger than its window —
    /// so a count that does not fit is itself the evidence that the window is the bigger one.
    public static func limit(model: String?, agent: AgentKind = .claude, observed: Int = 0) -> Int {
        let base = declaredLimit(model: model, agent: agent)
        guard observed > base else { return base }
        return observed <= 1_000_000 ? 1_000_000 : observed
    }

    private static func declaredLimit(model: String?, agent: AgentKind) -> Int {
        guard let model = model?.lowercased(), !model.isEmpty else { return agent == .codex ? 272_000 : 200_000 }
        if model.contains("[1m]") || model.contains("-1m") { return 1_000_000 }
        if agent == .codex {
            // GPT-5 class models the Codex CLI runs.
            if model.contains("gpt-5") || model.contains("codex") { return 272_000 }
            return 128_000
        }
        return 200_000
    }

    /// The part of the window that is actually usable: the CLI starts compacting before the end.
    public static let compactionHeadroom = 0.92

    public struct Usage: Equatable, Sendable {
        public var tokens: Int
        public var limit: Int

        public init(tokens: Int, limit: Int) {
            self.tokens = tokens
            self.limit = limit
        }

        public var fraction: Double { limit > 0 ? min(1, Double(tokens) / Double(limit)) : 0 }
        /// Past this the CLI is about to compact on its own.
        public var isTight: Bool { fraction >= 0.75 }
        public var isCritical: Bool { fraction >= ContextWindow.compactionHeadroom }

        /// "128k / 200k".
        public var label: String { "\(ContextWindow.short(tokens)) / \(ContextWindow.short(limit))" }
        public var percentLabel: String { "\(Int((fraction * 100).rounded()))%" }
    }

    public static func short(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return "\(Int((Double(tokens) / 1_000).rounded()))k" }
        return "\(tokens)"
    }
}
