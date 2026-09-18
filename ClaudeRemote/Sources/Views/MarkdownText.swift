import SwiftUI

/// Lightweight Markdown: fenced code blocks become monospaced boxes, everything else goes
/// through Foundation's inline Markdown parser with newlines preserved.
struct MarkdownText: View {
    let text: String

    private enum Segment: Identifiable {
        case prose(String)
        case code(String, language: String?)
        var id: String {
            switch self {
            case .prose(let s): return "p" + s
            case .code(let s, _): return "c" + s
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let s):
                    Text(MarkdownText.attributed(s))
                        .textSelection(.enabled)
                case .code(let code, let language):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topTrailing) {
                        if let language, !language.isEmpty {
                            Text(language).font(.caption2).foregroundStyle(.tertiary).padding(6)
                        }
                    }
                }
            }
        }
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        var prose: [String] = []
        var code: [String] = []
        var language: String?
        var inCode = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCode {
                    result.append(.code(code.joined(separator: "\n"), language: language))
                    code = []
                    inCode = false
                } else {
                    if !prose.isEmpty { result.append(.prose(prose.joined(separator: "\n"))); prose = [] }
                    language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCode = true
                }
                continue
            }
            if inCode { code.append(line) } else { prose.append(line) }
        }
        if inCode { result.append(.code(code.joined(separator: "\n"), language: language)) }
        if !prose.isEmpty { result.append(.prose(prose.joined(separator: "\n"))) }
        return result
    }

    static func attributed(_ s: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        if let a = try? AttributedString(markdown: s, options: options) { return a }
        return AttributedString(s)
    }
}
