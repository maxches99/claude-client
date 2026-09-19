import SwiftUI
import ClaudeRemoteCore

// MARK: - Blocks

/// The user's prompt: a soft neutral card spanning the column, like Claude Code's desktop transcript.
struct UserMessageView: View {
    let text: String
    let images: [InlineImage]
    let keyPrefix: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !images.isEmpty { InlineImagesView(images: images, keyPrefix: keyPrefix) }
            if !text.isEmpty {
                Text(text)
                    .font(CDS.prose)
                    .foregroundStyle(CDS.textPrimary)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CDS.fillNeutral, in: RoundedRectangle(cornerRadius: CDS.radius + 2))
    }
}

/// Assistant prose: plain Markdown on the page background, no bubble.
struct AssistantMessageView: View {
    let text: String
    let streaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MarkdownText(text: text)
            if streaming { StreamingIndicator() }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Thinking + tool steps of one stretch of work. Live: rows stream in as they happen.
/// Finished: folded under "Worked for 41s · 8 steps" until tapped.
struct ActivityGroupView: View {
    let group: ActivityGroup
    @Binding var expandedGroups: Set<String>
    @Binding var expandedSteps: Set<String>

    private var isExpanded: Bool { group.isLive || expandedGroups.contains(group.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !group.isLive {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if expandedGroups.contains(group.id) { expandedGroups.remove(group.id) } else { expandedGroups.insert(group.id) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 18)
                        Text(summary).font(CDS.bodyMedium).foregroundStyle(CDS.textSecondary)
                        Text(detail).font(CDS.body).foregroundStyle(CDS.textMuted)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(CDS.textMuted)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(group.steps) { step in
                        stepView(step)
                    }
                }
                .padding(.leading, group.isLive ? 0 : 6)
            }
        }
    }

    private var summary: String {
        if let d = group.duration, d >= 1 { return "Worked for \(Self.format(d))" }
        let n = group.steps.count
        return "\(n) step\(n == 1 ? "" : "s")"
    }

    private var detail: String {
        guard let d = group.duration, d >= 1 else { return "" }
        let tools = group.toolCount
        if tools == 0 { return group.hasThinking ? "· thought" : "" }
        return "· \(tools) tool call\(tools == 1 ? "" : "s")"
    }

    @ViewBuilder
    private func stepView(_ step: ActivityStep) -> some View {
        switch step {
        case .thinking(let id, let text, let streaming, let duration):
            ThinkingStepRow(text: text, streaming: streaming, duration: duration, expanded: binding(for: id))
        case .tool(let tool):
            ToolStepRow(step: tool, expanded: binding(for: tool.id))
        case .orphanResult(let id, let text, let isError, let images):
            ToolResultView(text: text, isError: isError, images: images, keyPrefix: id)
                .padding(.leading, 26).padding(.vertical, 4)
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedSteps.contains(id) },
            set: { on in if on { expandedSteps.insert(id) } else { expandedSteps.remove(id) } }
        )
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

/// Bottom-of-transcript status while the assistant works ("Thinking…", "Running Bash…").
struct WorkingStatusRow: View {
    let status: String

    var body: some View {
        HStack(spacing: 8) {
            SpinningGlyph()
            ShimmerText(text: status)
        }
        .padding(.horizontal, 4)
    }
}

struct SpinningGlyph: View {
    @State private var spinning = false

    var body: some View {
        Image(systemName: "asterisk")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(CDS.brand)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear { withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { spinning = true } }
    }
}

struct StreamingIndicator: View {
    @State private var phase = 0.0
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle().fill(CDS.textMuted).frame(width: 5, height: 5)
                    .opacity(0.3 + 0.7 * abs(sin(phase + Double(i) * 0.9)))
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = .pi * 2 }
        }
    }
}

// MARK: - Steps

