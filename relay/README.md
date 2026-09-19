# ccremote relay

Lets your phone reach the Mac's `ccremote` daemon when they're **not on the same network**.

```
 iPhone (ClaudeRemote)                relay (your VPS)                 Mac (ccremote)
        │  wss://relay/client?room ───────►│                                 │
        │                                  │◄──── wss://relay/agent (control)┤  (dials OUT)
        │                                  │──── {"t":"new","conn":id} ─────►│
        │                                  │◄──── wss://relay/agent-conn ────┤  (dials OUT per phone)
        │  ◄════════ frames bridged 1:1 ══════════════════════════════════► │
```

The Mac **dials out** to the relay, so nothing needs to be exposed at home (works behind NAT/CGNAT).
The ccremote **pairing token still authenticates the phone to the daemon end-to-end** — the relay
only forwards frames. It *can* read them, though, so **run it on a host you control**.

## Run it

Needs Node 18+. On the VPS:

```bash
cd relay
npm install
CCRELAY_SECRET="$(openssl rand -hex 16)" node relay.mjs --port 8787 --host 127.0.0.1
```

- `CCRELAY_SECRET` — shared secret the daemon must present on `/agent` and `/agent-conn`. Keep it
  private; it's what stops a stranger from registering as your Mac.
- The relay listens **plain ws on 127.0.0.1** by default — put TLS in front (below).

### TLS with Caddy (recommended)

`Caddyfile`:

```
relay.example.com {
    reverse_proxy 127.0.0.1:8787
}
```

Caddy gets a Let's Encrypt cert automatically and upgrades WebSockets. Your relay base URL is then
`wss://relay.example.com`.

### systemd unit

`/etc/systemd/system/ccremote-relay.service`:

```ini
[Unit]
Description=ccremote relay
After=network.target

[Service]
Environment=CCRELAY_SECRET=<your-secret>
WorkingDirectory=/opt/ccremote/relay
ExecStart=/usr/bin/node relay.mjs --port 8787 --host 127.0.0.1
Restart=always
User=ccremote

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now ccremote-relay
```

## Point the Mac at it

```bash
ccremote --relay wss://relay.example.com --relay-secret <your-secret>
# or persist it:
scripts/install-launchagent.sh --relay wss://relay.example.com --relay-secret <your-secret>
```

The daemon prints a pairing URL/QR that now carries both the **direct** address (used on the LAN) and
the **relay** route. The app tries direct first, then falls back to the relay — so the same pairing
works at home and away. `--room` defaults to a stable per-Mac id (stored in the support dir); pass it
explicitly to run several Macs through one relay.

## WireGuard / Tailscale instead

If you'd rather not run a relay, a mesh VPN needs **no relay and no app code**: put the Mac and phone
on the same WireGuard/Tailscale net and pair by the Mac's VPN address (e.g. `wss://mac.tailnet.ts.net:7811`).
The relay is the option for when you don't want a VPN client on the phone.
