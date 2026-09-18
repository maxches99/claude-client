#!/bin/sh
# Builds ccremote in release mode and installs it as a LaunchAgent that starts at login.
set -e
cd "$(dirname "$0")/.."
swift build -c release --product ccremote
mkdir -p "$HOME/.local/bin" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cp .build/release/ccremote "$HOME/.local/bin/ccremote"
PLIST="$HOME/Library/LaunchAgents/dev.maxches.ccremote.plist"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>dev.maxches.ccremote</string>
    <key>ProgramArguments</key>
    <array>
        <string>$HOME/.local/bin/ccremote</string>
        <string>--quiet</string>
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
echo "ccremote installed and started. Pairing info:"
"$HOME/.local/bin/ccremote" --print-pairing
