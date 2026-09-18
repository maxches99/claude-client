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
| `Sources/ClaudeRemoteCore` | Shared package: wire protocol, `JSONValue`, transcript reducer, WebSocket channel |
| `Sources/ClaudeCodeHost` | Mac-only: `CLIProcess` (stream-json + control protocol), transcript index, live-session registry, `SessionManager` |
| `Sources/ccremote` | The daemon: WebSocket server, Bonjour, pairing token + QR |
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

   It prints the Bonjour name, LAN addresses, the pairing token and a QR code. To start it
   at login instead: `scripts/install-launchagent.sh` (then `ccremote --print-pairing`
   shows the QR again).

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

## Remote access (off Wi-Fi)

Bonjour discovery is LAN-only, but the connection is a plain WebSocket to a host:port, and the
pairing screen accepts any hostname — so anything that gives the phone a route to the Mac works:

* **Same Wi-Fi / LAN** — pick the Mac from the list, or use its `ws://<ip>:7811`.
* **Anywhere (recommended): Tailscale / WireGuard** — install it on both, then pair by the
  Mac's tailnet name, e.g. host `mac.tail-net.ts.net`, port `7811`, and the token. The mesh
  VPN carries the traffic; nothing is exposed to the internet. Generate a QR for it with
  `ccremote --name mac.tail-net.ts.net --print-pairing` after setting the host, or just type
  the host on the pairing screen.
* **Not recommended:** forwarding port 7811 on your router — the transport is plain `ws://`,
  so only do this behind TLS/a tunnel. TLS is a planned follow-up.

## Options

```
ccremote [--port 7811] [--token …] [--claude /path/to/claude] [--name "Bonjour name"]
         [--rotate-token] [--print-pairing] [--quiet]
```

`CCREMOTE_CLAUDE_PATH` also overrides the binary.

## Security notes

* The token is the only authentication; keep the pair URL private. `--rotate-token`
  invalidates old pairings.
* Traffic is plain `ws://`. Use it on a trusted LAN or over Tailscale / WireGuard (the app
  accepts any host name, e.g. `mac.tail-net.ts.net`). TLS pinning is a planned follow-up.
* Anything the phone approves runs on the Mac with your user's permissions — same as
  approving it in Claude Desktop.

## Protocol drift

`CLIProcess` speaks the `--input-format stream-json` / `--permission-prompt-tool stdio`
protocol. It is what Claude Desktop and `@anthropic-ai/claude-agent-sdk` use, but it is not
a public API; when the CLI updates, check `SessionManager.handleControlRequest` and the
message shapes in `Transcript.swift` against the SDK's `sdk.mjs`.
