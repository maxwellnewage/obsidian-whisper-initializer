// Transcoding proxy for the whisper.cpp server.
// Obsidian (webm/opus) -> [ffmpeg -> wav 16k mono] -> whisper-server (/inference)
const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");
const crypto = require("crypto");

const PORT = Number(process.env.PORT || 8081);
const UPSTREAM = process.env.UPSTREAM || "http://127.0.0.1:8080";
const FFMPEG = process.env.FFMPEG || "ffmpeg";
const DEFAULT_LANG = process.env.WHISPER_LANG || "en";

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
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  if (req.method === "OPTIONS") return res.writeHead(204).end();
  if (req.method !== "POST") return res.writeHead(405).end("POST only");

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

      const ext = path.extname(filePart.filename || "") || ".webm";
      inFile = path.join(tmp, `whisper-${id}${ext}`);
      fs.writeFileSync(inFile, filePart.data);
      console.log(`[${new Date().toISOString()}] received ${filePart.filename} (${filePart.data.length} bytes) -> wav`);
      await toWav(inFile, outFile);

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
      res.writeHead(500, { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" });
      res.end(JSON.stringify({ error: e.message }));
    } finally {
      for (const f of [inFile, outFile]) { try { if (f) fs.unlinkSync(f); } catch {} }
    }
  });
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`whisper-proxy listening on http://127.0.0.1:${PORT}/inference -> ${UPSTREAM}`);
});
