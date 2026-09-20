import Foundation

/// A base64 image block from a user turn or a tool result (screenshots, pasted images).
public struct InlineImage: Codable, Equatable, Hashable, Sendable {
    public var mediaType: String
    public var base64: String

    public init(mediaType: String, base64: String) {
        self.mediaType = mediaType
        self.base64 = base64
    }

    static func parse(_ block: JSONValue) -> InlineImage? {
        guard block["type"]?.string == "image", let source = block["source"], source["type"]?.string == "base64",
              let data = source["data"]?.string else { return nil }
        return InlineImage(mediaType: source["media_type"]?.string ?? "image/png", base64: data)
    }
}

/// A file sent from the phone with a prompt (document, video, voice memo, or any non-image file).
/// Images travel as `InlineImage` for direct vision; everything else the host stages to disk and
/// references by path in the prompt, so the agent opens it with its own tools.
public struct Attachment: Codable, Equatable, Hashable, Sendable {
    public var filename: String
    public var mediaType: String   // MIME, e.g. application/pdf, video/quicktime, audio/m4a
    public var base64: String

    public init(filename: String, mediaType: String, base64: String) {
        self.filename = filename
        self.mediaType = mediaType
        self.base64 = base64
    }

    public var isImage: Bool { mediaType.hasPrefix("image/") }

    /// Approximate decoded size in bytes (base64 expands ~4:3), for display in the composer.
    public var approxBytes: Int { base64.count / 4 * 3 }
}

/// One row in the chat view.
public struct TranscriptItem: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case user(text: String, images: [InlineImage])
        case assistantText(text: String, streaming: Bool)
        case thinking(text: String, streaming: Bool)
        case toolUse(id: String, name: String, input: JSONValue, partialInput: String, streaming: Bool)
        case toolResult(toolUseId: String, text: String, isError: Bool, images: [InlineImage])
        case note(text: String)
        case turnEnd(summary: String, isError: Bool)
    }

    public var id: String
    public var kind: Kind
    public var timestamp: Date?

    public init(id: String, kind: Kind, timestamp: Date? = nil) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
    }
}

/// Reduces raw stream-json messages (live) and transcript entries (from disk) —
/// both have the same `type: user | assistant` shape — into rows for the UI.
public struct Transcript: Equatable, Sendable {
    public private(set) var items: [TranscriptItem] = []
    public private(set) var model: String?
    public private(set) var isStreaming = false
    /// Cumulative session cost and token usage, from the latest `result` message.
    public private(set) var totalCostUSD: Double = 0
    public private(set) var inputTokens: Int = 0
    public private(set) var outputTokens: Int = 0
    /// When the latest prompt was sent and how much the assistant has produced since — the
    /// "2m 58s · 1.9k tokens" of the status line while a turn runs.
    public private(set) var turnStartedAt: Date?
    public var turnOutputTokens: Int { turnOutputByMessage.values.reduce(0, +) }
    /// message id → output tokens, so a message re-applied from disk (one entry per block) counts once.
    private var turnOutputByMessage: [String: Int] = [:]

    /// message.id → number of full assistant blocks already applied (to pair with streamed blocks).
    private var appliedBlocks: [String: Int] = [:]
    private var streamingMessageId: String?
    /// content block index → item id, for the message currently streaming.
    private var streamingBlockItems: [Int: String] = [:]
    private var index: [String: Int] = [:]   // item id → position in `items`
    /// tool_use id → item id, so a later tool_result can flip `streaming` off.
    private var toolItemIds: [String: String] = [:]

    public init() {}

    public mutating func reset() { self = Transcript() }

    public mutating func apply(_ message: JSONValue) {
        guard let type = message["type"]?.string else { return }
        // Sub-agent traffic is nested under a parent tool use; keep the main thread only.
        if let parent = message["parent_tool_use_id"], !parent.isNull { return }
        if message["isSidechain"]?.bool == true { return }
        let timestamp = message["timestamp"]?.string.flatMap(Transcript.parseDate)

        switch type {
        case "user": applyUser(message, timestamp: timestamp)
        case "assistant": applyAssistant(message, timestamp: timestamp)
        case "stream_event": applyStreamEvent(message)
        case "result": applyResult(message, timestamp: timestamp)
        case "system": applySystem(message, timestamp: timestamp)
        default: break
        }
    }

