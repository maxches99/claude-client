import Foundation

/// A tool call together with its result, as one step of the assistant's work.
public struct ToolStep: Equatable, Sendable {
    public var id: String
    public var toolUseId: String
    public var name: String
    public var input: JSONValue
    public var partialInput: String
    public var running: Bool
    public var resultText: String?
    public var isError: Bool
    public var resultImages: [InlineImage]
    public var startedAt: Date?

    /// The call was emitted but no result has arrived yet — i.e. it is executing right now.
    public var awaitingResult: Bool { resultText == nil }
}

/// One row inside an activity group.
public enum ActivityStep: Identifiable, Equatable, Sendable {
    case thinking(id: String, text: String, streaming: Bool, duration: TimeInterval?)
    case tool(ToolStep)
    /// A tool result whose call is not in the transcript (e.g. history cut by compaction).
    case orphanResult(id: String, text: String, isError: Bool, images: [InlineImage])

    public var id: String {
        switch self {
        case .thinking(let id, _, _, _): return id
        case .tool(let step): return step.id
        case .orphanResult(let id, _, _, _): return id
        }
    }
}

/// Consecutive thinking / tool steps between two pieces of prose — the "Worked for 41s" block.
public struct ActivityGroup: Identifiable, Equatable, Sendable {
    public var id: String
    public var steps: [ActivityStep]
    /// Still being appended to: the session is running and nothing has closed the group yet.
    public var isLive: Bool
    public var duration: TimeInterval?

    public var toolCount: Int { steps.filter { if case .tool = $0 { return true } else { return false } }.count }
    public var hasThinking: Bool { steps.contains { if case .thinking = $0 { return true } else { return false } } }

    /// The tool executing right now (call sent, result not back). Nil when nothing is running.
    public var runningTool: ToolStep? {
        for step in steps.reversed() {
            if case .tool(let t) = step, t.awaitingResult { return t }
        }
        return nil
    }

    /// How many tools are executing at once (Claude can fan out parallel calls).
    public var runningToolCount: Int {
        steps.reduce(0) { count, step in
            if case .tool(let t) = step, t.awaitingResult { return count + 1 }
            return count
        }
    }

    /// The collapsed row's label, worded like Claude Code's desktop transcript: a finished group reads
    /// "Ran 5 commands" / "Recalled a memory, read 3 files"; a live one names the current step,
    /// "Running a command" / "Thinking…".
    public var title: String {
        if isLive {
            if let step = steps.last, case .thinking(_, _, true, _) = step { return "Thinking…" }
            let running = steps.compactMap { step -> ToolStep? in
                if case .tool(let t) = step, t.awaitingResult { return t }
                return nil
            }
            if !running.isEmpty { return ActivitySummary.progress(running) }
        }
        let tools = steps.compactMap { step -> ToolStep? in
            if case .tool(let t) = step { return t }
            return nil
        }
        if tools.isEmpty, hasThinking {
            if let d = duration, d >= 1 { return "Thought for \(ActivitySummary.format(d))" }
            return "Thought"
        }
        return ActivitySummary.finished(tools)
    }

    /// The trailing status line's phase while the group is live: "Running tools…" / "Thinking…" / "Working…".
    public var phase: String {
        if runningTool != nil { return "Running tools…" }
        if let step = steps.last, case .thinking(_, _, true, _) = step { return "Thinking…" }
        return "Working…"
    }

    /// What the assistant is doing right now, for the live status line — names the running command,
    /// e.g. "Bash: swift build" or "Read: ~/app/Main.swift".
    public var liveStatus: String {
        if let t = runningTool {
            let name = ToolSummary.displayName(t.name)
            let raw = ToolSummary.line(name: t.name, input: t.input)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            let extra = runningToolCount > 1 ? " (+\(runningToolCount - 1) more)" : ""
            if raw.isEmpty { return "Running \(name)…\(extra)" }
            let detail = raw.count > 100 ? String(raw.prefix(100)) + "…" : raw
            return "\(name): \(detail)\(extra)"
        }
        for step in steps.reversed() {
            if case .thinking(_, _, true, _) = step { return "Thinking…" }
        }
        return "Working…"
    }
}

