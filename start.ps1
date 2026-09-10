# Levanta whisper-server (GPU/CPU) + el proxy transcodificador en esta misma consola.
# Cerrar esta ventana apaga ambos servicios.
$ErrorActionPreference = "Stop"
$raiz = $PSScriptRoot

# --- configuracion: valores por defecto, sobreescribibles en config.ps1 ---
$ServerDir    = Join-Path $raiz "whisper-server"
$Model        = "models\ggml-large-v3-turbo.bin"
$Idioma       = "es"
$PuertoServer = 8080
$PuertoProxy  = 8081

$config = Join-Path $raiz "config.ps1"
if (Test-Path $config) { . $config }

if (-not [IO.Path]::IsPathRooted($Model)) { $ModelPath = Join-Path $ServerDir $Model } else { $ModelPath = $Model }
$logDir = Join-Path $env:TEMP "obsidian-whisper-local"

function Test-Puerto($puerto) {
  try { $c = New-Object Net.Sockets.TcpClient; $c.Connect("127.0.0.1", $puerto); $c.Close(); return $true }
  catch { return $false }
}
function Salir-Con-Pausa($codigo) {
  Write-Host ""; Read-Host "  Pulsa Enter para cerrar"; exit $codigo
}

try { Clear-Host } catch { }
Write-Host ""
Write-Host "   WHISPER LOCAL PARA OBSIDIAN" -ForegroundColor Cyan
Write-Host "   ===========================" -ForegroundColor Cyan
Write-Host ""

# --- comprobaciones previas ---
$fallos = @()
if (-not (Test-Path (Join-Path $ServerDir "whisper-server.exe"))) { $fallos += "no encuentro whisper-server.exe en: $ServerDir" }
if (-not (Test-Path $ModelPath))                                  { $fallos += "no encuentro el modelo: $ModelPath" }
if (-not (Test-Path (Join-Path $raiz "proxy.js")))                { $fallos += "no encuentro proxy.js junto a este script" }
if (-not (Get-Command node   -ErrorAction SilentlyContinue))      { $fallos += "node no esta en el PATH (instala Node.js 18 o superior)" }
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue))      { $fallos += "ffmpeg no esta en el PATH (winget install Gyan.FFmpeg)" }

if ($fallos.Count -gt 0) {
  Write-Host "   No puedo arrancar:" -ForegroundColor Red
  foreach ($f in $fallos) { Write-Host "     - $f" -ForegroundColor Red }
  if (-not (Test-Path $config)) {
    Write-Host ""
    Write-Host "   Parece que aun no configuraste las rutas." -ForegroundColor Yellow
    Write-Host "   Copia config.example.ps1 como config.ps1 y edita el valor de ServerDir."
  }
  Salir-Con-Pausa 1
}

if ((Test-Puerto $PuertoServer) -or (Test-Puerto $PuertoProxy)) {
  Write-Host "   Ya hay servicios escuchando en $PuertoServer/$PuertoProxy." -ForegroundColor Yellow
  Write-Host "   No arranco otra copia para no chocar de puerto."
  Write-Host ""
  Write-Host "   URL para Obsidian:  http://localhost:$PuertoProxy/inference" -ForegroundColor Green
  Salir-Con-Pausa 0
}

