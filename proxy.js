// Transcoding proxy and supervisor for the whisper.cpp server.
// Obsidian (webm/opus) -> [ffmpeg -> wav 16k mono] -> whisper-server (/inference)
//
// The proxy is the only thing that stays up. whisper-server is started on the
// first transcription and stopped again after WHISPER_IDLE_TIMEOUT seconds of
// silence, so the model only occupies VRAM while you are actually dictating.
const http = require("http");
const net = require("net");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");
const crypto = require("crypto");

const PORT = Number(process.env.PORT || 8081);
const UPSTREAM = process.env.UPSTREAM || "http://127.0.0.1:8080";
const FFMPEG = process.env.FFMPEG || "ffmpeg";
const DEFAULT_LANG = process.env.WHISPER_LANG || "en";

function envNumber(name, fallback) {
  const v = process.env[name];
  if (v === undefined || v.trim() === "") return fallback;
  const n = Number(v);
  return Number.isFinite(n) && n >= 0 ? n : fallback;
}

// --- supervisor configuration ---
const SERVER_BIN = process.env.WHISPER_BIN || "";
const SERVER_MODEL = process.env.WHISPER_MODEL || "";
const SERVER_DIR = process.env.WHISPER_DIR || (SERVER_BIN ? path.dirname(SERVER_BIN) : "");
const IDLE_TIMEOUT = envNumber("WHISPER_IDLE_TIMEOUT", 900); // seconds; 0 = never stop it
const START_TIMEOUT = envNumber("WHISPER_START_TIMEOUT", 120);
const PRELOAD = /^(1|true|yes)$/i.test(process.env.WHISPER_PRELOAD || "");
const LOG_DIR = process.env.WHISPER_LOG_DIR || path.join(os.tmpdir(), "obsidian-whisper-local");
const PID_FILE = path.join(LOG_DIR, "whisper-server.pid");
const ERR_LOG = path.join(LOG_DIR, "server-err.log");

const upstream = new URL(UPSTREAM);
const SERVER_HOST = upstream.hostname;
const SERVER_PORT = Number(upstream.port) || 80;
// We only take charge of a server we can actually reach and restart ourselves.
const MANAGED =
  Boolean(SERVER_BIN && SERVER_MODEL) &&
  ["127.0.0.1", "localhost", "::1"].includes(SERVER_HOST);

function log(msg) {
  console.log(`[${new Date().toISOString()}] ${msg}`);
}

// ---------------------------------------------------------------------------
// whisper-server lifecycle
// ---------------------------------------------------------------------------

let serverPid = null; // the process we are responsible for stopping
let external = false; // a server we did not start: use it, never kill it
let starting = null; // in-flight start, shared by concurrent requests
let idleTimer = null;
let inFlight = 0;

function probe(timeout = 500) {
  return new Promise((resolve) => {
    const sock = net.connect({ host: SERVER_HOST, port: SERVER_PORT });
    const done = (ok) => { sock.destroy(); resolve(ok); };
    sock.setTimeout(timeout);
    sock.once("connect", () => done(true));
    sock.once("timeout", () => done(false));
    sock.once("error", () => done(false));
  });
}

function alive(pid) {
  try { process.kill(pid, 0); return true; } catch { return false; }
}

function readPidFile() {
  try {
    const pid = Number(fs.readFileSync(PID_FILE, "utf8").trim());
    return Number.isInteger(pid) && pid > 1 ? pid : null;
  } catch { return null; }
}

function writePidFile(pid) {
  try { fs.writeFileSync(PID_FILE, String(pid)); } catch { }
}

function clearPidFile() {
  try { fs.unlinkSync(PID_FILE); } catch { }
}

// Guards against adopting — and later killing — an unrelated process that has
// been given the pid our last run wrote down.
function looksLikeTheServer(pid) {
  try { return /whisper/i.test(fs.readFileSync(`/proc/${pid}/cmdline`, "utf8")); }
  catch { return process.platform !== "linux"; }
}

