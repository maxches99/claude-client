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
| `Sources/ClaudeRemoteCore` | Shared package: wire protocol, `JSONValue`, transcript reducer, `CodexTranslator` / `CodexRollout` (Codex events and session files → the same reducer), WebSocket channel (TLS roles), the queue / palette / worktree / turn-review / digest / review / duel models (`DuelJudge`: the blind brief and verdict parser), the Telegram digest (`DigestTelegram`), `Automation` (issues, CI state, model duels, templates, the audit rules, relay setup, updates), the terminal emulator (`TerminalScreen`) and the share page (`TranscriptHTML`) |
| `Sources/ClaudeCodeHost` | Mac-only: `CLIProcess` (stream-json + control protocol), `CodexAppServer` + `CodexBackend` (Codex threads over JSON-RPC), transcript index, live-session registry, `PeerInbox` (write into desktop sessions), `ClaudeHooks` (the PermissionRequest hook in settings.json), `TLSIdentity`, `SessionManager` and its feature files (`…Rewind`, `…Palette`, `…Worktrees`, `…Tasks`, `…Digest`, `…DigestSchedule`, `…PullRequests`, `…Review`, `…Duels`, `…Workspace`, `…Automation` (issues, CI repair, templates, audit, GitHub login), `…Operations` (event feed, snapshots, before/after screenshots, health), `…Handoff`, `…Share`, `BackgroundProcesses`, `TerminalSessions` — the pseudo-terminal itself is the small C target `CPTY`) |
| `Sources/ClaudeRemoteDaemon` | The daemon as a library: `Daemon` (config → listener + Bonjour, relay dial-out, notifier, phone tracking, status), `DaemonConfig` (`config.json`), `PhoneSession`, `WebSocketServer`, `HookServer` (hook socket), `RelayClient`, `DeviceRegistry`, pairing URL + QR |
| `Sources/ccremote` | Thin CLI front-end for the daemon (flags, terminal QR) |
| `ClaudeRemoteHost/` | **Mac menu-bar app** hosting the daemon: status, paired phones, QR, settings, open-at-login, keep-awake (Tuist project) |
| `relay/` | Node relay for reaching the Mac off-network, and the host of share links (`relay/README.md`) |
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
Team allows 3 sideloaded apps at once (the store itself is one) and 10 App IDs a week — the app plus its
widget are two; the Watch app is not in the .ipa (sideloaders can't install watchOS apps).

What the source serves is **`ClaudeRemote-no-widget.ipa`**: a free Apple ID cannot sign an App Group,
which is how the home-screen widget reads the app's data, so the widget is left out and the app itself
installs cleanly (and keeps updating — same bundle ID). The full build with the widget is
`ClaudeRemote.ipa` on the same release page, for a paid account: install it from AltStore's
**My Apps → +** or with [Sideloadly](https://sideloadly.io).

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

**Codex without the Claude CLI** works too: a Mac with only Codex runs the daemon as usual, the phone
starts every session, chat and task with Codex and shows no agent picker, and the Host app's menu
says The Claude CLI is not installed. A chat asked of Claude (a Siri shortcut, an older app) goes to
Codex; a Claude work session is refused with a message. `CCREMOTE_CLAUDE_PATH=none` runs a Mac
that has both as Codex-only.

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

### Phone sessions in the desktop apps

A Codex thread started from the phone in a folder that is a project in the Codex app shows up under
that project in the app's sidebar on its own; the new-session sheet marks those folders. Claude
Desktop only lists sessions it started, so the Host menu keeps "Started on the phone" — one click
imports a session into Desktop's Code tab (`claude://resume`) and opens it. The experimental
setting "Show phone sessions in Claude Desktop and the Codex app" does it without clicking by
writing the apps' own state files: a record in Desktop's session list after each turn (Desktop reads
the list at launch, so it appears after Desktop's next start), and the project for a folder the Codex
app does not have yet (written only while the Codex app is closed, since it saves over the file).

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

## Catching up

Come back after a while and the session list opens with **While you were away**: which sessions moved,
which are waiting for you, which ran into errors, and the tasks that finished — across every connected
Mac. Tap it for the details: per session the prompts it got, the files it wrote, the commands it ran,
its errors and its last reply; the queue's finished tasks and the background processes that stopped.
**Catch up…** in the list menu shows the same for the last hour, today, the last day or the last week.
The Mac works it out from the transcripts (Claude's and Codex's), so it covers Desktop and terminal
sessions as well as the phone's own.

**A morning digest in Telegram**: Settings → Digest turns on a daily message at a time you pick —
what's waiting for you, what moved and where, finished and failed tasks (with PR links), decided
duels and processes that died — covering everything since the last one. "Send one now" sends it
right away. It uses the Telegram bot configured for notifications (the Host app's Settings, or
`--telegram-token` / `--telegram-chat`); the schedule lives in `digest-schedule.json`.

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
* **Terminal.** **Terminal…** (session menu, or **Terminals…** in the list menu) opens a login shell on
  the Mac in a real pseudo-terminal — your prompt, your aliases, ^C and job control, colours, and
  full-screen programs (`top`, `less`, `vim`) on an xterm-compatible screen. A bar above the keyboard
  has Esc, Tab, a sticky Ctrl, ^C and the arrows; a hardware keyboard works as is, and Paste uses
  bracketed paste. The shell keeps running when you leave: come back, or open it from another phone,
  and the screen is replayed. Opening one is Face ID-gated like running a command.
* **Continue on the Mac** (session menu) hands a session back to the desk: **Continue in Claude
  Desktop** imports it into the Code tab (through Desktop's own `claude://resume` link), **Continue in
  Terminal** opens `claude --resume` (or `codex resume`) in a new Terminal window, and the project
  opens in Finder, Xcode (when there is a workspace, project or package) or an editor you have installed.
  For a session the phone hosts, the daemon lets go of it first, so the transcript has one writer; mid-turn
  it refuses. The phone can still follow the session from the list afterwards.
* **Read aloud / hands-free.** Any reply can be read out (message menu, or "Read last reply aloud").
  **Hands-free voice** in the session menu turns the chat into a conversation: each finished reply
  is read aloud, then the mic opens; stop talking for a couple of seconds and the prompt is sent.
  Code blocks are skipped when reading. When the agent stops to ask, the request is read out too
  ("Claude wants to run swift test. Say yes or no.") and a spoken yes / no — or да / нет — answers
  it; Face ID still guards Allow when it is on, and an unclear answer leaves the card for a tap.
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

A finished task shows what it changed (files, +/−). With **Open a draft pull request when done**
(needs a worktree and `gh` on the Mac) the daemon commits the worktree's changes on its `task/…`
branch, pushes it and runs `gh pr create --draft` with the prompt and the agent's summary as the
body; the PR link appears on the task. A finished worktree task can also do that later from its menu.

**Review the changes…** (a task's menu, a session's menu, or the Git screen) is a GitHub-style review:
every file changed on the branch against its base — the commit the task started from, or the default
branch's merge-base, or any ref you type — with a per-file diff. Select lines, write what should
change, repeat across files, add general remarks; **Send N remarks** puts one numbered review in the
session's composer (each remark with its file, lines and quote) to read over and send.

**From a GitHub issue.** "Start from → From a GitHub issue…" in the task editor lists the project's
open issues (`gh issue list`); picking one makes the prompt from the issue, runs it in a worktree and
opens a draft PR whose body says `Fixes #N`. Templates show up in the same menu (below).

**Fix CI failures on it.** With this on, the host watches the task's pull request (`gh pr view`, every
three minutes). When a check fails it starts a repair task in the same worktree, told which checks
failed and the end of their log (`gh run view --log-failed`); the repair's change is committed but not
pushed — the task shows **Push the fix**, and only that updates the pull request. At most three tries
per pull request; a new push of your own resets the watch, and a merged or closed PR ends it.

**Before and after.** "Screenshot before and after" on a task runs the project's preview command when
the task starts and again when it ends, and takes a Simulator still each time; the task shows both
side by side (tap for full screen). The command lives in `.ccremote.json`:
`"preview": {"command": "scripts/run-in-simulator.sh", "device": "<simulator name or UDID>", "settle": 4}`
(or just a string) — it should build, install and launch the app; `device` matters when more than one
Simulator is booted, `settle` is how long the app gets to draw.

**Undo a task.** A task that runs in the project itself (not a worktree) first takes a snapshot: the
working tree — tracked and untracked files, ignored ones left out — as a commit under
`refs/ccremote/snapshots/<task>`, without touching the tree, the index or the branch. **Undo the task's
changes** in its menu puts everything back: its edits, new files and commits are gone.

**Prompt templates.** A project's `.ccremote.json` can carry `"templates": [{"name": "New screen",
"prompt": "Add a {screen} screen like {existing}", "description": "…"}]`, and the host its own in
`templates.json` in the support directory. They appear in the composer's launch palette and in the
task editor; the phone asks for each `{field}` and fills the prompt in.

### Claude vs Codex

**New duel** (the queue's + menu, when the Mac has Codex) gives the same prompt to Claude and Codex,
each in its own worktree of the repo. When both are done the Mac runs the project's test command in
each checkout (the first project command with "test" in its name: `.ccremote.json`, then
`swift test`, `npm test`, `cargo test`, `go test`, `pytest`, `make test`…), then a **blind judge** — a tool-less chat with Claude or Codex — gets both diffs, the test
results and the summaries as "Solution A" and "Solution B" (shuffled; it never learns which agent
wrote which) and scores correctness, completeness, code quality and tests, 0–10 each, with a winner
or a tie. The duel screen shows the verdict, the score bars, each side's diff, session and test
result; **Keep** one removes the other's worktree and branch, **Rejudge** asks again (with the other
agent as judge, if you like), and either side can become a draft PR. Codex duel tasks run with the
workspace-write sandbox so they can actually edit.

**Model vs model.** The duel editor also pits any two agent / model / reasoning combinations against
each other — Opus against Sonnet, or one Codex model at medium against high — to see what a kind of
job is worth. The judge is still blind; on a Mac with only one agent that is the only kind of duel.

### Code on the hub

**Clone a repository…** (list menu) clones into the host's workspace — `~/work` by default,
`--workspace DIR` to change it — from `owner/name` or any git URL, or picks from your GitHub
repositories when `gh` is logged in there. Everything in the workspace shows up as a project, so a
Mac or the Linux hub can take tasks on repositories that were never checked out on it. PRs and
private repositories need a GitHub login and a git identity on the host — both set from the phone:
Settings → Connected Mac → **GitHub** runs `gh auth login --web` on the host and shows the one-time
code (type it at github.com/login/device on any device; then `gh auth setup-git` lets git push with it),
and takes the name and email commits are signed with. With that, the hub works from GitHub alone:
clone, task from an issue, draft PR, CI repair — no Mac awake.

## Feed and health

**Feed…** (list menu) is one timeline of every paired Mac and the hub: turns that finished or failed,
approvals waiting, tasks started and done, pull requests, CI failures and fixes, duels decided, host
warnings — filter by kind and Mac, search, tap to open the session (or the link). Each host keeps the
last 1500 events in `events.json`; the phone asks for what it missed on every connect.

**Health** (Settings → Connected Mac) shows the host's disk, memory, load, battery and uptime and
whether Claude, Codex and GitHub are still logged in. The host checks every ten minutes and, the first
time something needs attention — the disk nearly full, memory nearly full, the battery running down
off power, an agent logged out — says so once in the feed and as a notification.

## Share into the app and back up settings

**Send to Mac** in any app's share sheet (Safari, Notes, Mail…) hands the page title and link, or the
text, to the app: make it a task on the Mac, or drop it into a session's composer. It needs no App
Group, so it is in the widget-less build as well.

**Back up or restore settings** (Settings) writes every paired Mac with its token, saved prompts, pins
and archives, share links and preferences to one file — sealed with a passphrase (AES-GCM, key from
PBKDF2) unless you leave it empty — and restores them on a new phone; Macs already there are refreshed,
not doubled.

## Audit

**Audit…** (list menu) lists what agents did on the Mac in the last hour, day or week: every command,
file write or delete, web fetch and MCP tool call, read from the transcripts (Claude's and Codex's).
**Only what stands out** keeps the ones worth a look — writes outside the project, `sudo`, recursive
deletes, piping a download into a shell, the network, force pushes, credentials and `.env` files,
system settings, installs, CI workflow files. Tapping one opens its session.

## Find, share, dictate

* **Find in transcript** (session menu) — matches prompts, replies, thinking and tool calls/results;
  ↑/↓ walk the hits and unfold the step they live in.
* **Share transcript…** exports the whole session as Markdown (prompts and replies in full, tool
  work folded into `<details>` blocks); **Copy last reply** is one tap. Long-press any message for
  Copy / Share / Quote in reply.
* **Dictation** — tap the mic and talk; the text streams into the composer as you speak (on-device
  recognition when the language supports it). Hold the mic for the older voice-memo attachment.

## Share links

**Share as a link…** (session menu) publishes the transcript as a read-only page for someone without
the app: prompts and replies, tool work folded up, in their browser, for an hour, a day or a week.
The page is rendered and **encrypted on the phone** (AES-256-GCM, a fresh key per link). The Mac passes
only the ciphertext to its relay, the relay stores it and serves a small viewer, and the key is the
`#fragment` of the link, which browsers never send to a server — so neither the Mac nor the relay can
read what was shared. The viewer decrypts in the reader's browser, takes the key out of the address
bar, and shows the page in a sandboxed frame where no script runs and nothing outside can load.
Revoke a link from the same sheet or from Settings → Shared links; the relay deletes it. It needs a
relay (Host → Settings → Remote access); links survive relay restarts when it has a data directory
(`--data`, which `relay/deploy.sh` sets up).

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

Tap any image in the transcript — a simulator screenshot, a pasted picture, an image the agent sent —
and it opens full screen: pinch or double-tap to zoom, swipe to the turn's other images, pull down to
close. **Save to Photos**, **Copy**, and Share hand it over as a PNG (`screenshot.png`, or the file's
own name); a long press on the image in the chat offers the same without opening it.

**Camera and mark-up.** The composer's + menu can take a photo; any picture in the composer — a
photo, a screenshot, the simulator's still — opens for drawing on when tapped (PencilKit, a red marker
to start), so "this is misaligned" can come with a circle around it. The drawing is burned into the
image before it goes to the agent.

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

