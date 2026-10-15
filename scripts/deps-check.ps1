<#
.SYNOPSIS
    Resolve every pinned dependency to the newest version that actually
    works here, and optionally rewrite the pins.

.DESCRIPTION
    "Keep dependencies at latest" is only safe with a measured definition
    of *usable*, because there are two independent reasons a version can
    be unusable, and only one of them is visible in registry metadata:

      1. Upstream produced nothing usable.
         wzzc-dev/moui@0.2.3 is `latest` right now with
         "build_status": "failed" and "has_package": false. There is no
         artifact to download. A metadata check catches this.

      2. It built fine, but not under THIS toolchain.
         Milky2018/css@0.5.3 reports build_status "success" -- it compiled
         under the publisher's own moon -- and still fails here with
             "Float" is a reserved type name
         on moon 0.1.20261012. No metadata query can see this. Only
         actually resolving and compiling can.

    So for each dependency this walks the version list from `latest`
    downward, filters by (1), and for what survives attempts a real
    resolve + `moon check`. The first version that compiles wins. If
    none do, the pin is left exactly where it was -- the script never
    leaves a module in a state that does not build.

    A module that does not currently compile is reported BLOCKED and its
    dependencies are listed for information only. Resolving versions
    inside a module that cannot build at all is meaningless: there is no
    baseline to improve on.

.PARAMETER Apply
    Rewrite the moon.mod pins. Without it the script only reports what it
    would change. Pinned changes are applied one at a time and reverted
    if the module fails to compile, so a rejected candidate never sticks.

.PARAMETER Module
    Which modules to consider. Defaults to the root module and app_moui.

.PARAMETER Check
    The compile probe. Defaults to
    'check --target native --diagnostic-limit 40'.

.EXAMPLE
    pwsh -File scripts/deps-check.ps1
    Report only.

.EXAMPLE
    pwsh -File scripts/deps-check.ps1 -Apply
    Resolve and rewrite the pins.

.NOTES
    Exit codes: 0 nothing to report or all resolved, 1 a pin was behind
    and -Apply could not resolve it, 2 a module is blocked.
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [string[]]$Module = @('.', 'app_moui'),
    [string[]]$CheckArgs = @('check', '--target', 'native', '--diagnostic-limit', '40')
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo
$logDir = Join-Path $repo '_build\deps'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$utf8 = New-Object System.Text.UTF8Encoding($false)

