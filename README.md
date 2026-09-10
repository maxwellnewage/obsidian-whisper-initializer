# obsidian-whisper-initializer

**Fully local** speech-to-text for the [Obsidian Whisper plugin](https://github.com/nikdanilov/whisper-obsidian-plugin), running [whisper.cpp](https://github.com/ggerganov/whisper.cpp) on your own machine. No API key, and your audio never leaves your computer.

One click on a desktop shortcut starts everything; closing the window shuts it down. The model is only loaded while you are actually dictating, so it does not hold onto your VRAM all day. Works on **Windows and Linux**.

## The problem this solves

The Obsidian plugin records through `MediaRecorder`, and Electron/Chromium only ever hands you **webm/opus**. The whisper.cpp server only decodes **WAV PCM** — support for other formats requires building with `WHISPER_FFMPEG`, which is tied to libav and only works on Linux.

Point the plugin straight at the server and it fails:

```
error: failed to decode audio data from memory buffer
error: failed to read audio data
```

This repo adds a **proxy** that sits in between, converts the audio with ffmpeg and forwards it in the format the server understands:

```
Obsidian ──webm/opus──> proxy :8081 ──ffmpeg──> wav 16kHz mono ──> whisper-server :8080
```

The proxy also handles two details that otherwise ruin the experience:

- The plugin sends `language: ""` when no language is selected, and that empty field makes the server fail. The proxy strips it and injects the configured language instead.
- Some server versions return the transcription split into segments joined by newlines, breaking even mid-word (`ver\nificar`). The proxy requests `split_on_word` and returns flowing text. The `srt` and `vtt` formats are passed through untouched, since there the line breaks are structural.

Because the proxy sees every request, it is also what decides when the server needs to be running at all — see [When the model is loaded](#when-the-model-is-loaded).

## Requirements

**Windows**

| | |
|---|---|
| Windows | 10 or 11 |
| PowerShell | 7 or newer (`winget install Microsoft.PowerShell`) |
| Node.js | 18 or newer (`winget install OpenJS.NodeJS`) |
| ffmpeg | on your PATH (`winget install Gyan.FFmpeg`) |
| whisper-server | see below |

**Linux**

| | |
|---|---|
| bash | any recent version |
| Node.js | 18 or newer (`sudo apt install nodejs`) |
| ffmpeg | `sudo apt install ffmpeg` |
| whisper-server | see below |

## Setup

### 1. Download a whisper.cpp build

Pick the build that matches your hardware. For **AMD GPUs**, the builds from [lemonade-sdk/whisper.cpp-rocm](https://github.com/lemonade-sdk/whisper.cpp-rocm/releases) bundle the ROCm runtimes, so there is no HIP SDK to install:

| Hardware | Windows | Linux |
|---|---|---|
| AMD RDNA4 (RX 9070 / 9060) | `*-windows-rocm-gfx120X.zip` | `*-linux-rocm-gfx120X.tar.gz` |
| AMD RDNA3 (RX 7900 / 7800, 780M iGPU) | `*-windows-rocm-gfx110X.zip` | `*-linux-rocm-gfx110X.tar.gz` |
| Ryzen AI 300 / MAX+ | `*-windows-rocm-gfx1150.zip` / `gfx1151` | `*-linux-rocm-gfx1150.tar.gz` / `gfx1151` |
| Any GPU (AMD, NVIDIA, Intel) | `*-windows-vulkan-x64.zip` | `*-linux-vulkan-x86_64.tar.gz` |
| No GPU | `*-windows-cpu-x64.zip` | `*-linux-cpu-x86_64.tar.gz` |

For **NVIDIA**, the [official whisper.cpp releases](https://github.com/ggerganov/whisper.cpp/releases) ship CUDA builds.

Extract it anywhere — `C:\whisper-server\` on Windows, `~/whisper-server/` on Linux — and check that it contains `whisper-server.exe` (or `whisper-server` on Linux).

### 2. Download a model

Grab one from [Hugging Face](https://huggingface.co/ggerganov/whisper.cpp/tree/main). Recommended: **`ggml-large-v3-turbo.bin`** (1.6 GB) — the best quality-to-speed ratio, and far better than the small models on non-English audio. If you are running on CPU and find it slow, try `ggml-base.bin` (148 MB).

Put it in a `models` folder inside the server directory.

### 3. Configure

**Windows**

```powershell
copy config.example.ps1 config.ps1
```

```powershell
$ServerDir   = "C:\whisper-server"
$Model       = "models\ggml-large-v3-turbo.bin"
$Language    = "en"                            # transcription language
$IdleTimeout = 900                             # unload the model after 15 min idle
```

**Linux**

```bash
cp config.example.sh config.sh
```

```bash
SERVER_DIR="$HOME/whisper-server"
MODEL="models/ggml-large-v3-turbo.bin"
LANGUAGE="en"                                  # transcription language
IDLE_TIMEOUT=900                               # unload the model after 15 min idle
```

### 4. Start it

**Windows**

```powershell
pwsh -NoProfile -File .\start.ps1
```

**Linux**

```bash
./start.sh
```

To get a one-click desktop shortcut:

```powershell
pwsh -NoProfile -File .\create-shortcut.ps1     # Windows
```

```bash
./create-shortcut.sh                            # Linux (.desktop launcher)
```

### 5. Point the plugin at the proxy

In Obsidian: **Settings → Whisper → API URL**

```
http://localhost:8081/inference
```

Leave the API key empty. That's it.

## Performance

Measured on 23 seconds of speech with large-v3-turbo:

| | Time | Speed |
|---|---|---|
| CPU (Ryzen 5 5600X, 6 threads) | 10.7 s | 0.46× real time |
| GPU (Radeon RX 9070 XT, ROCm) | 0.24 s | ~95× real time |

On GPU, transcription is effectively instant.

Loading the model adds about a second on GPU and a few on CPU, and only on the first recording after an idle period.

## When the model is loaded

`large-v3-turbo` takes roughly 2 GB of VRAM, and whisper.cpp holds it for as long as the server process lives. Keeping that resident all day so you can dictate twice is a poor trade, so the two processes have very different lifetimes:

- The **proxy** runs the whole time. It is an idle Node process: a few tens of MB of RAM, no VRAM, no GPU context.
- The **server** is started by the proxy on your first recording, and stopped again after `IDLE_TIMEOUT` seconds without a transcription. The model leaves memory; the next recording brings it back.

The launcher script does not start the server at all any more — it only starts the proxy and hands it the paths it needs.

A cold start costs the model load, which the proxy overlaps with the ffmpeg transcode so you pay the longer of the two rather than the sum. On a GPU that is a second or two; on CPU it is slower, and `PRELOAD=true` (`$Preload = $true` on Windows) restores the old behaviour of loading at startup. `IDLE_TIMEOUT=0` keeps the model loaded once it is up.

## How the shutdown works

The proxy owns the server process, so there is one place that has to get this right rather than two.

On **Windows**, `start.ps1` runs the proxy as a child of its own console and binds it to a **Job Object** with `KILL_ON_JOB_CLOSE`. Job membership is inherited, so the server the proxy spawns lands in the same job. Closing the window kills both, even on an abrupt close — the kernel guarantees it, rather than an event handler that might never get to run.

On **Linux**, `start.sh` `exec`s into Node, so the proxy *is* the process the terminal owns; there is no shell in between to lose track of anything. It handles `SIGINT`, `SIGTERM` and `SIGHUP` by stopping the server (`SIGTERM`, then `SIGKILL` after 5 s) before exiting.

That leaves one gap that no handler can close: `SIGKILL` on the proxy itself, or a hard logout. The server would survive as an orphan holding VRAM. So the proxy writes its server's pid to `whisper-server.pid` in the log directory, and on the next start:

- if that pid is alive and serving the port, it **adopts** it instead of failing on a port collision — and it is then subject to the idle timeout like any other,
- if the pid is alive but no longer listening, it is **reaped**,
- if something else is on the port, the proxy uses it but never kills it, since it is not ours to manage.

The launcher only refuses to start when the *proxy* port is taken, and it tells apart another copy of itself (`GET /health` reports `whisper-proxy`) from an unrelated program, which are two different problems with two different fixes.

## Troubleshooting

**`failed to decode audio data`** — the plugin is pointing at the server (8080) instead of the proxy (8081).

**The server dies on startup with `GGML_ASSERT(ctx->mem_buffer != NULL) failed`** — you are running a 32-bit binary. An x86 process cannot address the ~2 GB that large-v3-turbo needs. Use an x64 build.

**`no GPU found` in the log** — you downloaded the CPU build, or one that doesn't match your GPU architecture.

**Odd line breaks in the text** — make sure Obsidian points at the proxy, not the server.

**It won't start and mentions `config.ps1`** — step 3 is missing.

**The first recording after a while takes a couple of seconds longer** — that is the model being loaded again after the idle timeout. Raise `IDLE_TIMEOUT`, set it to `0`, or turn on `PRELOAD`.

**`Port 8081 is taken by something that is not this proxy`** — some other program has the port. Change `PROXY_PORT` in your config (and the URL in Obsidian to match).

## Advanced configuration

`proxy.js` reads these environment variables, and the launcher scripts fill them in from your config file:

| | |
|---|---|
| `PORT` | port the proxy listens on (8081) |
| `UPSTREAM` | where the server is (`http://127.0.0.1:8080`) |
| `FFMPEG` | ffmpeg binary (`ffmpeg`) |
| `WHISPER_LANG` | language passed to the server (`en`) |
| `WHISPER_BIN` | server executable — **unset it to manage the server yourself** |
| `WHISPER_MODEL` | model passed to `-m` |
| `WHISPER_DIR` | working directory for the server |
| `WHISPER_IDLE_TIMEOUT` | seconds of silence before unloading, `0` to never (900) |
| `WHISPER_START_TIMEOUT` | seconds to wait for the model to load (120) |
| `WHISPER_PRELOAD` | `1` to load at startup instead of on demand |
| `WHISPER_LOG_DIR` | server logs and pid file (`$TMPDIR/obsidian-whisper-local`) |

Without `WHISPER_BIN` and `WHISPER_MODEL`, or with a non-loopback `UPSTREAM`, the proxy manages nothing and just forwards to whatever is already listening — which is what you want if you run the server under systemd or on another machine.

On Linux, `start.sh` also sets `LD_LIBRARY_PATH` to the server directory, which the ROCm and Vulkan tarballs need in order to find their bundled `.so` files.

## Credits

- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) by Georgi Gerganov
- [whisper.cpp-rocm](https://github.com/lemonade-sdk/whisper.cpp-rocm) for the AMD builds
- [Whisper for Obsidian](https://github.com/nikdanilov/whisper-obsidian-plugin) by Nik Danilov

MIT.
