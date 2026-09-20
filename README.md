# ClaudeRemote

Drive the Claude Code — and Codex — sessions on your Mac from your iPhone. Sessions keep running
on the Mac — the phone is a remote: read the transcript live, send prompts, approve or deny tool
permissions, interrupt, switch model / permission mode, and start or resume sessions.

```
┌──────────────── Mac ─────────────────┐   WebSocket (LAN / relay / VPN)   ┌──── iPhone ────┐
│ ClaudeRemote Host (menu-bar app)     │◄─────────────────────────────────►│ ClaudeRemote    │
│  = the ccremote daemon + status + QR │   Bonjour + pairing token         │  SwiftUI app    │
│  ├─ claude CLI processes             │                                   └────────────────┘
│  │   (stream-json, the same channel  │
│  │    Claude Desktop / Agent SDK use)│
│  ├─ codex app-server (JSON-RPC, the  │
│  │    channel the Codex app uses)    │
│  └─ ~/.claude transcripts, ~/.codex  │
└──────────────────────────────────────┘
```

## Parts

| Path | What |
|---|---|
| `Sources/ClaudeRemoteCore` | Shared package: wire protocol, `JSONValue`, transcript reducer, `CodexTranslator` / `CodexRollout` (Codex events and session files → the same reducer), WebSocket channel (TLS roles) |
| `Sources/ClaudeCodeHost` | Mac-only: `CLIProcess` (stream-json + control protocol), `CodexAppServer` + `CodexBackend` (Codex threads over JSON-RPC), transcript index, live-session registry, `PeerInbox` (write into desktop sessions), `TLSIdentity`, `SessionManager` |
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

The app has two tabs: **Sessions** (work in a project) and **Chats**. Claude is clay-coloured
throughout, Codex blue, so a glance at a row or a chat says which agent it belongs to.

* **Chats** — a quick question that has nothing to do with a codebase: "New chat" starts the agent
  with **no tools at all** (`--tools ""` for Claude, a read-only sandbox with nothing to approve for
  Codex), its own system prompt, and none of your CLAUDE.md / project settings. They run in a scratch
  directory (`~/Library/Application Support/ccremote/chats`) which is what marks them as chats, so they
  keep their own section in the list, stay out of the project picker, and can be reopened later like
  any other session. Claude chats default to Sonnet for speed; the model chip still switches it.

### Codex

If the Codex CLI is on the Mac — on `PATH`, or bundled inside the Codex desktop app — the
session list also shows Codex threads (badge "Codex") and "New session" offers an agent picker.
The daemon runs one `codex app-server` (the JSON-RPC channel the Codex app and IDE extension
use) and hosts threads in it: start, resume, fork, prompt with images, interrupt. Codex's
approval requests (commands, file changes, extra permissions) show up as the same permission
cards as Claude's; instead of a permission mode you pick an **approval policy** (ask when
needed / ask for untrusted commands / never), a **sandbox** (workspace write / read only / full
access) and the **reasoning effort** of the model — all changeable per session from the
composer chips, applied to the next turn. Login is shared with the Codex app (`~/.codex/auth.json`),
so nothing to log in.

A session **open in the Codex app right now** shows up as "Codex app" and is mirrored live: the
daemon reads Codex's own session file (`~/.codex/sessions/…/rollout-*.jsonl`, which carries the
messages, reasoning and tool calls that `thread/read` leaves out for a thread it does not host) and
tails it. Codex marks such a thread with a held `flock` on `~/.codex/thread-writer-locks/<id>.lock`,
which is how "open somewhere else" is told apart from "closed" — and when it is closed there, the
session turns into an ordinary one the phone can resume. It cannot be driven from the phone, but a
message you send is handed to `codex queue`, so the session picks it up in the app. Closed threads
open the normal way (resume), or "Continue a copy on the phone" forks them.

## Git from the phone

