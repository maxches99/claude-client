#if os(macOS)
import Foundation
import ClaudeRemoteCore

/// Continuing a session on the Mac itself: in Claude Desktop (its `claude://resume` link imports a CLI
/// session), in a terminal running the CLI, or just opening the project in Finder or an editor.
extension SessionManager {
    public enum HandoffError: Error, CustomStringConvertible {
        case busy
        case openElsewhere(String)
        case unavailable(String)

        public var description: String {
            switch self {
            case .busy: return "The agent is in the middle of a turn — stop it or wait for it to finish first."
            case .openElsewhere(let where_): return "It is already open in \(where_) on the Mac."
            case .unavailable(let what): return what
            }
        }
    }

    /// Editors worth offering, when installed.
    private static let editors: [(id: String, app: String, label: String)] = [
        ("vscode", "Visual Studio Code", "Visual Studio Code"),
        ("cursor", "Cursor", "Cursor"),
        ("zed", "Zed", "Zed"),
    ]

    static func applicationPath(_ name: String) -> String? {
        for dir in ["/Applications", NSHomeDirectory() + "/Applications", "/System/Applications"] {
            let path = "\(dir)/\(name).app"
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    public func handoffTargets(sessionId: String) -> [HandoffTarget] {
        let summary = listSessions().first { $0.id == sessionId }
        let agent = summary?.agent ?? hosted[sessionId]?.agent ?? .claude
        let kind = summary?.kind ?? hosted[sessionId]?.state.kind ?? .agent
        let cwd = cwdFor(sessionId) ?? summary?.cwd ?? ""
        var items: [HandoffTarget] = []
        if agent == .claude, kind == .agent, SessionManager.applicationPath("Claude") != nil {
            items.append(HandoffTarget(id: "desktop", label: "Continue in Claude Desktop", systemImage: "macwindow", kind: .session,
                                       detail: "Imports the session into the Code tab and opens it"))
        }
        if agent == .claude || codex != nil {
            items.append(HandoffTarget(id: "terminal", label: "Continue in Terminal", systemImage: "terminal", kind: .session,
                                       detail: agent == .codex ? "codex resume in a new Terminal window" : "claude --resume in a new Terminal window"))
        }
        guard kind == .agent, !cwd.isEmpty, FileManager.default.fileExists(atPath: cwd) else { return items }
        items.append(HandoffTarget(id: "finder", label: "Show in Finder", systemImage: "folder", kind: .folder, detail: (cwd as NSString).lastPathComponent))
        if SessionManager.applicationPath("Xcode") != nil, SessionManager.xcodeProject(in: cwd) != nil {
            items.append(HandoffTarget(id: "xcode", label: "Open in Xcode", systemImage: "hammer", kind: .folder,
                                       detail: SessionManager.xcodeProject(in: cwd).map { ($0 as NSString).lastPathComponent }))
        }
        for editor in SessionManager.editors where SessionManager.applicationPath(editor.app) != nil {
            items.append(HandoffTarget(id: editor.id, label: "Open in \(editor.label)", systemImage: "chevron.left.forwardslash.chevron.right", kind: .folder))
        }
        return items
    }

    public func handoff(sessionId: String, targetId: String) async throws {
        let summary = listSessions().first { $0.id == sessionId }
        let agent = summary?.agent ?? hosted[sessionId]?.agent ?? .claude
        let cwd = cwdFor(sessionId) ?? summary?.cwd ?? NSHomeDirectory()
        switch targetId {
        case "desktop":
            // Desktop opens a session it already has; for one we host, let go of it first so the
            // transcript has a single writer.
            try await releaseForHandoff(sessionId: sessionId, allowOpenElsewhere: true)
            try SessionManager.openOnMac(["claude://resume?session=\(sessionId)"])
        case "terminal":
            try await releaseForHandoff(sessionId: sessionId, allowOpenElsewhere: false)
            let command: String
            if agent == .codex {
                guard let codex else { throw HandoffError.unavailable("Codex is not installed on this Mac.") }
                command = "\(SessionManager.shellQuote(codex.cli.path)) resume \(SessionManager.shellQuote(sessionId))"
            } else {
                command = "\(SessionManager.shellQuote(try claudePath())) --resume \(SessionManager.shellQuote(sessionId))"
            }
            try openInTerminal(cwd: cwd, command: command, name: "resume-\(sessionId.prefix(8))")
        case "finder":
            try SessionManager.openOnMac([cwd])
        case "xcode":
            try SessionManager.openOnMac(["-a", "Xcode", SessionManager.xcodeProject(in: cwd) ?? cwd])
        default:
            guard let editor = SessionManager.editors.first(where: { $0.id == targetId }) else {
                throw HandoffError.unavailable("Unknown place to open it.")
            }
            try SessionManager.openOnMac(["-a", editor.app, cwd])
        }
        log("[\(sessionId.prefix(8))] handed off to \(targetId)")
    }

    /// Stops our own process for the session (the transcript stays), refusing mid-turn.
    private func releaseForHandoff(sessionId: String, allowOpenElsewhere: Bool) async throws {
        if let h = hosted[sessionId] {
            if h.state.status == .running || h.state.status == .awaitingPermission { throw HandoffError.busy }
            await close(sessionId: sessionId)
            broadcast(.sessions(items: listSessions()))
            return
        }
        if !allowOpenElsewhere, let summary = listSessions().first(where: { $0.id == sessionId }), summary.origin == .desktop {
            throw HandoffError.openElsewhere(summary.sourceLabel)
        }
    }

    /// A `.command` file opened with `open` runs in Terminal without the Automation permission a
    /// scripted Terminal would need.
    private func openInTerminal(cwd: String, command: String, name: String) throws {
        let dir = NSTemporaryDirectory() + "ccremote-handoff"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = "\(dir)/\(name).command"
        let script = """
        #!/bin/zsh -l
        cd \(SessionManager.shellQuote(cwd)) || exit 1
        rm -f \(SessionManager.shellQuote(path))
        exec \(command)
        """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        try SessionManager.openOnMac([path])
    }

    static func openOnMac(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw HandoffError.unavailable(message.isEmpty ? "The Mac could not open it." : message)
        }
    }

    /// A workspace, then a project, then a Swift package — what "Open in Xcode" should open.
    static func xcodeProject(in cwd: String) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: cwd)) ?? []
        if let ws = names.sorted().first(where: { $0.hasSuffix(".xcworkspace") }) { return (cwd as NSString).appendingPathComponent(ws) }
        if let proj = names.sorted().first(where: { $0.hasSuffix(".xcodeproj") }) { return (cwd as NSString).appendingPathComponent(proj) }
        if names.contains("Package.swift") { return (cwd as NSString).appendingPathComponent("Package.swift") }
        return nil
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
#endif
