# ClaudeRemote

Drive the Claude Code sessions on your Mac from your iPhone. Sessions keep running on the
Mac — the phone is a remote: read the transcript live, send prompts, approve or deny tool
permissions, interrupt, switch model / permission mode, and start or resume sessions.

```
┌──────────────── Mac ─────────────────┐   WebSocket (LAN / relay / VPN)   ┌──── iPhone ────┐
│ ClaudeRemote Host (menu-bar app)     │◄─────────────────────────────────►│ ClaudeRemote    │
│  = the ccremote daemon + status + QR │   Bonjour + pairing token         │  SwiftUI app    │
│  ├─ claude CLI processes             │                                   └────────────────┘
│  │   (stream-json, the same channel  │
│  │    Claude Desktop / Agent SDK use)│
│  └─ ~/.claude transcripts            │
└──────────────────────────────────────┘
```

## Parts

| Path | What |
|---|---|
| `Sources/ClaudeRemoteCore` | Shared package: wire protocol, `JSONValue`, transcript reducer, WebSocket channel (TLS roles) |
| `Sources/ClaudeCodeHost` | Mac-only: `CLIProcess` (stream-json + control protocol), transcript index, live-session registry, `PeerInbox` (write into desktop sessions), `TLSIdentity`, `SessionManager` |
| `Sources/ClaudeRemoteDaemon` | The daemon as a library: `Daemon` (config → listener + Bonjour, relay dial-out, notifier, phone tracking, status), `DaemonConfig` (`config.json`), `PhoneSession`, `WebSocketServer`, `RelayClient`, `DeviceRegistry`, pairing URL + QR |
| `Sources/ccremote` | Thin CLI front-end for the daemon (flags, terminal QR) |
| `ClaudeRemoteHost/` | **Mac menu-bar app** hosting the daemon: status, paired phones, QR, settings, open-at-login, keep-awake (xcodegen project) |
| `relay/` | Node relay for reaching the Mac off-network (`relay/README.md`) |
| `ClaudeRemote/` | iOS app (xcodegen project) |
| `Tests/` | Reducer / protocol tests (`swift test`) |

## Setup

### Mac — ClaudeRemote Host (recommended)

One app, drag to /Applications, done. It **is** the daemon: a phone icon in the menu bar shows
whether the Mac is listening, which phones are paired / connected right now (and how — Wi‑Fi or
relay), the pairing QR, and the Claude CLI login. The first launch opens a pairing window with a
big QR to scan.

```bash
scripts/build-mac-app.sh --install      # builds dist/ClaudeRemote Host.app (+ zip), installs, launches
```

Or open `ClaudeRemoteHost/ClaudeRemoteHost.xcodeproj` (after `cd ClaudeRemoteHost && xcodegen generate`)
and run it from Xcode. To put it on **another Mac**: copy `dist/ClaudeRemote-Host.zip` over, unzip,
drag to Applications, open. The build is ad-hoc signed unless you export `TEAM_ID` (see the script),
so Gatekeeper may ask once — right-click → Open, or allow it under System Settings › Privacy & Security.
The app installs nothing else: no LaunchAgent, no scripts; "Open at login" is a normal Login Item.

From the menu-bar panel:

* **Phones** — connected phones live (route + since), paired-but-away phones with "last seen".
* **QR / Copy link / Open pairing…** — the pairing URL carries the LAN address, cert fingerprint and
  (if set) the relay route. "New token…" in the pairing window invalidates every pairing.
* **Claude CLI** — version and login; "Log in…" runs `claude auth login` in Terminal for you
  (Claude Desktop feeds its bundled CLI credentials itself, so a standalone launch needs this once).
* **Open at login**, **Keep Mac awake while on power** (an IOKit assertion, like `caffeinate -s`).
* **Settings…** — relay URL/secret, notifications (ntfy / Telegram), port, name, CLI path. Saved to
  `~/Library/Application Support/ccremote/config.json`; applying restarts the daemon.
* **Log** — the live daemon log (also `~/Library/Logs/ccremote.log`).

If the old `install-launchagent.sh` daemon is still installed on that Mac, the app notices (it holds
the port), imports its flags into `config.json` and offers **Switch to the app**, which unloads the
LaunchAgent. Token, TLS cert and relay room live in the same support directory, so existing
pairings keep working.

### Mac — headless CLI (alternative)

The same daemon without the UI, e.g. on a Mac mini you only SSH into:

```bash
swift run ccremote                       # reads config.json; flags override
scripts/install-launchagent.sh [flags]   # LaunchAgent under caffeinate -s (the pre-app way)
```

`ccremote --print-pairing` reprints the pairing URL/QR (and writes `pairing-qr.png`) any time.

### Claude CLI login

The daemon uses the `claude` binary bundled with Claude Desktop (or one on `PATH`). If the panel
says "Not logged in", click **Log in…** — or run it yourself:

```bash
"$HOME/Library/Application Support/Claude/claude-code/<version>/claude.app/Contents/MacOS/claude" auth login
```

### iPhone

`cd ClaudeRemote && xcodegen generate && open ClaudeRemote.xcodeproj`, set your team, run on the
phone. On first launch scan the QR from the Mac (menu-bar panel or pairing window), or pick the Mac
from the Bonjour list and enter the token.

