#!/usr/bin/env node
// ccremote relay — lets phones reach a Mac's ccremote daemon when they're not on the same
// network. The daemon dials OUT to /agent (so it works behind NAT); phones connect to /client;
// the relay glues each phone to a fresh daemon-dialed /agent-conn and forwards frames verbatim.
//
// The ccremote pairing token still authenticates the phone to the daemon end-to-end. The relay
// only forwards bytes — but it CAN read them, so run it on a host you control. Put TLS in front
// (see relay/README.md); this process listens plain on 127.0.0.1 by default.
//
//   CCRELAY_SECRET=... node relay.mjs [--port 8787] [--host 127.0.0.1] [--data /var/lib/ccremote-relay]
//
// Env: CCRELAY_SECRET (required) — shared secret the daemon presents on /agent and /agent-conn.
//      CCRELAY_DATA — where share links are kept across restarts (memory only when unset).
//
// It also hosts share links (see share.mjs): the Mac posts a transcript page the phone sealed with a
// key only the phone has; people open /s/<id>#<key> and the page is decrypted in their browser.

import http from "node:http";
import { WebSocketServer } from "ws";
import { parse as parseURL } from "node:url";
import { ShareStore, handleShareHTTP } from "./share.mjs";

const args = process.argv.slice(2);
function opt(name, def) { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : def; }
const PORT = parseInt(opt("--port", process.env.CCRELAY_PORT || "8787"), 10);
const HOST = opt("--host", process.env.CCRELAY_HOST || "127.0.0.1");
const SECRET = process.env.CCRELAY_SECRET;
if (!SECRET) { console.error("CCRELAY_SECRET is required"); process.exit(2); }
const CLIENT_WAIT_MS = 20000;

const log = (...a) => console.log(new Date().toISOString(), ...a);

const rooms = new Map();           // room -> { agent: ws }
const pending = new Map();         // connId -> { client, agentConn, buf: [], timer }
let connSeq = 0;

const DATA = opt("--data", process.env.CCRELAY_DATA || "");
const shares = new ShareStore({ dir: DATA || null, log });

// One HTTP server: share links over plain requests, the relay itself over WebSocket upgrades.
const server = http.createServer((req, res) => {
  handleShareHTTP(req, res, { store: shares, secret: SECRET, log }).catch((e) => {
    log(`share: ${e?.message || e}`);
    if (!res.headersSent) { res.writeHead(500, { "Content-Type": "application/json" }); res.end('{"error":"internal"}'); }
  });
});
const wss = new WebSocketServer({ server });
server.listen(PORT, HOST, () => log(`relay listening on ws://${HOST}:${PORT}${DATA ? ` · shares in ${DATA}` : " · shares in memory"}`));

wss.on("connection", (ws, req) => {
  const { pathname, query } = parseURL(req.url, true);
  const room = query.room;
  if (pathname === "/agent") return onAgent(ws, room, query.secret);
  if (pathname === "/agent-conn") return onAgentConn(ws, room, query.secret, query.conn);
  if (pathname === "/client") return onClient(ws, room);
  ws.close(1008, "unknown path");
});

function onAgent(ws, room, secret) {
  if (secret !== SECRET) { ws.close(1008, "bad secret"); return; }
  if (!room) { ws.close(1008, "no room"); return; }
  const existing = rooms.get(room);
  if (existing?.agent) { try { existing.agent.close(1012, "replaced"); } catch {} }
  rooms.set(room, { agent: ws });
  log(`agent registered room=${room}`);
  ws.on("close", () => { if (rooms.get(room)?.agent === ws) { rooms.delete(room); log(`agent gone room=${room}`); } });
  ws.on("error", () => {});
}

function onClient(ws, room) {
  const entry = rooms.get(room);
  if (!entry?.agent || entry.agent.readyState !== entry.agent.OPEN) { ws.close(1013, "no agent"); return; }
  const connId = `${Date.now().toString(36)}-${(connSeq++).toString(36)}`;
  const rec = { client: ws, agentConn: null, buf: [], timer: null };
  pending.set(connId, rec);
  log(`client in room=${room} conn=${connId}`);
  try { entry.agent.send(JSON.stringify({ t: "new", conn: connId })); }
  catch { ws.close(1011, "agent send failed"); pending.delete(connId); return; }

  rec.timer = setTimeout(() => {
    if (pending.get(connId) === rec && !rec.agentConn) { log(`conn ${connId} timed out waiting for agent`); try { ws.close(1013, "agent did not connect"); } catch {}; pending.delete(connId); }
  }, CLIENT_WAIT_MS);

  ws.on("message", (data, isBinary) => {
    if (rec.agentConn) send(rec.agentConn, data, isBinary);
    else rec.buf.push([data, isBinary]);   // buffer until the agent-conn is glued
  });
  ws.on("close", () => { if (rec.agentConn) try { rec.agentConn.close(); } catch {}; cleanup(connId); });
  ws.on("error", () => {});
}

function onAgentConn(ws, room, secret, connId) {
  if (secret !== SECRET) { ws.close(1008, "bad secret"); return; }
  const rec = pending.get(connId);
  if (!rec) { ws.close(1008, "unknown conn"); return; }
  clearTimeout(rec.timer);
  rec.agentConn = ws;
  log(`bridged conn=${connId}`);
  for (const [data, isBinary] of rec.buf) send(ws, data, isBinary);
  rec.buf = [];
  ws.on("message", (data, isBinary) => send(rec.client, data, isBinary));
  ws.on("close", () => { try { rec.client.close(); } catch {}; cleanup(connId); });
  ws.on("error", () => {});
}

function send(ws, data, isBinary) {
  if (ws && ws.readyState === ws.OPEN) { try { ws.send(data, { binary: isBinary }); } catch {} }
}

function cleanup(connId) {
  const rec = pending.get(connId);
  if (!rec) return;
  clearTimeout(rec.timer);
  pending.delete(connId);
}

process.on("SIGINT", () => process.exit(0));
process.on("SIGTERM", () => process.exit(0));
