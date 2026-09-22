import Foundation

/// A command left running on the Mac — a dev server, a watcher, a long build. Unlike a one-shot
/// `runCommand`, it outlives the phone's connection: the daemon keeps it and buffers its output, so
/// reopening the app attaches to what is still running.
public struct BackgroundProcess: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var command: String
    /// The name it was started under (a quick command's name), when it had one.
    public var label: String?
    public var cwd: String
    /// The session whose project it belongs to, when started from one.
    public var sessionId: String?
    public var startedAt: Date
    public var finishedAt: Date?
    public var exitCode: Int32?
    public var running: Bool
    /// How much output the daemon is holding (the tail of it, when the phone attaches).
    public var outputBytes: Int

    public init(id: String, command: String, label: String? = nil, cwd: String, sessionId: String? = nil, startedAt: Date = Date(),
                finishedAt: Date? = nil, exitCode: Int32? = nil, running: Bool = true, outputBytes: Int = 0) {
        self.id = id
        self.command = command
        self.label = label
        self.cwd = cwd
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.exitCode = exitCode
        self.running = running
        self.outputBytes = outputBytes
    }

    public var projectName: String { (cwd as NSString).lastPathComponent }
    public var displayName: String { label ?? command }
}
