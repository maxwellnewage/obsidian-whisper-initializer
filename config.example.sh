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
