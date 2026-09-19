#!/usr/bin/env bash
# One-shot relay deploy — run ON the VPS, from the repo's relay/ directory, as a sudoer.
#
#   sudo ./deploy.sh --domain relay.example.com [--secret <hex>] [--port 8787]
#                    [--dir /opt/ccremote/relay] [--user ccremote]
#
# It installs the Node relay as a systemd service and PRINTS a Caddy site block for you to
# add (it does not touch your existing Caddyfile). Node 18+ must already be installed.
set -euo pipefail

DOMAIN=""; SECRET=""; PORT="8787"; DIR="/opt/ccremote/relay"; SVCUSER="ccremote"
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2;;
    --secret) SECRET="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --dir) DIR="$2"; shift 2;;
    --user) SVCUSER="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$DOMAIN" ] || { echo "--domain is required" >&2; exit 2; }
[ -n "$SECRET" ] || SECRET="$(openssl rand -hex 16)"
command -v node >/dev/null || { echo "Node.js 18+ is required (install it first)" >&2; exit 1; }

SRC="$(cd "$(dirname "$0")" && pwd)"
id "$SVCUSER" >/dev/null 2>&1 || useradd --system --home "$DIR" --shell /usr/sbin/nologin "$SVCUSER"
mkdir -p "$DIR"
install -m 0644 "$SRC/relay.mjs" "$SRC/package.json" "$SRC/package-lock.json" "$DIR/"
( cd "$DIR" && npm ci --omit=dev --no-audit --no-fund )
chown -R "$SVCUSER":"$SVCUSER" "$DIR"

install -m 0600 /dev/stdin /etc/ccremote-relay.env <<ENV
CCRELAY_SECRET=$SECRET
CCRELAY_PORT=$PORT
CCRELAY_HOST=127.0.0.1
ENV

install -m 0644 /dev/stdin /etc/systemd/system/ccremote-relay.service <<UNIT
[Unit]
Description=ccremote relay
After=network.target

[Service]
EnvironmentFile=/etc/ccremote-relay.env
WorkingDirectory=$DIR
ExecStart=/usr/bin/env node relay.mjs --port \${CCRELAY_PORT} --host \${CCRELAY_HOST}
Restart=always
User=$SVCUSER
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now ccremote-relay
sleep 1
systemctl --no-pager --lines=5 status ccremote-relay || true

cat <<DONE

── relay service is up on 127.0.0.1:$PORT ─────────────────────────────
Add this to your Caddy config (it auto-provisions TLS and upgrades WebSockets):

  $DOMAIN {
      reverse_proxy 127.0.0.1:$PORT
  }

then: sudo systemctl reload caddy

Point the Mac at it:

  ccremote --relay wss://$DOMAIN --relay-secret $SECRET
  # or persist:
  scripts/install-launchagent.sh --relay wss://$DOMAIN --relay-secret $SECRET

Relay secret (also in /etc/ccremote-relay.env): $SECRET
───────────────────────────────────────────────────────────────────────
DONE
