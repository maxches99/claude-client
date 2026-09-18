import SwiftUI
import ClaudeRemoteCore

struct TranscriptRow: View {
    let item: TranscriptItem

    var body: some View {
        switch item.kind {
        case .user(let text, let images):
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 6) {
                    if !images.isEmpty { InlineImagesView(images: images, keyPrefix: item.id) }
                    if !text.isEmpty {
                        Text(text)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Color.accentColor.opacity(0.9), in: RoundedRectangle(cornerRadius: 18))
                            .foregroundStyle(.white)
                    }
                }
            }
        case .assistantText(let text, let streaming):
            VStack(alignment: .leading, spacing: 4) {
                MarkdownText(text: text)
                if streaming { StreamingIndicator() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .thinking(let text, let streaming):
            ThinkingRow(text: text, streaming: streaming)
        case .toolUse(let id, let name, let input, let partial, let streaming):
            ToolUseCard(toolId: id, name: name, input: input, partialInput: partial, streaming: streaming)
        case .toolResult(_, let text, let isError, let images):
            ToolResultCard(text: text, isError: isError, images: images, keyPrefix: item.id)
        case .note(let text):
            Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        case .turnEnd(let summary, let isError):
            Text(summary.isEmpty ? (isError ? "Turn failed" : "Done") : summary)
                .font(.caption2)
                .foregroundStyle(isError ? Color.red : Color.secondary.opacity(0.7))
                .frame(maxWidth: .infinity)
        }
    }
}

struct StreamingIndicator: View {
    @State private var phase = 0.0
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle().fill(.secondary).frame(width: 5, height: 5)
                    .opacity(0.3 + 0.7 * abs(sin(phase + Double(i) * 0.9)))
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = .pi * 2 }
        }
    }
}

struct ThinkingRow: View {
    let text: String
    let streaming: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain").font(.caption)
                    Text(streaming ? "Thinking…" : "Thought").font(.caption)
                    if streaming { ProgressView().controlSize(.mini) }
                    if !text.isEmpty { Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2) }
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if expanded, !text.isEmpty {
                Text(text).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}

struct ToolUseCard: View {
    let toolId: String
    let name: String
    let input: JSONValue
    let partialInput: String
    let streaming: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation { expanded.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: ToolIcon.symbol(for: name)).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ToolSummary.displayName(name)).font(.subheadline.weight(.semibold))
                        let summary = ToolSummary.line(name: name, input: input)
                        if !summary.isEmpty {
                            Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(expanded ? nil : 2)
                                .font(.system(.caption, design: name == "Bash" ? .monospaced : .default))
                        } else if streaming, !partialInput.isEmpty {
                            Text(partialInput).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer()
                    if streaming { ProgressView().controlSize(.small) }
                }
            }
            .buttonStyle(.plain)
            if expanded {
                ToolInputDetail(name: name, input: input)
            }
            if name == "SendUserFile", let files = input["files"]?.array?.compactMap(\.string), !files.isEmpty {
                ForEach(files, id: \.self) { path in
                    RemoteImageView(path: path)
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Base64 images embedded in a turn (pasted images, simulator screenshots).
struct InlineImagesView: View {
    @Environment(AppModel.self) private var model
    let images: [InlineImage]
    let keyPrefix: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                let key = "\(keyPrefix)#img\(index)"
                if let ui = model.imageCache.image(key: key, base64: image.base64) {
                    Image(uiImage: ui)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else if model.imageCache.failures.contains(key) {
                    Label("Image could not be decoded", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView().frame(height: 80)
                }
            }
        }
    }
}

/// An image file on the Mac, fetched through the daemon (e.g. SendUserFile deliveries).
struct RemoteImageView: View {
    @Environment(AppModel.self) private var model
    let path: String

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "svg"]

    var body: some View {
        let key = "file:\(path)"
        let ext = (path as NSString).pathExtension.lowercased()
        VStack(alignment: .leading, spacing: 4) {
            Text(ToolSummary.shortPath(path)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if !RemoteImageView.imageExtensions.contains(ext) {
                Label("Not an image — open it on the Mac", systemImage: "doc").font(.caption).foregroundStyle(.secondary)
            } else if let ui = model.imageCache.images[key] {
                Image(uiImage: ui)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if model.imageCache.failures.contains(key) {
                Label("Could not load from the Mac", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().frame(height: 80)
                    .onAppear { model.requestFile(path) }
            }
        }
    }
}

/// Full tool input, formatted per tool where it matters.
struct ToolInputDetail: View {
    let name: String
    let input: JSONValue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch name {
            case "Bash":
                mono(input["command"]?.string ?? "")
                if let d = input["description"]?.string { Text(d).font(.caption).foregroundStyle(.secondary) }
            case "Edit":
                Text(ToolSummary.shortPath(input["file_path"]?.string ?? "")).font(.caption).foregroundStyle(.secondary)
                if let old = input["old_string"]?.string { labeled("− old", old, tint: .red) }
                if let new = input["new_string"]?.string { labeled("+ new", new, tint: .green) }
            case "Write":
                Text(ToolSummary.shortPath(input["file_path"]?.string ?? "")).font(.caption).foregroundStyle(.secondary)
                mono(String((input["content"]?.string ?? "").prefix(4000)))
            default:
                mono(input.prettyPrinted())
            }
        }
    }

    private func labeled(_ label: String, _ text: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(tint)
            mono(text)
        }
    }

    private func mono(_ text: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }
}

struct ToolResultCard: View {
    let text: String
    let isError: Bool
    var images: [InlineImage] = []
    var keyPrefix: String = ""
    @State private var expanded = false

    private var lines: [String] { text.components(separatedBy: "\n") }

    var body: some View {
        let preview = lines.prefix(3).joined(separator: "\n")
        let truncated = lines.count > 3 || text.count > 400
        VStack(alignment: .leading, spacing: 4) {
            if !images.isEmpty { InlineImagesView(images: images, keyPrefix: keyPrefix) }
            if !text.isEmpty {
                Text(expanded ? String(text.prefix(20_000)) : String(preview.prefix(400)))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(isError ? .red : .secondary)
                    .textSelection(.enabled)
            }
            if truncated {
                Button(expanded ? "Show less" : "Show more (\(lines.count) lines)") { withAnimation { expanded.toggle() } }
                    .font(.caption2)
            }
        }
        .padding(.leading, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum ToolIcon {
    static func symbol(for name: String) -> String {
        switch name {
        case "Bash": return "terminal"
        case "Read": return "doc.text"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "pencil"
        case "Grep", "Glob": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        case "Task", "Agent": return "person.2"
        case "TodoWrite": return "checklist"
        case "Skill": return "sparkles"
        case "AskUserQuestion": return "questionmark.bubble"
        default: return name.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench"
        }
    }
}
