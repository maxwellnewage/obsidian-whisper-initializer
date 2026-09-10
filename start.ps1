# Starts the transcoding proxy in this console. The proxy starts whisper-server
# by itself on the first transcription, and stops it again after $IdleTimeout
# seconds of silence, so the model is not sitting in VRAM while you are not
# dictating.
# Closing this window shuts everything down.
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot

# --- configuration: defaults, overridable in config.ps1 ---
$ServerDir   = Join-Path $root "whisper-server"
$Model       = "models\ggml-large-v3-turbo.bin"
$Language    = "en"
$ServerPort  = 8080
$ProxyPort   = 8081
$IdleTimeout = 900
$Preload     = $false

$config = Join-Path $root "config.ps1"
if (Test-Path $config) { . $config }

if (-not [IO.Path]::IsPathRooted($Model)) { $ModelPath = Join-Path $ServerDir $Model } else { $ModelPath = $Model }
$ServerBin = Join-Path $ServerDir "whisper-server.exe"
$logDir = Join-Path $env:TEMP "obsidian-whisper-local"

function Test-Port($port) {
  try { $c = New-Object Net.Sockets.TcpClient; $c.Connect("127.0.0.1", $port); $c.Close(); return $true }
  catch { return $false }
}
# The proxy answers any GET with a JSON body naming itself, which tells it apart
# from whatever else might be holding the port.
function Test-OurProxy($port) {
  try { return (Invoke-RestMethod -Uri "http://127.0.0.1:$port/health" -TimeoutSec 2).name -eq "whisper-proxy" }
  catch { return $false }
}
function Exit-WithPause($code) {
  Write-Host ""; Read-Host "  Press Enter to close"; exit $code
}

try { Clear-Host } catch { }
Write-Host ""
Write-Host "   LOCAL WHISPER FOR OBSIDIAN" -ForegroundColor Cyan
Write-Host "   ==========================" -ForegroundColor Cyan
Write-Host ""

# --- preflight checks ---
$problems = @()
if (-not (Test-Path $ServerBin))                             { $problems += "cannot find whisper-server.exe in: $ServerDir" }
if (-not (Test-Path $ModelPath))                             { $problems += "cannot find the model: $ModelPath" }
if (-not (Test-Path (Join-Path $root "proxy.js")))           { $problems += "cannot find proxy.js next to this script" }
if (-not (Get-Command node   -ErrorAction SilentlyContinue)) { $problems += "node is not on your PATH (install Node.js 18 or newer)" }
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $problems += "ffmpeg is not on your PATH (winget install Gyan.FFmpeg)" }

if ($problems.Count -gt 0) {
  Write-Host "   Cannot start:" -ForegroundColor Red
  foreach ($p in $problems) { Write-Host "     - $p" -ForegroundColor Red }
  if (-not (Test-Path $config)) {
    Write-Host ""
    Write-Host "   Looks like you haven't configured your paths yet." -ForegroundColor Yellow
    Write-Host "   Copy config.example.ps1 to config.ps1 and set ServerDir."
  }
  Exit-WithPause 1
}

# A second copy would only fight the first one for the port. The server port is
# not checked here: the proxy adopts or reaps whatever it finds on it.
if (Test-Port $ProxyPort) {
  if (Test-OurProxy $ProxyPort) {
    Write-Host "   The proxy is already running on port $ProxyPort." -ForegroundColor Yellow
    Write-Host "   Nothing to do - this window can be closed."
    Write-Host ""
    Write-Host "   URL for Obsidian:  http://localhost:$ProxyPort/inference" -ForegroundColor Green
    Exit-WithPause 0
  }
  Write-Host "   Port $ProxyPort is taken by something that is not this proxy." -ForegroundColor Red
  Write-Host "   Stop it, or set a different ProxyPort in config.ps1."
  Exit-WithPause 1
}

# --- tie the proxy to this window: if it dies, Windows kills it with it ---
# whisper-server inherits the job from the proxy that spawns it, so the same
# guarantee covers the model process without us tracking it here.
$jobSrc = @"
using System;
using System.Runtime.InteropServices;
public static class WindowJob {
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
try { Add-Type -TypeDefinition $jobSrc -ErrorAction Stop; $jobOk = [WindowJob]::Init() } catch { $jobOk = $false }

New-Item -ItemType Directory -Path $logDir -Force | Out-Null

$proxy = $null
try {
  $env:PORT                  = "$ProxyPort"
  $env:UPSTREAM              = "http://127.0.0.1:$ServerPort"
  $env:WHISPER_LANG          = $Language
  $env:WHISPER_BIN           = $ServerBin
  $env:WHISPER_MODEL         = $ModelPath
  $env:WHISPER_DIR           = $ServerDir
  $env:WHISPER_IDLE_TIMEOUT  = "$IdleTimeout"
  $env:WHISPER_LOG_DIR       = $logDir
  $env:WHISPER_PRELOAD       = if ($Preload) { "1" } else { "0" }

  $proxy = Start-Process -FilePath "node" -ArgumentList "proxy.js" `
    -WorkingDirectory $root -NoNewWindow -PassThru
  if ($jobOk) { $null = [WindowJob]::Add($proxy.Handle) }
  Start-Sleep -Milliseconds 600

  Write-Host ""
  Write-Host "   Proxy  :  http://127.0.0.1:$ProxyPort"
  if ($Preload) {
    Write-Host "   Server :  starting now, on port $ServerPort"
  } else {
    Write-Host "   Server :  starts on your first recording, on port $ServerPort"
  }
  if ($IdleTimeout -gt 0) {
    $idleFor = if ($IdleTimeout -ge 60) { "$([int]($IdleTimeout / 60)) min" } else { "$IdleTimeout s" }
    Write-Host "             and stops again after $idleFor without dictation"
  }
  Write-Host ""
  Write-Host "   URL for Obsidian:  http://localhost:$ProxyPort/inference" -ForegroundColor Green
  Write-Host ""
  Write-Host "   Close this window to shut everything down." -ForegroundColor DarkGray
  Write-Host "   ------------------------------------------------------------"
  Write-Host ""

  while (-not $proxy.HasExited) { Start-Sleep -Seconds 1 }
  Write-Host ""
  Write-Host "   The proxy stopped." -ForegroundColor Yellow
}
catch {
  Write-Host ""
  Write-Host "   Error: $_" -ForegroundColor Red
  Exit-WithPause 1
}
finally {
  if ($proxy -and -not $proxy.HasExited) { Stop-Process -Id $proxy.Id -Force -ErrorAction SilentlyContinue }
}
