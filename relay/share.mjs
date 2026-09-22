// Share links for ccremote transcripts.
//
// The phone renders a transcript as an HTML page and seals it (AES-256-GCM) with a fresh key; the
// Mac posts only the ciphertext here, authenticated with the relay secret. A link is
// https://relay/s/<id>#<key>: browsers never send the #fragment, so the relay — and the Mac — hold
// ciphertext they cannot read. The viewer page decrypts in the reader's browser and shows the
// result in a sandboxed frame (no scripts, no access to this origin).

import { randomBytes, timingSafeEqual } from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const MAX_TTL = 7 * 24 * 3600;             // seconds
const MAX_BODY = 6 * 1024 * 1024;          // bytes of JSON (4 MB of ciphertext as base64, plus room)
const MAX_PER_ROOM = 200;
const MAX_TOTAL = 500 * 1024 * 1024;       // bytes across all shares

export class ShareStore {
  constructor({ dir, log }) {
    this.dir = dir;
    this.log = log;
    this.items = new Map();                // id -> { room, iv, ct, expiresAt, createdAt }
    if (dir) {
      fs.mkdirSync(dir, { recursive: true });
      for (const name of fs.readdirSync(dir)) {
        if (!name.endsWith(".json")) continue;
        try {
          const rec = JSON.parse(fs.readFileSync(path.join(dir, name), "utf8"));
          if (rec.expiresAt > Date.now()) this.items.set(name.slice(0, -5), rec);
          else fs.rmSync(path.join(dir, name), { force: true });
        } catch {}
      }
      log(`shares: ${this.items.size} kept from ${dir}`);
    }
    setInterval(() => this.sweep(), 60_000).unref();
  }

  get totalBytes() { let n = 0; for (const r of this.items.values()) n += r.ct.length; return n; }

  add(room, iv, ct, ttl) {
    let inRoom = 0;
    for (const r of this.items.values()) if (r.room === room) inRoom++;
    if (inRoom >= MAX_PER_ROOM) throw Object.assign(new Error("too many links for this Mac — revoke some"), { status: 429 });
    if (this.totalBytes + ct.length > MAX_TOTAL) throw Object.assign(new Error("the relay is out of room for links"), { status: 507 });
    const id = randomBytes(16).toString("base64url");
    const now = Date.now();
    const rec = { room, iv, ct, createdAt: now, expiresAt: now + Math.min(Math.max(60, ttl | 0), MAX_TTL) * 1000 };
    this.items.set(id, rec);
    if (this.dir) fs.writeFileSync(path.join(this.dir, `${id}.json`), JSON.stringify(rec), { mode: 0o600 });
    return { id, expiresAt: rec.expiresAt };
  }

  get(id) {
    const rec = this.items.get(id);
    if (!rec) return null;
    if (rec.expiresAt <= Date.now()) { this.remove(id); return null; }
    return rec;
  }

  remove(id) {
    this.items.delete(id);
    if (this.dir) fs.rmSync(path.join(this.dir, `${id}.json`), { force: true });
  }

  sweep() {
    const now = Date.now();
    for (const [id, rec] of this.items) if (rec.expiresAt <= now) this.remove(id);
  }
}

function secretMatches(given, secret) {
  if (typeof given !== "string") return false;
  const a = Buffer.from(given), b = Buffer.from(secret);
  return a.length === b.length && timingSafeEqual(a, b);
}

function json(res, status, body) {
  res.writeHead(status, { "Content-Type": "application/json", "Cache-Control": "no-store" });
  res.end(JSON.stringify(body));
}

function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (c) => {
      size += c.length;
      if (size > limit) { reject(Object.assign(new Error("too large"), { status: 413 })); req.destroy(); return; }
      chunks.push(c);
    });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

const B64 = /^[A-Za-z0-9+/]+={0,2}$/;
const ID = /^[A-Za-z0-9_-]{16,64}$/;

