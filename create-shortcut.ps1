# Creates a desktop shortcut that starts start.ps1 with one click.
$root  = $PSScriptRoot
$start = Join-Path $root "start.ps1"

if (-not (Test-Path $start)) { Write-Host "cannot find start.ps1 next to this script" -ForegroundColor Red; exit 1 }
$pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwshExe) { Write-Host "PowerShell 7 required: winget install Microsoft.PowerShell" -ForegroundColor Red; exit 1 }

$desktop = [Environment]::GetFolderPath("Desktop")
$lnk = Join-Path $desktop "Whisper for Obsidian.lnk"

$w = New-Object -ComObject WScript.Shell
$s = $w.CreateShortcut($lnk)
$s.TargetPath       = $pwshExe
$s.Arguments        = "-NoProfile -ExecutionPolicy Bypass -File `"$start`""
$s.WorkingDirectory = $root
$s.Description      = "Starts whisper-server and the proxy for the Obsidian Whisper plugin"
$icon = "$env:SystemRoot\System32\mmres.dll"
if (Test-Path $icon) { $s.IconLocation = "$icon,0" }
$s.Save()

Write-Host "Shortcut created at:" -ForegroundColor Green
Write-Host "  $lnk"
