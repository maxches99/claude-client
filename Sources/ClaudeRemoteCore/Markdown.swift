import Foundation

/// Block-level Markdown as Claude Code's terminal renderer understands it: headings, bullet /
/// numbered / task lists (nested), block quotes, tables, thematic breaks and fenced code.
/// Inline syntax (bold, italic, code spans, links, strikethrough) stays as-is in the block text
/// and is left to the platform's inline parser.
public indirect enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(String, language: String?)
    case list(ordered: Bool, start: Int, items: [MarkdownListItem])
    case quote([MarkdownBlock])
    case rule
    case table(header: [String], rows: [[String]], alignments: [MarkdownColumnAlignment])
}

public struct MarkdownListItem: Equatable {
    /// `nil` for a plain item, otherwise the state of a `- [ ]` / `- [x]` task checkbox.
    public var checked: Bool?
    public var blocks: [MarkdownBlock]
    public init(checked: Bool? = nil, blocks: [MarkdownBlock]) {
        self.checked = checked
        self.blocks = blocks
    }
}

public enum MarkdownColumnAlignment: Equatable {
    case leading, center, trailing
}

public enum MarkdownParser {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        parse(lines: text.components(separatedBy: "\n"))
    }

    // MARK: - Blocks

    private static func parse(lines: [String]) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }

            if let fence = fenceMarker(trimmed) {
                let language = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i]); i += 1
                }
                if i < lines.count { i += 1 } // closing fence (absent while still streaming)
                blocks.append(.code(code.joined(separator: "\n"), language: language.isEmpty ? nil : language))
                continue
            }
            if let heading = heading(trimmed) { blocks.append(heading); i += 1; continue }
            if isRule(trimmed) { blocks.append(.rule); i += 1; continue }
            if trimmed.hasPrefix(">") {
                var inner: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    var body = t.dropFirst()
                    if body.hasPrefix(" ") { body = body.dropFirst() }
                    inner.append(String(body)); i += 1
                }
                blocks.append(.quote(parse(lines: inner)))
                continue
            }
            if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                let header = tableCells(lines[i])
                let alignments = tableAlignments(lines[i + 1], count: header.count)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    var cells = tableCells(lines[i])
                    if cells.count < header.count { cells += Array(repeating: "", count: header.count - cells.count) }
                    rows.append(Array(cells.prefix(header.count))); i += 1
                }
                blocks.append(.table(header: header, rows: rows, alignments: alignments))
                continue
            }
            if let marker = listMarker(line) {
                let (list, next) = parseList(lines: lines, from: i, first: marker)
                blocks.append(list); i = next
                continue
            }

            var paragraph = [trimmed]
            i += 1
            while i < lines.count {
                let next = lines[i]
                let t = next.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || startsBlock(next) { break }
                paragraph.append(t); i += 1
            }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
        }
        return blocks
    }

    private static func startsBlock(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return fenceMarker(t) != nil || heading(t) != nil || isRule(t) || t.hasPrefix(">") || listMarker(line) != nil
    }

    private static func fenceMarker(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("```") { return "```" }
        if trimmed.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func heading(_ trimmed: String) -> MarkdownBlock? {
        let hashes = trimmed.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Optional closing hashes: `## Title ##`
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: hashes.count, text: text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let chars = trimmed.filter { $0 != " " }
        guard chars.count >= 3, let first = chars.first, "-*_".contains(first) else { return false }
        return chars.allSatisfy { $0 == first }
    }

    // MARK: - Lists

    struct ListMarker {
        let indent: Int
        let ordered: Bool
        let number: Int
        /// Column where the item's content starts; deeper-indented lines belong to this item.
        let contentIndent: Int
        let content: String
    }

    private static func leadingIndent(_ line: String) -> Int {
        var indent = 0
        for c in line {
            if c == " " { indent += 1 } else if c == "\t" { indent += 4 } else { break }
        }
        return indent
    }

    static func listMarker(_ line: String) -> ListMarker? {
        let indent = leadingIndent(line)
        let rest = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let first = rest.first else { return nil }
        var markerWidth = 0
        var ordered = false
        var number = 0
        if "-*+".contains(first) {
            markerWidth = 1
        } else if first.isASCII, first.isNumber {
            let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
            let delimiter = rest.dropFirst(digits.count).first
            guard digits.count <= 9, let n = Int(digits), delimiter == "." || delimiter == ")" else { return nil }
            ordered = true; number = n; markerWidth = digits.count + 1
        } else {
            return nil
        }
        let after = rest.dropFirst(markerWidth)
        if after.isEmpty {
            return ListMarker(indent: indent, ordered: ordered, number: number, contentIndent: indent + markerWidth + 1, content: "")
        }
        guard after.first == " " || after.first == "\t" else { return nil }
        let spaces = after.prefix(while: { $0 == " " || $0 == "\t" }).count
        return ListMarker(indent: indent, ordered: ordered, number: number,
                          contentIndent: indent + markerWidth + min(spaces, 4),
                          content: String(after.dropFirst(spaces)))
    }

    private static func parseList(lines: [String], from start: Int, first: ListMarker) -> (MarkdownBlock, Int) {
        var items: [(marker: ListMarker, lines: [String])] = []
        var current = (marker: first, lines: [first.content])
        var i = start + 1
        loop: while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                // A blank line stays inside the list only if something list-shaped follows it.
                var j = i + 1
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                guard j < lines.count else { break }
                let next = lines[j]
                if leadingIndent(next) >= current.marker.contentIndent {
                    current.lines.append(""); i += 1; continue
                }
                if let m = listMarker(next), m.indent >= first.indent, m.ordered == first.ordered {
                    current.lines.append(""); i += 1; continue
                }
                break
            }
            if let m = listMarker(line), m.indent < current.marker.contentIndent {
                guard m.indent >= first.indent, m.ordered == first.ordered else { break loop }
                items.append(current)
                current = (marker: m, lines: [m.content])
                i += 1; continue
            }
            if leadingIndent(line) >= current.marker.contentIndent {
                current.lines.append(dedent(line, by: current.marker.contentIndent)); i += 1; continue
            }
            // Lazy continuation of the item's paragraph.
            if let last = current.lines.last, !last.isEmpty, !startsBlock(line) {
                current.lines.append(trimmed); i += 1; continue
            }
            break
        }
        items.append(current)

        let parsed = items.map { item -> MarkdownListItem in
            var lines = item.lines
            var checked: Bool?
            if let head = lines.first {
                if head.hasPrefix("[ ] ") || head == "[ ]" { checked = false; lines[0] = String(head.dropFirst(3)) }
                else if head.hasPrefix("[x] ") || head.hasPrefix("[X] ") || head == "[x]" || head == "[X]" { checked = true; lines[0] = String(head.dropFirst(3)) }
            }
            return MarkdownListItem(checked: checked, blocks: parse(lines: lines))
        }
        return (.list(ordered: first.ordered, start: first.ordered ? first.number : 1, items: parsed), i)
    }

    private static func dedent(_ line: String, by columns: Int) -> String {
        var removed = 0
        var index = line.startIndex
        while index < line.endIndex, removed < columns {
            let c = line[index]
            if c == " " { removed += 1 } else if c == "\t" { removed += 4 } else { break }
            index = line.index(after: index)
        }
        return String(line[index...])
    }

    // MARK: - Tables

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|"), t.contains("-") else { return false }
        return t.allSatisfy { "|:- ".contains($0) }
    }

    private static func tableCells(_ line: String) -> [String] {
        var t = Substring(line.trimmingCharacters(in: .whitespaces))
        if t.hasPrefix("|") { t = t.dropFirst() }
        if t.hasSuffix("|") { t = t.dropLast() }
        // Keep `\|` inside a cell as a literal pipe.
        let placeholder = "\u{1}"
        return t.replacingOccurrences(of: "\\|", with: placeholder)
            .components(separatedBy: "|")
            .map { $0.replacingOccurrences(of: placeholder, with: "|").trimmingCharacters(in: .whitespaces) }
    }

    private static func tableAlignments(_ line: String, count: Int) -> [MarkdownColumnAlignment] {
        var result = tableCells(line).map { cell -> MarkdownColumnAlignment in
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): return .center
            case (false, true): return .trailing
            default: return .leading
            }
        }
        if result.count < count { result += Array(repeating: .leading, count: count - result.count) }
        return Array(result.prefix(count))
    }
}

