#!/bin/sh
# Builds ccremote (release) and installs it as a LaunchAgent that starts at login
# and keeps the Mac awake while it runs (so it stays reachable from your phone).
#
# Any extra arguments are passed straight to ccremote, e.g.:
#   scripts/install-launchagent.sh --relay wss://vps.example.com --relay-secret s3cret
set -e
cd "$(dirname "$0")/.."
swift build -c release --product ccremote
mkdir -p "$HOME/.local/bin" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

PLIST="$HOME/Library/LaunchAgents/dev.maxches.ccremote.plist"

# Stop the running agent BEFORE replacing its binary — overwriting a running executable in
# place breaks its code signature and macOS then kills it (OS_REASON_CODESIGNING). Install
# atomically (temp + re-sign + mv) so the on-disk binary is always a valid, complete image.
launchctl bootout "gui/$(id -u)/dev.maxches.ccremote" 2>/dev/null || true
launchctl unload "$PLIST" 2>/dev/null || true
cp .build/release/ccremote "$HOME/.local/bin/ccremote.new"
codesign --force --sign - "$HOME/.local/bin/ccremote.new" 2>/dev/null || true
mv -f "$HOME/.local/bin/ccremote.new" "$HOME/.local/bin/ccremote"

# Build the <array> of ProgramArguments: caffeinate -s keeps the system awake
# (on AC power) only while ccremote runs — no global pmset change needed.
ARGS='        <string>/usr/bin/caffeinate</string>
        <string>-s</string>
        <string>'"$HOME"'/.local/bin/ccremote</string>
        <string>--quiet</string>'
for arg in "$@"; do
    esc=$(printf '%s' "$arg" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
    ARGS="$ARGS
        <string>$esc</string>"
done

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>dev.maxches.ccremote</string>
    <key>ProgramArguments</key>
    <array>
$ARGS
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$HOME/Library/Logs/ccremote.log</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/ccremote.log</string>
</dict>
</plist>
PLIST

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
echo "ccremote installed and started (kept awake via caffeinate while running)."
echo "Pairing info:"
"$HOME/.local/bin/ccremote" --print-pairing