function stopPid(pid) {
  try { process.kill(pid, "SIGTERM"); } catch { }
  setTimeout(() => {
    if (alive(pid)) { try { process.kill(pid, "SIGKILL"); } catch { } }
  }, 5000).unref();
}

function stopServer(reason) {
  if (!serverPid) return;
  const pid = serverPid;
  serverPid = null;
  clearIdleTimer();
  clearPidFile();
  log(`stopping whisper-server, pid ${pid} (${reason})`);
  stopPid(pid);
}

function clearIdleTimer() {
  if (idleTimer) { clearTimeout(idleTimer); idleTimer = null; }
}

function armIdleTimer() {
  clearIdleTimer();
  if (!IDLE_TIMEOUT || !serverPid || inFlight > 0) return;
  idleTimer = setTimeout(() => stopServer(`idle for ${IDLE_TIMEOUT}s`), IDLE_TIMEOUT * 1000);
  idleTimer.unref();
}

function tailErrLog(lines = 12) {
  try {
    return fs.readFileSync(ERR_LOG, "utf8").trimEnd().split("\n").slice(-lines).join("\n");
  } catch { return "(no log)"; }
}

function unavailable(message) {
  const e = new Error(message);
  e.status = 503;
  return e;
}

async function spawnServer() {
  fs.mkdirSync(LOG_DIR, { recursive: true });
  const out = fs.openSync(path.join(LOG_DIR, "server-out.log"), "a");
  const err = fs.openSync(ERR_LOG, "a");
  const args = ["-m", SERVER_MODEL, "--port", String(SERVER_PORT), "-l", DEFAULT_LANG];

  log("starting whisper-server (loading the model)");
  const p = spawn(SERVER_BIN, args, { cwd: SERVER_DIR || undefined, stdio: ["ignore", out, err] });
  // Written before the server is ready, so that a crash of this proxy still
  // leaves a trail for the next run to clean up.
  if (p.pid) writePidFile(p.pid);
  p.once("exit", (code, signal) => {
    for (const fd of [out, err]) { try { fs.closeSync(fd); } catch { } }
    if (serverPid === p.pid) { serverPid = null; clearPidFile(); clearIdleTimer(); }
    log(`whisper-server exited (${signal || "code " + code})`);
  });

  await new Promise((resolve, reject) => {
    let settled = false;
    const t0 = Date.now();
    const finish = (fn, arg) => { if (!settled) { settled = true; fn(arg); } };

    p.once("error", (e) =>
      finish(reject, unavailable(`could not run whisper-server: ${e.message}`)));

    const tick = async () => {
      if (settled) return;
      if (p.exitCode !== null || p.signalCode) {
        clearPidFile();
        return finish(reject, unavailable(
          `whisper-server died on startup. Last lines of the log:\n${tailErrLog()}`));
      }
      if (await probe()) return finish(resolve);
      if (Date.now() - t0 > START_TIMEOUT * 1000) {
        stopPid(p.pid);
        clearPidFile();
        return finish(reject, unavailable(
          `whisper-server did not respond within ${START_TIMEOUT}s`));
      }
      setTimeout(tick, 300);
    };
    setTimeout(tick, 300);
  });

  serverPid = p.pid;
  log(`whisper-server ready, pid ${p.pid}`);
}

async function resolveServer() {
  external = false;

  // A server left behind by an earlier run: take it over rather than fight it
  // for the port, so it becomes subject to the idle timeout like any other.
  const orphan = readPidFile();
  if (orphan && alive(orphan) && looksLikeTheServer(orphan)) {
    if (await probe()) {
      serverPid = orphan;
      log(`adopted the whisper-server from an earlier run, pid ${orphan}`);
      return;
    }
    log(`reaping a leftover whisper-server that is no longer listening, pid ${orphan}`);
    stopPid(orphan);
    clearPidFile();
  }

  if (await probe()) {
    external = true;
    log(`${UPSTREAM} is already being served by someone else; leaving its lifecycle alone`);
    return;
  }

  await spawnServer();
}

