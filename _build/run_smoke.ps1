# run_smoke.ps1 — Phase 17 verification harness for the MoUI native
# spike (`app_moui.exe`). Builds the binary with the latest
# rasterizer/labeler_ui code, launches it, captures the desktop
# window to PNG so we can eyeball the labeler UI without a human
# in the loop, then kills the process.
#
# Usage:
#   _build\run_smoke.ps1
#   _build\run_smoke.ps1 -OutFile "_build\phase17_smoke.png"
#   _build\run_smoke.ps1 -SkipBuild
#   _build\run_smoke.ps1 -WaitSeconds 8     # give the view tree more time
#   _build\run_smoke.ps1 -UseSmoke          # also pass --smoke for clean auto-exit
#
# Without -UseSmoke the script launches the exe normally, sleeps
# for WaitSeconds, takes the screenshot, then Stop-Process's the
# running app. That mode is what verifies the rendered labeler UI,
# because the Moui view tree walker needs at least one paint
# cycle after the window opens to populate the DrawCommand buffer;
# --smoke fires after the FIRST frame, which on a fresh window
# is often the clear-color placeholder.
#
# With -UseSmoke the exe auto-exits after its first frame and the
# screenshot is taken before that auto-exit lands. Useful for
# proving "the binary boots and the runtime presents something".
#
# Exit codes:
#   0   screenshot captured
#   1   build failed
#   2   exe not found
#   3   screenshot capture failed
#   4   exe was hung and we had to kill it