struct ThinkingStepRow: View {
    let text: String
    let streaming: Bool
    let duration: TimeInterval?
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CDS.textMuted)
                        .frame(width: 18)
                    if streaming {
                        ShimmerText(text: "Thinking…")
                    } else {
                        Text(label).font(CDS.bodyMedium).foregroundStyle(CDS.textSecondary)
                    }
                    Spacer(minLength: 0)
                    if !text.isEmpty { Chevron(expanded: expanded) }
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(text.isEmpty)
            if expanded, !text.isEmpty {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(CDS.textSecondary)
                    .textSelection(.enabled)
                    .padding(.leading, 26).padding(.bottom, 8)
            }
        }
    }

    private var label: String {
        if let duration, duration >= 1 { return "Thought for \(ActivityGroupView.format(duration))" }
        return "Thought"
    }
}

struct Chevron: View {
    let expanded: Bool
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(CDS.textMuted)
            .rotationEffect(.degrees(expanded ? 90 : 0))
    }
}

/// One tool call: `icon · Verb · argument ›`, with the input and result folded underneath.
struct ToolStepRow: View {
    let step: ToolStep
    @Binding var expanded: Bool

    private var presentation: ToolPresentation { ToolPresentation(name: step.name, input: step.input, partialInput: step.partialInput) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: ToolIcon.symbol(for: step.name))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(step.isError ? CDS.danger : CDS.textMuted)
                        .frame(width: 18)
                    Text(presentation.verb)
                        .font(CDS.bodyMedium)
                        .foregroundStyle(step.isError ? CDS.danger : CDS.textSecondary)
                        .layoutPriority(1)
                    if !presentation.argument.isEmpty {
                        Text(presentation.argument)
                            .font(presentation.monospaced ? CDS.code : CDS.body)
                            .foregroundStyle(CDS.textPrimary)
                            .lineLimit(1)
                            .truncationMode(presentation.truncateMiddle ? .middle : .tail)
                    }
                    Spacer(minLength: 4)
                    if step.running {
                        ProgressView().controlSize(.mini).tint(CDS.textMuted)
                    } else {
                        Chevron(expanded: expanded)
                    }
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Screenshots and other images a tool returned are the point — show them without expanding.
            if !step.resultImages.isEmpty {
                InlineImagesView(images: step.resultImages, keyPrefix: "result:\(step.toolUseId)")
                    .padding(.leading, 26).padding(.bottom, 8)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ToolInputDetail(name: step.name, input: step.input, partialInput: step.partialInput)
                    if let result = step.resultText, !result.isEmpty {
                        ToolResultView(text: result, isError: step.isError, keyPrefix: "result:\(step.toolUseId)")
                    } else if step.running {
                        Text("Running…").font(CDS.codeSmall).foregroundStyle(CDS.textMuted)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CDS.surface1, in: RoundedRectangle(cornerRadius: CDS.radius))
                .overlay(RoundedRectangle(cornerRadius: CDS.radius).strokeBorder(CDS.border))
                .padding(.leading, 26).padding(.bottom, 8)
            }

            // Files delivered to the user are worth seeing without expanding.
            if step.name == "SendUserFile", let files = step.input["files"]?.array?.compactMap(\.string), !files.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(files, id: \.self) { path in RemoteImageView(path: path) }
                }
                .padding(.leading, 26).padding(.bottom, 8)
            }
        }
    }
}

/// How a tool call reads in its row: `Read  ChatView.swift`, `Bash  swift build`, `Grep  pattern in dir`.
struct ToolPresentation {
    let verb: String
    let argument: String
    let monospaced: Bool
    let truncateMiddle: Bool

