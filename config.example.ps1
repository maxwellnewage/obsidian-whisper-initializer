# Copia este archivo como  config.ps1  y ajusta las rutas a tu equipo.
# config.ps1 no se sube al repositorio (esta en .gitignore).

# Carpeta donde vive whisper-server.exe (el build que descargaste para tu GPU).
$ServerDir = "E:\proyectos\whisper-rocm"

# Ruta del modelo, relativa a $ServerDir (o absoluta si lo tienes en otro sitio).
$Model = "models\ggml-large-v3-turbo.bin"

# Idioma de las transcripciones: es, en, pt, fr...  ("auto" para detectarlo)
$Idioma = "es"

# Puertos. Solo cambialos si ya tienes algo ocupando el 8080 o el 8081.
$PuertoServer = 8080
$PuertoProxy  = 8081