The branch icon in a session opens the repo: current branch (switch or create one from the menu),
ahead/behind counts, Pull / Push (Publish sets the upstream), staged / unstaged / untracked files with
a per-file diff, stage / unstage / discard by swipe, and a commit box (staged only, or `commit -a`).
Actions run `git` on the Mac in the session's directory with `GIT_TERMINAL_PROMPT=0`, so a push that
needs a password fails fast instead of hanging — use the keychain helper or an SSH key with an agent.
While the agent is mid-turn in that repo, actions are refused so the phone doesn't race its edits.

## Find, share, dictate

* **Find in transcript** (session menu) — matches prompts, replies, thinking and tool calls/results;
  ↑/↓ walk the hits and unfold the step they live in.
* **Share transcript…** exports the whole session as Markdown (prompts and replies in full, tool
  work folded into `<details>` blocks); **Copy last reply** is one tap. Long-press any message for
  Copy / Share / Quote in reply.
* **Dictation** — tap the mic and talk; the text streams into the composer as you speak (on-device
  recognition when the language supports it). Hold the mic for the older voice-memo attachment.

## Live Activity / Dynamic Island

A session started from the phone (and any session you have open) shows up as a Live Activity while it
works: what the agent is doing right now, a turn timer, and — when it stops to ask — **Deny** and
**Allow** right on the lock screen or in the Dynamic Island. With "Require Face ID to approve" on,
Allow opens the app on the session instead of approving inline. A finished turn stays as "Done" for
a quarter of an hour, then goes away. Tapping the activity deep-links into the session.

iOS closes the app's socket ~30 s after it leaves the foreground, so by default the activity stops
updating once you are elsewhere for a while. To keep it live, give the Mac an APNs auth key
(Host app → Settings → Live Activity push; or `--apns-key … --apns-key-id … --apns-team …`): the
daemon then pushes every state change straight to the activity, and the Deny button still goes
through the app (iOS wakes it in the background to run the intent). The key is an `AuthKey_*.p8`
from the developer portal (Keys → +, tick APNs); Xcode builds use the sandbox gateway (the default),
TestFlight / App Store builds need `--apns-production`.

## iPad and Mac

On an iPad (and as a Mac Catalyst app) the session list is a sidebar and the chat fills the rest.
Pair the iPad / Mac with **Paste pairing link** on the pairing screen — "Copy link" in the Host app's
menu puts the same URL the QR carries on the clipboard. The Catalyst build has no QR scanner, Watch
app or Live Activities.

## Images and files

Inline images in the transcript (pasted images, screenshots returned by tools) render in the
chat. Files delivered by a `SendUserFile` tool call are fetched from the Mac on demand (≤ 12 MB):
images show inline; anything else is a chip that opens a viewer — Markdown rendered like a reply,
text and code monospaced, PDFs paged — with Copy and a share button that hands the bytes over as a
real file, so "Save to Files", AirDrop or "Open in…" keep the name and type.

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
ccremote [--port 7811] [--token …] [--claude /path/to/claude] [--codex /path/to/codex] [--name "Bonjour name"]
         [--rotate-token] [--print-pairing] [--quiet] [--no-tls]
         [--relay wss://vps | --no-relay] [--relay-secret S] [--room R] [--relay-fingerprint FP]
         [--ntfy TOPIC] [--telegram-token T --telegram-chat ID] [--no-notify-done]
         [--apns-key PATH --apns-key-id ID --apns-team TEAM] [--apns-bundle ID] [--apns-production]
```

Running a second daemon for development next to the Host app? Use another port **and** `--no-relay`
(or `--room`): two daemons registering the same relay room keep kicking each other out of it.

`CCREMOTE_CLAUDE_PATH` / `CCREMOTE_CODEX_PATH` also override the binaries. Other files in the support dir: `token`,
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

`CodexBackend` speaks the `codex app-server` v2 JSON-RPC protocol, marked experimental by
OpenAI. Its schema is generated by the CLI itself — `codex app-server generate-json-schema --out DIR`
— so when Codex updates, diff that against the methods used in `CodexBackend.swift` and the
item shapes in `CodexTranslator.swift`.
