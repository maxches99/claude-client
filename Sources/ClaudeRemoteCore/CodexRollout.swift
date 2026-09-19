import Foundation

/// Reads Codex's own session file — `~/.codex/sessions/<date>/rollout-*.jsonl` — and turns it into
/// the same stream-json events the transcript reducer takes.
///
/// This is how a session **owned by another process** (the Codex app) is mirrored onto the phone:
/// the app-server's `thread/read` only reports messages for a thread it has not loaded, while the
/// rollout carries everything the session did — reasoning, tool calls and their output.
///
/// Each line is `{"timestamp":…, "type": session_meta | response_item | event_msg | turn_context |
/// world_state, "payload": {…}}`; `response_item` holds the durable conversation, `event_msg` the
/// turn boundaries.
public struct CodexRollout: Sendable {
    /// Set while a turn is in flight (between `task_started` and `task_complete`).
    public private(set) var isRunning = false

    public init() {}

    /// Zero or more transcript events for one rollout line.
    public mutating func apply(_ line: JSONValue) -> [JSONValue] {
        guard let payload = line["payload"] else { return [] }
        let timestamp = line["timestamp"]?.string
        switch line["type"]?.string {
        case "response_item":
            return responseItem(payload, timestamp: timestamp)
        case "event_msg":
            switch payload["type"]?.string {
            case "task_started":
                isRunning = true
                return []
            case "task_complete":
                isRunning = false
                var result: [String: JSONValue] = [
                    "type": "result", "subtype": "success", "is_error": false,
                    "uuid": .string(payload["turn_id"]?.string ?? UUID().uuidString),
                ]
                if let ts = timestamp { result["timestamp"] = .string(ts) }
                if let ms = payload["duration_ms"]?.double { result["duration_ms"] = .number(ms) }
                if let text = payload["last_agent_message"]?.string { result["result"] = .string(text) }
                return [.object(result)]
            case "error", "stream_error":
                let text = payload["message"]?.string ?? payload["error"]?.string ?? "Codex error"
                return [.object(["type": "system", "subtype": "api_error", "error": .string(text),
                                 "uuid": .string(UUID().uuidString), "timestamp": .string(timestamp ?? "")])]
            default:
                return []
            }
        default:
            return []
        }
    }

    /// Every event for a whole rollout file, in order.
    public static func history(lines: [JSONValue]) -> [JSONValue] {
        var translator = CodexRollout()
        return lines.flatMap { translator.apply($0) }
    }

    // MARK: response items

