<#
.SYNOPSIS
    Local simulation of the GitHub Actions pipeline for this repository.

.DESCRIPTION
    Runs the same gates as .github/workflows/ci.yml and the release gate
    from publish.yml, but against a **cold clone**: a fresh `git clone` of
    the committed tree into a scratch directory, with no `.mooncakes/`,
    no `_build/`, and no warm cache.

    That coldness is the entire point. A warm working tree reuses `.obj`
    files and never re-invokes the C compiler, and a warm `.mooncakes/`
    never re-fetches a dependency -- so a developer machine passes builds
    that a clean checkout fails instantly. Several CI-only failures in this
    repository's history were hidden exactly that way, including four
    consecutive missing-prerequisite bugs that stayed invisible for 28
    consecutive red runs.

    Stages:
      1. preflight   -- tools present, working tree clean
      2. deps        -- every pinned dependency vs registry latest
      3. cold clone  -- a fresh checkout of HEAD
      4. lint        -- moon fmt --check, typos
      5. build/test  -- moon check, moon test
      6. release     -- moon publish --dry-run (the actual release gate)
      7. summary

    Stage 2 is advisory by default and fails the run only with -StrictDeps.

.PARAMETER StrictDeps
    Fail when a pinned dependency is behind the registry's latest *and*
    that latest is actually usable (build_status=success and a published
    package). This cannot catch a version that builds under the
    publisher's own toolchain but not under this machine's moon -- see the
    Milky2018/css note in the script body.

.PARAMETER SkipBuild
    Skip the `moon build` stage. It compiles app/ and links CEF, so it
    needs the CEF SDK; the release gate already covers packaging.

.PARAMETER SkipRelease
    Skip the `moon publish --dry-run` stage.

.PARAMETER WorkDir
    Scratch directory for the cold clone. Defaults to a timestamped
    directory under _build/ci-local.

.EXAMPLE
    pwsh -File scripts/ci-local.ps1
    Run every stage and report.

.EXAMPLE
    pwsh -File scripts/ci-local.ps1 -StrictDeps
    Also fail when a dependency is behind latest.

.NOTES
    Exit codes: 0 all stages passed, 1 a gate failed, 2 preflight failed.
