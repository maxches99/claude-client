import Foundation

/// Turns Codex app-server traffic (JSON-RPC notifications and `ThreadItem`s) into the stream-json
/// message shapes the transcript reducer already understands, so a Codex thread renders on the
/// phone exactly like a Claude session: `assistant` blocks, `stream_event` deltas, `user`
/// tool results and a `result` per turn.
///
/// One translator per thread — it keeps just enough state to pair deltas with their items and to
/// summarise a turn when it completes.
public struct CodexTranslator: Sendable {
    public private(set) var currentTurnId: String?
    /// Text of the last agent message in the current turn — becomes `result` (shown in pushes).
    private var lastAgentText: String?
    /// Streamed text per item, used when the completed item is missing it (reasoning summaries).
    private var streamed: [String: String] = [:]
    /// Items whose streaming block has been opened on the phone.
    private var opened: Set<String> = []
    /// Prompts we already showed as our own `user` event; the echo from Codex is dropped.
    private var recentPrompts: [String] = []
    private var seenUserItems: Set<String> = []
    /// Tool-like items whose call row was already emitted at `started` (so `completed` adds only the result).
    private var startedTools: Set<String> = []

    public init() {}

    // MARK: our own prompt

    /// The user turn as the reducer expects it (Claude's CLI replays it; Codex does not).
    public mutating func userEvent(text: String, images: [InlineImage]) -> JSONValue {
        recentPrompts.append(text)
        if recentPrompts.count > 4 { recentPrompts.removeFirst() }
        var content: [JSONValue] = []
        if !text.isEmpty { content.append(.object(["type": "text", "text": .string(text)])) }
        for image in images {
            content.append(.object(["type": "image", "source": .object([
                "type": "base64", "media_type": .string(image.mediaType), "data": .string(image.base64),
            ])]))
        }
        return .object([
            "type": "user", "uuid": .string("prompt:" + UUID().uuidString.lowercased()),
            "timestamp": .string(Self.iso(Date())),
            "message": .object(["role": "user", "content": .array(content)]),
        ])
    }

    // MARK: notifications

    /// Zero or more stream-json events for one server notification.
    public mutating func translate(method: String, params: JSONValue) -> [JSONValue] {
        switch method {
        case "turn/started":
            currentTurnId = params["turn"]?["id"]?.string
            lastAgentText = nil
            return []
        case "turn/completed":
            let turn = params["turn"] ?? .object([:])
            let status = turn["status"]?.string ?? "completed"
            let error = turn["error"]?["message"]?.string
            var result: [String: JSONValue] = [
                "type": "result",
                "subtype": .string(status == "completed" ? "success" : status),
                "is_error": .bool(status == "failed"),
                "uuid": .string(turn["id"]?.string ?? UUID().uuidString),
                "timestamp": .string(Self.iso(Date())),
            ]
            if let ms = turn["durationMs"]?.double { result["duration_ms"] = .number(ms) }
            if let text = error ?? lastAgentText { result["result"] = .string(text) }
            currentTurnId = nil
            return [.object(result)]
        case "item/started":
            guard let item = params["item"] else { return [] }
            return itemEvents(item, completed: false, timestamp: params["startedAtMs"]?.double.map(Self.iso(ms:)))
        case "item/completed":
            guard let item = params["item"] else { return [] }
            return itemEvents(item, completed: true, timestamp: params["completedAtMs"]?.double.map(Self.iso(ms:)))
        case "item/agentMessage/delta", "item/plan/delta":
            guard let id = params["itemId"]?.string, let delta = params["delta"]?.string else { return [] }
            return open(id, kind: "text") + [Self.delta(id, ["type": "text_delta", "text": .string(delta)])]
        case "item/reasoning/summaryTextDelta":
            guard let id = params["itemId"]?.string, let delta = params["delta"]?.string else { return [] }
            streamed[id, default: ""] += delta
            return open(id, kind: "thinking") + [Self.delta(id, ["type": "thinking_delta", "thinking": .string(delta)])]
        case "item/reasoning/summaryPartAdded":
            guard let id = params["itemId"]?.string, (params["summaryIndex"]?.int ?? 0) > 0, opened.contains(id) else { return [] }
            streamed[id, default: ""] += "\n\n"
            return [Self.delta(id, ["type": "thinking_delta", "thinking": "\n\n"])]
        case "error":
            var text = params["error"]?["message"]?.string ?? "Codex error"
            if params["willRetry"]?.bool == true { text += " (retrying)" }
            return [.object(["type": "system", "subtype": "api_error", "error": .string(text), "timestamp": .string(Self.iso(Date()))])]
        case "thread/compacted":
            return [Self.compacted()]
        default:
            return []
        }
    }

