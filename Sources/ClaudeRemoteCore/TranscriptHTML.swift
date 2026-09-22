import Foundation

/// Renders a transcript as one self-contained HTML page — the thing a share link shows. Every piece
/// of text from the transcript is escaped (it is agent and tool output, anything could be in it), the
/// Markdown of prompts and replies is rendered by `MarkdownParser` plus a small inline pass, tool work
/// folds into `<details>`, and the styling is inline so the page needs nothing from anywhere.
public enum TranscriptHTML {
    public static func page(items: [TranscriptItem], options: TranscriptExport.Options, generatedAt: Date = Date()) -> String {
        var body = ""
        let blocks = TranscriptLayout.blocks(for: items, sessionRunning: false)
        for block in blocks {
            switch block {
            case .user(let item):
                guard case .user(let text, let images) = item.kind else { continue }
                body += "<section class=\"turn you\"><div class=\"who\">You</div>"
                if !images.isEmpty { body += "<p class=\"meta\">\(images.count) image\(images.count == 1 ? "" : "s") attached</p>" }
                body += markdown(text) + "</section>\n"
            case .assistant(let item):
                guard case .assistantText(let text, _) = item.kind else { continue }
                body += "<section class=\"turn agent\"><div class=\"who\">\(escape(options.agentName))</div>" + markdown(text) + "</section>\n"
            case .activity(let group):
                body += "<details class=\"work\"><summary>\(escape(group.title))</summary>"
                for step in group.steps {
                    switch step {
                    case .thinking(_, let text, _, _):
                        guard options.includeThinking, !text.isEmpty else { continue }
                        body += "<div class=\"step\"><div class=\"tool\">Thinking</div><blockquote>\(markdown(text))</blockquote></div>"
                    case .tool(let tool):
                        let line = ToolSummary.line(name: tool.name, input: tool.input)
                        body += "<div class=\"step\"><div class=\"tool\">\(escape(ToolSummary.displayName(tool.name)))"
                        if !line.isEmpty { body += " <code>\(escape(line))</code>" }
                        body += "</div>"
                        if let result = tool.resultText, !result.isEmpty {
                            body += "<pre class=\"\(tool.isError ? "error" : "")\">\(escape(truncate(result, lines: options.maxResultLines)))</pre>"
                        }
                        body += "</div>"
                    case .orphanResult(_, let text, let isError, _):
                        if !text.isEmpty { body += "<pre class=\"\(isError ? "error" : "")\">\(escape(truncate(text, lines: options.maxResultLines)))</pre>" }
                    }
                }
                body += "</details>\n"
            case .note(let item):
                if case .note(let text) = item.kind { body += "<p class=\"note\">\(escape(text))</p>\n" }
            case .turnError(let item):
                if case .turnEnd(let text, _) = item.kind { body += "<p class=\"note error\">⚠️ \(escape(text.isEmpty ? "Turn failed" : text))</p>\n" }
            }
        }
        let stamp = ISO8601DateFormatter().string(from: generatedAt)
        var header = "<h1>\(escape(options.title))</h1>"
        if let subtitle = options.subtitle, !subtitle.isEmpty { header += "<p class=\"meta\">\(escape(subtitle))</p>" }
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(options.title))</title>
        <style>\(style)</style></head>
        <body><main>
        <header>\(header)</header>
        \(body)
        <footer>Shared from ClaudeRemote · <time datetime="\(stamp)">\(stamp)</time></footer>
        </main></body></html>
        """
    }

    static let style = """
    :root{--bg:#f9f9f7;--fg:#1a1a18;--muted:#73726c;--line:rgba(31,30,29,.12);--card:#fff;--code:#f0efea;--clay:#d97757;--err:#b53333}
    @media (prefers-color-scheme:dark){:root{--bg:#1c1c1a;--fg:#ecebe6;--muted:#a09f99;--line:rgba(255,255,255,.12);--card:#262624;--code:#30302e;--err:#e07070}}
    *{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
    main{max-width:760px;margin:0 auto;padding:24px 16px 48px}h1{font-size:1.5rem;margin:0 0 4px}
    .meta{color:var(--muted);font-size:.85rem;margin:4px 0}
    .turn{margin:20px 0}.who{font-size:.75rem;font-weight:600;text-transform:uppercase;letter-spacing:.04em;color:var(--muted);margin-bottom:4px}
    .you{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:10px 14px}.agent .who{color:var(--clay)}
    details.work{border:1px solid var(--line);border-radius:10px;padding:6px 12px;margin:12px 0;color:var(--muted)}
    details.work summary{cursor:pointer;font-size:.9rem}.step{margin:8px 0}.tool{font-size:.85rem;color:var(--fg)}
    pre{background:var(--code);border-radius:8px;padding:10px;overflow-x:auto;font:12.5px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace;white-space:pre-wrap;word-break:break-word}
    code{background:var(--code);border-radius:4px;padding:1px 4px;font:.9em ui-monospace,SFMono-Regular,Menlo,monospace}pre code{background:none;padding:0}
    pre.error,.error{color:var(--err)}blockquote{border-left:3px solid var(--line);margin:8px 0;padding:0 12px;color:var(--muted)}
    table{border-collapse:collapse;margin:8px 0;display:block;overflow-x:auto}th,td{border:1px solid var(--line);padding:4px 8px;text-align:left}
    .note{color:var(--muted);font-size:.85rem;text-align:center}a{color:var(--clay)}hr{border:0;border-top:1px solid var(--line)}
    footer{margin-top:40px;color:var(--muted);font-size:.8rem;text-align:center}
    """

    // MARK: Markdown

    static func markdown(_ text: String) -> String {
        blocksHTML(MarkdownParser.parse(text))
    }

    static func blocksHTML(_ blocks: [MarkdownBlock]) -> String {
        blocks.map { block -> String in
            switch block {
            case .heading(let level, let text):
                let l = min(6, max(2, level + 1))   // the page title owns <h1>
                return "<h\(l)>\(inline(text))</h\(l)>"
            case .paragraph(let text):
                return "<p>\(inline(text).replacingOccurrences(of: "\n", with: "<br>"))</p>"
            case .code(let code, let language):
                let cls = language.map { " class=\"language-\(escape($0))\"" } ?? ""
                return "<pre><code\(cls)>\(escape(code))</code></pre>"
            case .list(let ordered, let start, let items):
                let tag = ordered ? "ol" : "ul"
                let open = ordered && start != 1 ? "<ol start=\"\(start)\">" : "<\(tag)>"
                let lis = items.map { item -> String in
                    let box = item.checked.map { $0 ? "☑ " : "☐ " } ?? ""
                    var inner = blocksHTML(item.blocks)
                    // A tight list item is one paragraph — drop the <p> so bullets hug their text.
                    if item.blocks.count == 1, case .paragraph = item.blocks[0], inner.hasPrefix("<p>"), inner.hasSuffix("</p>") {
                        inner = String(inner.dropFirst(3).dropLast(4))
                    }
                    return "<li>\(box)\(inner)</li>"
                }.joined()
                return open + lis + "</\(tag)>"
            case .quote(let inner):
                return "<blockquote>\(blocksHTML(inner))</blockquote>"
            case .rule:
                return "<hr>"
            case .table(let header, let rows, let alignments):
                func align(_ i: Int) -> String {
                    guard i < alignments.count else { return "" }
                    switch alignments[i] {
                    case .leading: return ""
                    case .center: return " style=\"text-align:center\""
                    case .trailing: return " style=\"text-align:right\""
                    }
                }
                let head = header.enumerated().map { "<th\(align($0.offset))>\(inline($0.element))</th>" }.joined()
                let body = rows.map { row in "<tr>" + row.enumerated().map { "<td\(align($0.offset))>\(inline($0.element))</td>" }.joined() + "</tr>" }.joined()
                return "<table><thead><tr>\(head)</tr></thead><tbody>\(body)</tbody></table>"
            }
        }.joined(separator: "\n")
    }

    /// Code spans, bold, italic, strikethrough and links — on already-escaped text, so nothing the
    /// transcript contains can turn into markup of its own. Links are kept only for http(s) and mailto.
    static func inline(_ raw: String) -> String {
        // Code spans first, out of reach of the other rules.
        var spans: [String] = []
        var text = ""
        var rest = Substring(raw)
        while let open = rest.firstIndex(of: "`") {
            text += rest[..<open]
            let after = rest[rest.index(after: open)...]
            guard let close = after.firstIndex(of: "`") else { text += rest[open...]; rest = ""; break }
            spans.append("<code>\(escape(String(after[..<close])))</code>")
            text += "\u{E000}\(spans.count - 1)\u{E001}"
            rest = after[after.index(after: close)...]
        }
        text += rest
        var html = escape(text)
        html = replace(html, #"\[([^\]]+)\]\(([^)\s]+)\)"#) { groups in
            let label = groups[1], url = groups[2]
            let lower = url.lowercased()
            guard lower.hasPrefix("https://") || lower.hasPrefix("http://") || lower.hasPrefix("mailto:") else { return label }
            return "<a href=\"\(url)\" rel=\"noopener noreferrer\">\(label)</a>"
        }
        html = replace(html, #"\*\*(.+?)\*\*"#) { "<strong>\($0[1])</strong>" }
        html = replace(html, #"__(.+?)__"#) { "<strong>\($0[1])</strong>" }
        html = replace(html, #"~~(.+?)~~"#) { "<del>\($0[1])</del>" }
        html = replace(html, #"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#) { "<em>\($0[1])</em>" }
        html = replace(html, #"(?<![\w_])_(?!\s)(.+?)(?<!\s)_(?![\w_])"#) { "<em>\($0[1])</em>" }
        for (i, span) in spans.enumerated() {
            html = html.replacingOccurrences(of: "\u{E000}\(i)\u{E001}", with: span)
        }
        return html
    }

    private static func replace(_ text: String, _ pattern: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            var groups: [String] = []
            for g in 0..<match.numberOfRanges {
                let r = match.range(at: g)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            out += transform(groups)
            last = match.range.location + match.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    public static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    private static func truncate(_ text: String, lines: Int) -> String {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard all.count > lines else { return text }
        return all.prefix(lines).joined(separator: "\n") + "\n… (\(all.count - lines) more lines)"
    }
}