    public mutating func apply(entries: [JSONValue]) {
        for entry in entries { apply(entry) }
    }

    // MARK: user

    private mutating func applyUser(_ message: JSONValue, timestamp: Date?) {
        if message["isMeta"]?.bool == true { return }
        guard let msg = message["message"] else { return }
        let baseId = message["uuid"]?.string ?? UUID().uuidString
        if let text = msg["content"]?.string {
            appendUserText(text, images: [], id: baseId, timestamp: timestamp)
            return
        }
        guard let blocks = msg["content"]?.array else { return }
        // Text and images of one turn are shown as a single bubble.
        var texts: [String] = []
        var images: [InlineImage] = []
        for (i, block) in blocks.enumerated() {
            switch block["type"]?.string {
            case "text":
                if let text = block["text"]?.string { texts.append(text) }
            case "image":
                if let image = InlineImage.parse(block) { images.append(image) }
            case "tool_result":
                let toolUseId = block["tool_use_id"]?.string ?? "\(baseId)#\(i)"
                let text = Transcript.flattenContent(block["content"])
                let isError = block["is_error"]?.bool ?? false
                let resultImages = block["content"]?.array?.compactMap(InlineImage.parse) ?? []
                upsert(TranscriptItem(id: "result:\(toolUseId)", kind: .toolResult(toolUseId: toolUseId, text: text, isError: isError, images: resultImages), timestamp: timestamp))
                finishToolUse(id: toolUseId)
            default:
                break
            }
        }
        if !texts.isEmpty || !images.isEmpty {
            appendUserText(texts.joined(separator: "\n"), images: images, id: baseId, timestamp: timestamp)
        }
    }

    private mutating func appendUserText(_ raw: String, images: [InlineImage], id: String, timestamp: Date?) {
        let text = Transcript.cleanUserText(raw)
        guard !text.isEmpty || !images.isEmpty else { return }
        upsert(TranscriptItem(id: "user:\(id)", kind: .user(text: text, images: images), timestamp: timestamp))
        turnStartedAt = timestamp ?? Date()
        turnOutputByMessage = [:]
    }

    // MARK: assistant

    private mutating func applyAssistant(_ message: JSONValue, timestamp: Date?) {
        guard let msg = message["message"], let blocks = msg["content"]?.array else { return }
        if let m = msg["model"]?.string, !m.hasPrefix("<") { model = m }
        let messageId = msg["id"]?.string ?? message["uuid"]?.string ?? UUID().uuidString
        if let out = msg["usage"]?["output_tokens"]?.int, out > 0 { turnOutputByMessage[messageId] = out }
        for block in blocks {
            let blockIndex = appliedBlocks[messageId, default: 0]
            appliedBlocks[messageId] = blockIndex + 1
            let itemId = "\(messageId)#\(blockIndex)"
            switch block["type"]?.string {
            case "text":
                let text = block["text"]?.string ?? ""
                if text.isEmpty { continue }
                upsert(TranscriptItem(id: itemId, kind: .assistantText(text: text, streaming: false), timestamp: timestamp))
            case "thinking":
                let text = block["thinking"]?.string ?? ""
                upsert(TranscriptItem(id: itemId, kind: .thinking(text: text, streaming: false), timestamp: timestamp))
            case "tool_use":
                let toolId = block["id"]?.string ?? itemId
                let name = block["name"]?.string ?? "tool"
                let input = block["input"] ?? .object([:])
                // A streamed placeholder (if any) shares `itemId`, so upsert replaces it in place.
                upsert(TranscriptItem(id: itemId, kind: .toolUse(id: toolId, name: name, input: input, partialInput: "", streaming: true), timestamp: timestamp))
                toolItemIds[toolId] = itemId
            default:
                continue
            }
        }
    }

    private mutating func finishToolUse(id toolId: String) {
        guard let itemId = toolItemIds[toolId], let pos = index[itemId],
              case .toolUse(let id, let name, let input, let partial, _) = items[pos].kind else { return }
        items[pos].kind = .toolUse(id: id, name: name, input: input, partialInput: partial, streaming: false)
    }

    // MARK: stream events (partial messages)