/** Handles the share routes; everything else is a 404 (WebSocket upgrades never reach here). */
export async function handleShareHTTP(req, res, { store, secret, log }) {
  const url = new URL(req.url, "http://relay");
  const parts = url.pathname.split("/").filter(Boolean);

  if (req.method === "GET" && url.pathname === "/healthz") { res.writeHead(200); res.end("ok"); return; }

  if (parts[0] === "share") {
    if (!secretMatches(req.headers["x-relay-secret"], secret)) return json(res, 401, { error: "bad secret" });
    const room = String(req.headers["x-relay-room"] || "");
    if (!room) return json(res, 400, { error: "no room" });
    if (req.method === "POST" && parts.length === 1) {
      let body;
      try { body = JSON.parse((await readBody(req, MAX_BODY)).toString("utf8")); }
      catch (e) { return json(res, e.status || 400, { error: e.status === 413 ? "too large" : "bad json" }); }
      const { iv, ct, ttl } = body || {};
      if (typeof iv !== "string" || typeof ct !== "string" || !B64.test(iv) || !B64.test(ct)) return json(res, 400, { error: "bad payload" });
      try {
        const created = store.add(room, iv, ct, Number(ttl) || 86400);
        log(`share created room=${room} id=${created.id.slice(0, 6)}… ${ct.length} bytes`);
        return json(res, 200, created);
      } catch (e) { return json(res, e.status || 500, { error: e.message }); }
    }
    if (req.method === "DELETE" && parts.length === 2) {
      const rec = store.get(parts[1]);
      if (!rec || rec.room !== room) return json(res, 404, { error: "not found" });
      store.remove(parts[1]);
      log(`share revoked room=${room} id=${parts[1].slice(0, 6)}…`);
      return json(res, 200, { ok: true });
    }
    return json(res, 405, { error: "method not allowed" });
  }

  if (req.method === "GET" && parts[0] === "s" && parts.length === 2 && ID.test(parts[1])) {
    res.writeHead(200, {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "Referrer-Policy": "no-referrer",
      "X-Robots-Tag": "noindex, nofollow",
      "X-Content-Type-Options": "nosniff",
      // The viewer's own script is the only one that runs; the transcript itself goes into a
      // sandboxed frame, which also inherits this policy (its inline styles are allowed, nothing else).
      "Content-Security-Policy": "default-src 'none'; script-src 'self'; connect-src 'self'; style-src 'unsafe-inline'; img-src data:; frame-src 'self' about:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
    });
    res.end(VIEWER_HTML);
    return;
  }

  if (req.method === "GET" && parts[0] === "s" && parts.length === 3 && parts[2] === "data" && ID.test(parts[1])) {
    const rec = store.get(parts[1]);
    if (!rec) return json(res, 404, { error: "gone" });
    return json(res, 200, { iv: rec.iv, ct: rec.ct, expiresAt: rec.expiresAt });
  }

  if (req.method === "GET" && url.pathname === "/viewer.js") {
    res.writeHead(200, { "Content-Type": "text/javascript; charset=utf-8", "Cache-Control": "public, max-age=300", "X-Content-Type-Options": "nosniff" });
    res.end(VIEWER_JS);
    return;
  }

  res.writeHead(404, { "Content-Type": "text/plain" });
  res.end("not found");
}

const VIEWER_HTML = `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Shared transcript</title>
<style>
:root{--bg:#f9f9f7;--fg:#1a1a18;--muted:#73726c}
@media (prefers-color-scheme:dark){:root{--bg:#1c1c1a;--fg:#ecebe6;--muted:#a09f99}}
html,body{margin:0;height:100%;background:var(--bg);color:var(--fg);font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
#status{position:fixed;inset:0;display:flex;align-items:center;justify-content:center;padding:24px;text-align:center;color:var(--muted)}
#page{position:fixed;inset:0;width:100%;height:100%;border:0;display:none;background:var(--bg)}
</style></head>
<body><div id="status">Decrypting…</div><iframe id="page" sandbox="allow-same-origin" title="Transcript"></iframe>
<script src="/viewer.js"></script></body></html>`;

const VIEWER_JS = `(async () => {
  const status = document.getElementById("status");
  const frame = document.getElementById("page");
  const fail = (text) => { status.textContent = text; };
  const b64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
  const b64url = (s) => b64(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4));
  const key = location.hash.slice(1);
  // The key never leaves this browser; take it out of the address bar so it isn't copied by accident.
  history.replaceState(null, "", location.pathname);
  if (!key) return fail("This link is missing its key — ask for the full link again.");
  if (!window.crypto || !crypto.subtle) return fail("This browser cannot decrypt the page (it needs a secure connection).");
  let data;
  try {
    const res = await fetch(location.pathname + "/data", { cache: "no-store" });
    if (res.status === 404) return fail("This link has expired or was revoked.");
    if (!res.ok) return fail("The page could not be loaded (" + res.status + ").");
    data = await res.json();
  } catch { return fail("The page could not be loaded."); }
  try {
    const k = await crypto.subtle.importKey("raw", b64url(key), "AES-GCM", false, ["decrypt"]);
    const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: b64(data.iv) }, k, b64(data.ct));
    frame.srcdoc = new TextDecoder().decode(plain);
    frame.style.display = "block";
    status.style.display = "none";
    const titled = new DOMParser().parseFromString(frame.srcdoc, "text/html").title;
    if (titled) document.title = titled;
  } catch { fail("The key does not match this page — the link may be damaged."); }
})();`;