    init(name: String, input: JSONValue, partialInput: String) {
        func file(_ key: String) -> String { ((input[key]?.string ?? "") as NSString).lastPathComponent }
        switch name {
        case "Bash":
            verb = "Bash"
            let command = input["command"]?.string ?? ""
            argument = command.isEmpty ? String(partialInput.prefix(120)) : ToolPresentation.firstLine(command)
            monospaced = true; truncateMiddle = false
        case "Read": verb = "Read"; argument = file("file_path"); monospaced = true; truncateMiddle = true
        case "Write": verb = "Write"; argument = file("file_path"); monospaced = true; truncateMiddle = true
        case "Edit", "MultiEdit": verb = "Edit"; argument = file("file_path"); monospaced = true; truncateMiddle = true
        case "NotebookEdit": verb = "Edit"; argument = file("notebook_path"); monospaced = true; truncateMiddle = true
        case "Glob", "Grep":
            verb = name == "Glob" ? "Search files" : "Grep"
            let pattern = input["pattern"]?.string ?? ""
            if let path = input["path"]?.string, !path.isEmpty {
                argument = "\(pattern) in \((path as NSString).lastPathComponent)"
            } else {
                argument = pattern
            }
            monospaced = true; truncateMiddle = false
        case "WebFetch":
            verb = "Fetch"
            let url = input["url"]?.string ?? ""
            argument = url.replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
            monospaced = false; truncateMiddle = true
        case "WebSearch": verb = "Search"; argument = input["query"]?.string ?? ""; monospaced = false; truncateMiddle = false
        case "Task", "Agent":
            verb = "Agent"
            argument = input["description"]?.string ?? String((input["prompt"]?.string ?? "").prefix(80))
            monospaced = false; truncateMiddle = false
        case "Skill": verb = "Skill"; argument = input["skill"]?.string ?? ""; monospaced = true; truncateMiddle = false
        case "TodoWrite":
            verb = "Update todos"
            let n = input["todos"]?.array?.count ?? 0
            argument = n > 0 ? "\(n) item\(n == 1 ? "" : "s")" : ""
            monospaced = false; truncateMiddle = false
        case "AskUserQuestion":
            verb = "Question"
            argument = input["questions"]?.array?.first?["question"]?.string ?? ""
            monospaced = false; truncateMiddle = false
        case "SendUserFile":
            verb = "Sent file"
            let files = input["files"]?.array?.compactMap(\.string) ?? []
            argument = files.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            monospaced = true; truncateMiddle = true
        default:
            // `mcp__Server__tool` → verb "tool"; the server shows in the expanded panel.
            verb = ToolPresentation.mcpParts(name)?.tool ?? name
            argument = ToolSummary.line(name: name, input: input)
            monospaced = false; truncateMiddle = false
        }
    }

    /// `mcp__Claude_Code_iOS_Simulator__control` → ("Claude Code iOS Simulator", "control").
    static func mcpParts(_ name: String) -> (server: String, tool: String)? {
        guard name.hasPrefix("mcp__") else { return nil }
        let parts = name.dropFirst(5).components(separatedBy: "__")
        guard parts.count >= 2 else { return nil }
        let server = parts[0].replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return (server, parts[1...].joined(separator: "__"))
    }

    private static func firstLine(_ s: String) -> String {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: true)
        guard let first = lines.first else { return "" }
        let text = first.trimmingCharacters(in: .whitespaces)
        return lines.count > 1 ? text + " …" : text
    }
}

// MARK: - Details