    private func responseItem(_ payload: JSONValue, timestamp: String?) -> [JSONValue] {
        let id = payload["id"]?.string ?? payload["call_id"]?.string ?? UUID().uuidString
        let ts = timestamp ?? ""
        switch payload["type"]?.string {
        case "message":
            // `developer` / `system` messages are the harness prompt and skill catalogue, not conversation.
            let role = payload["role"]?.string ?? ""
            let text = Self.text(of: payload["content"])
            guard !text.isEmpty else { return [] }
            switch role {
            case "user":
                // Codex prepends its context blocks as user turns; they are harness plumbing, not a prompt.
                let prompt = Self.stripContextBlocks(text)
                guard !prompt.isEmpty else { return [] }
                return [.object(["type": "user", "uuid": .string(id), "timestamp": .string(ts),
                                 "message": .object(["role": "user", "content": .array([.object(["type": "text", "text": .string(prompt)])])])])]
            case "assistant":
                return [Self.assistant(id: id, blocks: [.object(["type": "text", "text": .string(text)])], timestamp: ts)]
            default:
                return []
            }
        case "reasoning":
            var text = (payload["summary"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n\n")
            if text.isEmpty { text = Self.text(of: payload["content"]) }
            guard !text.isEmpty else { return [] }
            return [Self.assistant(id: id, blocks: [.object(["type": "thinking", "thinking": .string(text)])], timestamp: ts)]
        case "custom_tool_call":
            let callId = payload["call_id"]?.string ?? id
            let name = payload["name"]?.string ?? "tool"
            return [Self.assistant(id: id, blocks: [Self.toolUse(id: callId, name: name, input: Self.input(payload["input"]))], timestamp: ts)]
        case "function_call":
            let callId = payload["call_id"]?.string ?? id
            let name = payload["name"]?.string ?? "tool"
            return [Self.assistant(id: id, blocks: [Self.toolUse(id: callId, name: name, input: Self.input(payload["arguments"]))], timestamp: ts)]
        case "local_shell_call":
            let callId = payload["call_id"]?.string ?? id
            let command = (payload["action"]?["command"]?.array ?? []).compactMap(\.string).joined(separator: " ")
            return [Self.assistant(id: id, blocks: [Self.toolUse(id: callId, name: "Bash", input: .object(["command": .string(command)]))], timestamp: ts)]
        case "custom_tool_call_output", "function_call_output", "local_shell_call_output":
            guard let callId = payload["call_id"]?.string else { return [] }
            let text = Self.text(of: payload["output"])
            let isError = payload["status"]?.string == "failed" || payload["success"]?.bool == false
            return [Self.toolResult(callId: callId, text: Self.cap(text), isError: isError, timestamp: ts)]
        default:
            return []
        }
    }

    // MARK: helpers

    /// Context Codex injects into the conversation as user turns — environment, plugin and skill
    /// catalogues. Dropping them keeps the mirrored transcript to what a person actually said.
    static let contextTags = ["environment_context", "recommended_plugins", "skills_instructions",
                              "apps_instructions", "user_instructions", "world_state", "collaboration_mode"]

    public static func stripContextBlocks(_ raw: String) -> String {
        var text = raw
        for tag in contextTags {
            text = text.replacingOccurrences(of: "<\(tag)>[\\s\\S]*?</\(tag)>", with: "", options: .regularExpression)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unclosed or unknown context block still reads as markup, never as a prompt.
        if trimmed.hasPrefix("<"), let close = trimmed.range(of: ">"), trimmed.distance(from: trimmed.startIndex, to: close.lowerBound) < 40,
           contextTags.contains(where: { trimmed.hasPrefix("<\($0)") }) {
            return ""
        }
        return trimmed
    }

    /// Rollout content is either a string or a list of `{type: input_text|output_text…, text}` parts.
    private static func text(of value: JSONValue?) -> String {
        guard let value else { return "" }
        if let s = value.string { return s }
        guard let parts = value.array else { return "" }
        return parts.compactMap { $0["text"]?.string ?? $0.string }.joined()
    }

    /// Tool input is a JSON string when the tool takes arguments, and source code for `exec`.
    private static func input(_ value: JSONValue?) -> JSONValue {
        guard let value else { return .object([:]) }
        if let raw = value.string {
            if let parsed = try? JSONValue.parse(raw), parsed.object != nil { return parsed }
            return .object(["input": .string(raw)])
        }
        return value.object != nil ? value : .object(["input": value])
    }

    private static func assistant(id: String, blocks: [JSONValue], timestamp: String) -> JSONValue {
        .object(["type": "assistant", "uuid": .string(id), "timestamp": .string(timestamp),
                 "message": .object(["id": .string(id), "role": "assistant", "content": .array(blocks)])])
    }

    private static func toolUse(id: String, name: String, input: JSONValue) -> JSONValue {
        .object(["type": "tool_use", "id": .string(id), "name": .string(name), "input": input])
    }

    private static func toolResult(callId: String, text: String, isError: Bool, timestamp: String) -> JSONValue {
        .object(["type": "user", "uuid": .string("result:" + callId), "timestamp": .string(timestamp),
                 "message": .object(["role": "user", "content": .array([
                     .object(["type": "tool_result", "tool_use_id": .string(callId), "content": .string(text), "is_error": .bool(isError)]),
                 ])])])
    }

    private static func cap(_ text: String, limit: Int = 30_000) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\n… (truncated)" : text
    }
}
