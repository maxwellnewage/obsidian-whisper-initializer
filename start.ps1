# Starts whisper-server (GPU/CPU) and the transcoding proxy in this console.
# Closing this window shuts both services down.
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot

# --- configuration: defaults, overridable in config.ps1 ---
$ServerDir  = Join-Path $root "whisper-server"
$Model      = "models\ggml-large-v3-turbo.bin"
$Language   = "en"
$ServerPort = 8080
$ProxyPort  = 8081

$config = Join-Path $root "config.ps1"
if (Test-Path $config) { . $config }

if (-not [IO.Path]::IsPathRooted($Model)) { $ModelPath = Join-Path $ServerDir $Model } else { $ModelPath = $Model }
$logDir = Join-Path $env:TEMP "obsidian-whisper-local"

function Test-Port($port) {
  try { $c = New-Object Net.Sockets.TcpClient; $c.Connect("127.0.0.1", $port); $c.Close(); return $true }
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
if (-not (Test-Path (Join-Path $ServerDir "whisper-server.exe"))) { $problems += "cannot find whisper-server.exe in: $ServerDir" }
if (-not (Test-Path $ModelPath))                                  { $problems += "cannot find the model: $ModelPath" }
if (-not (Test-Path (Join-Path $root "proxy.js")))                { $problems += "cannot find proxy.js next to this script" }
if (-not (Get-Command node   -ErrorAction SilentlyContinue))      { $problems += "node is not on your PATH (install Node.js 18 or newer)" }
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue))      { $problems += "ffmpeg is not on your PATH (winget install Gyan.FFmpeg)" }

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

if ((Test-Port $ServerPort) -or (Test-Port $ProxyPort)) {
  Write-Host "   Something is already listening on $ServerPort/$ProxyPort." -ForegroundColor Yellow
  Write-Host "   Not starting a second copy, to avoid a port clash."
  Write-Host ""
  Write-Host "   URL for Obsidian:  http://localhost:$ProxyPort/inference" -ForegroundColor Green
  Exit-WithPause 0
}

# --- tie the services to this window: if it dies, Windows kills them with it ---
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
$logOut = Join-Path $logDir "server-out.log"
$logErr = Join-Path $logDir "server-err.log"
$processes = @()

try {
  Write-Host "   Loading the model (a few seconds)..." -NoNewline
  $processes += Start-Process -FilePath (Join-Path $ServerDir "whisper-server.exe") `
    -ArgumentList @("-m", "`"$ModelPath`"", "--port", "$ServerPort", "-l", $Language) `
    -WorkingDirectory $ServerDir -NoNewWindow -PassThru `
    -RedirectStandardOutput $logOut -RedirectStandardError $logErr
  if ($jobOk) { $null = [WindowJob]::Add($processes[-1].Handle) }

  $t0 = Get-Date
  while (-not (Test-Port $ServerPort)) {
    if ($processes[0].HasExited) {
      Write-Host " failed." -ForegroundColor Red
      Write-Host ""
      Write-Host "   The server died on startup. Last lines of the log:" -ForegroundColor Red
      Get-Content $logErr -Tail 12 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "     $_" -ForegroundColor DarkGray }
      Exit-WithPause 1
    }
    if (((Get-Date) - $t0).TotalSeconds -gt 120) { throw "the server did not respond within 120 seconds" }
    Start-Sleep -Milliseconds 400
  }
  Write-Host " ready." -ForegroundColor Green

  $env:PORT         = "$ProxyPort"
  $env:UPSTREAM     = "http://127.0.0.1:$ServerPort"
  $env:WHISPER_LANG = $Language
  $processes += Start-Process -FilePath "node" -ArgumentList "proxy.js" `
    -WorkingDirectory $root -NoNewWindow -PassThru
  if ($jobOk) { $null = [WindowJob]::Add($processes[-1].Handle) }
  Start-Sleep -Milliseconds 600

  Write-Host ""
  Write-Host "   Server :  http://127.0.0.1:$ServerPort"
  Write-Host "   Proxy  :  http://127.0.0.1:$ProxyPort"
  Write-Host ""
  Write-Host "   URL for Obsidian:  http://localhost:$ProxyPort/inference" -ForegroundColor Green
  Write-Host ""
  Write-Host "   Close this window to shut everything down." -ForegroundColor DarkGray
  Write-Host "   ------------------------------------------------------------"
  Write-Host ""

  while (-not ($processes | Where-Object { $_.HasExited })) { Start-Sleep -Seconds 1 }
  Write-Host ""
  Write-Host "   A service stopped. Shutting down the rest..." -ForegroundColor Yellow
}
catch {
  Write-Host ""
  Write-Host "   Error: $_" -ForegroundColor Red
  Exit-WithPause 1
}
finally {
  foreach ($p in $processes) {
    if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
  }
}
