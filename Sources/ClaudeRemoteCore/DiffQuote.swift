import Foundation

/// A unified diff broken into lines that know which file and line numbers they belong to, so a
/// selection in the phone's diff viewer can be quoted back to the agent as "these lines of that file".
public struct DiffLines {
    public enum Kind: Equatable, Sendable {
        case added, removed, context
        /// `diff --git`, `index`, `---`/`+++`, `@@` and anything else that is not file content.
        case meta
    }

    public struct Line: Identifiable, Equatable, Sendable {
        public let id: Int
        public let text: String
        public let kind: Kind
        public let file: String?
        /// Line number in the new file (added / context lines).
        public let newLine: Int?
        /// Line number in the old file (removed / context lines).
        public let oldLine: Int?
        public var isContent: Bool { kind != .meta }
    }

    public let lines: [Line]

    private static let hunk = try! NSRegularExpression(pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#)

    public init(_ diff: String, maxLines: Int = .max) {
        var out: [Line] = []
        var file: String?
        var newLine: Int?
        var oldLine: Int?
        // A section (`# Status` / `# Diff`) header or a file header resets the counters; hunk headers
        // set them. Inside a hunk, `+`/`-`/` ` lines advance the respective side.
        for (i, raw) in diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if i >= maxLines { break }
            let text = String(raw)
            var kind = Kind.meta
            var lineNew: Int?
            var lineOld: Int?
            if text.hasPrefix("+++ ") {
                file = DiffLines.path(fromHeader: text)
                newLine = nil; oldLine = nil
            } else if text.hasPrefix("--- ") || text.hasPrefix("diff --git") || text.hasPrefix("index ") || text.hasPrefix("# ") {
                if text.hasPrefix("diff --git") || text.hasPrefix("# ") { file = nil }
                newLine = nil; oldLine = nil
            } else if text.hasPrefix("@@"), let m = DiffLines.hunk.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
                oldLine = Int(text[Range(m.range(at: 1), in: text)!])
                newLine = Int(text[Range(m.range(at: 2), in: text)!])
            } else if newLine != nil || oldLine != nil {
                if text.hasPrefix("+") {
                    kind = .added; lineNew = newLine; newLine? += 1
                } else if text.hasPrefix("-") {
                    kind = .removed; lineOld = oldLine; oldLine? += 1
                } else if text.hasPrefix("\\") {
                    kind = .meta   // "\ No newline at end of file"
                } else {
                    kind = .context; lineNew = newLine; lineOld = oldLine; newLine? += 1; oldLine? += 1
                }
            }
            out.append(Line(id: i, text: text, kind: kind, file: file, newLine: lineNew, oldLine: lineOld))
        }
        lines = out
    }

    /// `+++ b/path` → `path`; `+++ /dev/null` → nil.
    static func path(fromHeader header: String) -> String? {
        var p = String(header.dropFirst(4))
        if let tab = p.firstIndex(of: "\t") { p = String(p[..<tab]) }
        if p == "/dev/null" { return nil }
        if p.hasPrefix("b/") || p.hasPrefix("a/") { p.removeFirst(2) }
        return p.isEmpty ? nil : p
    }

    /// The prompt text for a selection of line ids: a header naming the file and line range, then the
    /// lines as a fenced diff (prefixes kept so added / removed are unambiguous). Lines from several
    /// files become several blocks. Returns nil for an empty selection.
    public func quote(ids: Set<Int>) -> String? {
        let picked = lines.filter { ids.contains($0.id) && $0.isContent }
        guard !picked.isEmpty else { return nil }
        var blocks: [String] = []
        var current: [Line] = []
        func flush() {
            guard let first = current.first else { return }
            let file = first.file ?? "diff"
            let numbers = current.compactMap { $0.newLine ?? $0.oldLine }
            var header = "`\(file)`"
            if let lo = numbers.min(), let hi = numbers.max() {
                header += lo == hi ? " line \(lo)" : " lines \(lo)–\(hi)"
                if current.allSatisfy({ $0.kind == .removed }) { header += " (removed)" }
            }
            let body = current.map { $0.text.isEmpty ? " " : $0.text }.joined(separator: "\n")
            blocks.append("\(header):\n```diff\n\(body)\n```")
            current = []
        }
        for line in picked {
            if let last = current.last, last.file != line.file { flush() }
            current.append(line)
        }
        flush()
        return blocks.joined(separator: "\n\n")
    }
}
