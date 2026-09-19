# ClaudeRemote

Drive the Claude Code sessions on your Mac from your iPhone. Sessions keep running on the
Mac — the phone is a remote: read the transcript live, send prompts, approve or deny tool
permissions, interrupt, switch model / permission mode, and start or resume sessions.

```
┌──────────── Mac ─────────────┐   WebSocket (LAN / Tailscale)   ┌──── iPhone ────┐
│ ccremote (daemon)            │◄───────────────────────────────►│ ClaudeRemote    │
│  ├─ claude CLI processes     │   Bonjour + pairing token       │  SwiftUI app    │
│  │   (stream-json, the same  │                                 └────────────────┘
│  │    channel Claude Desktop │
│  │    and the Agent SDK use) │
│  └─ ~/.claude transcripts    │
└──────────────────────────────┘
```

## Parts

| Path | What |
|---|---|
| `Sources/ClaudeRemoteCore` | Shared package: wire protocol, `JSONValue`, transcript reducer, WebSocket channel (TLS roles) |
| `Sources/ClaudeCodeHost` | Mac-only: `CLIProcess` (stream-json + control protocol), transcript index, live-session registry, `PeerInbox` (write into desktop sessions), `TLSIdentity`, `SessionManager` |
| `Sources/ccremote` | The daemon: `PhoneSession` (one phone connection), `WebSocketServer` (LAN listener + Bonjour), `RelayClient` (dial-out to a relay), pairing token + QR |
| `relay/` | Node relay for reaching the Mac off-network (`relay/README.md`) |
| `ClaudeRemote/` | iOS app (xcodegen project) |
| `Tests/` | Reducer / protocol tests (`swift test`) |

## Setup

1. **Log the CLI in** (one-time). The daemon uses the `claude` binary bundled with Claude
   Desktop (or one on `PATH`). Claude Desktop feeds it credentials itself, so a standalone
   launch is not logged in until you run:

   ```bash
   "$HOME/Library/Application Support/Claude/claude-code/<version>/claude.app/Contents/MacOS/claude" auth login
   ```

   `ccremote` prints the exact path on start if login is still missing.

2. **Run the daemon**:

   ```bash
   swift run ccremote
   ```

   It serves `wss://` (self-signed cert, generated once) and prints the Bonjour name, LAN
   addresses, the pairing token, the cert fingerprint and a QR code. To start it at login
   **and keep the Mac awake while it runs** (so it stays reachable): `scripts/install-launchagent.sh`
   — it wraps the daemon in `caffeinate -s` and prints the pairing again (`ccremote --print-pairing`
   reprints it any time).

3. **Build the app**: `cd ClaudeRemote && xcodegen generate && open ClaudeRemote.xcodeproj`,
   set your team, run on the phone. On first launch pick the Mac from the Bonjour list and
   enter the token, or scan the QR.

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
First make sure the Mac stays reachable: it must not sleep. `scripts/install-launchagent.sh` runs
the daemon under `caffeinate -s` (no-sleep on AC while it runs); or set `sudo pmset -c sleep 0`.

Then pick a route to reach it:

* **Same Wi-Fi / LAN** — pick the Mac from the list, or use `wss://<ip>:7811`.
* **Mesh VPN — Tailscale / WireGuard (simplest, no relay, no extra code):** put both on the same
  VPN and pair by the Mac's VPN name, e.g. `wss://mac.tail-net.ts.net:7811`. The tunnel carries the
  traffic; nothing is exposed to the internet. Type the host on the pairing screen, or
  `ccremote --name mac.tail-net.ts.net --print-pairing` for a QR.
* **Relay you run (no VPN client on the phone):** run a small relay on a VPS and start the daemon
  with `--relay wss://vps --relay-secret …`. The Mac dials out (NAT-friendly); the phone reaches
  the relay. See [`relay/README.md`](relay/README.md).
* **Not recommended:** forwarding port 7811 on the router — CGNAT often breaks it and it exposes the
  daemon directly.

## Options

```
ccremote [--port 7811] [--token …] [--claude /path/to/claude] [--name "Bonjour name"]
         [--rotate-token] [--print-pairing] [--quiet] [--no-tls]
         [--relay wss://vps] [--relay-secret S] [--room R] [--relay-fingerprint FP]
```

`CCREMOTE_CLAUDE_PATH` also overrides the binary.

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
