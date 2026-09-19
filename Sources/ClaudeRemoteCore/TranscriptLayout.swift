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

    /// What the assistant is doing right now, for the live status line.
    public var liveStatus: String {
        for step in steps.reversed() {
            switch step {
            case .tool(let t) where t.running: return "Running \(ToolSummary.displayName(t.name))…"
            case .thinking(_, _, true, _): return "Thinking…"
            default: continue
            }
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
