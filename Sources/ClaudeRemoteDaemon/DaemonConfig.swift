#if os(macOS)
import Foundation
import ClaudeCodeHost

/// Everything the daemon needs to run, apart from secrets it mints itself (pairing token,
/// TLS identity, relay room). Persisted as `config.json` in the support directory so the
/// CLI and the menu-bar app share one setup; CLI flags overlay it for a single run.
public struct DaemonConfig: Codable, Equatable, Sendable {
    public var port: UInt16 = 7811
    /// Bonjour service name. `nil` → this Mac's name.
    public var serviceName: String?
    /// Path to the `claude` binary. `nil` → Claude Desktop's bundled CLI, else PATH.
    public var claudePath: String?
    /// Path to the `codex` binary. `nil` → PATH, else the one bundled with the Codex app.
    public var codexPath: String?
    /// Serve `wss://` with the self-signed identity (default). `false` → plain `ws://`, LAN debugging only.
    public var useTLS: Bool = true

    /// Relay base URL, e.g. `wss://relay.example.com`. Empty / nil → relay off.
    public var relayURL: String?
    public var relaySecret: String?
    /// Room id on the relay. `nil` → a stable per-Mac id kept in the support directory.
    public var relayRoom: String?
    /// Pin the relay's TLS cert (SHA-256 hex) instead of system trust.
    public var relayFingerprint: String?

    /// ntfy topic ("my-mac-xyz", uses ntfy.sh) or full URL.
    public var ntfy: String?
    public var telegramToken: String?
    public var telegramChat: String?
    /// Also notify when a turn completes (permission-needed and errors always notify).
    public var notifyDone: Bool = true

    public init() {}

    // Decode with defaults so a config written by an older build still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 7811
        serviceName = try c.decodeIfPresent(String.self, forKey: .serviceName)
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath)
        codexPath = try c.decodeIfPresent(String.self, forKey: .codexPath)
        useTLS = try c.decodeIfPresent(Bool.self, forKey: .useTLS) ?? true
        relayURL = try c.decodeIfPresent(String.self, forKey: .relayURL)
        relaySecret = try c.decodeIfPresent(String.self, forKey: .relaySecret)
        relayRoom = try c.decodeIfPresent(String.self, forKey: .relayRoom)
        relayFingerprint = try c.decodeIfPresent(String.self, forKey: .relayFingerprint)
        ntfy = try c.decodeIfPresent(String.self, forKey: .ntfy)
        telegramToken = try c.decodeIfPresent(String.self, forKey: .telegramToken)
        telegramChat = try c.decodeIfPresent(String.self, forKey: .telegramChat)
        notifyDone = try c.decodeIfPresent(Bool.self, forKey: .notifyDone) ?? true
    }

    // MARK: derived

    public var relayEnabled: Bool { !(relayURL?.isEmpty ?? true) }

    public var notifierConfig: NotifierConfig {
        NotifierConfig(ntfyURL: ntfy.flatMap { $0.isEmpty ? nil : NotifierConfig.ntfyURL(from: $0) },
                       telegramToken: telegramToken.flatMap { $0.isEmpty ? nil : $0 },
                       telegramChatID: telegramChat.flatMap { $0.isEmpty ? nil : $0 },
                       notifyDone: notifyDone)
    }

    // MARK: persistence

    public static let supportDirectory = NSHomeDirectory() + "/Library/Application Support/ccremote"
    public static var path: String { supportDirectory + "/config.json" }

    /// The saved config, or defaults when there is none (or it is unreadable).
    public static func load(directory: String = supportDirectory) -> DaemonConfig {
        guard let data = FileManager.default.contents(atPath: directory + "/config.json") else { return DaemonConfig() }
        return (try? JSONDecoder().decode(DaemonConfig.self, from: data)) ?? DaemonConfig()
    }

    public static func exists(directory: String = supportDirectory) -> Bool {
        FileManager.default.fileExists(atPath: directory + "/config.json")
    }

    /// Writes `config.json` (0600 — it may hold the relay secret and bot token).
    public func save(directory: String = supportDirectory) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let path = directory + "/config.json"
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}

/// The `ccremote` command line. Config flags overlay the saved config; the rest are run modes.
public struct DaemonArguments {
    public var config: DaemonConfig
    public var tokenOverride: String?
    public var quiet = false
    public var rotateToken = false
    public var printPairingOnly = false
    public var help = false

    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
    }

    /// Parses `arguments` (without the program name) on top of `base`.
    public static func parse(_ arguments: [String], base: DaemonConfig = .load()) throws -> DaemonArguments {
        var result = DaemonArguments(config: base)
        var args = arguments
        func value(_ flag: String) throws -> String {
            guard !args.isEmpty else { throw ParseError(description: "\(flag) needs a value") }
            return args.removeFirst()
        }
        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "--port":
                guard let p = UInt16(try value(a)) else { throw ParseError(description: "--port needs a number 1–65535") }
                result.config.port = p
            case "--token": result.tokenOverride = try value(a)
            case "--claude": result.config.claudePath = try value(a)
            case "--codex": result.config.codexPath = try value(a)
            case "--name": result.config.serviceName = try value(a)
            case "--quiet": result.quiet = true
            case "--rotate-token": result.rotateToken = true
            case "--print-pairing": result.printPairingOnly = true
            case "--no-tls": result.config.useTLS = false
            case "--relay": result.config.relayURL = try value(a)
            case "--no-relay": result.config.relayURL = nil
            case "--relay-secret": result.config.relaySecret = try value(a)
            case "--room": result.config.relayRoom = try value(a)
            case "--relay-fingerprint": result.config.relayFingerprint = try value(a)
            case "--ntfy": result.config.ntfy = try value(a)
            case "--telegram-token": result.config.telegramToken = try value(a)
            case "--telegram-chat": result.config.telegramChat = try value(a)
            case "--no-notify-done": result.config.notifyDone = false
            case "-h", "--help": result.help = true
            default: throw ParseError(description: "unknown option \(a)")
            }
        }
        return result
    }
}
#endif