# --- ata los servicios a esta ventana: si muere, Windows los mata con ella ---
$jobSrc = @"
using System;
using System.Runtime.InteropServices;
public static class VentanaJob {
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode)]
  static extern IntPtr CreateJobObject(IntPtr a, string n);
  [DllImport("kernel32.dll")]
  static extern bool SetInformationJobObject(IntPtr j, int c, IntPtr i, uint l);
  [DllImport("kernel32.dll")]
  static extern bool AssignProcessToJobObject(IntPtr j, IntPtr p);
  [StructLayout(LayoutKind.Sequential)] struct IO_COUNTERS { public ulong a,b,c,d,e,f; }
  [StructLayout(LayoutKind.Sequential)] struct BASIC {
    public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
    public uint LimitFlags; public UIntPtr MinWS, MaxWS;
    public uint ActiveProcessLimit; public UIntPtr Affinity;
    public uint PriorityClass, SchedulingClass; }
  [StructLayout(LayoutKind.Sequential)] struct EXTENDED {
    public BASIC Basic; public IO_COUNTERS Io;
    public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcess, PeakJob; }
  static IntPtr job = IntPtr.Zero;
  public static bool Init() {
    job = CreateJobObject(IntPtr.Zero, null);
    if (job == IntPtr.Zero) return false;
    var e = new EXTENDED();
    e.Basic.LimitFlags = 0x2000;              // KILL_ON_JOB_CLOSE
    int len = Marshal.SizeOf(e);
    IntPtr p = Marshal.AllocHGlobal(len);
    Marshal.StructureToPtr(e, p, false);
    bool ok = SetInformationJobObject(job, 9, p, (uint)len);
    Marshal.FreeHGlobal(p);
    return ok;
  }
  public static bool Add(IntPtr h) { return AssignProcessToJobObject(job, h); }
}
"@
try { Add-Type -TypeDefinition $jobSrc -ErrorAction Stop; $jobOk = [VentanaJob]::Init() } catch { $jobOk = $false }

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logOut = Join-Path $logDir "server-out.log"
$logErr = Join-Path $logDir "server-err.log"
$procesos = @()

try {
  Write-Host "   Cargando el modelo (unos segundos)..." -NoNewline
  $procesos += Start-Process -FilePath (Join-Path $ServerDir "whisper-server.exe") `
    -ArgumentList @("-m", "`"$ModelPath`"", "--port", "$PuertoServer", "-l", $Idioma) `
    -WorkingDirectory $ServerDir -NoNewWindow -PassThru `
    -RedirectStandardOutput $logOut -RedirectStandardError $logErr
  if ($jobOk) { $null = [VentanaJob]::Add($procesos[-1].Handle) }

  $t0 = Get-Date
  while (-not (Test-Puerto $PuertoServer)) {
    if ($procesos[0].HasExited) {
      Write-Host " fallo." -ForegroundColor Red
      Write-Host ""
      Write-Host "   El servidor murio al arrancar. Ultimas lineas del log:" -ForegroundColor Red
      Get-Content $logErr -Tail 12 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "     $_" -ForegroundColor DarkGray }
      Salir-Con-Pausa 1
    }
    if (((Get-Date) - $t0).TotalSeconds -gt 120) { throw "el servidor no respondio en 120 segundos" }
    Start-Sleep -Milliseconds 400
  }
  Write-Host " listo." -ForegroundColor Green

  $env:PORT         = "$PuertoProxy"
  $env:UPSTREAM     = "http://127.0.0.1:$PuertoServer"
  $env:WHISPER_LANG = $Idioma
  $procesos += Start-Process -FilePath "node" -ArgumentList "proxy.js" `
    -WorkingDirectory $raiz -NoNewWindow -PassThru
  if ($jobOk) { $null = [VentanaJob]::Add($procesos[-1].Handle) }
  Start-Sleep -Milliseconds 600

  Write-Host ""
  Write-Host "   Servidor  :  http://127.0.0.1:$PuertoServer"
  Write-Host "   Proxy     :  http://127.0.0.1:$PuertoProxy"
  Write-Host ""
  Write-Host "   URL para Obsidian:  http://localhost:$PuertoProxy/inference" -ForegroundColor Green
  Write-Host ""
  Write-Host "   Cierra esta ventana para apagar todo." -ForegroundColor DarkGray
  Write-Host "   ------------------------------------------------------------"
  Write-Host ""

  while (-not ($procesos | Where-Object { $_.HasExited })) { Start-Sleep -Seconds 1 }
  Write-Host ""
  Write-Host "   Un servicio se detuvo. Apagando el resto..." -ForegroundColor Yellow
}
catch {
  Write-Host ""
  Write-Host "   Error: $_" -ForegroundColor Red
  Salir-Con-Pausa 1
}
finally {
  foreach ($p in $procesos) {
    if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
  }
}
