import Foundation

/// Renders a transcript as Markdown for sharing: prompts and replies in full, each stretch of tool
/// work folded into a `<details>` block with the calls and (truncated) results.
public enum TranscriptExport {
    public struct Options: Sendable {
        public var title: String
        public var subtitle: String?
        public var agentName: String
        /// Result lines kept per tool call; the rest is elided with a note.
        public var maxResultLines: Int
        public var includeThinking: Bool

        public init(title: String, subtitle: String? = nil, agentName: String = "Claude", maxResultLines: Int = 40, includeThinking: Bool = false) {
            self.title = title
            self.subtitle = subtitle
            self.agentName = agentName
            self.maxResultLines = maxResultLines
            self.includeThinking = includeThinking
        }
    }

    public static func markdown(items: [TranscriptItem], options: Options) -> String {
        var out = "# \(options.title)\n"
        if let subtitle = options.subtitle, !subtitle.isEmpty { out += "\n_\(subtitle)_\n" }
        let blocks = TranscriptLayout.blocks(for: items, sessionRunning: false)
        for block in blocks {
            switch block {
            case .user(let item):
                guard case .user(let text, let images) = item.kind else { continue }
                out += "\n## You\n\n"
                if !images.isEmpty { out += "_\(images.count) image\(images.count == 1 ? "" : "s") attached_\n\n" }
                out += text + "\n"
            case .assistant(let item):
                guard case .assistantText(let text, _) = item.kind else { continue }
                out += "\n## \(options.agentName)\n\n" + text + "\n"
            case .activity(let group):
                out += "\n<details>\n<summary>\(group.title)</summary>\n\n"
                for step in group.steps {
                    switch step {
                    case .thinking(_, let text, _, _):
                        guard options.includeThinking, !text.isEmpty else { continue }
                        out += "**Thinking**\n\n" + quoted(text) + "\n\n"
                    case .tool(let tool):
                        let line = ToolSummary.line(name: tool.name, input: tool.input)
                        out += "**\(ToolSummary.displayName(tool.name))**" + (line.isEmpty ? "" : " `\(line.replacingOccurrences(of: "`", with: "'"))`") + "\n\n"
                        if let result = tool.resultText, !result.isEmpty {
                            out += fenced(truncate(result, lines: options.maxResultLines), error: tool.isError) + "\n"
                        }
                    case .orphanResult(_, let text, let isError, _):
                        if !text.isEmpty { out += fenced(truncate(text, lines: options.maxResultLines), error: isError) + "\n" }
                    }
                }
                out += "</details>\n"
            case .note(let item):
                if case .note(let text) = item.kind { out += "\n> \(text)\n" }
            case .turnError(let item):
                if case .turnEnd(let text, _) = item.kind { out += "\n> ⚠️ \(text.isEmpty ? "Turn failed" : text)\n" }
            }
        }
        return out
    }

    /// The last assistant reply, for "copy the answer" — empty when there is none.
    public static func lastReply(items: [TranscriptItem]) -> String {
        for item in items.reversed() {
            if case .assistantText(let text, _) = item.kind, !text.isEmpty { return text }
        }
        return ""
    }

    private static func truncate(_ text: String, lines: Int) -> String {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard all.count > lines else { return text }
        return all.prefix(lines).joined(separator: "\n") + "\n… (\(all.count - lines) more lines)"
    }

    private static func fenced(_ text: String, error: Bool) -> String {
        // A result may itself contain ``` — pick a fence the text doesn't use.
        var fence = "```"
        while text.contains(fence) { fence += "`" }
        return fence + (error ? "text\n⚠️ " : "\n") + text + "\n" + fence + "\n"
    }

    private static func quoted(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
    }

    /// A file-safe name for the export: the session title, trimmed and without path characters.
    public static func fileName(for title: String) -> String {
        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        name = name.unicodeScalars.map { bad.contains($0) ? "-" : Character($0) }.map(String.init).joined()
        if name.count > 60 { name = String(name.prefix(60)) }
        return (name.isEmpty ? "transcript" : name) + ".md"
    }
}

/// Finds transcript rows containing a query, for the chat's find bar. A match points at a block
/// (what the chat scrolls to) and, inside an activity group, the step to unfold.
public struct TranscriptMatch: Equatable, Sendable {
    public var blockId: String
    public var stepId: String?

    public init(blockId: String, stepId: String? = nil) {
        self.blockId = blockId
        self.stepId = stepId
    }
}

public enum TranscriptSearch {
    public static func matches(in blocks: [TranscriptBlock], query: String) -> [TranscriptMatch] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        func hit(_ text: String) -> Bool { text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        var result: [TranscriptMatch] = []
        for block in blocks {
            switch block {
            case .user(let item):
                if case .user(let text, _) = item.kind, hit(text) { result.append(TranscriptMatch(blockId: block.id)) }
            case .assistant(let item):
                if case .assistantText(let text, _) = item.kind, hit(text) { result.append(TranscriptMatch(blockId: block.id)) }
            case .activity(let group):
                for step in group.steps {
                    switch step {
                    case .thinking(_, let text, _, _):
                        if hit(text) { result.append(TranscriptMatch(blockId: block.id, stepId: step.id)) }
                    case .tool(let tool):
                        let line = ToolSummary.line(name: tool.name, input: tool.input)
                        if hit(tool.name) || hit(line) || hit(tool.resultText ?? "") || hit(tool.input.serializedString()) {
                            result.append(TranscriptMatch(blockId: block.id, stepId: step.id))
                        }
                    case .orphanResult(_, let text, _, _):
                        if hit(text) { result.append(TranscriptMatch(blockId: block.id, stepId: step.id)) }
                    }
                }
            case .note(let item):
                if case .note(let text) = item.kind, hit(text) { result.append(TranscriptMatch(blockId: block.id)) }
            case .turnError(let item):
                if case .turnEnd(let text, _) = item.kind, hit(text) { result.append(TranscriptMatch(blockId: block.id)) }
            }
        }
        return result
    }
}