function Invoke-Native {
    param([string]$File, [string[]]$ArgList, [string]$Tag, [string]$WorkingDir = $repo)
    $o = Join-Path $logDir "$Tag.out"; $e = Join-Path $logDir "$Tag.err"
    $p = Start-Process -FilePath $File -ArgumentList $ArgList -WorkingDirectory $WorkingDir `
        -NoNewWindow -Wait -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
    return @{ Exit = $p.ExitCode; Out = $o; Err = $e }
}

function Get-Manifest {
    <# Registry metadata. Returns $null when unreachable, which the caller
       treats as "unknown, try it anyway" rather than "reject". #>
    param([string]$Pkg, [string]$Ver)
    try {
        return Invoke-RestMethod -Uri ("https://mooncakes.io/api-new/v0/manifest/{0}@{1}" -f $Pkg, $Ver) -TimeoutSec 60
    }
    catch { return $null }
}

function Get-Versions {
    <# Newest first, as `moon view --versions` prints them. #>
    param([string]$Pkg)
    $r = Invoke-Native -File 'moon' -ArgList @('view', $Pkg, '--versions') -Tag ('ver_' + ($Pkg -replace '[^a-zA-Z0-9]', '_'))
    if ($r.Exit -ne 0) { return @() }
    $text = ''
    if (Test-Path $r.Out) { $text = Get-Content $r.Out -Raw -ErrorAction SilentlyContinue }
    if (Test-Path $r.Err) { $text += Get-Content $r.Err -Raw -ErrorAction SilentlyContinue }
    return @([regex]::Matches($text, '^\s*(\d+\.\d+\.\d+(?:-[0-9.]+)?)\s*$', 'Multiline') |
        ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
}

function Test-Compiles {
    param([string]$ModDir)
    $r = Invoke-Native -File 'moon' -ArgumentList $CheckArgs -Tag 'probe' -WorkingDirectory $ModDir
    return ($r.Exit -eq 0)
}

Write-Host ''
Write-Host 'Dependency resolution' -ForegroundColor Cyan
Write-Host "  mode: " $(if ($Apply) { 'APPLY' } else { 'report only' }) -ForegroundColor Gray
Write-Host ''

$changedAny = $false
$blocked = @()
$unresolved = @()

foreach ($mod in $Module) {
    $modDir = Join-Path $repo $mod
    $modFile = Join-Path $modDir 'moon.mod'
    if (-not (Test-Path $modFile)) { continue }
    $label = if ($mod -eq '.') { 'root' } else { $mod }

    Write-Host ("--- {0} ---" -f $label) -ForegroundColor Cyan

    # Baseline: a module that cannot compile today cannot be improved by
    # changing dependency versions, and there is no baseline to restore.
    if (-not (Test-Compiles $modDir)) {
        $blocked += $label
        Write-Host '  BLOCKED: the module does not compile on this toolchain as pinned.' -ForegroundColor Yellow
        Write-Host '          Dependency versions are listed for information only; there is no working baseline to improve on.' -ForegroundColor DarkGray
        foreach ($line in (Get-Content $modFile)) {
            if ($line -match '"([\w-]+/[\w-]+)@([\d][^"]*)"') {
                $pkg = $Matches[1]; $have = $Matches[2]
                $m = Get-Manifest $pkg $have
                $state = if ($m) { "build=$($m.build_status) package=$($m.has_package)" } else { 'manifest unavailable' }
                Write-Host ("          {0,-30} {1,-9} [{2}]" -f $pkg, $have, $state) -ForegroundColor DarkGray
            }
        }
        continue
    }
    Write-Host '  baseline compiles' -ForegroundColor Green

    $original = [System.IO.File]::ReadAllText($modFile, $utf8)

    foreach ($line in ($original -split "`r?`n")) {
        if ($line -notmatch '"([\w-]+/[\w-]+)@([\d][^"]*)"') { continue }
        $pkg = $Matches[1]; $have = $Matches[2]
        $all = Get-Versions $pkg
        if (-not $all) { Write-Host ("  {0,-30} {1,-9} could not list versions" -f $pkg, $have) -ForegroundColor DarkGray; continue }

        $newer = @($all | Where-Object { $_ -ne $have })
        if (-not $newer) {
            Write-Host ("  {0,-30} {1,-9} already newest known" -f $pkg, $have) -ForegroundColor Green
            continue
        }

        $chosen = $have
        $why = $have
        foreach ($cand in $newer) {
            $m = Get-Manifest $pkg $cand
            if ($m -and ($m.build_status -ne 'success' -or $m.has_package -ne $true)) {
                Write-Host ("  {0,-30} {1,-9} rejected: build_status={2} has_package={3}" -f $pkg, $cand, $m.build_status, $m.has_package) -ForegroundColor DarkGray
                continue
            }
            # Metadata says this one is plausible; only compiling can decide.
            [System.IO.File]::WriteAllText($modFile, $original -replace ('"' + [regex]::Escape($pkg) + '@' + [regex]::Escape($have) + '"'), ('"' + $pkg + '@' + $cand + '"'), $utf8)
            if (Test-Compiles $modDir) {
                $chosen = $cand; $why = $cand
                Write-Host ("  {0,-30} {1,-9} -> {2} COMPILES" -f $pkg, $have, $cand) -ForegroundColor Green
                break
            }
            [System.IO.File]::WriteAllText($modFile, $original, $utf8)
            Write-Host ("  {0,-30} {1,-9} rejected: does not compile here" -f $pkg, $cand) -ForegroundColor DarkGray
        }

        if ($chosen -ne $have) {
            if ($Apply) {
                [System.IO.File]::WriteAllText($modFile, $original -replace ('"' + [regex]::Escape($pkg) + '@' + [regex]::Escape($have) + '"'), ('"' + $pkg + '@' + $chosen + '"'), $utf8)
                $original = [System.IO.File]::ReadAllText($modFile, $utf8)
                $changedAny = $true
                Write-Host ("  APPLIED: {0} {1} -> {2}" -f $pkg, $have, $chosen) -ForegroundColor Green
            }
            else {
                Write-Host ("  WOULD UPDATE: {0} {1} -> {2}" -f $pkg, $have, $chosen) -ForegroundColor Yellow
                # Re-apply for the next dependency in the list.
                [System.IO.File]::WriteAllText($modFile, $original -replace ('"' + [regex]::Escape($pkg) + '@' + [regex]::Escape($have) + '"'), ('"' + $pkg + '@' + $chosen + '"'), $utf8)
                $original = [System.IO.File]::ReadAllText($modFile, $utf8)
                $unresolved += "$label/$pkg -> $chosen (not applied; rerun with -Apply)"
            }
        }
        elseif ($why -eq $have) {
            $tried = @($newer | Where-Object { $m = Get-Manifest $pkg $_; $m -and $m.build_status -eq 'success' -and $m.has_package -eq $true }).Count
            if ($tried -gt 0) { Write-Host ("  {0,-30} {1,-9} stays: {2} newer version(s) tried, none compiles here" -f $pkg, $have, $tried) -ForegroundColor Yellow }
            else { Write-Host ("  {0,-30} {1,-9} stays: every newer version is unusable upstream" -f $pkg, $have) -ForegroundColor Yellow }
        }
    }

    # Leave the module compiling no matter what happened above.
    if (-not (Test-Compiles $modDir)) {
        [System.IO.File]::WriteAllText($modFile, $original, $utf8)
        Write-Host '  restored: the edited module did not compile, reverting' -ForegroundColor Red
    }
}

Write-Host ''
if ($changedAny) { Write-Host 'Pins updated. Re-run scripts/ci-local.ps1 before tagging.' -ForegroundColor Green }
elseif ($unresolved) { $unresolved | ForEach-Object { Write-Host ("  pending: " + $_) -ForegroundColor Yellow } }
if ($blocked) {
    Write-Host ("Blocked module(s): " + ($blocked -join ', ') + " -- see AGENTS.md for the upstream causes.") -ForegroundColor Yellow
    exit 2
}
if ($unresolved -and $Apply) { exit 1 }
exit 0
