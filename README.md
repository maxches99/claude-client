# ClaudeRemote

[![CI](https://github.com/maxches99/claude-client/actions/workflows/ci.yml/badge.svg)](https://github.com/maxches99/claude-client/actions/workflows/ci.yml)

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
| `Sources/ClaudeRemoteCore` | Shared package: wire protocol, `JSONValue`, transcript reducer, `CodexTranslator` / `CodexRollout` (Codex events and session files → the same reducer), WebSocket channel (TLS roles), the queue / palette / worktree / turn-review models |
| `Sources/ClaudeCodeHost` | Mac-only: `CLIProcess` (stream-json + control protocol), `CodexAppServer` + `CodexBackend` (Codex threads over JSON-RPC), transcript index, live-session registry, `PeerInbox` (write into desktop sessions), `ClaudeHooks` (the PermissionRequest hook in settings.json), `TLSIdentity`, `SessionManager` and its feature files (`…Rewind`, `…Palette`, `…Worktrees`, `…Tasks`, `BackgroundProcesses`) |
| `Sources/ClaudeRemoteDaemon` | The daemon as a library: `Daemon` (config → listener + Bonjour, relay dial-out, notifier, phone tracking, status), `DaemonConfig` (`config.json`), `PhoneSession`, `WebSocketServer`, `HookServer` (hook socket), `RelayClient`, `DeviceRegistry`, pairing URL + QR |
| `Sources/ccremote` | Thin CLI front-end for the daemon (flags, terminal QR) |
| `ClaudeRemoteHost/` | **Mac menu-bar app** hosting the daemon: status, paired phones, QR, settings, open-at-login, keep-awake (Tuist project) |
| `relay/` | Node relay for reaching the Mac off-network (`relay/README.md`) |
| `ClaudeRemote/` | iOS app + widget, watchOS app + complication (Tuist project) |
| `Tests/` | Reducer / protocol tests (`swift test`) |
| `Tuist.swift`, `Workspace.swift`, `Tuist/` | Tuist config: `tuist generate` writes `ClaudeRemote.xcworkspace` with both app projects; your Apple team goes into the untracked `Tuist/team.xcconfig` |

## Setup

### Mac — ClaudeRemote Host (recommended)

One app, drag to /Applications, done. It **is** the daemon: a phone icon in the menu bar shows
whether the Mac is listening, which phones are paired / connected right now (and how — Wi‑Fi or
relay), the pairing QR, and the Claude CLI login. The first launch opens a pairing window with a
big QR to scan.

```bash
brew install --cask maxches99/tap/claude-remote-host   # later: brew upgrade
```

The cask points at the newest [GitHub Release](https://github.com/maxches99/claude-client/releases) and
clears the quarantine flag itself, so the ad-hoc-signed app opens without the Gatekeeper dance. Without
Homebrew: download `ClaudeRemote-Host.zip` from the release, unzip, run
`xattr -dr com.apple.quarantine "ClaudeRemote Host.app"`, drag to Applications. Or build it yourself:

```bash
scripts/build-mac-app.sh --install      # builds dist/ClaudeRemote Host.app (+ zip), installs, launches
```

Or `tuist generate` (`brew install tuist`) and run the `ClaudeRemoteHost` scheme from Xcode. The build is
ad-hoc signed unless you export `TEAM_ID` (see the script); one side effect of that is macOS forgetting
per-app permissions (notifications, local network, Automation) after an update — it asks again.
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

No App Store build yet (no paid developer account), so the app is sideloaded and re-signed with your
own Apple ID. Two ways:

**SideStore / AltStore (updates by themselves).** Install [SideStore](https://sidestore.io) (refreshes
the 7-day signature on the phone itself, no computer afterwards) or [AltStore](https://altstore.io)
(AltServer on the Mac does the refreshing over Wi-Fi — the Mac running the host is a natural fit). Then
add this source and install ClaudeRemote from it:

```
https://github.com/maxches99/claude-client/releases/latest/download/altstore.json
```

The URL always redirects to the newest release, so new versions show up under Updates. A free Personal
Team allows 3 sideloaded apps at once (the store itself is one) and 10 App IDs a week — the app plus
its widget are two; the Watch app is not in the .ipa (sideloaders can't install watchOS apps).
[Sideloadly](https://sideloadly.io) with `ClaudeRemote.ipa` from the release works too, no source needed.

**Xcode.** `cp Tuist/team.xcconfig.example Tuist/team.xcconfig`, put your Apple team ID in it (once — the
file is untracked), then `tuist generate` opens `ClaudeRemote.xcworkspace` with the team already set;
run the `ClaudeRemote` scheme on the phone. With a free team the build expires after 7 days; run again.
This is the only way to get the Watch app on.

On first launch scan the QR from the Mac (menu-bar panel or pairing window), or pick the Mac from the
Bonjour list and enter the token.

## Sessions

* **Phone** — started or resumed from the app; a `claude -p` process owned by the daemon.
  Full control: clean user prompts, permission approvals, interrupt, model / mode.
* **Desktop / Terminal** — currently open on the Mac (from `~/.claude/sessions`). Followed
  live by tailing the transcript. You can **write to them from the phone**: the prompt is
  delivered through the running process's messaging inbox (the same Unix-socket channel
  sessions use to message each other). Because that channel is peer-to-peer, the Mac shows
  your prompt as coming from another session — Claude still acts on it, but for a clean
  user-role thread use "Continue a copy on the phone", which forks it
  (`--resume --fork-session`) into a Phone session with the full history. Their permission
  prompts can come to the phone too — see "Approving Desktop and terminal sessions" below.
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

### Sharing the app-server with the Codex app

The Codex app normally runs a private `codex app-server` over stdio, which is why a session open in
the app can only be mirrored (below). Give the daemon a port instead — Host app → Settings →
"Shared Codex app-server port" (or `--codex-port 4141`) — and it runs `codex app-server --listen
ws://127.0.0.1:<port>` and talks to it as a WebSocket client. Point the Codex app at the same server
("Point the Codex app here", which sets launchd's `CODEX_APP_SERVER_WS_URL` for apps launched from
then on; quit and reopen the Codex app). Now a thread open in the app is just another thread on
that server: opening it from the phone resumes it there, which subscribes the phone to its live
events — including approval requests, which either side can answer — and lets it prompt and
interrupt. The server outlives daemon restarts when something else started it; the app reconnects to
it on its own.

Without a shared server, a session **open in the Codex app right now** shows up as "Codex app" and is mirrored live: the
daemon reads Codex's own session file (`~/.codex/sessions/…/rollout-*.jsonl`, which carries the
messages, reasoning and tool calls that `thread/read` leaves out for a thread it does not host) and
tails it. Codex marks such a thread with a held `flock` on `~/.codex/thread-writer-locks/<id>.lock`,
which is how "open somewhere else" is told apart from "closed" — and when it is closed there, the
session turns into an ordinary one the phone can resume. It cannot be driven from the phone, but a
message you send is handed to `codex queue`, so the session picks it up in the app. Closed threads
open the normal way (resume), or "Continue a copy on the phone" forks them.

## Questions, plans, and the queue

* **Questions** — when the agent asks something (`AskUserQuestion`), the card above the composer
  is the form: the options as chips (one or several per question), "Other…" for a typed answer,
  one question at a time with Next / Send answers; "Expand" opens all of them in a sheet with
  room for notes. The answers go back through the same permission reply, as the CLI's own
  dialog would send them. Answering needs no Face ID — nothing runs yet.
* **Plans** — `ExitPlanMode` shows as "Plan ready for review": a glimpse in the card, Review to
  read the plan rendered like a reply (and share it), then Approve, "Approve & accept edits"
  when the CLI suggests switching mode, or Request changes with a note — which is sent back as
  the rejection reason, so the agent revises the plan.
* **Queue** — sending while the agent is mid-turn does not interrupt it: the prompt waits in a
  strip above the composer ("Queued · goes out when this turn ends") and is sent, in order, as
  soon as the turn finishes. The × pulls one back. Works for Claude and Codex sessions the phone
  hosts; a Desktop session's inbox already queues on its own.

## Rewinding, and undoing one turn

Two separate takebacks, deliberately kept apart — one is about what the agent *knows*, the other about
what it *wrote*.

* **Rewind to here** (long-press a prompt in the transcript) copies the conversation up to just before
  that prompt into a new session on the Mac and opens it, so you can ask again differently. The
  original session is untouched and stays in the list; the copy says how much was left behind. Claude
  sessions only — a Codex thread cannot be cut this way yet.
* **Changes by turn…** (session menu) reads the transcript and lists, newest first, every turn that
  wrote a file: which files, which commands it ran, the diff of each file, and **Undo this turn's file
  changes** — `git checkout --` for exactly those paths. It takes the files back to the last commit,
  so anything uncommitted in them goes, including edits made after that turn; the conversation is not
  touched (rewind it too if you want the agent to forget as well).

## The approvals inbox

The bell in the session list opens everything waiting on you — across sessions, chats, projects **and
every paired Mac** — oldest first. Swipe a row to allow or deny it on the spot, tap it for the full
request (the same sheet the session shows, so questions and plan reviews work there too), or open the
session it belongs to. A request from another Mac is answered on that Mac's own connection; nothing
switches over behind your back.

## Approving Desktop and terminal sessions

Sessions the Mac runs itself — Claude Desktop, `claude` in a terminal, an SDK script — cannot
be driven over stdin, but their permission prompts can still be answered from the phone. Turn on
**Host app → Settings → "Ask the phone before prompting on the Mac"** (or `ccremote
--install-hook`). That adds a `PermissionRequest` hook to `~/.claude/settings.json`: before the
CLI shows its dialog it POSTs the request over the daemon's Unix socket
(`~/Library/Application Support/ccremote/hook.sock`); the daemon shows it on every connected
phone as the usual permission card (with Allow / Deny / "Allow & don't ask again", the question
form, or the plan review), and the hook's answer is the decision. Nothing is answered on the Mac
meanwhile — its dialog only appears if no phone answers within ten minutes, or at once when no
phone is connected (the socket answers empty and the CLI prompts as usual). Hooks are read when a
session starts, so sessions already open keep prompting on the Mac until restarted; without the
daemon running the hook exits quietly. `--uninstall-hook` (or the toggle) removes it.

## Files, search, commands

* **Browse files…** (session menu) opens the project: folders and files, a search field that greps
  file contents on the Mac (`git grep`, so ignored files stay out), and any file in the viewer with
  line numbers — a search hit opens scrolled to its line. The file's menu has **Attach to prompt**,
  which puts it in the composer as an `@` mention, and Copy path.
* **Run a command…** runs build / test / generate on the Mac without the agent, streaming the output
  to the phone with Cancel and the exit code; **Send output to the agent** drops the tail into the
  composer as a fenced block. Commands come from `.ccremote.json` in the repo
  (`{"commands": [{"name": "Tests", "command": "swift test"}]}`) or are guessed from the build files
  (Package.swift, Tuist, package.json, Cargo, Go, pytest, Makefile…); anything can be typed. Running
  is Face ID-gated like an approval when that setting is on.
* **The palette** (the ⌘ button in the composer) is everything you can launch here without
  remembering its name: the slash commands the CLI advertises, the skills and sub-agents defined in
  `.claude/` (the project's first, then yours from `~/.claude`, each with its description), and your
  own **saved prompts** — kept on the phone, so they follow you between Macs. "Save the draft as a
  prompt" turns what is in the composer into one. The same project commands and skills also show up
  in the "/" list as you type.
* **Context meter.** Once the model is carrying more than half its window, a ring in the composer says
  how full it is (yellow past 75%, red when the CLI is about to compact on its own); the session menu
  always shows the figure, and both offer **Compact the conversation** — the CLI's own `/compact`.
* **Background processes.** A dev server or a watcher does not belong in a one-shot run: **Background
  processes…** starts one that keeps running when the phone goes away, buffers its output on the Mac,
  and lets any phone attach later and see the tail — with Stop when you're done. They are listed with
  what they are doing per project, and they stop with the Mac app.
* **Read aloud / hands-free.** Any reply can be read out (message menu, or "Read last reply aloud").
  **Hands-free voice** in the session menu turns the chat into a conversation: each finished reply
  is read aloud, then the mic opens; stop talking for a couple of seconds and the prompt is sent.
  Code blocks are skipped when reading.
* **Sub-agents.** An `Agent` row shows what its sub-agent is doing ("Reading a file"), and expands
  into the sub-agent's own transcript — its prose and tool steps, nested as deep as agents go. Works
  live for sessions the phone hosts and, from the `subagents/` files, for Desktop / terminal ones.

## Git from the phone

The branch icon in a session opens the repo: current branch (switch or create one from the menu),
ahead/behind counts, Pull / Push (Publish sets the upstream), staged / unstaged / untracked files with
a per-file diff, stage / unstage / discard by swipe, and a commit box (staged only, or `commit -a`).
Actions run `git` on the Mac in the session's directory with `GIT_TERMINAL_PROMPT=0`, so a push that
needs a password fails fast instead of hanging — use the keychain helper or an SSH key with an agent.
While the agent is mid-turn in that repo, actions are refused so the phone doesn't race its edits.

**Worktrees** (the Git menu, or the session menu) list the repo's checkouts: the main working tree
and the extras next to it. Add one — `<repo>-<name>` on a branch of its own, created from HEAD or any
base you name — and start a session in it straight from the list, so two agents can work on two
branches without editing the same files. Removing one deletes its directory, so it asks first.

**Pull requests** need GitHub's `gh` on the Mac: the Git screen shows the branch's PR (state, review
decision, conflicts, every CI check with a link) with "Open on GitHub", or **Create pull request…**
(title, description, draft — the branch is pushed with an upstream first if it has none). The Git
icon in a session carries a dot with the CI result once the PR has been looked up.

Diffs are how you point at code: tap a line, then another, and the range is selected; **Ask about
this** drops it into the composer as a quote — the file, the line numbers and the lines as a
fenced `diff` block — so "this condition is inverted" carries exactly the lines you mean. The same
works in the permission sheet's working-tree review. Copy puts the same quote on the clipboard.

## The task queue

**Task queue…** (list menu) is a list of chores the Mac works off by itself. A task is a prompt, a
project, an agent and a permission mode; the daemon starts a session for it, sends the prompt, and
marks it done with the agent's last reply as the summary — so a finished task is an ordinary session
you can open and take over. Tasks run **one at a time** by default (up to four in parallel), the queue
can be paused, and each task can start as soon as there's a slot, at a time today, or **every day** at
one — a nightly "run the tests and tell me what broke". **Run in a fresh worktree** gives a task its
own checkout so parallel ones don't collide.

Nobody is watching a queued task, so anything it stops to ask lands in the approvals inbox and that
task waits there — pick a permission mode that doesn't ask, or plan to answer. The queue lives in
`tasks.json` next to the other daemon files and survives a restart; a task that was running when the
Mac app stopped is marked failed rather than left claiming to run.

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

## Several Macs at once

The app stays connected to every Mac you have paired, not just the one on screen: their sessions and
their approvals keep arriving, so the inbox and the widget are never half the picture. **Show every
Mac** (list menu) folds them into one list — each row carries the Mac it lives on, and opening one
from another Mac switches over first. Both switches live in Settings → Macs; turning the first off
goes back to one Mac at a time.

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

## Simulator live view and control

When an iOS Simulator is booted on the Mac (e.g. the agent is driving your app in it), a phone
icon appears in the toolbar. It opens a live view of the simulator's screen, streamed as H.264
straight from the simulator's framebuffer: the daemon reads the display's IOSurface through
CoreSimulator's display port, encodes it with VideoToolbox (≤ 1400 px, ~2.5 Mbit/s, up to 30 fps)
only when something was drawn, and the phone decodes it with `AVSampleBufferDisplayLayer`. A static
screen costs nothing but a heartbeat. If the framebuffer cannot be opened (no Xcode, an unusual
runtime) the daemon falls back to JPEG snapshots from `xcrun simctl io <udid> screenshot` at a few
fps. Several booted simulators can be switched from the view's menu.

The picture is interactive: your finger is forwarded live — down, moves, up — so taps, long
presses, swipes and scrolls happen in the simulator as you make them (coordinates travel as
fractions of the screen, so the frame size never matters); the bar below has Home, Lock,
Backspace and Return, and a keyboard button opens a field whose text is entered into whatever the
simulator has focused. Text goes through the simulator pasteboard and ⌘V rather than key codes,
so Cyrillic and emoji work and the guest's keyboard layout is irrelevant (watchOS runtimes have no
pasteboard, so text is unavailable there).

Two fingers zoom the picture (1–4×, around the pinch) for precise taps; a full-screen button shows
it edge to edge on black, with a landscape simulator rotated to fill the phone. While an agent is
inside a simulator tool call the status line says so, so you don't fight it for the screen.

The camera button grabs a full-resolution still: opened from a chat it lands in that chat's
composer as an image attachment (so "this button is misaligned" can carry the picture); opened from
the session list it goes to the clipboard. The device menu also runs the simulators themselves —
switch between booted ones, boot another headless (no Simulator.app window needed; the phone's
view is the window), shut one down, launch any installed app, or open a URL / deep link in it.

`simctl` has no input commands, so the daemon injects HID events the way Simulator.app, idb and
Claude Desktop's own simulator helper do: it `dlopen`s Xcode's private SimulatorKit, builds Indigo
messages with `IndigoHIDMessageFor…` and posts them through `SimDeviceLegacyHIDClient`
(`SimulatorInput.swift`; the display side is `SimulatorScreen.swift`). Nothing is linked against
the private frameworks; a Mac without Xcode just reports that input is unavailable.
`ccremote --sim-input <udid> '{"tap":{"x":0.5,"y":0.5}}'` and `ccremote --sim-video <udid> 10
out.h264` exercise both paths from a terminal.

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

## Always-on hub on a Linux server

The daemon also builds for Linux, so a VPS (or any x86_64/arm64 box) can host **quick chats** and
phone-hosted sessions around the clock — no Mac awake needed. It runs next to the relay on the same
server: the hub dials the relay over loopback, phones reach it through the relay's public `wss://`
address, and the hub's own listener stays on `127.0.0.1`. Mac-only features (desktop sessions,
Simulator view, Bonjour, the self-signed TLS identity) are simply absent there; the Linux build
speaks plain `ws://`, which is why it belongs behind the relay or a mesh VPN.

From the Mac, with the relay already deployed (`relay/deploy.sh`):

```
scripts/deploy-linux-hub.sh --host root@vps --relay-public wss://relay.example.com:8445 --name "VPS hub" [--with-codex]
```

It cross-compiles a static binary (needs the swift.org toolchain matching Xcode's Swift, installed
per-user, plus the Static Linux SDK of the same version — `swift sdk install …`), uploads it, creates
the `cchub` user, installs the claude CLI for it (and Codex from npm with `--with-codex`), and starts the
`ccremote-hub` systemd unit (`MemoryMax=1500M`, restarts on failure, secret from
`/etc/ccremote-relay.env`). Every open chat keeps a `claude`/`codex` process resident (~250 MB), so
the hub runs with `--idle-timeout 15`: a chat idle for 15 minutes is closed and reopened from its
transcript on the next tap. Then log the hub in and pair:

```
ssh root@vps sudo -u cchub -H /home/cchub/.local/bin/claude auth login   # prints a URL; paste the code back
ssh root@vps /opt/ccremote/hub/print-pairing                              # URL + QR (also ~cchub/.config/ccremote/pairing-qr.png)
```

The hub shows up in the app as one more Mac; pick it and tap **New chat**. Codex needs
`~cchub/.codex/auth.json` (copy it from a logged-in machine or run `codex login` there).
On Linux the config and files live in `$XDG_CONFIG_HOME/ccremote` (default `~/.config/ccremote`);
the QR needs `qrencode` (installed by the script on Debian/Ubuntu).

## Options

Everything lives in `~/Library/Application Support/ccremote/config.json` (edited by the Host app's
Settings). The CLI reads it too; flags override it for one run:

```
ccremote [--port 7811] [--listen 127.0.0.1] [--token …] [--claude /path/to/claude] [--codex /path/to/codex] [--name "Bonjour name"]
         [--rotate-token] [--print-pairing] [--quiet] [--no-tls]
         [--relay wss://vps | --no-relay] [--relay-secret S] [--relay-public wss://public] [--room R] [--relay-fingerprint FP]
         [--ntfy TOPIC] [--telegram-token T --telegram-chat ID] [--no-notify-done] [--idle-timeout MIN]
         [--apns-key PATH --apns-key-id ID --apns-team TEAM] [--apns-bundle ID] [--apns-production]
         [--install-hook | --uninstall-hook] [--codex-port N]
```

Running a second daemon for development next to the Host app? Use another port **and** `--no-relay`
(or `--room`): two daemons registering the same relay room keep kicking each other out of it.

`CCREMOTE_CLAUDE_PATH` / `CCREMOTE_CODEX_PATH` also override the binaries. Other files in the support dir: `token`,
`tls-identity.p12` (+ pem), `relay-room`, `devices.json` (paired phones), `pairing-qr.png`.

## Sessions: rename, pin, archive, search

Long-press a session (or swipe): **Rename…** writes the title to the session on the Mac (Claude: a
`custom-title` entry in the transcript, the same thing `/rename` does; Codex: `thread/name/set`),
**Pin** keeps it at the top, **Archive** hides it (the list menu shows archived ones again). Pins and
archives are the phone's own, per Mac. The search field also searches **inside every transcript on
the Mac** (Claude projects and Codex rollouts): hits show a snippet, and opening one lands in the
session with find-in-transcript already on that word.

## Shortcuts, Siri, Spotlight

App Intents: **Ask the agent** (a question → a quick tool-less chat on the Mac → the reply comes back
into the shortcut, so "Ask Claude …" works from Siri and Shortcuts), **Pending approvals** (count +
which), **Approve pending** / **Deny pending** (Approve needs the app when Face ID is required),
**Send to session** (a prompt into an existing session) and **Open session** (a session picker).
Sessions are indexed in Spotlight by title and project; a hit opens the session.

## Reconnects, offline, widget

* A reconnecting phone asks for the events it missed (`open … since <seq>`): the Mac numbers every
  durable event and keeps the last few hundred per session, so a dropped connection costs the gap,
  not the whole transcript again — unless the Mac restarted or the gap is too old.
* With the Mac unreachable the app still opens: the last session list and the transcripts it had
  opened come from a per-Mac cache (Library/Caches; the banner says "showing what was last seen").
  Sending waits for the connection.
* A **home-screen / lock-screen widget** ("Sessions") shows approvals waiting, agents working and the
  sessions worth a look; a tap opens the first one needing approval. The app updates it whenever
  sessions or permissions change (App Group; a simulator build shows placeholder data).

## Security notes

* **Through the relay the traffic is end-to-end encrypted.** The relay only ever carries sealed frames:
  after the WebSocket opens, phone and Mac exchange ephemeral X25519 keys and nonces and derive a
  ChaCha20-Poly1305 key from that plus the pairing token (`E2ELink`), so the relay — which sees every
  byte — can neither read nor forge anything, and a token that leaks later does not open past
  traffic. Each frame is bound to its direction and sequence, so it cannot be replayed. Direct links
  pin the Mac's certificate instead.
* **Phones can be blocked one at a time.** The Host panel's menu on a paired phone has Block (it is
  dropped and refused at its next hello, by the device id it reports) and Forget; "New token" still
  cuts everyone off at once.
* **Every decision made from a phone is logged** to `~/Library/Application Support/ccremote/approvals.jsonl`
  (when, which phone, session, tool, summary, allow / deny / remembered) — "Approvals…" in the panel
  opens it.

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

## CI

`.github/workflows/ci.yml` runs on every push and pull request: `swift build` + `swift test` for the
package, then `tuist generate` and unsigned builds of the iOS app (with the Watch app and widgets)
and the Mac host app, on the newest Xcode the runner has.

## Releases

```bash
git tag v1.0.1 && git push origin v1.0.1
```

`.github/workflows/release.yml` takes it from there: the version comes from the tag (every Info.plist
reads `$(MARKETING_VERSION)`; the build number is the run number), `scripts/build-mac-app.sh` makes the
universal ad-hoc-signed Mac zip, `scripts/build-ios-ipa.sh` the unsigned `.ipa` (Watch app stripped,
entitlements kept), `scripts/release/altstore-source.sh` the `altstore.json`, and everything lands in a
GitHub Release with `SHA256SUMS`. A second job renders `scripts/release/cask.sh` into
`Casks/claude-remote-host.rb` in [maxches99/homebrew-tap](https://github.com/maxches99/homebrew-tap) and
pushes it with the `TAP_GITHUB_TOKEN` secret (a fine-grained PAT with write access to that repo only).

Keep tags above the versions people already have installed: the first one should be `v1.0.1` or higher,
because dev builds from Xcode report `1.0` and AltStore only offers updates that compare newer. When an
Apple developer account shows up, the same workflow grows `TEAM_ID` + `notarytool` for the Mac and
TestFlight for the phone; the Homebrew and AltStore channels keep working as they are.

## Protocol drift

`CLIProcess` speaks the `--input-format stream-json` / `--permission-prompt-tool stdio`
protocol. It is what Claude Desktop and `@anthropic-ai/claude-agent-sdk` use, but it is not
a public API; when the CLI updates, check `SessionManager.handleControlRequest` and the
message shapes in `Transcript.swift` against the SDK's `sdk.mjs`.

`CodexBackend` speaks the `codex app-server` v2 JSON-RPC protocol, marked experimental by
OpenAI. Its schema is generated by the CLI itself — `codex app-server generate-json-schema --out DIR`
— so when Codex updates, diff that against the methods used in `CodexBackend.swift` and the
item shapes in `CodexTranslator.swift`.