/// A link in an agent's reply that points at a file on the Mac rather than a web page — the Anthropic CLI
/// writes `[Bar.tsx:42](app/Bar.tsx:42)` relative to the project, Codex `[Bar.tsx](/abs/app/Bar.tsx#L42)`.
/// `path` is absolute (resolved against the session's folder), `relativePath` is how the composer
/// should mention it, `line` is the 1-based line the link pointed at, if any.
public struct FileLink: Equatable {
    public var path: String
    public var relativePath: String
    public var line: Int?

    public init(path: String, relativePath: String, line: Int?) {
        self.path = path
        self.relativePath = relativePath
        self.line = line
    }

    /// `nil` for web, mail and app links — those go to the system as usual.
    public static func parse(_ destination: String, cwd: String) -> FileLink? {
        var s = destination.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("<"), s.hasSuffix(">") { s = String(s.dropFirst().dropLast()) }
        if s.lowercased().hasPrefix("file://") {
            s = String(s.dropFirst("file://".count))
            if let slash = s.firstIndex(of: "/") { s = String(s[slash...]) } else { return nil }  // file://host/path
        } else if let colon = s.firstIndex(of: ":") {
            // A real scheme (https:, mailto:, vscode://…) — as opposed to "Bar.tsx:42", whose
            // "scheme" has a dot in it, or "src/Bar.tsx:42", where a slash comes first.
            let scheme = s[..<colon]
            let looksLikeScheme = !scheme.isEmpty && scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" }
                && scheme.first!.isLetter
            if looksLikeScheme, !s[s.index(after: colon)...].allSatisfy({ $0.isNumber || $0 == ":" || $0 == "-" }) { return nil }
        }
        s = s.removingPercentEncoding ?? s

        var line: Int?
        if let hash = s.range(of: "#L", options: .backwards) {
            line = Int(s[hash.upperBound...].prefix { $0.isNumber })
            s = String(s[..<hash.lowerBound])
        } else if let hash = s.firstIndex(of: "#") {
            s = String(s[..<hash])
        }
        // ":42", ":42:7" or ":42-50" after the file name.
        if let match = s.range(of: #":(\d+)(?::\d+|-\d+)?$"#, options: .regularExpression) {
            line = line ?? Int(s[match].dropFirst().prefix { $0.isNumber })
            s = String(s[..<match.lowerBound])
        }
        while s.hasPrefix("./") { s.removeFirst(2) }
        guard !s.isEmpty, s != "/" else { return nil }

        let root = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        if s.hasPrefix("/") || s.hasPrefix("~") {
            let relative = !root.isEmpty && s.hasPrefix(root + "/") ? String(s.dropFirst(root.count + 1)) : s
            return FileLink(path: s, relativePath: relative, line: line)
        }
        return FileLink(path: root.isEmpty ? s : root + "/" + s, relativePath: s, line: line)
    }
}
