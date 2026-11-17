// AnnotateKit relay: the public half of the remote delivery mode.
//
//   App (Kit)  --HTTPS POST-->  relay  <--HTTPS pull--  agent (annotate CLI / MCP)
//
// A tunnel (e.g. cloudflared) publishes this to the internet; every process shares one key that is
// regenerated per run. Storage is plain files under --dir, one directory per session id, mirroring
// the on-device bundle layout so both ends speak the same shapes as the LAN mode.
//
// ponytail: bearer-token auth, no per-user accounts, no TLS termination here (the tunnel does it).
// Sessions are pruned by age; bump the limits when real usage shows they bite.

import { createServer } from "node:http";
import { mkdir, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { join, normalize, sep } from "node:path";

const args = process.argv.slice(2);
const arg = (name, fallback) => {
  const i = args.indexOf("--" + name);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
};

const PORT = Number(arg("port", process.env.PORT ?? 8099));
const HOST = arg("host", "127.0.0.1");
const DIR = arg("dir", process.env.ANNOTATE_RELAY_DIR ?? "/tmp/annotate-relay");
const KEY = arg("key", process.env.ANNOTATE_RELAY_KEY ?? "");
const MAX_AGE_MS = Number(arg("max-age-hours", 72)) * 3600_000;

if (!KEY || KEY.length < 16) {
  console.error("annotate-relay: --key (>=16 chars) or ANNOTATE_RELAY_KEY is required");
  process.exit(2);
}

const authorized = (req) => {
  const header = req.headers.authorization ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : "";
  return token.length === KEY.length && token === KEY;
};

const send = (res, status, body, type = "application/json; charset=utf-8") => {
  const payload = typeof body === "string" || body instanceof Uint8Array ? body : JSON.stringify(body);
  res.writeHead(status, { "content-type": type, "content-length": Buffer.byteLength(payload) });
  res.end(payload);
};

const body = async (req, limit = 64 * 1024 * 1024) => {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > limit) throw new Error("payload too large");
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
};

const safeId = (id) => typeof id === "string" && /^[A-Za-z0-9._-]{4,80}$/.test(id) && !id.includes("..");
const safeRel = (rel) => rel.split("/").every((part) => part && part !== ".." && !part.startsWith("."));

const sessionDir = (id) => join(DIR, id);

const prune = async () => {
  try {
    const entries = await readdir(DIR);
    const now = Date.now();
    for (const id of entries) {
      const path = sessionDir(id);
      const info = await stat(path);
      if (now - info.mtimeMs > MAX_AGE_MS) await rm(path, { recursive: true, force: true });
    }
  } catch {}
};

const server = createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", "http://relay");
  const parts = url.pathname.split("/").filter(Boolean);

  if (parts[0] === "health") return send(res, 200, { ok: true });

  if (!authorized(req)) return send(res, 401, { error: "unauthorized" });

  try {
    if (parts[0] !== "v1" || parts[1] !== "sessions") return send(res, 404, { error: "not found" });
    const id = parts[2];

    if (!id) {
      if (req.method === "GET") {
        await prune();
        const entries = await readdir(DIR).catch(() => []);
        const complete = [];
        for (const name of entries) {
          if (!safeId(name)) continue;
          try {
            await stat(join(sessionDir(name), "session.json"));
            complete.push(name);
          } catch {}
        }
        return send(res, 200, { sessions: complete.sort().reverse() });
      }
      if (req.method === "POST") {
        // Upsert a whole bundle: { files: { "session.json": base64, "prompt.md": base64, … } }
        const payload = JSON.parse((await body(req)).toString("utf8"));
        if (!safeId(payload.id) || typeof payload.files !== "object") {
          return send(res, 400, { error: "id and files required" });
        }
        const target = sessionDir(payload.id);
        await mkdir(target, { recursive: true });
        for (const [rel, b64] of Object.entries(payload.files)) {
          if (!safeRel(rel)) return send(res, 400, { error: "bad path " + rel });
          const file = join(target, normalize(rel));
          if (!file.startsWith(target + sep)) return send(res, 400, { error: "bad path " + rel });
          await mkdir(join(file, ".."), { recursive: true });
          await writeFile(file, Buffer.from(b64, "base64"));
        }
        return send(res, 200, { ok: true, id: payload.id });
      }
      return send(res, 405, { error: "method not allowed" });
    }

    if (!safeId(id)) return send(res, 400, { error: "bad id" });

    if (req.method === "GET") {
      const rest = parts.slice(3);
      if (rest.length === 0) return send(res, 200, await readFile(join(sessionDir(id), "session.json")).catch(() => null)).catch(() => send(res, 404, { error: "not found" }));
      if (!safeRel(rest.join("/"))) return send(res, 400, { error: "bad path" });
      try {
        const data = await readFile(join(sessionDir(id), rest.join("/")));
        const type = rest.at(-1).endsWith(".png") ? "image/png" : rest.at(-1).endsWith(".json") ? "application/json; charset=utf-8" : "text/plain; charset=utf-8";
        return send(res, 200, data, type);
      } catch {
        return send(res, 404, { error: "not found" });
      }
    }

    if (req.method === "POST") {
      const rest = parts.slice(3);
      if (rest.length !== 1) return send(res, 400, { error: "bad path" });
      const payload = await body(req);
      const file = join(sessionDir(id), rest[0]);
      if (rest[0] === "status.json") {
        await mkdir(sessionDir(id), { recursive: true });
        await writeFile(file, payload);
        return send(res, 200, { ok: true });
      }
      if (rest[0] === "replies.json") {
        let existing = Buffer.alloc(0);
        try { existing = await readFile(file); } catch {}
        const merged = Buffer.concat([existing, existing.length && existing.at(-1) !== 10 ? Buffer.from("\n") : Buffer.alloc(0), payload, payload.at(-1) === 10 ? Buffer.alloc(0) : Buffer.from("\n")]);
        await mkdir(sessionDir(id), { recursive: true });
        await writeFile(file, merged);
        return send(res, 200, { ok: true });
      }
      return send(res, 404, { error: "not found" });
    }

    return send(res, 405, { error: "method not allowed" });
  } catch (error) {
    return send(res, 500, { error: String(error?.message ?? error) });
  }
});

await mkdir(DIR, { recursive: true });
server.listen(PORT, HOST, () => {
  console.log(`annotate-relay listening on http://${HOST}:${PORT} dir=${DIR}`);
});
