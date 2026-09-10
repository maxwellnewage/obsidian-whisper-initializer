#!/usr/bin/env bash
# Levanta whisper-server + el proxy transcodificador en esta misma terminal.
# Ctrl+C o cerrar la terminal apaga ambos servicios.
set -uo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- configuracion: valores por defecto, sobreescribibles en config.sh ---
SERVER_DIR="$RAIZ/whisper-server"
MODEL="models/ggml-large-v3-turbo.bin"
IDIOMA="es"
PUERTO_SERVER=8080
PUERTO_PROXY=8081

[ -f "$RAIZ/config.sh" ] && . "$RAIZ/config.sh"

case "$MODEL" in
  /*) MODEL_PATH="$MODEL" ;;
   *) MODEL_PATH="$SERVER_DIR/$MODEL" ;;
esac

LOG_DIR="${TMPDIR:-/tmp}/obsidian-whisper-local"
LOG_OUT="$LOG_DIR/server-out.log"
LOG_ERR="$LOG_DIR/server-err.log"
PIDS=()

verde()   { printf '\033[32m%s\033[0m\n' "$1"; }
rojo()    { printf '\033[31m%s\033[0m\n' "$1"; }
amarillo(){ printf '\033[33m%s\033[0m\n' "$1"; }

puerto_ocupado() { (echo > "/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1; }

limpiar() {
  trap - EXIT INT TERM HUP
  for pid in "${PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  wait 2>/dev/null
}
trap limpiar EXIT INT TERM HUP

echo
echo "   WHISPER LOCAL PARA OBSIDIAN"
echo "   ==========================="
echo

# --- localizar el binario del servidor ---
SERVER_BIN=""
for candidato in "$SERVER_DIR/whisper-server" "$SERVER_DIR/bin/whisper-server" "$SERVER_DIR/build/bin/whisper-server"; do
  if [ -x "$candidato" ]; then SERVER_BIN="$candidato"; break; fi
done

# --- comprobaciones previas ---
fallos=()
[ -n "$SERVER_BIN" ]        || fallos+=("no encuentro el ejecutable whisper-server en: $SERVER_DIR")
[ -f "$MODEL_PATH" ]        || fallos+=("no encuentro el modelo: $MODEL_PATH")
[ -f "$RAIZ/proxy.js" ]     || fallos+=("no encuentro proxy.js junto a este script")
command -v node   >/dev/null 2>&1 || fallos+=("node no esta instalado (Node.js 18 o superior)")
command -v ffmpeg >/dev/null 2>&1 || fallos+=("ffmpeg no esta instalado")

if [ ${#fallos[@]} -gt 0 ]; then
  rojo "   No puedo arrancar:"
  for f in "${fallos[@]}"; do rojo "     - $f"; done
  if [ ! -f "$RAIZ/config.sh" ]; then
    echo
    amarillo "   Parece que aun no configuraste las rutas."
    echo "   Copia config.example.sh como config.sh y edita SERVER_DIR."
  fi
  exit 1
fi

if puerto_ocupado "$PUERTO_SERVER" || puerto_ocupado "$PUERTO_PROXY"; then
  amarillo "   Ya hay servicios escuchando en $PUERTO_SERVER/$PUERTO_PROXY."
  echo "   No arranco otra copia para no chocar de puerto."
  echo
  verde "   URL para Obsidian:  http://localhost:$PUERTO_PROXY/inference"
  exit 0
fi

mkdir -p "$LOG_DIR"

# los builds ROCm/Vulkan traen sus .so junto al binario
export LD_LIBRARY_PATH="$(dirname "$SERVER_BIN"):$SERVER_DIR:${LD_LIBRARY_PATH:-}"

printf '   Cargando el modelo (unos segundos)...'
"$SERVER_BIN" -m "$MODEL_PATH" --port "$PUERTO_SERVER" -l "$IDIOMA" >"$LOG_OUT" 2>"$LOG_ERR" &
PIDS+=($!)
SERVER_PID=${PIDS[0]}

inicio=$(date +%s)
while ! puerto_ocupado "$PUERTO_SERVER"; do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo " fallo."
    echo
    rojo "   El servidor murio al arrancar. Ultimas lineas del log:"
    tail -n 12 "$LOG_ERR" 2>/dev/null | sed 's/^/     /'
    exit 1
  fi
  if [ $(( $(date +%s) - inicio )) -gt 120 ]; then
    echo " fallo."
    rojo "   El servidor no respondio en 120 segundos."
    exit 1
  fi
  sleep 0.4
done
verde " listo."

cd "$RAIZ"
PORT="$PUERTO_PROXY" UPSTREAM="http://127.0.0.1:$PUERTO_SERVER" WHISPER_LANG="$IDIOMA" node proxy.js &
PIDS+=($!)
sleep 1

echo
echo "   Servidor  :  http://127.0.0.1:$PUERTO_SERVER"
echo "   Proxy     :  http://127.0.0.1:$PUERTO_PROXY"
echo
verde "   URL para Obsidian:  http://localhost:$PUERTO_PROXY/inference"
echo
echo "   Ctrl+C (o cerrar esta terminal) apaga todo."
echo "   ------------------------------------------------------------"
echo

# espera hasta que alguno muera; el trap se encarga del resto
while :; do
  for pid in "${PIDS[@]}"; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo
      amarillo "   Un servicio se detuvo. Apagando el resto..."
      exit 1
    fi
  done
  sleep 1
done
