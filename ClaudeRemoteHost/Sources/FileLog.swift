import Foundation
import os

/// Appends timestamped lines to `~/Library/Logs/ccremote.log` (the file the LaunchAgent used
/// to write, so `Console.app` and old habits keep working) and mirrors them to the unified log.
final class FileLog: @unchecked Sendable {
    static let defaultPath = NSHomeDirectory() + "/Library/Logs/ccremote.log"
    private static let maxBytes: UInt64 = 5 * 1024 * 1024

    private let path: String
    private let queue = DispatchQueue(label: "ccremote.host.log")
    private let logger = Logger(subsystem: "dev.maxches.ccremote", category: "daemon")
    private var handle: FileHandle?
    private let formatter = ISO8601DateFormatter()
    /// The most recent lines, for the in-app log view.
    private(set) var recent: [String] = []
    var onLine: (@Sendable (String) -> Void)?

    init(path: String = FileLog.defaultPath) {
        self.path = path
        queue.sync { open() }
    }

    private func open() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // Keep one previous generation instead of growing forever.
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? UInt64, size > FileLog.maxBytes {
            try? fm.removeItem(atPath: path + ".1")
            try? fm.moveItem(atPath: path, toPath: path + ".1")
        }
        if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
        handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
    }

    @Sendable func write(_ line: String) {
        logger.info("\(line, privacy: .public)")
        let stamped = "[\(formatter.string(from: Date()))] \(line)"
        queue.async { [self] in
            handle?.write(Data((stamped + "\n").utf8))
            recent.append(stamped)
            if recent.count > 300 { recent.removeFirst(recent.count - 300) }
            onLine?(stamped)
        }
    }

    var fileURL: URL { URL(fileURLWithPath: path) }
}
