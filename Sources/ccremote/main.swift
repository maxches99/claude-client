import Foundation
import ClaudeRemoteCore
import ClaudeCodeHost
import ClaudeRemoteDaemon

func usage() -> Never {
    print("""
    ccremote — drive local Claude Code sessions from your phone.

    Usage: ccremote [--port N] [--token TOKEN] [--claude PATH] [--name NAME] [--quiet]

    Settings are read from \(DaemonConfig.path) (written by the ClaudeRemote Host app);
    flags override them for this run.

      --port N       TCP port to listen on (default 7811)
      --token TOKEN  pairing token (default: generated once, stored in the support dir)
      --claude PATH  path to the claude binary (default: Claude Desktop's bundled CLI, else PATH)
      --codex PATH   path to the codex binary (default: PATH, else the Codex app's bundled CLI)
      --name NAME    Bonjour service name (default: this Mac's name)
      --rotate-token generate a new pairing token (forgets paired phones)
      --print-pairing print the pairing QR / URL and exit
      --no-tls       serve plain ws:// instead of wss:// (LAN debugging only)
      --relay URL    also reach phones through a relay you run, e.g. wss://vps.example.com
      --no-relay     ignore the relay from config.json (a test daemon must not take over the real Mac's relay room)
      --relay-secret S   shared secret the daemon presents to the relay's /agent endpoint
      --room R       relay room id (default: stable per-Mac id in the support dir)
      --relay-fingerprint FP   pin the relay's TLS cert (SHA-256 hex) instead of system trust
      --ntfy TOPIC   phone notifications via ntfy: a topic (uses ntfy.sh) or a full URL
      --telegram-token T / --telegram-chat ID   phone notifications via a Telegram bot
      --no-notify-done   only notify on permission-needed and errors, not on completed turns
      --apns-key PATH / --apns-key-id ID / --apns-team TEAM   push Live Activity updates to the phone (APNs auth key)
      --apns-bundle ID   the iOS app's bundle id (default dev.maxches.ClaudeRemote)
      --apns-production  use the production APNs gateway (default: sandbox, for Xcode builds)
      --quiet        do not print the QR code
    """)
    exit(2)
}

@Sendable func log(_ line: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(ts)] \(line)\n".utf8))
}

// Developer check of the simulator input path: `ccremote --sim-input <udid> '{"tap":{"x":0.5,"y":0.5}}'`.
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--sim-input" {
    let udid = CommandLine.arguments[2]
    do {
        let event = try ProtocolCoding.decode(SimulatorInputEvent.self, from: CommandLine.arguments[3])
        try await injectSimulatorInput(event, udid: udid, log: log)
        exit(0)
    } catch {
        log("\(error.localizedDescription)")
        exit(1)
    }
}

let arguments: DaemonArguments
do {
    arguments = try DaemonArguments.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    print("\(error)")
    usage()
}
if arguments.help { usage() }

let daemon: Daemon
do {
    daemon = try Daemon(config: arguments.config, tokenOverride: arguments.tokenOverride, rotateToken: arguments.rotateToken, log: log)
} catch {
    log("\(error)")
    exit(1)
}

func printPairing() {
    let status = daemon.status
    let pairing = status.pairing
    print("Bonjour: \(daemon.serviceName) (_ccremote._tcp) · port \(pairing.port)")
    for a in status.addresses { print("  \(a.interface): \(pairing.scheme)://\(a.address):\(pairing.port)") }
    print("Pairing token: \(pairing.token)")
    if let fp = pairing.fingerprint { print("TLS cert fingerprint (SHA-256): \(fp)") }
    if let relay = pairing.relayURL, let room = pairing.room { print("Relay: \(relay) room \(room)") }
    print("Pair URL: \(pairing.absoluteString)")
    if daemon.writePairingImage() {
        print("QR image: \(daemon.pairingImagePath)  (open it and scan — reliable even for long URLs)")
    }
    if !arguments.quiet, let lines = QRCode.terminalLines(for: pairing.absoluteString) {
        print("")
        for l in lines { print(l) }
        print("")
    }
    print("Scan the QR in the ClaudeRemote app, or pick this Mac from the list and enter the token.")
    fflush(stdout)
}

if arguments.printPairingOnly {
    printPairing()
    exit(0)
}

do {
    try daemon.start()
} catch {
    log("cannot start server: \(error)")
    exit(1)
}

let version = daemon.cli.version() ?? "?"
let auth = daemon.cli.authStatus()
print("ccremote \(Daemon.version) · claude \(version) at \(daemon.cli.path)")
if auth?.loggedIn == true {
    print("claude auth: logged in" + (auth?.email.map { " (\($0))" } ?? ""))
} else {
    print("claude auth: NOT logged in — run:  \(daemon.loginCommand)")
}
if let codex = daemon.codex {
    print("codex \(codex.version() ?? "?") at \(codex.path)" + (CodexCLI.hasCredentials() ? "" : " — not logged in (run `codex login`)"))
}
let channels = daemon.notificationChannels
if !channels.isEmpty {
    print("Notifications: \(channels.joined(separator: ", ")) (permission, error\(daemon.config.notifyDone ? ", done" : ""))")
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
            await daemon.stop()
            try? await Task.sleep(nanoseconds: 300_000_000)
            exit(0)
        }
    }
    source.resume()
}

dispatchMain()