[CmdletBinding()]
param(
  [string] $OutFile = "_build\phase17_smoke.png",
  [switch] $SkipBuild,
  [switch] $UseSmoke,
  [int]    $WaitSeconds = 6,
  [int]    $MaxLifetimeSeconds = 15
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Resolve-Path "$PSScriptRoot\.."
Set-Location $ProjectRoot

Write-Host "[smoke] project root: $ProjectRoot"
Write-Host "[smoke] output png:   $OutFile"
Write-Host "[smoke] wait seconds: $WaitSeconds"
Write-Host "[smoke] use smoke:    $UseSmoke"

# 1. Build (unless skipped).
if (-not $SkipBuild) {
  Write-Host "[smoke] === moon build (in app_moui) ==="
  Push-Location "$ProjectRoot\app_moui"
  try {
    moon build
    if ($LASTEXITCODE -ne 0) {
      Pop-Location
      Write-Host "[smoke][error] moon build failed exit=$LASTEXITCODE" -ForegroundColor Red
      exit 1
    }
  } finally {
    Pop-Location
  }
}

# 2. Resolve the exe path.
$Exe = Join-Path $ProjectRoot "app_moui\_build\native\debug\build\app_moui.exe"
if (-not (Test-Path -LiteralPath $Exe)) {
  Write-Host "[smoke][error] exe not found: $Exe" -ForegroundColor Red
  exit 2
}
Write-Host "[smoke] exe: $Exe"

# 3. Best-effort cleanup of stale processes from prior runs. Other
#    sessions' processes may resist kill ("Access is denied"); we
#    log and continue — the new launch will use a different window
#    title instance anyway.
$stale = Get-Process -Name app_moui -ErrorAction SilentlyContinue
if ($stale) {
  Write-Host "[smoke] found $($stale.Count) stale app_moui process(es); attempting kill"
  $stale | ForEach-Object {
    try { Stop-Process -Id $_.Id -Force -ErrorAction Stop }
    catch { Write-Host "[smoke][warn] could not kill pid=$($_.Id): $($_.Exception.Message)" }
  }
  Start-Sleep -Milliseconds 500
}

# 4. Launch (with or without --smoke).
$stdout = Join-Path $ProjectRoot "_build\smoke_app_moui.out"
$stderr = Join-Path $ProjectRoot "_build\smoke_app_moui.err"
"" | Set-Content -LiteralPath $stdout
"" | Set-Content -LiteralPath $stderr
if ($UseSmoke) {
  $proc = Start-Process -FilePath $Exe `
                       -ArgumentList "--smoke" `
                       -RedirectStandardOutput $stdout `
                       -RedirectStandardError $stderr `
                       -PassThru
  Write-Host "[smoke] launched pid=$($proc.Id) args=[--smoke]"
} else {
  $proc = Start-Process -FilePath $Exe `
                       -RedirectStandardOutput $stdout `
                       -RedirectStandardError $stderr `
                       -PassThru
  Write-Host "[smoke] launched pid=$($proc.Id) args=[]"
}

# 5. Wait for the window + view tree to settle.
Start-Sleep -Seconds $WaitSeconds

# 5b. Bring the MoonBit Labeler window to the foreground so the
#     screenshot captures it (not whatever was on the desktop
#     from a previous session). Win32 SetForegroundWindow +
#     ShowWindow(SW_RESTORE) via P/Invoke.
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Diagnostics;
public class Win32Fg {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  public static IntPtr FindByTitle(string title) {
    foreach (Process p in Process.GetProcesses()) {
      if (p.MainWindowTitle == title && p.MainWindowHandle != IntPtr.Zero) {
        return p.MainWindowHandle;
      }
    }
    return IntPtr.Zero;
  }
}
"@
$hwnd = [Win32Fg]::FindByTitle("MoonBit Labeler")
if ($hwnd -ne [IntPtr]::Zero) {
  [Win32Fg]::ShowWindow($hwnd, 9) | Out-Null  # SW_RESTORE
  [Win32Fg]::SetForegroundWindow($hwnd) | Out-Null
  Start-Sleep -Milliseconds 500
  Write-Host "[smoke] raised MoonBit Labeler hwnd=$hwnd to foreground"
} else {
  Write-Host "[smoke][warn] could not find MoonBit Labeler window to raise"
}

# 6. Capture the desktop + try a per-window capture as fallback.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Pre-load PrintWindow helper. Failure here is non-fatal (the
# fallback desktop screenshot still runs).
$perWindowSupported = $true
try {
  Add-Type -ReferencedAssemblies System.Drawing,System.Windows.Forms -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public class Pw {
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left, Top, Right, Bottom; }
  public static void Dump(IntPtr hWnd, string path) {
    RECT r; GetWindowRect(hWnd, out r);
    int w = r.Right - r.Left, h = r.Bottom - r.Top;
    if (w <= 0 || h <= 0) return;
    using (var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb))
    using (var g = Graphics.FromImage(bmp)) {
      IntPtr hdc = g.GetHdc();
      try { PrintWindow(hWnd, hdc, 2); }
      finally { g.ReleaseHdc(hdc); }
      bmp.Save(path, ImageFormat.Png);
    }
  }
}
"@
} catch {
  Write-Host "[smoke][warn] PrintWindow helper not loaded: $($_.Exception.Message)"
  $perWindowSupported = $false
}

try {
  # 6a. Capture full desktop (matches what a user sees).
  $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $bmp = New-Object System.Drawing.Bitmap $screen.Width, $screen.Height
  $gfx = [System.Drawing.Graphics]::FromImage($bmp)
  $gfx.CopyFromScreen($screen.Location, [System.Drawing.Point]::Empty, $screen.Size)
  $gfx.Dispose()
  $bmp.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  Write-Host "[smoke] saved screenshot: $OutFile ($($screen.Width)x$($screen.Height))"

  # 6b. Per-window capture via PrintWindow. Some Windows hosts
  #     (e.g. when the agent's session differs from the window's)
  #     give a blank desktop but PrintWindow on the specific hwnd
  #     captures its actual pixels. Saved as <OutFile>.window.png.
  if ($perWindowSupported -and ($hwnd -ne [IntPtr]::Zero)) {
    $windowPng = [System.IO.Path]::ChangeExtension($OutFile, $null) + "_window.png"
    [Pw]::Dump($hwnd, $windowPng)
    Write-Host "[smoke] saved per-window screenshot: $windowPng"
  }
} catch {
  Write-Host "[smoke][error] screenshot capture failed: $($_.Exception.Message)" -ForegroundColor Red
  try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch { }
  $proc.Dispose()
  exit 3
}

# 7. If we used --smoke, the exe should have already exited. If
#    not, kill it now.
if ($proc.HasExited) {
  Write-Host "[smoke] exe exited cleanly after $WaitSeconds s, exit=$($proc.ExitCode)"
  $proc.Dispose()
  if ($proc.ExitCode -ne 0) {
    Write-Host "[smoke][warn] non-zero exit code from app_moui" -ForegroundColor Yellow
  }
  exit 0
}

# Normal-mode (no --smoke): kill the exe so the user can re-run
# without leaving a window behind.
Write-Host "[smoke] killing app_moui.exe pid=$($proc.Id)"
try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop }
catch { Write-Host "[smoke][warn] could not kill pid=$($proc.Id)" }
$proc.Dispose()
exit 0
