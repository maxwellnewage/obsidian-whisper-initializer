# Copia este archivo como  config.sh  y ajusta las rutas a tu equipo.
# config.sh no se sube al repositorio (esta en .gitignore).

# Carpeta donde extrajiste el build de whisper.cpp (la que contiene whisper-server).
SERVER_DIR="$HOME/whisper-server"

# Ruta del modelo, relativa a SERVER_DIR (o absoluta si lo tienes en otro sitio).
MODEL="models/ggml-large-v3-turbo.bin"

# Idioma de las transcripciones: es, en, pt, fr...  ("auto" para detectarlo)
IDIOMA="es"

# Puertos. Solo cambialos si ya tienes algo ocupando el 8080 o el 8081.
PUERTO_SERVER=8080
PUERTO_PROXY=8081