## Sessions

* **Phone** — started or resumed from the app; a `claude -p` process owned by the daemon.
  Full control: clean user prompts, permission approvals, interrupt, model / mode.
* **Desktop / Terminal** — currently open on the Mac (from `~/.claude/sessions`). Followed
  live by tailing the transcript. You can **write to them from the phone**: the prompt is
  delivered through the running process's messaging inbox (the same Unix-socket channel
  sessions use to message each other). Because that channel is peer-to-peer, the Mac shows
  your prompt as coming from another session — Claude still acts on it, but for a clean
  user-role thread use "Continue a copy on the phone", which forks it
  (`--resume --fork-session`) into a Phone session with the full history. Permission prompts
  for a Desktop session are still answered on the Mac.
* **Recent** — transcripts on disk. Opening one resumes it under the daemon.

## Images

Inline images in the transcript (pasted images, screenshots returned by tools) render in the
chat. Files delivered by a `SendUserFile` tool call are fetched from the Mac on demand and
shown inline when they are images (≤ 12 MB); other files show their path to open on the Mac.

## Simulator live view

When an iOS Simulator is booted on the Mac (e.g. the agent is driving your app in it), a phone
icon appears in the toolbar. It opens a live view of the simulator's screen: the daemon captures
frames with `xcrun simctl io <udid> screenshot`, downscales them (≤ 1000 px, JPEG) and streams
them over the same WebSocket at up to 3–4 fps — only while the view is open, and only frames
that changed (a static screen costs nothing but a heartbeat). Several booted simulators can be
switched from the view's menu. Frames are view-only for now; the agent's own screenshots still
land in the transcript as before.

## Remote access (off Wi-Fi)

Bonjour discovery is LAN-only, but the pairing URL/QR carries a direct address **and** an optional
relay route; the app tries direct first, then the relay — so one pairing works at home and away.
First make sure the Mac stays reachable: it must not sleep. The Host app's **Keep Mac awake while on
power** does that (an idle-sleep assertion while on AC, like `caffeinate -s`, which the LaunchAgent
script uses); or set `sudo pmset -c sleep 0`.

Then pick a route to reach it:

* **Same Wi-Fi / LAN** — pick the Mac from the list, or use `wss://<ip>:7811`.
* **Mesh VPN — Tailscale / WireGuard (simplest, no relay, no extra code):** put both on the same
  VPN and pair by the Mac's VPN name, e.g. `wss://mac.tail-net.ts.net:7811`. The tunnel carries the
  traffic; nothing is exposed to the internet. Type the host on the pairing screen, or
  `ccremote --name mac.tail-net.ts.net --print-pairing` for a QR.
* **Relay you run (no VPN client on the phone):** run a small relay on a VPS and point the Mac at it
  (Host app → Settings → Remote access, or `--relay wss://vps --relay-secret …`). The Mac dials out
  (NAT-friendly); the phone reaches the relay. See [`relay/README.md`](relay/README.md).
* **Not recommended:** forwarding port 7811 on the router — CGNAT often breaks it and it exposes the
  daemon directly.

## Options

Everything lives in `~/Library/Application Support/ccremote/config.json` (edited by the Host app's
Settings). The CLI reads it too; flags override it for one run:

```
ccremote [--port 7811] [--token …] [--claude /path/to/claude] [--name "Bonjour name"]
         [--rotate-token] [--print-pairing] [--quiet] [--no-tls]
         [--relay wss://vps | --no-relay] [--relay-secret S] [--room R] [--relay-fingerprint FP]
         [--ntfy TOPIC] [--telegram-token T --telegram-chat ID] [--no-notify-done]
```

Running a second daemon for development next to the Host app? Use another port **and** `--no-relay`
(or `--room`): two daemons registering the same relay room keep kicking each other out of it.

`CCREMOTE_CLAUDE_PATH` also overrides the binary. Other files in the support dir: `token`,
`tls-identity.p12` (+ pem), `relay-room`, `devices.json` (paired phones), `pairing-qr.png`.

## Security notes

* **Transport is `wss://` by default.** The daemon mints a self-signed cert (once, in the support
  dir) and publishes its SHA-256 fingerprint in the pairing URL/QR; the app **pins** it. Pairing
  without a fingerprint (manual host + token) trusts the cert on first use and pins it thereafter.
  `--no-tls` falls back to plain `ws://` for LAN debugging only.
* The pairing **token** authenticates the phone to the daemon end-to-end — including through a relay,
  which only forwards frames. Keep the pair URL private; `--rotate-token` invalidates old pairings.
* A **relay can read the traffic it forwards** (the token gates the daemon, but the bytes pass through
  it in the clear), so run the relay on a host you control. A mesh VPN avoids this entirely.
* Anything the phone approves runs on the Mac with your user's permissions — same as approving it in
  Claude Desktop. Prefer a private transport (VPN, or your own relay) over exposing the daemon.

## Protocol drift

`CLIProcess` speaks the `--input-format stream-json` / `--permission-prompt-tool stdio`
protocol. It is what Claude Desktop and `@anthropic-ai/claude-agent-sdk` use, but it is not
a public API; when the CLI updates, check `SessionManager.handleControlRequest` and the
message shapes in `Transcript.swift` against the SDK's `sdk.mjs`.
