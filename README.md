# obsidian-whisper-initializer

**Fully local** speech-to-text for the [Obsidian Whisper plugin](https://github.com/nikdanilov/whisper-obsidian-plugin), running [whisper.cpp](https://github.com/ggerganov/whisper.cpp) on your own machine. No API key, and your audio never leaves your computer.

One click on a desktop shortcut starts everything; closing the window shuts it down.

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

## Requirements

| | |
|---|---|
| Windows | 10 or 11 |
| PowerShell | 7 or newer (`winget install Microsoft.PowerShell`) |
| Node.js | 18 or newer (`winget install OpenJS.NodeJS`) |
| ffmpeg | on your PATH (`winget install Gyan.FFmpeg`) |
| whisper-server | see below |

## Setup

### 1. Download a whisper.cpp build

Pick the build that matches your hardware. For **AMD GPUs**, the builds from [lemonade-sdk/whisper.cpp-rocm](https://github.com/lemonade-sdk/whisper.cpp-rocm/releases) bundle the ROCm runtimes, so there is no HIP SDK to install:

| Hardware | Package |
|---|---|
| AMD RDNA4 (RX 9070 / 9060) | `whisper-*-windows-rocm-gfx120X.zip` |
| AMD RDNA3 (RX 7900 / 7800, 780M iGPU) | `whisper-*-windows-rocm-gfx110X.zip` |
| Ryzen AI 300 / MAX+ | `whisper-*-windows-rocm-gfx1150.zip` / `gfx1151` |
| Any GPU (AMD, NVIDIA, Intel) | `whisper-*-windows-vulkan-x64.zip` |
| No GPU | `whisper-*-windows-cpu-x64.zip` |

For **NVIDIA**, the [official whisper.cpp releases](https://github.com/ggerganov/whisper.cpp/releases) ship CUDA builds.

Extract the zip anywhere, for example `C:\whisper-server\`, and check that it contains `whisper-server.exe`.

### 2. Download a model

Grab one from [Hugging Face](https://huggingface.co/ggerganov/whisper.cpp/tree/main). Recommended: **`ggml-large-v3-turbo.bin`** (1.6 GB) — the best quality-to-speed ratio, and far better than the small models on non-English audio. If you are running on CPU and find it slow, try `ggml-base.bin` (148 MB).

Put it in a `models\` folder inside the server directory.

### 3. Configure

```powershell
copy config.example.ps1 config.ps1
```

Edit `config.ps1` and point it at wherever you extracted the server:

```powershell
$ServerDir = "C:\whisper-server"
$Model     = "models\ggml-large-v3-turbo.bin"
$Idioma    = "es"                              # transcription language
```

### 4. Start it

```powershell
pwsh -NoProfile -File .\start.ps1
```

To get a one-click desktop shortcut:

```powershell
pwsh -NoProfile -File .\crear-acceso-directo.ps1
```

### 5. Point the plugin at the proxy

In Obsidian: **Settings → Whisper → API URL**

```
http://localhost:8081/inference
```

Leave the API key empty. That's it.

## Performance

Measured on 23 seconds of Spanish audio with large-v3-turbo:

| | Time | Speed |
|---|---|---|
| CPU (Ryzen 5 5600X, 6 threads) | 10.7 s | 0.46× real time |
| GPU (Radeon RX 9070 XT, ROCm) | 0.24 s | ~95× real time |

On GPU, transcription is effectively instant.

## How the shutdown works

`start.ps1` runs both services as children of its own console and binds them to a Windows **Job Object** with `KILL_ON_JOB_CLOSE`. Closing the window kills both, even on an abrupt close — the kernel guarantees it, rather than an event handler that might never get to run.

## Troubleshooting

**`failed to decode audio data`** — the plugin is pointing at the server (8080) instead of the proxy (8081).

**The server dies on startup with `GGML_ASSERT(ctx->mem_buffer != NULL) failed`** — you are running a 32-bit binary. An x86 process cannot address the ~2 GB that large-v3-turbo needs. Use an x64 build.

**`no GPU found` in the log** — you downloaded the CPU build, or one that doesn't match your GPU architecture.

**Odd line breaks in the text** — make sure Obsidian points at the proxy, not the server.

**It won't start and mentions `config.ps1`** — step 3 is missing.

## Advanced configuration

`proxy.js` reads these environment variables: `PORT`, `UPSTREAM`, `FFMPEG`, `WHISPER_LANG`. `start.ps1` fills them in from `config.ps1`.

Note: the PowerShell scripts and their console output are in Spanish; the setting names above (`$ServerDir`, `$Model`, `$Idioma`) are the real variable names.

## Credits

- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) by Georgi Gerganov
- [whisper.cpp-rocm](https://github.com/lemonade-sdk/whisper.cpp-rocm) for the AMD builds
- [Whisper for Obsidian](https://github.com/nikdanilov/whisper-obsidian-plugin) by Nik Danilov

MIT.
