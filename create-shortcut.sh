#!/usr/bin/env bash
# Creates a .desktop launcher so start.sh can be run from the menu or the desktop.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
START="$ROOT/start.sh"

[ -f "$START" ] || { echo "cannot find start.sh next to this script" >&2; exit 1; }
chmod +x "$START"

APPS="$HOME/.local/share/applications"
mkdir -p "$APPS"
DESKTOP="$APPS/whisper-obsidian.desktop"

cat > "$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=Whisper for Obsidian
Comment=Starts whisper-server and the proxy for the Obsidian Whisper plugin
Exec=$START
Path=$ROOT
Icon=audio-input-microphone
Terminal=true
Categories=Utility;AudioVideo;
EOF
chmod +x "$DESKTOP"

echo "Launcher created at:"
echo "  $DESKTOP"

# optional copy on the desktop, if there is one
DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"
if [ -d "$DESKTOP_DIR" ]; then
  cp "$DESKTOP" "$DESKTOP_DIR/whisper-obsidian.desktop"
  chmod +x "$DESKTOP_DIR/whisper-obsidian.desktop"
  gio set "$DESKTOP_DIR/whisper-obsidian.desktop" metadata::trusted true 2>/dev/null || true
  echo "  $DESKTOP_DIR/whisper-obsidian.desktop"
  echo
  echo "On GNOME you may need to right-click > 'Allow launching' the first time."
fi