    private mutating func applyStreamEvent(_ message: JSONValue) {
        guard let event = message["event"], let kind = event["type"]?.string else { return }
        switch kind {
        case "message_start":
            streamingMessageId = event["message"]?["id"]?.string
            streamingBlockItems = [:]
            isStreaming = true
        case "content_block_start":
            guard let messageId = streamingMessageId, let idx = event["index"]?.int, let block = event["content_block"] else { return }
            let itemId = "\(messageId)#\(idx)"
            streamingBlockItems[idx] = itemId
            switch block["type"]?.string {
            case "text":
                upsert(TranscriptItem(id: itemId, kind: .assistantText(text: block["text"]?.string ?? "", streaming: true), timestamp: Date()))
            case "thinking":
                upsert(TranscriptItem(id: itemId, kind: .thinking(text: "", streaming: true), timestamp: Date()))
            case "tool_use":
                let toolId = block["id"]?.string ?? itemId
                upsert(TranscriptItem(id: itemId, kind: .toolUse(id: toolId, name: block["name"]?.string ?? "tool", input: .object([:]), partialInput: "", streaming: true), timestamp: Date()))
                toolItemIds[toolId] = itemId
            default:
                streamingBlockItems[idx] = nil
            }
        case "content_block_delta":
            guard let idx = event["index"]?.int, let itemId = streamingBlockItems[idx], let pos = index[itemId], let delta = event["delta"] else { return }
            switch delta["type"]?.string {
            case "text_delta":
                if case .assistantText(let t, _) = items[pos].kind {
                    items[pos].kind = .assistantText(text: t + (delta["text"]?.string ?? ""), streaming: true)
                }
            case "thinking_delta":
                if case .thinking(let t, _) = items[pos].kind {
                    items[pos].kind = .thinking(text: t + (delta["thinking"]?.string ?? ""), streaming: true)
                }
            case "input_json_delta":
                if case .toolUse(let id, let name, let input, let partial, _) = items[pos].kind {
                    items[pos].kind = .toolUse(id: id, name: name, input: input, partialInput: partial + (delta["partial_json"]?.string ?? ""), streaming: true)
                }
            default:
                break
            }
        case "content_block_stop":
            guard let idx = event["index"]?.int, let itemId = streamingBlockItems[idx], let pos = index[itemId] else { return }
            switch items[pos].kind {
            case .assistantText(let t, _): items[pos].kind = .assistantText(text: t, streaming: false)
            case .thinking(let t, _): items[pos].kind = .thinking(text: t, streaming: false)
            default: break
            }
        case "message_delta":
            // Cumulative for the message being streamed; the full assistant message repeats the final figure.
            if let id = streamingMessageId, let out = event["usage"]?["output_tokens"]?.int, out > 0 { turnOutputByMessage[id] = out }
        case "message_stop":
            streamingMessageId = nil
            streamingBlockItems = [:]
            isStreaming = false
        default:
            break
        }
    }

    // MARK: result / system

    private mutating func applyResult(_ message: JSONValue, timestamp: Date?) {
        isStreaming = false
        finishAllStreaming()
        if let cost = message["total_cost_usd"]?.double, cost > 0 { totalCostUSD = cost }
        if let usage = message["usage"] {
            let cacheRead = usage["cache_read_input_tokens"]?.int ?? 0
            let cacheCreate = usage["cache_creation_input_tokens"]?.int ?? 0
            let base = usage["input_tokens"]?.int ?? 0
            if base + cacheRead + cacheCreate > 0 { inputTokens = base + cacheRead + cacheCreate }
            if let out = usage["output_tokens"]?.int, out > 0 { outputTokens = out }
        }
        let isError = message["is_error"]?.bool ?? false
        var parts: [String] = []
        if let ms = message["duration_ms"]?.double { parts.append(Transcript.formatDuration(ms)) }
        if let turns = message["num_turns"]?.int { parts.append("\(turns) turn\(turns == 1 ? "" : "s")") }
        if let cost = message["total_cost_usd"]?.double, cost > 0 { parts.append(String(format: "$%.3f", cost)) }
        if isError, let subtype = message["subtype"]?.string, subtype != "success" { parts.append(subtype) }
        if isError, let text = message["result"]?.string, !text.isEmpty { parts.append(text) }
        let id = "turn:\(message["uuid"]?.string ?? UUID().uuidString)"
        upsert(TranscriptItem(id: id, kind: .turnEnd(summary: parts.joined(separator: " · "), isError: isError), timestamp: timestamp ?? Date()))
    }

