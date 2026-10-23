#if os(macOS) || os(Linux)
import Foundation
import ClaudeRemoteCore

/// Guesses the next prompt for a session the host only watches (open in Claude Desktop or a terminal).
/// Those CLIs make their own suggestions but never write them anywhere we can read, so after a turn the
/// host asks a small model once, from the last prompt and reply: the same one-line "what would you type
/// next" the CLI's `--prompt-suggestions` gives hosted sessions.
enum PromptSuggester {
    static let model = "claude-haiku-4-5"

    static let systemPrompt = """
        You predict the next message the user will send in a conversation with a coding agent. \
        Reply with only that message, as the user would type it: one short line, in the user's \
        language, no quotes, no explanation. If the agent asked a question, answer it the way the \
        user most likely would. If nothing obvious comes next, reply with an empty line.
        """

    /// The last user prompt and the last assistant reply in a transcript file, read from its tail.
    static func lastExchange(path: String, tailBytes: Int = 400_000) -> (prompt: String, reply: String)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        var prompt: String?
        var reply: String?
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let entry = try? JSONValue.parse(Data(line)) else { continue }   // the first line may be cut
            let type = entry["type"]?.string
            if type == "assistant", reply == nil, let text = text(of: entry), !text.isEmpty {
                reply = text
            } else if type == "user", reply != nil, entry["isMeta"]?.bool != true, let text = text(of: entry),
                      !text.isEmpty, !text.hasPrefix("<") {   // tool results and injected notices are not prompts
                prompt = text
                break
            }
        }
        guard let prompt, let reply else { return nil }
        return (prompt, reply)
    }

    /// Plain text of a message (string content, or its text blocks).
    private static func text(of entry: JSONValue) -> String? {
        let content = entry["message"]?["content"]
        if let s = content?.string { return s }
        let parts = (content?.array ?? []).compactMap { block -> String? in
            block["type"]?.string == "text" ? block["text"]?.string : nil
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// Runs the CLI once, without tools, settings, hooks or a saved session. `onStart` gets the pid so the
    /// caller can keep the short-lived process out of the live-session list. Nil when it fails or has nothing.
    static func suggest(cli: String, prompt: String, reply: String, workingDirectory: String,
                        onStart: (Int32) -> Void) async -> String? {
        let exchange = "User: \(clip(prompt, 2_000))\n\nAgent: \(clip(reply, 6_000))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["-p", "--model", model, "--no-session-persistence", "--setting-sources=", "--tools", "",
                             "--strict-mcp-config", "--output-format", "text", "--system-prompt", systemPrompt, exchange]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        onStart(process.processIdentifier)
        // A stuck call must not hang around: suggestions are only worth anything right after the turn.
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: killer)
        let data: Data = await withCheckedContinuation { done in
            DispatchQueue.global(qos: .utility).async {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                done.resume(returning: data)
            }
        }
        killer.cancel()
        guard process.terminationStatus == 0 else { return nil }
        let line = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"«»“”")) ?? ""
        return line.isEmpty || line.count > 300 ? nil : line
    }

    private static func clip(_ s: String, _ limit: Int) -> String {
        s.count > limit ? "…" + s.suffix(limit) : s
    }
}
#endif
