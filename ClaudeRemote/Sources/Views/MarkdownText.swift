import SwiftUI
import ClaudeRemoteCore

/// Renders assistant Markdown the way Claude Code does in the terminal: headings, nested
/// bullet / numbered / task lists, block quotes, tables, rules, fenced code with a copy button,
/// and highlighted inline code.
struct MarkdownText: View {
    let text: String

    var body: some View {
        MarkdownBlocksView(blocks: MarkdownParser.parse(text))
    }
}

struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    var depth = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, depth: depth)
            }
        }
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let depth: Int

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownInline.attributed(text, codeSize: headingCodeSize(level)))
                .font(headingFont(level))
                .textSelection(.enabled)
                .padding(.top, level <= 2 ? 4 : 2)
        case .paragraph(let text):
            Text(MarkdownInline.attributed(text))
                .textSelection(.enabled)
        case .code(let code, let language):
            CodeBlockView(code: code, language: language)
        case .list(let ordered, let start, let items):
            MarkdownListView(ordered: ordered, start: start, items: items, depth: depth)
        case .quote(let blocks):
            MarkdownBlocksView(blocks: blocks, depth: depth)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.4)).frame(width: 3)
                }
        case .rule:
            Divider().padding(.vertical, 2)
        case .table(let header, let rows, let alignments):
            MarkdownTableView(header: header, rows: rows, alignments: alignments)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.bold()
        case 2: return .title3.bold()
        case 3: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }

    private func headingCodeSize(_ level: Int) -> CGFloat {
        let style: UIFont.TextStyle = level == 1 ? .title2 : level == 2 ? .title3 : level == 3 ? .headline : .subheadline
        return UIFont.preferredFont(forTextStyle: style).pointSize - 1
    }
}

struct MarkdownListView: View {
    let ordered: Bool
    let start: Int
    let items: [MarkdownListItem]
    let depth: Int

    private static let bullets = ["•", "◦", "▪"]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    marker(index: index, item: item)
                        .frame(minWidth: ordered ? 22 : 14, alignment: .trailing)
                    MarkdownBlocksView(blocks: item.blocks, depth: depth + 1)
                }
            }
        }
    }

    @ViewBuilder
    private func marker(index: Int, item: MarkdownListItem) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? Color.accentColor : Color.secondary)
        } else if ordered {
            Text("\(start + index).").monospacedDigit().foregroundStyle(.secondary)
        } else {
            Text(Self.bullets[min(depth, Self.bullets.count - 1)]).foregroundStyle(.secondary)
        }
    }
}

struct CodeBlockView: View {
    let code: String
    let language: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    withAnimation { copied = true }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        withAnimation { copied = false }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? Color.green : Color.secondary)
            }
            .padding(.horizontal, 10).padding(.top, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 8)
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]
    let alignments: [MarkdownColumnAlignment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { column, text in
                        cell(text, column: column).fontWeight(.semibold)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Divider()
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, text in
                            cell(text, column: column)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(.separator)))
        }
    }

    private func cell(_ text: String, column: Int) -> some View {
        let alignment: HorizontalAlignment = switch alignments[column] {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        return Text(MarkdownInline.attributed(text, codeSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize - 1))
            .font(.subheadline)
            .textSelection(.enabled)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .gridColumnAlignment(alignment)
    }
}

enum MarkdownInline {
    /// Foundation's inline parser (bold, italic, strikethrough, links, code spans) with newlines
    /// preserved; code spans get a monospaced font and a subtle background like Claude Code's.
    static func attributed(_ s: String, codeSize: CGFloat = UIFont.preferredFont(forTextStyle: .body).pointSize - 1) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        guard var a = try? AttributedString(markdown: s, options: options) else { return AttributedString(s) }
        for run in a.runs {
            guard let intent = run.inlinePresentationIntent, intent.contains(.code) else { continue }
            a[run.range].font = .system(size: codeSize, design: .monospaced)
            a[run.range].backgroundColor = Color(.tertiarySystemFill)
        }
        return a
    }
}