/// What the chat renders: transcript rows folded into the blocks Claude Code shows.
public enum TranscriptBlock: Identifiable, Equatable, Sendable {
    case user(TranscriptItem)
    case assistant(TranscriptItem)
    case activity(ActivityGroup)
    case note(TranscriptItem)
    case turnError(TranscriptItem)

    public var id: String {
        switch self {
        case .user(let item), .assistant(let item), .note(let item), .turnError(let item): return item.id
        case .activity(let group): return group.id
        }
    }
}

public enum TranscriptLayout {
    /// Folds `items` into blocks. `sessionRunning` decides whether a trailing activity group is
    /// still live (steps shown) or finished (collapsed under a summary row).
    public static func blocks(for items: [TranscriptItem], sessionRunning: Bool) -> [TranscriptBlock] {
        var blocks: [TranscriptBlock] = []
        var open: ActivityGroup?
        var openStart: Date?
        var openLast: Date?
        /// tool_use id → (block index, step index) for pairing results with calls, across groups.
        var toolIndex: [String: (block: Int?, step: Int)] = [:]

        func close(at end: Date?) {
            guard var group = open else { return }
            group.isLive = false
            if let start = openStart, let stop = end ?? openLast, stop > start { group.duration = stop.timeIntervalSince(start) }
            blocks.append(.activity(group))
            // Steps of the closed group become addressable by block index for late results.
            for key in toolIndex.keys where toolIndex[key]?.block == nil { toolIndex[key]?.block = blocks.count - 1 }
            open = nil; openStart = nil; openLast = nil
        }

        func track(_ item: TranscriptItem) {
            if let ts = item.timestamp {
                if openStart == nil { openStart = ts }
                openLast = ts
            }
        }

        for (i, item) in items.enumerated() {
            switch item.kind {
            case .user:
                close(at: item.timestamp)
                blocks.append(.user(item))
            case .assistantText:
                close(at: item.timestamp)
                blocks.append(.assistant(item))
            case .note:
                close(at: item.timestamp)
                blocks.append(.note(item))
            case .turnEnd(_, let isError):
                close(at: item.timestamp)
                if isError { blocks.append(.turnError(item)) }
            case .thinking(let text, let streaming):
                if open == nil { open = ActivityGroup(id: "activity:\(item.id)", steps: [], isLive: true, duration: nil) }
                track(item)
                // A thinking block lasts until the next row starts (same-message rows share a timestamp → nil).
                var duration: TimeInterval?
                if let start = item.timestamp, let next = items[(i + 1)...].first(where: { $0.timestamp != nil })?.timestamp, next > start {
                    duration = next.timeIntervalSince(start)
                }
                open?.steps.append(.thinking(id: item.id, text: text, streaming: streaming, duration: duration))
            case .toolUse(let toolUseId, let name, let input, let partial, let streaming):
                if open == nil { open = ActivityGroup(id: "activity:\(item.id)", steps: [], isLive: true, duration: nil) }
                track(item)
                let step = ToolStep(id: item.id, toolUseId: toolUseId, name: name, input: input, partialInput: partial, running: streaming,
                                    resultText: nil, isError: false, resultImages: [], startedAt: item.timestamp)
                open?.steps.append(.tool(step))
                toolIndex[toolUseId] = (nil, (open?.steps.count ?? 1) - 1)
            case .toolResult(let toolUseId, let text, let isError, let images):
                if open != nil { track(item) }
                if let loc = toolIndex[toolUseId] {
                    if let b = loc.block, case .activity(var group) = blocks[b], case .tool(var step) = group.steps[loc.step] {
                        step.resultText = text; step.isError = isError; step.resultImages = images; step.running = false
                        group.steps[loc.step] = .tool(step)
                        blocks[b] = .activity(group)
                        continue
                    }
                    if loc.block == nil, var group = open, case .tool(var step) = group.steps[loc.step] {
                        step.resultText = text; step.isError = isError; step.resultImages = images; step.running = false
                        group.steps[loc.step] = .tool(step)
                        open = group
                        continue
                    }
                }
                if open == nil { open = ActivityGroup(id: "activity:\(item.id)", steps: [], isLive: true, duration: nil); track(item) }
                open?.steps.append(.orphanResult(id: item.id, text: text, isError: isError, images: images))
            }
        }
        if var group = open {
            group.isLive = sessionRunning
            if !sessionRunning, let start = openStart, let stop = openLast, stop > start { group.duration = stop.timeIntervalSince(start) }
            blocks.append(.activity(group))
        }
        return blocks
    }
}

