import Foundation

/// What one turn of the agent actually did to the project: which files it wrote and which commands
/// it ran, read straight out of the transcript. The phone uses it to review — and undo — a single
/// turn without hunting through the whole working tree.
public enum TurnChanges {
    /// Tools whose input names a file the agent wrote.
    public static let writingTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    public struct Turn: Identifiable, Equatable, Sendable {
        /// The id of the user item that opened the turn.
        public var id: String
        public var prompt: String
        public var startedAt: Date?
        public var endedAt: Date?
        /// Absolute paths the agent wrote, first touched first, without duplicates.
        public var paths: [String]
        /// Shell commands it ran, for context in the review sheet.
        public var commands: [String]
        /// The turn is the last one and still running.
        public var isCurrent: Bool

        public init(id: String, prompt: String, startedAt: Date?, endedAt: Date?, paths: [String], commands: [String], isCurrent: Bool) {
            self.id = id
            self.prompt = prompt
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.paths = paths
            self.commands = commands
            self.isCurrent = isCurrent
        }

        public var isEmpty: Bool { paths.isEmpty }
    }

    /// Splits a transcript into turns (a user message starts one) and collects each turn's writes.
    public static func turns(_ items: [TranscriptItem]) -> [Turn] {
        var result: [Turn] = []
        var current: Turn?
        var seen: Set<String> = []
        var streaming = false

        func flush() {
            if let turn = current { result.append(turn) }
            current = nil
            seen = []
        }

        for item in items {
            switch item.kind {
            case .user(let text, _):
                flush()
                current = Turn(id: item.id, prompt: text, startedAt: item.timestamp, endedAt: nil, paths: [], commands: [], isCurrent: true)
                streaming = false
            case .toolUse(_, let name, let input, _, let isStreaming):
                guard current != nil else { continue }
                streaming = streaming || isStreaming
                if writingTools.contains(name) {
                    let path = input["file_path"]?.string ?? input["notebook_path"]?.string ?? ""
                    if !path.isEmpty, seen.insert(path).inserted { current?.paths.append(path) }
                } else if name == "Bash", let command = input["command"]?.string, !command.isEmpty {
                    current?.commands.append(command)
                }
            case .turnEnd:
                current?.endedAt = item.timestamp
                current?.isCurrent = false
            default:
                break
            }
        }
        flush()
        return result
    }

    /// The turns worth offering for review, newest first: only those that wrote something.
    public static func reviewable(_ items: [TranscriptItem]) -> [Turn] {
        turns(items).filter { !$0.isEmpty }.reversed()
    }

    /// The paths of `turn`, relative to `cwd`, for git commands (paths outside the repo are dropped).
    public static func repoRelative(_ paths: [String], cwd: String) -> [String] {
        let root = (cwd as NSString).standardizingPath
        return paths.compactMap { path in
            let full = (path as NSString).standardizingPath
            guard full.hasPrefix(root + "/") else { return nil }
            return String(full.dropFirst(root.count + 1))
        }
    }
}