## Apple Watch

The Watch app (Xcode builds only — sideloaders cannot install it) opens on what is waiting: approvals
first, each with Allow / Deny, a plan to read and approve, or a question whose options are buttons (one
tap for a single choice, toggles and Send for several). The wrist taps when a new request arrives and
when a turn you opened there finishes. **Ask Claude** starts a quick chat by voice and shows the reply;
a session's Reply offers ready answers ("Yes, go ahead", "Run the tests"…) next to dictation, and a
running session shows what its agent is doing and can be stopped.

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
  **Another Mac onto the same relay** without typing the secret: on a Mac that is on it, Host app →
  Settings → Remote access → **Relay setup QR…**; on the phone, Settings → the other Mac →
  **Join a relay** → scan it (or pick a paired Mac that is on the relay). The phone sends the setting,
  the Host app restarts onto the relay and the phone picks up the new route by itself — every host
  now reports its relay route, so pairings stay current without a new QR.
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
         [--install-hook | --uninstall-hook] [--codex-port N] [--workspace ~/work]
```

Running a second daemon for development next to the Host app? Use another port **and** `--no-relay`
(or `--room`): two daemons registering the same relay room keep kicking each other out of it.

`CCREMOTE_CLAUDE_PATH` / `CCREMOTE_CODEX_PATH` also override the binaries. `CCREMOTE_SUPPORT_DIR`
moves the whole support directory — a development daemon with its own token, hook socket, queue and
config never touches the Host app's. Other files in the support dir: `token`,
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
**Send to session** (a prompt into an existing session), **Open session** (a session picker) and
**Add a task** (a prompt, a project, an agent, a worktree and a draft PR when done — "Add a task in
ClaudeRemote" from Siri; needs a host on protocol 6).
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
GitHub Release with `SHA256SUMS`. The `.ipa` is built twice: as-is, and with `STRIP_EXTENSIONS=1` into
`ClaudeRemote-no-widget.ipa`, which is the one `altstore.json` points at (entitlements in the source are
read back out of that .ipa, so they never drift). A second job renders `scripts/release/cask.sh` into
`Casks/claude-remote-host.rb` in [maxches99/homebrew-tap](https://github.com/maxches99/homebrew-tap) and
pushes it with the `TAP_GITHUB_TOKEN` secret (a fine-grained PAT with write access to that repo only).

Keep tags above the versions people already have installed: the first one should be `v1.0.1` or higher,
because dev builds from Xcode report `1.0` and AltStore only offers updates that compare newer. When an
Apple developer account shows up, the same workflow grows `TEAM_ID` + `notarytool` for the Mac and
TestFlight for the phone; the Homebrew and AltStore channels keep working as they are.

### Updating a host

The Host app looks for a newer release on launch and twice a day and offers **Update** in its menu;
the phone offers the same (Settings → Connected Mac → Version → **Update to …**). The app downloads
`ClaudeRemote-Host.zip`, checks it against the release's `SHA256SUMS`, swaps its own bundle and
relaunches — when it may write where it is installed (a Homebrew install is; `brew upgrade` stays an
option). The Linux hub does the same with `ccremote-linux-x86_64.tar.gz`, which the release workflow
builds from the `linux-hub` branch with the tag merged in: the hub checks the `.sha256`, replaces its
binary and exits, and systemd starts the new one.

## Protocol drift

`CLIProcess` speaks the `--input-format stream-json` / `--permission-prompt-tool stdio`
protocol. It is what Claude Desktop and `@anthropic-ai/claude-agent-sdk` use, but it is not
a public API; when the CLI updates, check `SessionManager.handleControlRequest` and the
message shapes in `Transcript.swift` against the SDK's `sdk.mjs`.

`CodexBackend` speaks the `codex app-server` v2 JSON-RPC protocol, marked experimental by
OpenAI. Its schema is generated by the CLI itself — `codex app-server generate-json-schema --out DIR`
— so when Codex updates, diff that against the methods used in `CodexBackend.swift` and the
item shapes in `CodexTranslator.swift`.
