#!/usr/bin/env bash
# Starts whisper-server and the transcoding proxy in this terminal.
# Ctrl+C, or closing the terminal, shuts both services down.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- configuration: defaults, overridable in config.sh ---
SERVER_DIR="$ROOT/whisper-server"
MODEL="models/ggml-large-v3-turbo.bin"
LANGUAGE="en"
SERVER_PORT=8080
PROXY_PORT=8081

[ -f "$ROOT/config.sh" ] && . "$ROOT/config.sh"

case "$MODEL" in
  /*) MODEL_PATH="$MODEL" ;;
   *) MODEL_PATH="$SERVER_DIR/$MODEL" ;;
esac

LOG_DIR="${TMPDIR:-/tmp}/obsidian-whisper-local"
LOG_OUT="$LOG_DIR/server-out.log"
LOG_ERR="$LOG_DIR/server-err.log"
PIDS=()

green()  { printf '\033[32m%s\033[0m\n' "$1"; }
red()    { printf '\033[31m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }

port_in_use() { (echo > "/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1; }

cleanup() {
  trap - EXIT INT TERM HUP
  for pid in "${PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  wait 2>/dev/null
}
trap cleanup EXIT INT TERM HUP

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

if port_in_use "$SERVER_PORT" || port_in_use "$PROXY_PORT"; then
  yellow "   Something is already listening on $SERVER_PORT/$PROXY_PORT."
  echo "   Not starting a second copy, to avoid a port clash."
  echo
  green "   URL for Obsidian:  http://localhost:$PROXY_PORT/inference"
  exit 0
fi

mkdir -p "$LOG_DIR"

# the ROCm and Vulkan tarballs ship their .so files next to the binary
export LD_LIBRARY_PATH="$(dirname "$SERVER_BIN"):$SERVER_DIR:${LD_LIBRARY_PATH:-}"

printf '   Loading the model (a few seconds)...'
"$SERVER_BIN" -m "$MODEL_PATH" --port "$SERVER_PORT" -l "$LANGUAGE" >"$LOG_OUT" 2>"$LOG_ERR" &
PIDS+=($!)
SERVER_PID=${PIDS[0]}

started=$(date +%s)
while ! port_in_use "$SERVER_PORT"; do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo " failed."
    echo
    red "   The server died on startup. Last lines of the log:"
    tail -n 12 "$LOG_ERR" 2>/dev/null | sed 's/^/     /'
    exit 1
  fi
  if [ $(( $(date +%s) - started )) -gt 120 ]; then
    echo " failed."
    red "   The server did not respond within 120 seconds."
    exit 1
  fi
  sleep 0.4
done
green " ready."

cd "$ROOT"
PORT="$PROXY_PORT" UPSTREAM="http://127.0.0.1:$SERVER_PORT" WHISPER_LANG="$LANGUAGE" node proxy.js &
PIDS+=($!)
sleep 1

echo
echo "   Server :  http://127.0.0.1:$SERVER_PORT"
echo "   Proxy  :  http://127.0.0.1:$PROXY_PORT"
echo
green "   URL for Obsidian:  http://localhost:$PROXY_PORT/inference"
echo
echo "   Ctrl+C, or closing this terminal, shuts everything down."
echo "   ------------------------------------------------------------"
echo

# wait until one of them dies; the trap takes care of the rest
while :; do
  for pid in "${PIDS[@]}"; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo
      yellow "   A service stopped. Shutting down the rest..."
      exit 1
    fi
  done
  sleep 1
done