async function ensureServer() {
  if (!MANAGED) return;
  if (starting) return starting;
  if (serverPid && alive(serverPid)) return;
  if (serverPid) { log("whisper-server is gone; starting a fresh one"); serverPid = null; }
  if (external && (await probe())) return;

  starting = resolveServer();
  try { await starting; } finally { starting = null; }
}

function serverStatus() {
  if (!MANAGED) return "unmanaged";
  if (starting) return "starting";
  if (external) return "external";
  return serverPid ? "running" : "stopped";
}

// ---------------------------------------------------------------------------
// transcoding
// ---------------------------------------------------------------------------

function parseMultipart(buf, boundary) {
  const parts = [];
  const delim = Buffer.from("--" + boundary);
  let i = buf.indexOf(delim);
  if (i < 0) return parts;
  i += delim.length;
  while (i < buf.length) {
    if (buf[i] === 0x2d && buf[i + 1] === 0x2d) break; // closing "--"
    if (buf[i] === 0x0d && buf[i + 1] === 0x0a) i += 2;
    const headerEnd = buf.indexOf("\r\n\r\n", i);
    if (headerEnd < 0) break;
    const headers = buf.slice(i, headerEnd).toString("utf8");
    const bodyStart = headerEnd + 4;
    const next = buf.indexOf(delim, bodyStart);
    if (next < 0) break;
    const name = /name="([^"]*)"/.exec(headers);
    const filename = /filename="([^"]*)"/.exec(headers);
    parts.push({
      name: name ? name[1] : "",
      filename: filename ? filename[1] : null,
      data: buf.slice(bodyStart, next - 2), // drop the CRLF before the delimiter
    });
    i = next + delim.length;
  }
  return parts;
}

