import Foundation
import ClaudeRemoteCore
import ClaudeCodeHost

let daemonVersion = "0.1.0"

func usage() -> Never {
    print("""
    ccremote — drive local Claude Code sessions from your phone.

    Usage: ccremote [--port N] [--token TOKEN] [--claude PATH] [--name NAME] [--quiet]

      --port N       TCP port to listen on (default 7811)
      --token TOKEN  pairing token (default: generated once, stored in ~/Library/Application Support/ccremote/token)
      --claude PATH  path to the claude binary (default: Claude Desktop's bundled CLI, else PATH)
      --name NAME    Bonjour service name (default: this Mac's name)
      --rotate-token generate a new pairing token
      --print-pairing print the pairing QR / URL for a running daemon and exit
      --no-tls       serve plain ws:// instead of wss:// (LAN debugging only)
      --relay URL    also reach phones through a relay you run, e.g. wss://vps.example.com
      --relay-secret S   shared secret the daemon presents to the relay's /agent endpoint
      --room R       relay room id (default: stable per-Mac id in the support dir)
      --relay-fingerprint FP   pin the relay's TLS cert (SHA-256 hex) instead of system trust
      --ntfy TOPIC   phone notifications via ntfy: a topic (uses ntfy.sh) or a full URL
      --telegram-token T / --telegram-chat ID   phone notifications via a Telegram bot
      --no-notify-done   only notify on permission-needed and errors, not on completed turns
      --quiet        do not print the QR code
    """)
    exit(2)
}

var port: UInt16 = 7811
var tokenOverride: String?
var claudeOverride: String?
var nameOverride: String?
var quiet = false
var rotate = false
var printPairingOnly = false
var useTLS = true
var relayURLString: String?
var relaySecret: String?
var roomOverride: String?
var relayFingerprint: String?
var ntfyValue: String?
var telegramToken: String?
var telegramChat: String?
var notifyDone = true

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--port": guard let v = args.first.flatMap({ UInt16($0) }) else { usage() }; args.removeFirst(); port = v
    case "--token": guard let v = args.first else { usage() }; args.removeFirst(); tokenOverride = v
    case "--claude": guard let v = args.first else { usage() }; args.removeFirst(); claudeOverride = v
    case "--name": guard let v = args.first else { usage() }; args.removeFirst(); nameOverride = v
    case "--quiet": quiet = true
    case "--rotate-token": rotate = true
    case "--print-pairing": printPairingOnly = true
    case "--no-tls": useTLS = false
    case "--relay": guard let v = args.first else { usage() }; args.removeFirst(); relayURLString = v
    case "--relay-secret": guard let v = args.first else { usage() }; args.removeFirst(); relaySecret = v
    case "--room": guard let v = args.first else { usage() }; args.removeFirst(); roomOverride = v
    case "--relay-fingerprint": guard let v = args.first else { usage() }; args.removeFirst(); relayFingerprint = v
    case "--ntfy": guard let v = args.first else { usage() }; args.removeFirst(); ntfyValue = v
    case "--telegram-token": guard let v = args.first else { usage() }; args.removeFirst(); telegramToken = v
    case "--telegram-chat": guard let v = args.first else { usage() }; args.removeFirst(); telegramChat = v
    case "--no-notify-done": notifyDone = false
    case "-h", "--help": usage()
    default: print("unknown option \(a)"); usage()
    }
}

func log(_ line: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(ts)] \(line)\n".utf8))
}

// MARK: pairing token

let supportDir = NSHomeDirectory() + "/Library/Application Support/ccremote"
let tokenPath = supportDir + "/token"

func loadOrCreateToken() -> String {
    if let t = tokenOverride { return t }
    let fm = FileManager.default
    if !rotate, let data = fm.contents(atPath: tokenPath), let t = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), t.count >= 16 {
        return t
    }
    try? fm.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
    var bytes = [UInt8](repeating: 0, count: 16)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    let t = bytes.map { String(format: "%02x", $0) }.joined()
    fm.createFile(atPath: tokenPath, contents: Data(t.utf8), attributes: [.posixPermissions: 0o600])
    return t
}

// MARK: start

let cli: ClaudeCLI
if let p = claudeOverride {
    cli = ClaudeCLI(path: p)
} else if let found = ClaudeCLI.locate() {
    cli = found
} else {
    log("claude binary not found. Install Claude Code or pass --claude /path/to/claude")
    exit(1)
}

let token = loadOrCreateToken()
let serviceName = nameOverride ?? (Host.current().localizedName ?? "Mac")

// Self-signed TLS identity (wss://). Clients pin its fingerprint from the pairing URL/QR.
var tlsIdentity: TLSIdentity?
if useTLS {
    do {
        tlsIdentity = try TLSIdentity.loadOrCreate(directory: supportDir)
    } catch {
        log("TLS setup failed (\(error)); falling back to plain ws://. Pass --no-tls to silence this.")
        useTLS = false
    }
}
let fingerprint = tlsIdentity?.fingerprint

