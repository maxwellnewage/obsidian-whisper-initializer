# Copy this file as  config.sh  and adjust the paths for your machine.
# config.sh is not tracked by git (see .gitignore).

# Folder where you extracted the whisper.cpp build (the one holding whisper-server).
SERVER_DIR="$HOME/whisper-server"

# Model path, relative to SERVER_DIR (or absolute if you keep it elsewhere).
MODEL="models/ggml-large-v3-turbo.bin"

# Transcription language: en, es, pt, fr...  ("auto" to detect it)
LANGUAGE="en"

# Ports. Only change these if something already uses 8080 or 8081.
SERVER_PORT=8080
PROXY_PORT=8081

# Seconds of silence after which the server is stopped and the model leaves
# VRAM. The next recording starts it again. 0 keeps it loaded forever.
IDLE_TIMEOUT=900

# Load the model at startup instead of waiting for the first recording. Worth
# turning on if you transcribe on CPU, where a cold start is slow.
PRELOAD=false