    // MARK: stored threads

    /// History entries for a `Thread` (from `thread/read` / `thread/resume`): every completed item of every turn.
    public static func history(thread: JSONValue) -> [JSONValue] {
        var translator = CodexTranslator()
        var entries: [JSONValue] = []
        for turn in thread["turns"]?.array ?? [] {
            let timestamp = turn["startedAt"]?.double.map { iso(Date(timeIntervalSince1970: $0)) }
            for item in turn["items"]?.array ?? [] {
                entries += translator.itemEvents(item, completed: true, timestamp: timestamp, replay: true)
            }
        }
        return entries
    }

    // MARK: items

    /// Events for an item at `started` or `completed`. `replay` = building history, where every
    /// item is final and there are no deltas to pair with.
    private mutating func itemEvents(_ item: JSONValue, completed: Bool, timestamp: String?, replay: Bool = false) -> [JSONValue] {
        guard let id = item["id"]?.string, let type = item["type"]?.string else { return [] }
        let ts = timestamp ?? Self.iso(Date())
        // A tool row is emitted once: at `started`, or at `completed` when no `started` was seen (history, fast items).
        let needUse = replay || !startedTools.contains(id)
        if !completed { startedTools.insert(id) } else { startedTools.remove(id) }
        func pair(_ use: JSONValue, _ result: JSONValue, status: String?) -> [JSONValue] {
            if !completed { return [use] }
            if status == "inProgress" { return needUse ? [use] : [] }
            return needUse ? [use, result] : [result]
        }
        switch type {
        case "userMessage":
            if !replay {
                // Live: the item shows up at `started` and again at `completed` — use the first sighting,
                // and drop the echo of a prompt we already showed as our own `user` event.
                guard !seenUserItems.contains(id) else { return [] }
                seenUserItems.insert(id)
                if let idx = recentPrompts.firstIndex(of: Self.userText(item)) {
                    recentPrompts.remove(at: idx)
                    return []
                }
            }
            return [.object(["type": "user", "uuid": .string(id), "timestamp": .string(ts),
                             "message": .object(["role": "user", "content": .array(Self.userContent(item))])])]
        case "agentMessage", "plan":
            let text = item["text"]?.string ?? ""
            guard completed else { return [] }
            if type == "agentMessage" { lastAgentText = text.isEmpty ? lastAgentText : text }
            guard !text.isEmpty else { return close(id) }
            return [Self.assistant(id: id, blocks: [.object(["type": "text", "text": .string(text)])], timestamp: ts)] + close(id)
        case "reasoning":
            guard completed else { return [] }
            var text = (item["summary"]?.array ?? []).compactMap(\.string).joined(separator: "\n\n")
            if text.isEmpty { text = (item["content"]?.array ?? []).compactMap(\.string).joined(separator: "\n\n") }
            if text.isEmpty { text = streamed[id] ?? "" }
            streamed[id] = nil
            guard !text.isEmpty else { return close(id) }
            return [Self.assistant(id: id, blocks: [.object(["type": "thinking", "thinking": .string(text)])], timestamp: ts)] + close(id)
        case "commandExecution":
            var input: [String: JSONValue] = ["command": .string(Self.unwrapShell(item["command"]?.string ?? ""))]
            if let cwd = item["cwd"]?.string { input["cwd"] = .string(cwd) }
            let use = Self.assistant(id: id, blocks: [Self.toolUse(id: id, name: "Bash", input: .object(input))], timestamp: ts)
            let status = item["status"]?.string ?? "completed"
            let exit = item["exitCode"]?.int
            var output = item["aggregatedOutput"]?.string ?? ""
            if status == "declined" { output = output.isEmpty ? "Declined" : output }
            if let exit, exit != 0 { output += (output.isEmpty ? "" : "\n") + "exit code \(exit)" }
            let isError = status == "failed" || status == "declined" || (exit ?? 0) != 0
            let result = Self.toolResults([(id, Self.cap(output), isError)], timestamp: ts)
            return pair(use, result, status: status)
        case "fileChange":
            let changes = item["changes"]?.array ?? []
            var blocks: [JSONValue] = []
            for (i, change) in changes.enumerated() {
                let kind = change["kind"]?["type"]?.string ?? "update"
                let name = kind == "add" ? "Write" : (kind == "delete" ? "Delete" : "Edit")
                var input: [String: JSONValue] = ["file_path": .string(change["path"]?.string ?? "")]
                if let move = change["kind"]?["move_path"]?.string { input["move_to"] = .string(move) }
                if let diff = change["diff"]?.string, !diff.isEmpty { input["diff"] = .string(diff) }
                blocks.append(Self.toolUse(id: "\(id)#\(i)", name: name, input: .object(input)))
            }
            guard !blocks.isEmpty else { return [] }
            let use = Self.assistant(id: id, blocks: blocks, timestamp: ts)
            let status = item["status"]?.string ?? "completed"
            let isError = status == "failed" || status == "declined"
            let text = status == "completed" ? "Applied" : status.capitalized
            let result = Self.toolResults(changes.indices.map { ("\(id)#\($0)", text, isError) }, timestamp: ts)
            return pair(use, result, status: status)
        case "mcpToolCall":
            let name = "mcp__\(item["server"]?.string ?? "mcp")__\(item["tool"]?.string ?? "tool")"
            let use = Self.assistant(id: id, blocks: [Self.toolUse(id: id, name: name, input: item["arguments"] ?? .object([:]))], timestamp: ts)
            let status = item["status"]?.string ?? "completed"
            var text = ""
            var isError = status == "failed"
            if let error = item["error"]?["message"]?.string {
                text = error
                isError = true
            } else if let content = item["result"]?["content"] {
                text = Transcript.flattenContent(content)
                if text.isEmpty, let structured = item["result"]?["structuredContent"] { text = structured.serializedString() }
            }
            let result = Self.toolResults([(id, Self.cap(text), isError)], timestamp: ts)
            return pair(use, result, status: status)
        case "dynamicToolCall":
            let use = Self.assistant(id: id, blocks: [Self.toolUse(id: id, name: item["tool"]?.string ?? "tool", input: item["arguments"] ?? .object([:]))], timestamp: ts)
            let text = (item["contentItems"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
            let result = Self.toolResults([(id, Self.cap(text), item["success"]?.bool == false)], timestamp: ts)
            return pair(use, result, status: item["status"]?.string)
        case "webSearch":
            let use = Self.assistant(id: id, blocks: [Self.toolUse(id: id, name: "WebSearch", input: .object(["query": .string(item["query"]?.string ?? "")]))], timestamp: ts)
            let count = item["results"]?.array?.count
            let result = Self.toolResults([(id, count.map { "\($0) result\($0 == 1 ? "" : "s")" } ?? "Done", false)], timestamp: ts)
            return pair(use, result, status: nil)
        case "contextCompaction":
            return completed ? [Self.compacted()] : []
        case "imageView", "sleep", "imageGeneration", "collabAgentToolCall", "subAgentActivity":
            var input = item.object ?? [:]
            input["id"] = nil
            input["type"] = nil
            let use = Self.assistant(id: id, blocks: [Self.toolUse(id: id, name: type, input: .object(input))], timestamp: ts)
            let result = Self.toolResults([(id, item["status"]?.string ?? "Done", item["status"]?.string == "failed")], timestamp: ts)
            return pair(use, result, status: nil)
        default:
            return []
        }
    }

    // MARK: streaming helpers

    /// Opens a streaming block for `id` the first time a delta arrives (message_start + content_block_start).
    private mutating func open(_ id: String, kind: String) -> [JSONValue] {
        guard !opened.contains(id) else { return [] }
        opened.insert(id)
        var block: [String: JSONValue] = ["type": .string(kind)]
        block[kind == "thinking" ? "thinking" : "text"] = ""
        return [
            .object(["type": "stream_event", "event": .object(["type": "message_start", "message": .object(["id": .string(id), "role": "assistant"])])]),
            .object(["type": "stream_event", "event": .object(["type": "content_block_start", "index": 0, "content_block": .object(block)])]),
        ]
    }

    /// Closes the streaming block if one was opened.
    private mutating func close(_ id: String) -> [JSONValue] {
        guard opened.remove(id) != nil else { return [] }
        return [
            .object(["type": "stream_event", "event": .object(["type": "content_block_stop", "index": 0])]),
            .object(["type": "stream_event", "event": .object(["type": "message_stop"])]),
        ]
    }

    private static func delta(_ id: String, _ delta: [String: JSONValue]) -> JSONValue {
        .object(["type": "stream_event", "event": .object(["type": "content_block_delta", "index": 0, "delta": .object(delta)])])
    }

    // MARK: message builders

    private static func assistant(id: String, blocks: [JSONValue], timestamp: String) -> JSONValue {
        .object(["type": "assistant", "uuid": .string(id), "timestamp": .string(timestamp),
                 "message": .object(["id": .string(id), "role": "assistant", "content": .array(blocks)])])
    }

    private static func toolUse(id: String, name: String, input: JSONValue) -> JSONValue {
        .object(["type": "tool_use", "id": .string(id), "name": .string(name), "input": input])
    }

    private static func toolResults(_ results: [(id: String, text: String, isError: Bool)], timestamp: String) -> JSONValue {
        let blocks = results.map { r in
            JSONValue.object(["type": "tool_result", "tool_use_id": .string(r.id), "content": .string(r.text), "is_error": .bool(r.isError)])
        }
        return .object(["type": "user", "uuid": .string("result:" + (results.first?.id ?? UUID().uuidString)), "timestamp": .string(timestamp),
                        "message": .object(["role": "user", "content": .array(blocks)])])
    }

    private static func compacted() -> JSONValue {
        .object(["type": "system", "subtype": "compact_boundary", "uuid": .string(UUID().uuidString), "timestamp": .string(iso(Date()))])
    }

    /// Text + image content of a `userMessage` item as reducer blocks. Data-URL images become
    /// inline images; images Codex only knows by path are named.
    private static func userContent(_ item: JSONValue) -> [JSONValue] {
        var blocks: [JSONValue] = []
        for input in item["content"]?.array ?? [] {
            switch input["type"]?.string {
            case "text":
                blocks.append(.object(["type": "text", "text": .string(input["text"]?.string ?? "")]))
            case "image":
                if let url = input["url"]?.string, let image = dataURLImage(url) {
                    blocks.append(.object(["type": "image", "source": .object(["type": "base64", "media_type": .string(image.mediaType), "data": .string(image.base64)])]))
                } else {
                    blocks.append(.object(["type": "text", "text": "[image]"]))
                }
            case "localImage":
                blocks.append(.object(["type": "text", "text": .string("[image: \(ToolSummary.shortPath(input["path"]?.string ?? ""))]")]))
            case "skill", "mention":
                blocks.append(.object(["type": "text", "text": .string("@\(input["name"]?.string ?? "")")]))
            default:
                break
            }
        }
        return blocks
    }

    private static func userText(_ item: JSONValue) -> String {
        (item["content"]?.array ?? []).compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined(separator: "\n")
    }

    private static func dataURLImage(_ url: String) -> InlineImage? {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
        let header = url[url.index(url.startIndex, offsetBy: 5)..<comma]
        guard header.hasSuffix(";base64") else { return nil }
        let mediaType = String(header.dropLast(7))
        return InlineImage(mediaType: mediaType.isEmpty ? "image/png" : mediaType, base64: String(url[url.index(after: comma)...]))
    }

    /// Codex runs commands as `/bin/zsh -lc '<command>'`; show the command itself.
    public static func unwrapShell(_ command: String) -> String {
        guard command.range(of: #"^(?:/bin/|/usr/bin/)?(?:zsh|bash|sh) -lc "#, options: .regularExpression) != nil,
              let marker = command.range(of: " -lc ") else { return command }
        let inner = String(command[marker.upperBound...])
        if inner.hasPrefix("'"), inner.hasSuffix("'"), inner.count >= 2 {
            return String(inner.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
        }
        if inner.hasPrefix("\""), inner.hasSuffix("\""), inner.count >= 2 {
            return String(inner.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
        }
        return inner
    }

    private static func cap(_ text: String, limit: Int = 30_000) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\n… (truncated)" : text
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func iso(_ date: Date) -> String { formatter.string(from: date) }
    static func iso(ms: Double) -> String { iso(Date(timeIntervalSince1970: ms / 1000)) }
}
