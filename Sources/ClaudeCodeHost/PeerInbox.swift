#if os(macOS)
import Foundation
import ClaudeRemoteCore

/// Delivers a user message into a `claude` process that is already running on this Mac
/// (Claude Desktop, a terminal, another daemon) through its messaging inbox.
///
/// Every interactive CLI listens on `~/.claude/sessions/<pid>.json#messagingSocketPath` and
/// publishes the inbox token in `<pid>.<sha256(socket path)>.key`. The wire format is what
/// the CLI itself prints in its debug log: one auth line, then message lines —
/// `{"type":"auth","token":…}` / `{"type":"user","message":{"role":"user","content":…}}`.
public enum PeerInbox {
    public enum InboxError: Error, CustomStringConvertible {
        case noKey(pid: Int32)
        case socket(String)

        public var description: String {
            switch self {
            case .noKey(let pid): return "No messaging key for pid \(pid) in ~/.claude/sessions"
            case .socket(let why): return "Could not reach the session's inbox: \(why)"
            }
        }
    }

    public static func send(text: String, socketPath: String, pid: Int32, sessionsDirectory: String) throws {
        let token = try peerToken(pid: pid, sessionsDirectory: sessionsDirectory)
        let auth = JSONValue.object(["type": "auth", "token": .string(token)])
        let message = JSONValue.object(["type": "user", "message": .object(["role": "user", "content": .string(text)])])
        var payload = try auth.serialized()
        payload.append(0x0A)
        payload.append(try message.serialized())
        payload.append(0x0A)
        try write(payload, to: socketPath)
    }

    static func peerToken(pid: Int32, sessionsDirectory: String) throws -> String {
        let fm = FileManager.default
        let prefix = "\(pid)."
        guard let files = try? fm.contentsOfDirectory(atPath: sessionsDirectory),
              let keyFile = files.first(where: { $0.hasPrefix(prefix) && $0.hasSuffix(".key") }),
              let data = fm.contents(atPath: sessionsDirectory + "/" + keyFile),
              let json = try? JSONValue.parse(data), let token = json["peerToken"]?.string else {
            throw InboxError.noKey(pid: pid)
        }
        return token
    }

    private static func write(_ payload: Data, to path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw InboxError.socket(String(cString: strerror(errno))) }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw InboxError.socket("socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            for (i, byte) in pathBytes.enumerated() { buffer[i] = byte }
            buffer[pathBytes.count] = 0
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + MemoryLayout<UInt8>.size + pathBytes.count + 1)
        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
        }
        guard connected == 0 else { throw InboxError.socket(String(cString: strerror(errno))) }
        var offset = 0
        while offset < payload.count {
            let written = payload.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress!.advanced(by: offset), payload.count - offset)
            }
            guard written > 0 else { throw InboxError.socket(String(cString: strerror(errno))) }
            offset += written
        }
        shutdown(fd, SHUT_WR)
        // Give the receiver a moment to read before we close; it may answer with a status line.
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 4096)
        _ = read(fd, &buffer, buffer.count)
    }
}
#endif