/// Words a run of tool calls the way Claude Code's desktop transcript does.
public enum ActivitySummary {
    /// The kinds of work a group's tools fold into, in the order they read best.
    enum Kind: Int, CaseIterable {
        case memory, command, read, edit, search, web, agent, skill, todo, other
    }

    static func kind(of tool: ToolStep) -> Kind {
        switch tool.name {
        case "Bash":
            // Memory is read with `cat …/memory/x.md` as often as with Read.
            let command = tool.input["command"]?.string ?? ""
            return isMemoryPath(command) && command.hasPrefix("cat ") ? .memory : .command
        case "Read": return isMemoryPath(tool.input["file_path"]?.string ?? "") ? .memory : .read
        case "Write", "Edit", "MultiEdit", "NotebookEdit", "Delete": return .edit
        case "Glob", "Grep": return .search
        case "WebFetch", "WebSearch": return .web
        case "Task", "Agent": return .agent
        case "Skill": return .skill
        case "TodoWrite": return .todo
        default: return .other
        }
    }

    private static func isMemoryPath(_ s: String) -> Bool { s.contains("/memory/") || s.hasSuffix("MEMORY.md") }

    /// "Ran 5 commands", "Recalled a memory, read 3 files, edited a file" — phrases in `Kind` order,
    /// not the order the calls happened. A lone Bash call with a description reads as that
    /// description ("Checked the build settings").
    public static func finished(_ tools: [ToolStep]) -> String {
        guard !tools.isEmpty else { return "Worked" }
        if tools.count == 1, tools[0].name == "Bash", let described = describedCommand(tools[0]) { return described }
        var counts: [Kind: Int] = [:]
        for tool in tools { counts[kind(of: tool), default: 0] += 1 }
        let phrases = counts.keys.sorted { $0.rawValue < $1.rawValue }.map { k -> String in
            let n = counts[k]!
            switch k {
            case .memory: return n == 1 ? "recalled a memory" : "recalled \(n) memories"
            case .command: return n == 1 ? "ran a command" : "ran \(n) commands"
            case .read: return n == 1 ? "read a file" : "read \(n) files"
            case .edit: return n == 1 ? "edited a file" : "edited \(n) files"
            case .search: return "searched the codebase"
            case .web: return "searched the web"
            case .agent: return n == 1 ? "ran an agent" : "ran \(n) agents"
            case .skill: return n == 1 ? "used a skill" : "used \(n) skills"
            case .todo: return "updated todos"
            case .other:
                if n == 1, let name = tools.first(where: { kind(of: $0) == .other }).map({ shortName($0.name) }) {
                    return "used \(name)"
                }
                return "used \(n) tools"
            }
        }
        return capitalized(phrases.joined(separator: ", "))
    }

    /// "Running a command", "Reading 2 files", "Editing a file" — the step(s) executing right now.
    public static func progress(_ running: [ToolStep]) -> String {
        guard let first = running.first else { return "Working…" }
        let n = running.count
        switch kind(of: first) {
        case .memory: return n == 1 ? "Recalling a memory" : "Recalling \(n) memories"
        case .command: return n == 1 ? "Running a command" : "Running \(n) commands"
        case .read: return n == 1 ? "Reading a file" : "Reading \(n) files"
        case .edit: return n == 1 ? "Editing a file" : "Editing \(n) files"
        case .search: return "Searching the codebase"
        case .web: return "Searching the web"
        case .agent: return n == 1 ? "Running an agent" : "Running \(n) agents"
        case .skill: return "Loading a skill"
        case .todo: return "Updating todos"
        case .other: return n == 1 ? "Running \(shortName(first.name))" : "Running \(n) tools"
        }
    }

    /// `mcp__Server__tool` → `tool`; the server is visible once the row is expanded.
    private static func shortName(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        let parts = name.dropFirst(5).components(separatedBy: "__")
        return parts.count >= 2 ? parts[1...].joined(separator: "__") : name
    }

    private static func describedCommand(_ tool: ToolStep) -> String? {
        guard var text = tool.input["description"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasSuffix(".") { text.removeLast() }
        return capitalized(text.count > 90 ? String(text.prefix(90)) + "…" : text)
    }

    private static func capitalized(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    public static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}