    private mutating func applySystem(_ message: JSONValue, timestamp: Date?) {
        switch message["subtype"]?.string {
        case "init":
            if let m = message["model"]?.string { model = m }
        case "compact_boundary":
            upsert(TranscriptItem(id: "note:\(message["uuid"]?.string ?? UUID().uuidString)", kind: .note(text: "Context compacted"), timestamp: timestamp))
        case "api_error", "error":
            let text = message["error"]?.string ?? message["message"]?.string ?? "API error"
            upsert(TranscriptItem(id: "note:\(UUID().uuidString)", kind: .note(text: text), timestamp: timestamp))
        default:
            break
        }
    }

    private mutating func finishAllStreaming() {
        for pos in items.indices {
            switch items[pos].kind {
            case .assistantText(let t, true): items[pos].kind = .assistantText(text: t, streaming: false)
            case .thinking(let t, true): items[pos].kind = .thinking(text: t, streaming: false)
            default: break
            }
        }
    }

    // MARK: storage helpers

    private mutating func upsert(_ item: TranscriptItem) {
        if let pos = index[item.id] {
            items[pos] = item
        } else {
            index[item.id] = items.count
            items.append(item)
        }
    }

    // MARK: text helpers

    /// Drops harness boilerplate that Claude Code embeds in user turns.
    public static func cleanUserText(_ raw: String) -> String {
        var text = raw
        for tag in ["system-reminder", "local-command-stdout", "local-command-stderr", "command-message", "command-args", "command-name"] {
            text = text.replacingOccurrences(of: "<\(tag)>[\\s\\S]*?</\(tag)>", with: "", options: .regularExpression)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<") && trimmed.hasSuffix(">") && !trimmed.contains("\n") { return "" }
        return trimmed
    }

    public static func flattenContent(_ content: JSONValue?) -> String {
        guard let content else { return "" }
        if let s = content.string { return s }
        guard let blocks = content.array else { return content.serializedString() }
        return blocks.compactMap { block -> String? in
            switch block["type"]?.string {
            case "text": return block["text"]?.string
            case "image": return nil
            default: return nil
            }
        }.joined(separator: "\n")
    }

    public static func formatDuration(_ ms: Double) -> String {
        let s = ms / 1000
        if s < 60 { return String(format: "%.1fs", s) }
        let m = Int(s) / 60, r = Int(s) % 60
        return "\(m)m \(r)s"
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFormatterNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func parseDate(_ s: String) -> Date? {
        isoFormatter.date(from: s) ?? isoFormatterNoFraction.date(from: s)
    }
}

/// Human-readable one-liner for a tool call, used in list rows and permission prompts.
public enum ToolSummary {
    public static func line(name: String, input: JSONValue) -> String {
        switch name {
        case "Bash": return input["command"]?.string ?? input["description"]?.string ?? ""
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit": return shortPath(input["file_path"]?.string ?? input["notebook_path"]?.string ?? "")
        case "Glob": return [input["pattern"]?.string, input["path"]?.string.map(shortPath)].compactMap { $0 }.joined(separator: " in ")
        case "Grep": return [input["pattern"]?.string, input["path"]?.string.map(shortPath)].compactMap { $0 }.joined(separator: " in ")
        case "WebFetch": return input["url"]?.string ?? ""
        case "WebSearch": return input["query"]?.string ?? ""
        case "Task", "Agent": return input["description"]?.string ?? input["prompt"]?.string?.prefix(80).description ?? ""
        case "Skill": return input["skill"]?.string ?? ""
        case "TodoWrite": return "update todos"
        default:
            if let first = input.object?.sorted(by: { $0.key < $1.key }).first?.value.string { return String(first.prefix(120)) }
            return input.object?.isEmpty == false ? input.serializedString().prefix(120).description : ""
        }
    }

    /// `mcp__Claude_Code_iOS_Simulator__control` → `control · Claude Code iOS Simulator`.
    public static func displayName(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        let parts = name.dropFirst(5).components(separatedBy: "__")
        guard parts.count >= 2 else { return name }
        let server = parts[0].replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return "\(parts[1...].joined(separator: "__")) · \(server)"
    }

    public static func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }
}