// Relay: a stable room id per Mac (so the pairing URL stays valid across restarts).
func loadOrCreateRoom() -> String {
    if let r = roomOverride { return r }
    let path = supportDir + "/relay-room"
    let fm = FileManager.default
    if let data = fm.contents(atPath: path), let r = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty {
        return r
    }
    try? fm.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
    var bytes = [UInt8](repeating: 0, count: 8)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    let r = bytes.map { String(format: "%02x", $0) }.joined()
    fm.createFile(atPath: path, contents: Data(r.utf8), attributes: [.posixPermissions: 0o600])
    return r
}

let relayURL = relayURLString.flatMap { URL(string: $0) }
let relayEnabled = relayURL != nil
let room = relayEnabled ? loadOrCreateRoom() : nil

func printPairing() {
    let scheme = useTLS ? "wss" : "ws"
    let addresses = NetworkInfo.lanAddresses()
    let primary = addresses.first?.address ?? "127.0.0.1"
    var components = URLComponents()
    components.scheme = "ccremote"
    components.host = "pair"
    var items = [
        URLQueryItem(name: "host", value: primary),
        URLQueryItem(name: "port", value: String(port)),
        URLQueryItem(name: "token", value: token),
        URLQueryItem(name: "name", value: serviceName),
    ]
    if let fingerprint { items.append(URLQueryItem(name: "fp", value: fingerprint)) }
    if !useTLS { items.append(URLQueryItem(name: "tls", value: "0")) }
    if let relayURLString, let room {
        items.append(URLQueryItem(name: "relay", value: relayURLString))
        items.append(URLQueryItem(name: "room", value: room))
    }
    components.queryItems = items
    let pairURL = components.url!.absoluteString
    print("Bonjour: \(serviceName) (\(WebSocketServer.serviceType)) · port \(port)")
    for a in addresses { print("  \(a.interface): \(scheme)://\(a.address):\(port)") }
    print("Pairing token: \(token)")
    if let fingerprint { print("TLS cert fingerprint (SHA-256): \(fingerprint)") }
    if let relayURLString, let room { print("Relay: \(relayURLString) room \(room)") }
    print("Pair URL: \(pairURL)")
    let pngPath = supportDir + "/pairing-qr.png"
    if QRImage.write(pairURL, to: pngPath) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pngPath)
        print("QR image: \(pngPath)  (open it and scan — reliable even for long URLs)")
    }
    if !quiet, let lines = QRCode.terminalLines(for: pairURL) {
        print("")
        for l in lines { print(l) }
        print("")
    }
    print("Scan the QR in the ClaudeRemote app, or pick this Mac from the list and enter the token.")
    fflush(stdout)
}

if printPairingOnly {
    printPairing()
    exit(0)
}

var notifier: Notifier?
let notifierConfig = NotifierConfig(ntfyURL: ntfyValue.flatMap { NotifierConfig.ntfyURL(from: $0) },
                                    telegramToken: telegramToken, telegramChatID: telegramChat, notifyDone: notifyDone)
if notifierConfig.isEnabled {
    notifier = Notifier(config: notifierConfig, log: { log($0) })
}

let manager = SessionManager(cli: cli, notifier: notifier, log: { log($0) })
SimulatorStreamer.log = { log($0) }
let serverTLS: TLSRole = tlsIdentity.map { .server(identity: $0.identity) } ?? .none
let server = WebSocketServer(port: port, token: token, serviceName: serviceName, manager: manager, daemonVersion: daemonVersion, tls: serverTLS, log: { log($0) })

do {
    try server.start()
} catch {
    log("cannot start server: \(error)")
    exit(1)
}

var relayClient: RelayClient?
if let relayURL, let room {
    guard let relaySecret else {
        log("--relay requires --relay-secret")
        exit(2)
    }
    let client = RelayClient(base: relayURL, room: room, secret: relaySecret, fingerprint: relayFingerprint,
                             manager: manager, token: token, daemonVersion: daemonVersion, log: { log($0) })
    client.start()
    relayClient = client
}

let version = cli.version() ?? "?"
let auth = cli.authStatus()
print("ccremote \(daemonVersion) · claude \(version) at \(cli.path)")
if auth?.loggedIn == true {
    print("claude auth: logged in" + (auth?.email.map { " (\($0))" } ?? ""))
} else {
    print("claude auth: NOT logged in — run:  \"\(cli.path)\" auth login")
}
if notifier != nil {
    var channels: [String] = []
    if notifierConfig.ntfyURL != nil { channels.append("ntfy") }
    if notifierConfig.telegramToken != nil { channels.append("telegram") }
    print("Notifications: \(channels.joined(separator: ", ")) (permission, error\(notifyDone ? ", done" : ""))")
}
printPairing()

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
for source in [sigint, sigterm] {
    source.setEventHandler {
        log("shutting down")
        relayClient?.stop()
        Task {
            await manager.shutdown()
            try? await Task.sleep(nanoseconds: 300_000_000)
            exit(0)
        }
    }
    source.resume()
}

dispatchMain()
