# Crea un acceso directo en el escritorio que arranca start.ps1 con un click.
$raiz  = $PSScriptRoot
$start = Join-Path $raiz "start.ps1"

if (-not (Test-Path $start)) { Write-Host "no encuentro start.ps1 junto a este script" -ForegroundColor Red; exit 1 }
$pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwshExe) { Write-Host "necesitas PowerShell 7: winget install Microsoft.PowerShell" -ForegroundColor Red; exit 1 }

$escritorio = [Environment]::GetFolderPath("Desktop")
$lnk = Join-Path $escritorio "Whisper para Obsidian.lnk"

$w = New-Object -ComObject WScript.Shell
$s = $w.CreateShortcut($lnk)
$s.TargetPath       = $pwshExe
$s.Arguments        = "-NoProfile -ExecutionPolicy Bypass -File `"$start`""
$s.WorkingDirectory = $raiz
$s.Description      = "Arranca whisper-server y el proxy para el plugin Whisper de Obsidian"
$icono = "$env:SystemRoot\System32\mmres.dll"
if (Test-Path $icono) { $s.IconLocation = "$icono,0" }
$s.Save()

Write-Host "Acceso directo creado en:" -ForegroundColor Green
Write-Host "  $lnk"
