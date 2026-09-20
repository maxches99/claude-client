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

/// Thinking + tool steps of one stretch of work, folded under a single row the way Claude Code's
/// desktop transcript does — "Ran 5 commands ›" once finished, "Running a command ›" while live.
/// Tapping the row reveals the individual steps.
struct ActivityGroupView: View {
    let group: ActivityGroup
    @Binding var expandedGroups: Set<String>
    @Binding var expandedSteps: Set<String>

    private var isExpanded: Bool { expandedGroups.contains(group.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded { expandedGroups.remove(group.id) } else { expandedGroups.insert(group.id) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(group.title)
                        .font(CDS.body)
                        .foregroundStyle(CDS.textMuted)
                        .lineLimit(1)
                    Chevron(expanded: isExpanded)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4).padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(group.steps) { step in
                        stepView(step)
                    }
                }
                .padding(.leading, 6)
            } else if !collapsedImages.isEmpty {
                // Screenshots a tool returned are the point of the step — keep them visible when folded.
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(collapsedImages, id: \.key) { InlineImagesView(images: $0.images, keyPrefix: $0.key) }
                }
                .padding(.horizontal, 4).padding(.top, 4)
            }
        }
    }

    private var collapsedImages: [(key: String, images: [InlineImage])] {
        group.steps.compactMap { step in
            switch step {
            case .tool(let t) where !t.resultImages.isEmpty: return ("result:\(t.toolUseId)", t.resultImages)
            case .orphanResult(let id, _, _, let images) where !images.isEmpty: return (id, images)
            default: return nil
            }
        }
    }

    @ViewBuilder
    private func stepView(_ step: ActivityStep) -> some View {
        switch step {
        case .thinking(let id, let text, let streaming, let duration):
            ThinkingStepRow(text: text, streaming: streaming, duration: duration, expanded: binding(for: id))
        case .tool(let tool):
            ToolStepRow(step: tool, live: group.isLive, expanded: binding(for: tool.id))
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

    static func format(_ seconds: TimeInterval) -> String { ActivitySummary.format(seconds) }
}

/// Bottom-of-transcript status while the assistant works: `✳ 2m 58s · 1.9k tokens · Running tools…`,
/// the clock ticking from the prompt that started the turn.
struct WorkingStatusRow: View {
    var startedAt: Date?
    var outputTokens: Int = 0
    let phase: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                SpinningGlyph()
                HStack(spacing: 0) {
                    if let prefix = prefix(at: context.date) {
                        Text(prefix + " · ").font(CDS.bodyMedium).foregroundStyle(CDS.textMuted)
                    }
                    ShimmerText(text: phase)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func prefix(at now: Date) -> String? {
        var parts: [String] = []
        if let startedAt, now > startedAt { parts.append(ActivitySummary.format(now.timeIntervalSince(startedAt))) }
        if outputTokens > 0 {
            parts.append(outputTokens >= 1000 ? String(format: "%.1fk tokens", Double(outputTokens) / 1000) : "\(outputTokens) tokens")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
    var live: Bool = false
    @Binding var expanded: Bool

    private var presentation: ToolPresentation { ToolPresentation(name: step.name, input: step.input, partialInput: step.partialInput) }
    /// Executing right now: still streaming its call, or awaiting a result inside a live group.
    private var isActive: Bool { step.running || (live && step.awaitingResult) }

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
                    if isActive {
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
                    } else if isActive {
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
                    ForEach(files, id: \.self) { path in RemoteFileView(path: path) }
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
        case "Delete": verb = "Delete"; argument = file("file_path"); monospaced = true; truncateMiddle = true
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
            case "Edit", "MultiEdit", "Delete":
                path(input["file_path"]?.string)
                if let old = input["old_string"]?.string { diff(old, removed: true) }
                if let new = input["new_string"]?.string { diff(new, removed: false) }
                if let unified = input["diff"]?.string { unifiedDiff(unified) }   // Codex file changes
            case "Write":
                path(input["file_path"]?.string)
                if let unified = input["diff"]?.string { unifiedDiff(unified) }
                else { mono(String((input["content"]?.string ?? "").prefix(4000))) }
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

    /// A unified diff, coloured per line (`+` added, `-` removed, hunk headers muted).
    private func unifiedDiff(_ text: String) -> some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(400)
        return ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    let s = String(line)
                    let color: Color = s.hasPrefix("+") ? CDS.gitAdded : (s.hasPrefix("-") ? CDS.gitRemoved : (s.hasPrefix("@@") ? CDS.textMuted : CDS.textSecondary))
                    Text(s.isEmpty ? " " : s).font(CDS.codeSmall).foregroundStyle(color)
                }
            }
            .textSelection(.enabled)
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

/// A file the agent handed over (SendUserFile), fetched through the daemon: images show inline, anything
/// else is a chip that opens the viewer (Markdown / text / PDF) and can be shared or saved to Files.
struct RemoteFileView: View {
    @Environment(AppModel.self) private var model
    let path: String
    @State private var showViewer = false

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "svg"]

    private var isImage: Bool { RemoteFileView.imageExtensions.contains((path as NSString).pathExtension.lowercased()) }

    var body: some View {
        let key = "file:\(path)"
        VStack(alignment: .leading, spacing: 4) {
            Text(ToolSummary.shortPath(path)).font(CDS.codeSmall).foregroundStyle(CDS.textMuted).lineLimit(1).truncationMode(.middle)
            if !isImage {
                fileChip
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
        .sheet(isPresented: $showViewer) { RemoteFileViewer(path: path) }
    }

    /// Name + kind, with the size once the bytes have arrived. Tapping fetches (if needed) and opens.
    private var fileChip: some View {
        let file = model.remoteFiles[path]
        let error = model.remoteFileErrors[path]
        return Button {
            if file == nil { model.requestFile(path, force: error != nil) }
            showViewer = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: RemoteFileViewer.symbol(for: path))
                    .font(.system(size: 18)).foregroundStyle(CDS.textSecondary).frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text((path as NSString).lastPathComponent).font(CDS.bodyMedium).foregroundStyle(CDS.textPrimary).lineLimit(1)
                    Text(file.map { "\(RemoteFileViewer.kindLabel(for: $0.mediaType)) · \(Media.humanSize($0.data.count))" }
                         ?? (error ?? "Tap to open"))
                        .font(CDS.caption).foregroundStyle(error != nil && file == nil ? CDS.danger : CDS.textMuted).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(CDS.textMuted)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: 320, alignment: .leading)
            .background(CDS.fillControl, in: RoundedRectangle(cornerRadius: CDS.radius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.isConnected && file == nil)
    }
}

enum ToolIcon {
    static func symbol(for name: String) -> String {
        switch name {
        case "Bash": return "terminal"
        case "Read": return "doc.text"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "pencil.line"
        case "Delete": return "trash"
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
