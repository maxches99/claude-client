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

func printPairing() {
    let addresses = NetworkInfo.lanAddresses()
    let primary = addresses.first?.address ?? "127.0.0.1"
    var components = URLComponents()
    components.scheme = "ccremote"
    components.host = "pair"
    components.queryItems = [
        URLQueryItem(name: "host", value: primary),
        URLQueryItem(name: "port", value: String(port)),
        URLQueryItem(name: "token", value: token),
        URLQueryItem(name: "name", value: serviceName),
    ]
    let pairURL = components.url!.absoluteString
    print("Bonjour: \(serviceName) (\(WebSocketServer.serviceType)) · port \(port)")
    for a in addresses { print("  \(a.interface): ws://\(a.address):\(port)") }
    print("Pairing token: \(token)")
    print("Pair URL: \(pairURL)")
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

let manager = SessionManager(cli: cli, log: { log($0) })
let server = WebSocketServer(port: port, token: token, serviceName: serviceName, manager: manager, daemonVersion: daemonVersion, log: { log($0) })

do {
    try server.start()
} catch {
    log("cannot start server: \(error)")
    exit(1)
}

let version = cli.version() ?? "?"
let auth = cli.authStatus()
print("ccremote \(daemonVersion) · claude \(version) at \(cli.path)")
if auth?.loggedIn == true {
    print("claude auth: logged in" + (auth?.email.map { " (\($0))" } ?? ""))
} else {
    print("claude auth: NOT logged in — run:  \"\(cli.path)\" auth login")
}
printPairing()

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
for source in [sigint, sigterm] {
    source.setEventHandler {
        log("shutting down")
        Task {
            await manager.shutdown()
            try? await Task.sleep(nanoseconds: 300_000_000)
            exit(0)
        }
    }
    source.resume()
}

dispatchMain()
