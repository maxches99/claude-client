#!/usr/bin/env bash
# Builds ccremote for x86_64 Linux on this Mac and installs it on a server as the systemd
# service `ccremote-hub` — an always-on daemon for quick chats (and phone-hosted sessions),
# reached through the ccremote relay running on the SAME server (relay/deploy.sh).
#
#   scripts/deploy-linux-hub.sh --host vpn-us --relay-public wss://relay.example.com:8445 [--name "VPS hub"]
#                               [--user cchub] [--dir /opt/ccremote/hub] [--port 7811] [--no-build] [--with-codex]
#
# Requirements on the Mac: the swift.org toolchain matching Xcode's Swift version
# (installed per-user in ~/Library/Developer/Toolchains) and the Static Linux SDK of the same
# version (`swift sdk install …`). On the server: root over ssh, the relay already deployed
# (/etc/ccremote-relay.env), Ubuntu/Debian (apt) for qrencode.
#
# After this script: log the hub's user into the claude CLI and (optionally) Codex, then pair:
#   ssh root@HOST sudo -u cchub -H /home/cchub/.local/bin/claude auth login
#   ssh root@HOST /opt/ccremote/hub/print-pairing
set -euo pipefail

HOST=""; RELAY_PUBLIC=""; NAME="VPS hub"; SVCUSER="cchub"; DIR="/opt/ccremote/hub"; PORT="7811"; BUILD=1; CODEX=0
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2;;
    --relay-public) RELAY_PUBLIC="$2"; shift 2;;
    --name) NAME="$2"; shift 2;;
    --user) SVCUSER="$2"; shift 2;;
    --dir) DIR="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --no-build) BUILD=0; shift;;
    --with-codex) CODEX=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$HOST" ] || { echo "--host is required (an ssh destination with root)" >&2; exit 2; }
[ -n "$RELAY_PUBLIC" ] || { echo "--relay-public is required (the wss:// address phones use)" >&2; exit 2; }

cd "$(dirname "$0")/.."
SDK="x86_64-swift-linux-musl"
BIN=".build/$SDK/release/ccremote"

if [ "$BUILD" = 1 ]; then
  # Xcode's Swift cannot use the Static Linux SDK (its modules come from the swift.org
  # compiler), so pick the swift.org toolchain of the same version from the user's toolchains.
  XCODE_VERSION="$(swift --version 2>&1 | sed -n 's/.*Swift version \([0-9.]*\).*/\1/p' | head -1)"
  TOOLCHAIN_ID=""
  for tc in "$HOME/Library/Developer/Toolchains"/swift-*.xctoolchain /Library/Developer/Toolchains/swift-*.xctoolchain; do
    [ -f "$tc/Info.plist" ] || continue
    # The toolchain's Version carries a build suffix (6.3.3.20260625101); match on the release part.
    case "$(/usr/libexec/PlistBuddy -c 'Print :Version' "$tc/Info.plist" 2>/dev/null || true)" in "$XCODE_VERSION"|"$XCODE_VERSION".*)
      TOOLCHAIN_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$tc/Info.plist")"
      break;;
    esac
  done
  [ -n "$TOOLCHAIN_ID" ] || { echo "No swift.org toolchain $XCODE_VERSION in ~/Library/Developer/Toolchains — install swift-$XCODE_VERSION-RELEASE-osx.pkg (per-user is fine)" >&2; exit 1; }
  swift sdk list 2>/dev/null | grep -q "static-linux" || { echo "Static Linux SDK not installed: swift sdk install <swift-$XCODE_VERSION-RELEASE_static-linux-*.artifactbundle.tar.gz>" >&2; exit 1; }
  echo "Building with toolchain $TOOLCHAIN_ID for $SDK…"
  TOOLCHAINS="$TOOLCHAIN_ID" swift build -c release --swift-sdk "$SDK" --product ccremote
fi
[ -x "$BIN" ] || { echo "$BIN missing — build first" >&2; exit 1; }

echo "Uploading to $HOST…"
scp -q "$BIN" "$HOST:/tmp/ccremote.new"