#>
[CmdletBinding()]
param(
    [switch]$StrictDeps,
    [switch]$SkipBuild,
    [switch]$SkipRelease,
    [string]$WorkDir
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

if (-not $WorkDir) {
    $WorkDir = Join-Path $repo ("_build\ci-local\" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$clone = Join-Path $WorkDir 'clone'
$logDir = Join-Path $WorkDir 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$script:results = @()

function Write-Step {
    param([string]$Name, [string]$Status, [string]$Detail = '')
    $script:results += [pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail }
    $colour = switch ($Status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } 'SKIP' { 'DarkGray' } default { 'Gray' } }
    Write-Host ("{0,-10} {1}{2}" -f "[$Status]", $Name, $(if ($Detail) { "  -- $Detail" } else { '' })) -ForegroundColor $colour
}

function Invoke-Native {
    <#  Runs a command, capturing both streams to files.
        Returns @{ Exit; Out; Err; Text }. Never throws, so a failing gate
        is reported rather than aborting the script mid-run. #>
    param([string]$File, [string[]]$ArgList, [string]$Tag, [string]$WorkingDir = $repo)
    $o = Join-Path $logDir "$Tag.out"
    $e = Join-Path $logDir "$Tag.err"
    $p = Start-Process -FilePath $File -ArgumentList $ArgList -WorkingDirectory $WorkingDir `
        -NoNewWindow -Wait -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
    $text = ''
    if (Test-Path $o) { $text += (Get-Content $o -Raw -ErrorAction SilentlyContinue) }
    if (Test-Path $e) { $text += "`n" + (Get-Content $e -Raw -ErrorAction SilentlyContinue) }
    return @{ Exit = $p.ExitCode; Out = $o; Err = $e; Text = $text }
}

function Show-Tail {
    param([string]$Path, [int]$Lines = 12)
    if (Test-Path $Path) {
        Get-Content $Path -Tail $Lines -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
    }
}

# --------------------------------------------------------------------------
Write-Host ''
Write-Host 'Local CI simulation' -ForegroundColor Cyan
Write-Host "  repo    : $repo"
Write-Host "  workdir : $WorkDir"
Write-Host ''

# --- 1. preflight ----------------------------------------------------------
$moonCmd = Get-Command moon -ErrorAction SilentlyContinue
if (-not $moonCmd) {
    Write-Step 'preflight' 'FAIL' 'moon is not on PATH'
    exit 2
}
$ver = (moon version --all 2>&1 | Select-Object -First 1)
$dirty = git status --porcelain
if ($dirty) {
    Write-Step 'preflight' 'WARN' ("{0} uncommitted path(s); the clone below tests HEAD, not your tree" -f ($dirty | Measure-Object).Count)
} else {
    Write-Step 'preflight' 'PASS' $ver
}

# --- 2. dependency freshness ----------------------------------------------
# Reads the registry manifest for each pin. Two things are checked, and the
# distinction matters:
#
#   build_status / has_package
#     Whether upstream produced a usable artifact at all. wzzc-dev/moui
#     0.2.3 is the live example: it is `latest` and its build_status is
#     "failed" with has_package false, so "always track latest" would
#     install something that cannot be downloaded.
#
#   actual compilability under THIS moon
#     Not covered by build_status, and cannot be. Milky2018/css@0.5.3
#     reports build_status "success" -- it built fine under the publisher's
#     own toolchain -- yet it fails here with "Float is a reserved type
#     name" on moon 0.1.20261012. build_status answers "did upstream build
#     this", never "will it compile for you". That is why the app_moui
#     upgrade is deliberately not automated.
$modFiles = @('moon.mod', 'app_moui\moon.mod')
$pins = @()
foreach ($mf in $modFiles) {
    $full = Join-Path $repo $mf
    if (-not (Test-Path $full)) { continue }
    foreach ($line in (Get-Content $full)) {
        if ($line -match '"([\w-]+/[\w-]+)@([\d][^"]*)"') {
            $pins += [pscustomobject]@{ Module = $Matches[1]; Version = $Matches[2]; Source = $mf }
        }
    }
}
$drift = @()
foreach ($p in ($pins | Sort-Object Module, Source -Unique)) {
    $latest = $null; $status = $null; $hasPkg = $null
    try {
        $m = Invoke-RestMethod -Uri ("https://mooncakes.io/api-new/v0/manifest/{0}@{1}" -f $p.Module, $p.Version) -TimeoutSec 60
        $latest = $m.latest_version
        $status = $m.build_status
        $hasPkg = $m.has_package
    }
    catch {
        Write-Step ("deps " + $p.Module) 'WARN' ("could not query registry: " + $_.Exception.Message)
        continue
    }
    $usable = ($status -eq 'success' -and $hasPkg -eq $true)
    $state = if ($latest -eq $p.Version) { 'current' }
             elseif (-not $usable) { 'latest is UNUSABLE (build={0}, package={1})' -f $status, $hasPkg }
             else { 'BEHIND' }
    $drift += [pscustomobject]@{ Module = $p.Module; Have = $p.Version; Latest = $latest; State = $state }
    Write-Step ("deps " + $p.Module) $(if ($state -eq 'current') { 'PASS' } else { 'WARN' }) ("have {0}, latest {1} [{2}] ({3})" -f $p.Version, $latest, $state, $p.Source)
}
if ($StrictDeps -and ($drift | Where-Object { $_.State -eq 'BEHIND' })) {
    Write-Step 'deps (strict)' 'FAIL' 'a dependency is behind latest'
    Write-Step 'summary' 'FAIL' 'preflight/dependency gate failed'
    exit 1
}

# --- 3. cold clone ---------------------------------------------------------
# Only committed state, exactly what actions/checkout gives the runner.
$cloneRun = Invoke-Native -File 'git' -ArgList @('clone', '--no-hardlinks', '--quiet', $repo, $clone) -Tag 'clone'
if ($cloneRun.Exit -ne 0) {
    Write-Step 'cold clone' 'FAIL' 'git clone failed'
    Show-Tail $cloneRun.Err
    Write-Step 'summary' 'FAIL' 'could not create the cold clone'
    exit 1
}
Write-Step 'cold clone' 'PASS' ("fresh checkout at " + (git -C $clone rev-parse --short HEAD))

# --- 4-6. gates inside the clone -----------------------------------------
Invoke-Native -File 'moon' -ArgList @('update') -Tag 'update' -WorkingDir $clone | Out-Null

$f = Invoke-Native -File 'moon' -ArgList @('fmt', '--check') -Tag 'fmt' -WorkingDir $clone
if ($f.Exit -eq 0) { Write-Step 'moon fmt --check' 'PASS' } else { Write-Step 'moon fmt --check' 'FAIL' ("exit " + $f.Exit); Show-Tail $f.Err 20 }

$typosCmd = Get-Command typos -ErrorAction SilentlyContinue
if ($typosCmd) {
    $t = Invoke-Native -File 'typos' -ArgList @('--config', '_typos.toml') -Tag 'typos' -WorkingDir $clone
    if ($t.Exit -eq 0) { Write-Step 'typos' 'PASS' } else { Write-Step 'typos' 'FAIL' ("exit " + $t.Exit); Show-Tail $t.Out 20 }
}
else {
    Write-Step 'typos' 'SKIP' 'typos-cli not installed locally (CI installs it via cargo)'
}

$c = Invoke-Native -File 'moon' -ArgList @('check', '--target', 'native', '--diagnostic-limit', '40') -Tag 'check' -WorkingDir $clone
if ($c.Exit -eq 0) { Write-Step 'moon check' 'PASS' } else { Write-Step 'moon check' 'FAIL' ("exit " + $c.Exit); Show-Tail $c.Err 25 }

$tests = Invoke-Native -File 'moon' -ArgList @('test', '-p', 'riantr/moonbit_labeler', '-p', 'riantr/moonbit_labeler/extensions/labeler', '--target', 'native', '--diagnostic-limit', '40') -Tag 'test' -WorkingDir $clone
$total = ([regex]::Match($tests.Text, 'Total tests:\s*(\d+)')).Groups[1].Value
if ($tests.Exit -eq 0) { Write-Step 'moon test' 'PASS' ("{0} tests" -f $total) }
else { Write-Step 'moon test' 'FAIL' ("exit " + $tests.Exit); Show-Tail $tests.Err 25 }

if ($SkipBuild) {
    Write-Step 'moon build' 'SKIP' '-SkipBuild'
}
else {
    $b = Invoke-Native -File 'moon' -ArgList @('build', '--target', 'native') -Tag 'build' -WorkingDir $clone
    if ($b.Exit -eq 0) { Write-Step 'moon build' 'PASS' } else { Write-Step 'moon build' 'FAIL' ("exit " + $b.Exit); Show-Tail $b.Err 25 }
}

if ($SkipRelease) {
    Write-Step 'publish --dry-run' 'SKIP' '-SkipRelease'
}
else {
    # This is the real release gate. `moon publish` packages, verifies the
    # zip, then extracts it into a temp directory with its OWN fresh
    # dependency cache and runs `moon check` there -- so a dependency problem
    # shows up here and nowhere else, and no earlier step can pre-empt it.
    #
    # The exit code is NOT the signal. A dry run prints the server's verdict
    # and then exits non-zero regardless, so judge on the response text:
    #   202 Accepted  -- credentials good, would publish
    #   409 Conflict  -- that version already exists
    # Both mean the pipeline ran end to end. Anything else (or a bare
    # "Failed to calculate build plan") is a real failure.
    $r = Invoke-Native -File 'moon' -ArgList @('publish', '--dry-run') -Tag 'publish' -WorkingDir $clone
    $resp = ([regex]::Match($r.Text, 'Server status:\s*(\d+)')).Groups[1].Value
    if ($resp -eq '202') { Write-Step 'publish --dry-run' 'PASS' '202 Accepted -- would publish' }
    elseif ($resp -eq '409') { Write-Step 'publish --dry-run' 'PASS' '409 Conflict -- version already on the registry' }
    elseif ($r.Exit -eq 0) { Write-Step 'publish --dry-run' 'PASS' 'exit 0' }
    else {
        Write-Step 'publish --dry-run' 'FAIL' ("no server response, exit " + $r.Exit)
        Show-Tail $r.Err 25
    }
}

# --- 7. summary ------------------------------------------------------------
Write-Host ''
$failed = @($script:results | Where-Object { $_.Status -eq 'FAIL' })
$warned = @($script:results | Where-Object { $_.Status -eq 'WARN' })
Write-Host ("{0} passed, {1} warned, {2} failed  (logs: {3})" -f `
    ($script:results | Where-Object { $_.Status -eq 'PASS' }).Count, $warned.Count, $failed.Count, $logDir) -ForegroundColor Cyan
if ($failed) {
    $failed | ForEach-Object { Write-Host ("  FAILED: " + $_.Name + " -- " + $_.Detail) -ForegroundColor Red }
    Write-Host ''
    Write-Host 'Not tagging. Fix the failures above, then re-run.' -ForegroundColor Yellow
    exit 1
}
Write-Host ''
Write-Host 'All gates passed on a cold clone. Safe to tag.' -ForegroundColor Green
exit 0
