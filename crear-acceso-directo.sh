#!/usr/bin/env bash
# Crea un lanzador .desktop para arrancar start.sh desde el menu o el escritorio.
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
START="$RAIZ/start.sh"

[ -f "$START" ] || { echo "no encuentro start.sh junto a este script" >&2; exit 1; }
chmod +x "$START"

APPS="$HOME/.local/share/applications"
mkdir -p "$APPS"
DESKTOP="$APPS/whisper-obsidian.desktop"

cat > "$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=Whisper para Obsidian
Comment=Arranca whisper-server y el proxy para el plugin Whisper de Obsidian
Exec=$START
Path=$RAIZ
Icon=audio-input-microphone
Terminal=true
Categories=Utility;AudioVideo;
EOF
chmod +x "$DESKTOP"

echo "Lanzador creado en:"
echo "  $DESKTOP"

# copia opcional al escritorio, si existe
ESCRITORIO="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"
if [ -d "$ESCRITORIO" ]; then
  cp "$DESKTOP" "$ESCRITORIO/whisper-obsidian.desktop"
  chmod +x "$ESCRITORIO/whisper-obsidian.desktop"
  gio set "$ESCRITORIO/whisper-obsidian.desktop" metadata::trusted true 2>/dev/null || true
  echo "  $ESCRITORIO/whisper-obsidian.desktop"
  echo
  echo "En GNOME quiza tengas que hacer click derecho > 'Permitir lanzar' la primera vez."
fi
