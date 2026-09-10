#!/usr/bin/env bash
# Starts the transcoding proxy in this terminal. The proxy starts whisper-server
# by itself on the first transcription, and stops it again after IDLE_TIMEOUT
# seconds of silence, so the model is not sitting in VRAM while you are not
# dictating.
# Ctrl+C, or closing the terminal, shuts everything down.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- configuration: defaults, overridable in config.sh ---
SERVER_DIR="$ROOT/whisper-server"
MODEL="models/ggml-large-v3-turbo.bin"
LANGUAGE="en"
SERVER_PORT=8080
PROXY_PORT=8081
IDLE_TIMEOUT=900
PRELOAD=false

[ -f "$ROOT/config.sh" ] && . "$ROOT/config.sh"

case "$MODEL" in
  /*) MODEL_PATH="$MODEL" ;;
   *) MODEL_PATH="$SERVER_DIR/$MODEL" ;;
esac

LOG_DIR="${TMPDIR:-/tmp}/obsidian-whisper-local"

green()  { printf '\033[32m%s\033[0m\n' "$1"; }
red()    { printf '\033[31m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }

port_in_use() { (echo > "/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1; }

# The proxy answers any GET with a JSON body naming itself, which tells it apart
# from whatever else might be holding the port.
proxy_health() {
  {
    exec 3<>"/dev/tcp/127.0.0.1/$PROXY_PORT" || return 1
    printf 'GET /health HTTP/1.0\r\nHost: localhost\r\n\r\n' >&3
    cat <&3
    exec 3<&-
  } 2>/dev/null
}

echo
echo "   LOCAL WHISPER FOR OBSIDIAN"
echo "   =========================="
echo

# --- locate the server binary ---
SERVER_BIN=""
for candidate in "$SERVER_DIR/whisper-server" "$SERVER_DIR/bin/whisper-server" "$SERVER_DIR/build/bin/whisper-server"; do
  if [ -x "$candidate" ]; then SERVER_BIN="$candidate"; break; fi
done

# --- preflight checks ---
problems=()
[ -n "$SERVER_BIN" ]    || problems+=("cannot find the whisper-server executable in: $SERVER_DIR")
[ -f "$MODEL_PATH" ]    || problems+=("cannot find the model: $MODEL_PATH")
[ -f "$ROOT/proxy.js" ] || problems+=("cannot find proxy.js next to this script")
command -v node   >/dev/null 2>&1 || problems+=("node is not installed (Node.js 18 or newer)")
command -v ffmpeg >/dev/null 2>&1 || problems+=("ffmpeg is not installed")

if [ ${#problems[@]} -gt 0 ]; then
  red "   Cannot start:"
  for p in "${problems[@]}"; do red "     - $p"; done
  if [ ! -f "$ROOT/config.sh" ]; then
    echo
    yellow "   Looks like you haven't configured your paths yet."
    echo "   Copy config.example.sh to config.sh and set SERVER_DIR."
  fi
  exit 1
fi

# A second copy would only fight the first one for the port. The server port is
# not checked here: the proxy adopts or reaps whatever it finds on it.
if port_in_use "$PROXY_PORT"; then
  if proxy_health | grep -q whisper-proxy; then
    yellow "   The proxy is already running on port $PROXY_PORT."
    echo "   Nothing to do — this window can be closed."
    echo
    green "   URL for Obsidian:  http://localhost:$PROXY_PORT/inference"
    exit 0
  fi
  red "   Port $PROXY_PORT is taken by something that is not this proxy."
  echo "   Stop it, or set a different PROXY_PORT in config.sh."
  exit 1
fi

mkdir -p "$LOG_DIR"

# the ROCm and Vulkan tarballs ship their .so files next to the binary
export LD_LIBRARY_PATH="$(dirname "$SERVER_BIN"):$SERVER_DIR:${LD_LIBRARY_PATH:-}"

echo "   Proxy  :  http://127.0.0.1:$PROXY_PORT"
if [ "$PRELOAD" = true ]; then
  echo "   Server :  starting now, on port $SERVER_PORT"
else
  echo "   Server :  starts on your first recording, on port $SERVER_PORT"
fi
if [ "$IDLE_TIMEOUT" -gt 0 ]; then
  if [ "$IDLE_TIMEOUT" -ge 60 ]; then idle_for="$((IDLE_TIMEOUT / 60)) min"; else idle_for="$IDLE_TIMEOUT s"; fi
  echo "             and stops again after $idle_for without dictation"
fi
echo
green "   URL for Obsidian:  http://localhost:$PROXY_PORT/inference"
echo
echo "   Ctrl+C, or closing this terminal, shuts everything down."
echo "   ------------------------------------------------------------"
echo

# exec: node becomes this process, so it receives Ctrl+C and the terminal's
# HUP directly, and there is no shell left in between to lose track of it.
cd "$ROOT"
exec env \
  PORT="$PROXY_PORT" \
  UPSTREAM="http://127.0.0.1:$SERVER_PORT" \
  WHISPER_LANG="$LANGUAGE" \
  WHISPER_BIN="$SERVER_BIN" \
  WHISPER_MODEL="$MODEL_PATH" \
  WHISPER_DIR="$SERVER_DIR" \
  WHISPER_IDLE_TIMEOUT="$IDLE_TIMEOUT" \
  WHISPER_LOG_DIR="$LOG_DIR" \
  WHISPER_PRELOAD="$([ "$PRELOAD" = true ] && echo 1 || echo 0)" \
  node proxy.js
