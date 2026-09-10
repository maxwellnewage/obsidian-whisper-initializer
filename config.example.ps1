# Copy this file as  config.ps1  and adjust the paths for your machine.
# config.ps1 is not tracked by git (see .gitignore).

# Folder containing whisper-server.exe (the build you downloaded for your GPU).
$ServerDir = "C:\whisper-server"

# Model path, relative to $ServerDir (or absolute if you keep it elsewhere).
$Model = "models\ggml-large-v3-turbo.bin"

# Transcription language: en, es, pt, fr...  ("auto" to detect it)
$Language = "en"

# Ports. Only change these if something already uses 8080 or 8081.
$ServerPort = 8080
$ProxyPort  = 8081
