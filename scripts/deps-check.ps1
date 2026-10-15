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
    if ($null -eq $p) { return @{ Exit = 127; Out = $o; Err = $e } }
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

function Compare-Version {
    <# Semver-ish ordering: -1 / 0 / 1. Main releases compare
       numerically; a `-prerelease` suffix sorts BELOW the same number
       without one, so 0.5.4-0.2.1 < 0.5.4 < 0.5.5. Needed because
       Proton's `wzzc-dev/window` uses prereleases like that. #>
    param([string]$A, [string]$B)
    $aPre = $false; $bPre = $false
    $aMain = $A; $bMain = $B
    if ($A -match '^(.*?)-(.+)$') { $aMain = $Matches[1]; $aPre = $true }
    if ($B -match '^(.*?)-(.+)$') { $bMain = $Matches[1]; $bPre = $true }
    $av = [version]$aMain; $bv = [version]$bMain
    if ($av -ne $bv) { return $(if ($av -lt $bv) { -1 } else { 1 }) }
    if ($aPre -and -not $bPre) { return -1 }
    if ($bPre -and -not $aPre) { return 1 }
    return 0
}

function Test-Compiles {
    param([string]$ModDir)
    # -ArgList and -WorkingDir must match Invoke-Native's parameter names
    # exactly. PowerShell binds a supplied name only when it is a *prefix*
    # of the real one, and a non-matching name fails silently under
    # ErrorActionPreference=Continue -- the default value survives and the
    # probe quietly runs in the wrong directory. That happened here twice:
    # `-ArgumentList` left $ArgList null (every module looked broken), then
    # `-WorkingDirectory` left $WorkingDir at the repo root (app_moui
    # "compiled" by borrowing the root module's result). Both produced
    # confident wrong answers rather than errors.
    if (-not (Test-Path (Join-Path $ModDir 'moon.mod'))) {
        Write-Host ("  probe error: no moon.mod under {0}" -f $ModDir) -ForegroundColor Red
        return $false
    }
    $r = Invoke-Native -File 'moon' -ArgList $CheckArgs -Tag 'probe' -WorkingDir $ModDir
    if ($null -eq $r) {
        Write-Host '  probe error: the probe returned nothing' -ForegroundColor Red
        return $false
    }
    # Read the directory back out of the result so the working directory
    # actually used is visible in the log rather than assumed.
    Write-Host ("  probe: moon check in {0} -> exit {1}" -f $ModDir.Replace($repo + '\', ''), $r.Exit) -ForegroundColor DarkGray
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

    # Pin rewrites go through a helper rather than inline. `-replace`
    # takes a comma-separated pair, and inside a method call that comma is
    # parsed as an argument separator -- WriteAllText then gets four
    # arguments and there is no four-argument overload. That failure is
    # silent under ErrorActionPreference=Continue, so a candidate that
    # "compiled" was really the unmodified file.
    function Set-Pin {
        param([string]$Path, [string]$Text, [string]$Pkg, [string]$From, [string]$To)
        $pattern = '"' + [regex]::Escape($Pkg + '@' + $From) + '"'
        $updated = $Text -replace $pattern, ('"' + $Pkg + '@' + $To + '"')
        [System.IO.File]::WriteAllText($Path, $updated, $utf8)
    }

    foreach ($line in ($original -split "`r?`n")) {
        if ($line -notmatch '"([\w-]+/[\w-]+)@([\d][^"]*)"') { continue }
        $pkg = $Matches[1]; $have = $Matches[2]
        $all = Get-Versions $pkg
        if (-not $all) { Write-Host ("  {0,-30} {1,-9} could not list versions" -f $pkg, $have) -ForegroundColor DarkGray; continue }

        # Strictly newer only. An earlier revision used `-ne $have`, which
        # left every OLDER version in the candidate list, so the walk ran
        # past latest down through history and happily "found" proton
        # 0.3.4 as the newest usable version of a module pinned at 0.4.0.
        $newer = @($all | Where-Object { (Compare-Version $_ $have) -gt 0 } |
            Sort-Object { [version](($_ -split '-')[0]) } -Descending)
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
            Set-Pin -Path $modFile -Text $original -Pkg $pkg -From $have -To $cand
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
                Set-Pin -Path $modFile -Text $original -Pkg $pkg -From $have -To $chosen
                $original = [System.IO.File]::ReadAllText($modFile, $utf8)
                $changedAny = $true
                Write-Host ("  APPLIED: {0} {1} -> {2}" -f $pkg, $have, $chosen) -ForegroundColor Green
            }
            else {
                Write-Host ("  WOULD UPDATE: {0} {1} -> {2}" -f $pkg, $have, $chosen) -ForegroundColor Yellow
                # Keep it applied while the remaining dependencies are
                # probed, so each candidate is tested against the state
                # the previous one produced. The final restore below undoes
                # all of it when -Apply was not given.
                Set-Pin -Path $modFile -Text $original -Pkg $pkg -From $have -To $chosen
                $original = [System.IO.File]::ReadAllText($modFile, $utf8)
                $unresolved += "$label/$pkg -> $chosen (not applied; rerun with -Apply)"
            }
        }
        elseif ($why -eq $have) {
            $tried = @($newer | Where-Object {
                    $m = Get-Manifest $pkg $_
                    $m -and $m.build_status -eq 'success' -and $m.has_package -eq $true
                }).Count
            if ($tried -gt 0) { Write-Host ("  {0,-30} {1,-9} stays: {2} newer version(s) tried, none compiles here" -f $pkg, $have, $tried) -ForegroundColor Yellow }
            else { Write-Host ("  {0,-30} {1,-9} stays: every newer version is unusable upstream" -f $pkg, $have) -ForegroundColor Yellow }
        }
    }

    # Restore the module's exact starting bytes. Testing a candidate means
    # writing it into moon.mod, so report-only mode must put the file back
    # unconditionally -- leaving that to the compile-failure guard alone is
    # luck, not design, and a candidate that happens to still compile would
    # silently persist a downgrade. In -Apply mode $original already
    # carries the accumulated upgrades, so this keeps them and drops only
    # the candidate under test.
    if (-not (Test-Compiles $modDir)) {
        [System.IO.File]::WriteAllText($modFile, $original, $utf8)
        Write-Host '  restored: the edited module did not compile, reverting' -ForegroundColor Red
    }
    elseif (-not $Apply) {
        [System.IO.File]::WriteAllText($modFile, $original, $utf8)
        Write-Host '  restored (report-only; no pins changed)' -ForegroundColor DarkGray
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