/// Full tool input, formatted per tool where it matters.
struct ToolInputDetail: View {
    let name: String
    let input: JSONValue
    var partialInput: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch name {
            case "Bash":
                mono(input["command"]?.string ?? partialInput)
                if let d = input["description"]?.string { Text(d).font(CDS.caption).foregroundStyle(CDS.textMuted) }
            case "Edit", "MultiEdit":
                path(input["file_path"]?.string)
                if let old = input["old_string"]?.string { diff(old, removed: true) }
                if let new = input["new_string"]?.string { diff(new, removed: false) }
            case "Write":
                path(input["file_path"]?.string)
                mono(String((input["content"]?.string ?? "").prefix(4000)))
            case "Read", "NotebookEdit":
                path(input["file_path"]?.string ?? input["notebook_path"]?.string)
                if input["offset"] != nil || input["limit"] != nil { mono(input.prettyPrinted()) }
            default:
                if let mcp = ToolPresentation.mcpParts(name) {
                    Text(mcp.server).font(CDS.caption).foregroundStyle(CDS.textMuted)
                }
                if input.object?.isEmpty == false {
                    mono(input.prettyPrinted())
                } else if !partialInput.isEmpty {
                    mono(partialInput)
                }
            }
        }
    }

    @ViewBuilder
    private func path(_ p: String?) -> some View {
        if let p, !p.isEmpty {
            Text(ToolSummary.shortPath(p)).font(CDS.codeSmall).foregroundStyle(CDS.textMuted).lineLimit(1).truncationMode(.middle)
        }
    }

    private func diff(_ text: String, removed: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 1).fill(removed ? CDS.gitRemoved : CDS.gitAdded).frame(width: 2)
            Text(text.isEmpty ? "(empty)" : text)
                .font(CDS.codeSmall)
                .foregroundStyle(removed ? CDS.gitRemoved : CDS.gitAdded)
                .textSelection(.enabled)
        }
        .padding(.leading, 2)
    }

    private func mono(_ text: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text).font(CDS.codeSmall).foregroundStyle(CDS.textSecondary).textSelection(.enabled)
        }
    }
}

/// A tool result: monospaced, muted (red on error), trimmed with "Show more".
struct ToolResultView: View {
    let text: String
    let isError: Bool
    var images: [InlineImage] = []
    var keyPrefix: String = ""
    @State private var expanded = false

    private static let previewLines = 6
    private var lines: [String] { text.components(separatedBy: "\n") }

    var body: some View {
        let truncated = lines.count > Self.previewLines || text.count > 600
        VStack(alignment: .leading, spacing: 6) {
            if !images.isEmpty { InlineImagesView(images: images, keyPrefix: keyPrefix) }
            if !text.isEmpty {
                Text(expanded ? String(text.prefix(20_000)) : String(lines.prefix(Self.previewLines).joined(separator: "\n").prefix(600)))
                    .font(CDS.codeSmall)
                    .foregroundStyle(isError ? CDS.danger : CDS.textMuted)
                    .textSelection(.enabled)
            }
            if truncated {
                Button(expanded ? "Show less" : "Show more (\(lines.count) lines)") { withAnimation { expanded.toggle() } }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(CDS.textSecondary)
                    .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Images

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
                        .clipShape(RoundedRectangle(cornerRadius: CDS.radius))
                        .overlay(RoundedRectangle(cornerRadius: CDS.radius).strokeBorder(CDS.border))
                } else if model.imageCache.failures.contains(key) {
                    Label("Image could not be decoded", systemImage: "photo").font(CDS.caption).foregroundStyle(CDS.textMuted)
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
            Text(ToolSummary.shortPath(path)).font(CDS.codeSmall).foregroundStyle(CDS.textMuted).lineLimit(1).truncationMode(.middle)
            if !RemoteImageView.imageExtensions.contains(ext) {
                Label("Not an image — open it on the Mac", systemImage: "doc").font(CDS.caption).foregroundStyle(CDS.textMuted)
            } else if let ui = model.imageCache.images[key] {
                Image(uiImage: ui)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: CDS.radius))
                    .overlay(RoundedRectangle(cornerRadius: CDS.radius).strokeBorder(CDS.border))
            } else if model.imageCache.failures.contains(key) {
                Label("Could not load from the Mac", systemImage: "exclamationmark.triangle").font(CDS.caption).foregroundStyle(CDS.textMuted)
            } else {
                ProgressView().frame(height: 80)
                    .onAppear { model.requestFile(path) }
            }
        }
    }
}

enum ToolIcon {
    static func symbol(for name: String) -> String {
        switch name {
        case "Bash": return "terminal"
        case "Read": return "doc.text"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "pencil.line"
        case "Grep", "Glob": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        case "Task", "Agent": return "person.2"
        case "TodoWrite": return "checklist"
        case "Skill": return "sparkles"
        case "AskUserQuestion": return "questionmark.bubble"
        case "SendUserFile": return "paperclip"
        default: return name.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench"
        }
    }
}