function toWav(inputFile, outputFile) {
  return new Promise((resolve, reject) => {
    const args = ["-hide_banner", "-loglevel", "error", "-y",
      "-i", inputFile, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", outputFile];
    const p = spawn(FFMPEG, args);
    let err = "";
    p.stderr.on("data", (d) => (err += d));
    p.on("error", (e) => reject(new Error("could not run ffmpeg: " + e.message)));
    p.on("close", (code) => (code === 0 ? resolve() : reject(new Error("ffmpeg exited " + code + ": " + err))));
  });
}

// The server splits the transcription into segments joined by newlines.
// For a voice note we want flowing text, not chopped-up columns.
function joinSegments(text) {
  return text.replace(/\s*\n\s*/g, " ").replace(/[ \t]{2,}/g, " ").trim();
}

const server = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  if (req.method === "OPTIONS") return res.writeHead(204).end();

  // Lets the launcher tell this proxy apart from anything else on the port.
  if (req.method === "GET") {
    res.writeHead(200, { "Content-Type": "application/json" });
    return res.end(JSON.stringify({
      name: "whisper-proxy",
      upstream: UPSTREAM,
      server: serverStatus(),
      idleTimeout: IDLE_TIMEOUT,
    }));
  }
  if (req.method !== "POST") return res.writeHead(405).end("POST only");

  inFlight++;
  clearIdleTimer();
  let released = false;
  const release = () => {
    if (released) return;
    released = true;
    inFlight--;
    armIdleTimer();
  };
  res.on("close", release); // covers a request the plugin gives up on

  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", async () => {
    const tmp = os.tmpdir();
    const id = crypto.randomBytes(6).toString("hex");
    let inFile = null;
    const outFile = path.join(tmp, `whisper-${id}.wav`);
    try {
      const ct = req.headers["content-type"] || "";
      const bm = /boundary=(?:"([^"]+)"|([^;]+))/.exec(ct);
      if (!bm) throw new Error("missing multipart boundary");
      const parts = parseMultipart(Buffer.concat(chunks), (bm[1] || bm[2]).trim());
      const filePart = parts.find((p) => p.filename !== null) || parts.find((p) => p.name === "file");
      if (!filePart) throw new Error("no audio file in the request");

      // Load the model while ffmpeg works, so a cold start costs the longer of
      // the two rather than the sum.
      let startupError = null;
      const serverReady = ensureServer().catch((e) => { startupError = e; });

      const ext = path.extname(filePart.filename || "") || ".webm";
      inFile = path.join(tmp, `whisper-${id}${ext}`);
      fs.writeFileSync(inFile, filePart.data);
      log(`received ${filePart.filename} (${filePart.data.length} bytes) -> wav`);
      await toWav(inFile, outFile);

      await serverReady;
      if (startupError) throw startupError;

      const fd = new FormData();
      fd.append("file", new Blob([fs.readFileSync(outFile)], { type: "audio/wav" }), "audio.wav");
      const sent = new Set();
      let format = "json";
      for (const p of parts) {
        if (p.filename !== null) continue;
        const v = p.data.toString("utf8");
        if (!v || p.name === "model" || p.name === "file") continue; // empty fields break the server
        if (p.name === "response_format") format = v;
        sent.add(p.name);
        fd.append(p.name, v);
      }
      if (!sent.has("language"))      fd.append("language", DEFAULT_LANG);
      if (!sent.has("split_on_word")) fd.append("split_on_word", "true"); // never cut mid-word
      if (!sent.has("max_len"))       fd.append("max_len", "0");

      const target = UPSTREAM + (req.url && req.url !== "/" ? req.url : "/inference");
      const up = await fetch(target, { method: "POST", body: fd });
      let body = Buffer.from(await up.arrayBuffer());

      // srt/vtt need their line breaks; json and text do not.
      if (up.ok && (format === "json" || format === "verbose_json" || format === "text")) {
        const raw = body.toString("utf8");
        try {
          const j = JSON.parse(raw);
          if (typeof j.text === "string") {
            j.text = joinSegments(j.text);
            body = Buffer.from(JSON.stringify(j), "utf8");
          }
        } catch {
          body = Buffer.from(joinSegments(raw), "utf8"); // plain text response
        }
      }

      res.writeHead(up.status, {
        "Content-Type": up.headers.get("content-type") || "application/json",
        "Access-Control-Allow-Origin": "*",
      });
      res.end(body);
      console.log(`  -> ${up.status} ${body.toString("utf8").slice(0, 200)}`);
    } catch (e) {
      console.error("  !! " + e.message);
      res.writeHead(e.status || 500, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
      res.end(JSON.stringify({ error: e.message }));
    } finally {
      for (const f of [inFile, outFile]) { try { if (f) fs.unlinkSync(f); } catch { } }
      release();
    }
  });
});

// ---------------------------------------------------------------------------
// shutdown
// ---------------------------------------------------------------------------

for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(signal, () => {
    stopServer(`proxy shutting down on ${signal}`);
    server.close();
    process.exit(0);
  });
}
// Last resort: an uncaught error must not leave the model resident.
process.on("exit", () => {
  if (serverPid) { try { process.kill(serverPid, "SIGTERM"); } catch { } }
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`whisper-proxy listening on http://127.0.0.1:${PORT}/inference -> ${UPSTREAM}`);
  if (!MANAGED) {
    console.log("  whisper-server: not managed (expecting one to be running already)");
  } else if (IDLE_TIMEOUT) {
    console.log(`  whisper-server: started on demand, stopped after ${IDLE_TIMEOUT}s idle`);
  } else {
    console.log("  whisper-server: started on demand, then left running");
  }
  if (MANAGED && PRELOAD) {
    ensureServer().then(armIdleTimer, (e) => log("preload failed: " + e.message));
  }
});