ssh "$HOST" "bash -s" -- "$SVCUSER" "$DIR" "$PORT" "$NAME" "$RELAY_PUBLIC" "$CODEX" <<'REMOTE'
set -euo pipefail
SVCUSER="$1"; DIR="$2"; PORT="$3"; NAME="$4"; RELAY_PUBLIC="$5"; CODEX="$6"
[ -f /etc/ccremote-relay.env ] || { echo "/etc/ccremote-relay.env not found — deploy the relay first (relay/deploy.sh)" >&2; exit 1; }
# shellcheck disable=SC1091
. /etc/ccremote-relay.env
RELAY_PORT="${CCRELAY_PORT:-8787}"

id "$SVCUSER" >/dev/null 2>&1 || useradd --create-home --shell /usr/sbin/nologin "$SVCUSER"
HOME_DIR="$(getent passwd "$SVCUSER" | cut -d: -f6)"
mkdir -p "$DIR"
install -m 0755 /tmp/ccremote.new "$DIR/ccremote.new"
rm -f /tmp/ccremote.new
if command -v apt-get >/dev/null && ! command -v qrencode >/dev/null; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q qrencode >/dev/null 2>&1 || echo "note: qrencode not installed — pairing prints the URL only"
fi

# The CLIs the hub drives, installed for its user: the claude CLI's native build (no Node needed)
# and, on request, the Codex CLI from npm (Node 18+ must be present).
if [ ! -x "$HOME_DIR/.local/bin/claude" ]; then
  echo "Installing the claude CLI for $SVCUSER…"
  sudo -u "$SVCUSER" -H bash -c 'curl -fsSL https://claude.ai/install.sh | bash' >/dev/null 2>&1 || echo "note: the claude CLI install failed — run the installer as $SVCUSER by hand"
fi
if [ "$CODEX" = 1 ] && [ ! -x "$HOME_DIR/.npm-global/bin/codex" ]; then
  echo "Installing Codex CLI for $SVCUSER…"
  sudo -u "$SVCUSER" -H bash -c 'mkdir -p ~/.npm-global && npm install -g --prefix ~/.npm-global @openai/codex' >/dev/null 2>&1 || echo "note: Codex install failed — npm install -g @openai/codex as $SVCUSER by hand"
fi

# Common flags: plain ws on loopback only (phones come through the relay on this box), relay
# dialed locally, public relay address in the pairing URL.
FLAGS="--no-tls --listen 127.0.0.1 --port $PORT --name \"$NAME\" --relay ws://127.0.0.1:$RELAY_PORT --relay-public $RELAY_PUBLIC"

install -m 0755 /dev/stdin "$DIR/print-pairing" <<EOF
#!/usr/bin/env bash
# Prints the hub's pairing URL + QR (also written to $HOME_DIR/.config/ccremote/pairing-qr.png).
set -e
. /etc/ccremote-relay.env
exec sudo -u $SVCUSER -H env HOME=$HOME_DIR PATH=$HOME_DIR/.local/bin:/usr/local/bin:/usr/bin:/bin \\
  $DIR/ccremote --print-pairing $FLAGS --relay-secret "\$CCRELAY_SECRET"
EOF

install -m 0644 /dev/stdin /etc/systemd/system/ccremote-hub.service <<EOF
[Unit]
Description=ClaudeRemote hub (quick chats and phone-hosted sessions)
After=network-online.target ccremote-relay.service
Wants=network-online.target ccremote-relay.service

[Service]
User=$SVCUSER
Environment=HOME=$HOME_DIR
Environment=PATH=$HOME_DIR/.local/bin:$HOME_DIR/.npm-global/bin:/usr/local/bin:/usr/bin:/bin
EnvironmentFile=/etc/ccremote-relay.env
ExecStart=$DIR/ccremote --quiet $FLAGS --relay-secret \${CCRELAY_SECRET}
Restart=always
RestartSec=3
# A runaway claude/codex child must not starve the rest of this box.
MemoryMax=1500M
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl stop ccremote-hub 2>/dev/null || true
mv -f "$DIR/ccremote.new" "$DIR/ccremote"
systemctl enable --now ccremote-hub
sleep 2
systemctl --no-pager --lines=8 status ccremote-hub || true
echo
echo "Next: log the hub in, then pair your phone:"
echo "  sudo -u $SVCUSER -H $HOME_DIR/.local/bin/claude auth login     # or: claude setup-token"
echo "  $DIR/print-pairing"
REMOTE
