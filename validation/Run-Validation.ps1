<#
.SYNOPSIS
  Single entry point for the SimpleInc validation suite (Windows).

.DESCRIPTION
  Builds SimpleInc (MSBuild) and helper tools (csc), generates all test inputs
  under a temporary work root, runs every scenario script, then deletes the
  work root. Designed for Windows with Visual Studio Build Tools / .NET Framework.

.PARAMETER SkipBuild
  Use Bin\Release\SimpleInc.exe instead of building from source (not recommended
  for validating local edits).

.PARAMETER KeepWorkRoot
  Do not delete the temp work directory after the suite (for debugging).

.PARAMETER Filter
  Optional substring filter on test script file names (e.g. "Dirty").

.PARAMETER UseRealTracker
  After FakeTracker tests, run one optional smoke against the real VS Tracker.exe
  if it can be located via vswhere.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File validation\Run-Validation.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [switch]$KeepWorkRoot,
    [string]$Filter = '',
    [switch]$UseRealTracker
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ValidationRoot = $PSScriptRoot
$RepoRoot = Split-Path -Parent $ValidationRoot
. (Join-Path $ValidationRoot 'lib\Common.ps1')

Write-ValLog "SimpleInc validation starting"
Write-ValLog "RepoRoot=$RepoRoot"

if ($env:OS -ne 'Windows_NT') {
    Write-ValLog 'This suite must run on Windows (SimpleInc.exe / Tracker are Win32).' 'ERROR'
    Write-ValLog 'See validation/README.md for how to run on a Windows host with VS.'
    exit 2
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$WorkRoot = Join-Path $env:TEMP "simpleinc-validation-$stamp-$PID"
$BuildOut = Join-Path $WorkRoot 'build'
$ToolsOut = Join-Path $WorkRoot 'tools'
New-Item -ItemType Directory -Path $WorkRoot, $BuildOut, $ToolsOut -Force | Out-Null
Write-ValLog "WorkRoot=$WorkRoot"

$failed = @()
$passed = @()
$skipped = @()

try {
    Clear-EnvFakeKnobs

    $simpleInc = Build-SimpleInc -RepoRoot $RepoRoot -OutDir $BuildOut -SkipBuild:$SkipBuild
    Build-HelperTools -ToolsSrcDir (Join-Path $ValidationRoot 'tools') -OutDir $ToolsOut

    # SimpleInc looks for <TrackerDir>\Tracker.exe — stage FakeTracker under that name.
    $fakeTrackerDir = Join-Path $WorkRoot 'faketracker-bin'
    New-Item -ItemType Directory -Path $fakeTrackerDir -Force | Out-Null
    Copy-Item (Join-Path $ToolsOut 'FakeTracker.exe') (Join-Path $fakeTrackerDir 'Tracker.exe') -Force

    $suite = [pscustomobject]@{
        RepoRoot        = $RepoRoot
        ValidationRoot  = $ValidationRoot
        WorkRoot        = $WorkRoot
        SimpleIncExe    = $simpleInc
        FakeTrackerDir  = $fakeTrackerDir
        TouchFileExe    = Join-Path $ToolsOut 'TouchFile.exe'
        EchoArgsExe     = Join-Path $ToolsOut 'EchoArgs.exe'
        FakeTrackerExe  = Join-Path $ToolsOut 'FakeTracker.exe'
    }

    $testScripts = @(Get-ChildItem (Join-Path $ValidationRoot 'tests') -Filter 'Test-*.ps1' | Sort-Object Name)
    if ($Filter) {
        $testScripts = @($testScripts | Where-Object { $_.Name -like "*$Filter*" })
    }
    if ($testScripts.Count -eq 0) {
        throw "No test scripts matched Filter='$Filter'"
    }

    Write-ValLog "Running $($testScripts.Count) test script(s)"
    foreach ($script in $testScripts) {
        Clear-EnvFakeKnobs
        Write-ValLog "---- $($script.Name) ----"
        try {
            & $script.FullName -Suite $suite
            $passed += $script.Name
            Write-ValLog "PASS $($script.Name)" 'PASS'
        }
        catch {
            $failed += $script.Name
            Write-ValLog "FAIL $($script.Name): $($_.Exception.Message)" 'FAIL'
            Write-ValLog ($_.ScriptStackTrace) 'FAIL'
        }
    }

    if ($UseRealTracker) {
        Write-ValLog '---- Optional real Tracker smoke ----'
        $trackerDir = Find-RealTrackerDir
        if (-not $trackerDir) {
            $skipped += 'RealTrackerSmoke'
            Write-ValLog 'Real Tracker.exe not found; skipping smoke.' 'WARN'
        }
        else {
            try {
                $smokeRoot = Join-Path $WorkRoot 'real-tracker-smoke'
                New-Item -ItemType Directory -Path $smokeRoot -Force | Out-Null
                $cache = Join-Path $smokeRoot 'cache'
                $data = Join-Path $smokeRoot 'data'
                New-Item -ItemType Directory -Path $cache, $data -Force | Out-Null
                $outFile = Join-Path $data 'real-out.txt'
                $cmd = "cmd.exe /C echo real-tracker-smoke> `"$outFile`""
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $simpleInc
                $psi.Arguments = "`"$trackerDir`" `"$cache`" $cmd"
                $psi.UseShellExecute = $false
                $p = [System.Diagnostics.Process]::Start($psi)
                $p.WaitForExit()
                Assert-ExitCode 0 $p.ExitCode 'real Tracker smoke first run'
                Assert-True (Test-Path $outFile) 'real Tracker child wrote output'
                $dirs = @(Get-ChildItem $cache -Directory)
                Assert-True ($dirs.Count -ge 1) 'real Tracker produced a cache hash dir'
                $complete = Test-Path (Join-Path $dirs[0].FullName 'complete.flag')
                Assert-True $complete 'real Tracker path should publish complete.flag'
                # Second run should skip
                $p2 = [System.Diagnostics.Process]::Start($psi)
                $p2.WaitForExit()
                Assert-ExitCode 0 $p2.ExitCode 'real Tracker smoke up-to-date'
                $passed += 'RealTrackerSmoke'
                Write-ValLog 'PASS RealTrackerSmoke' 'PASS'
            }
            catch {
                $failed += 'RealTrackerSmoke'
                Write-ValLog "FAIL RealTrackerSmoke: $($_.Exception.Message)" 'FAIL'
            }
        }
    }
}
finally {
    Clear-EnvFakeKnobs
    if ($KeepWorkRoot) {
        Write-ValLog "Keeping WorkRoot=$WorkRoot"
    }
    else {
        try {
            if (Test-Path $WorkRoot) {
                Remove-Item $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
                Write-ValLog "Cleaned WorkRoot=$WorkRoot"
            }
        }
        catch {
            Write-ValLog "Cleanup warning: $($_.Exception.Message)" 'WARN'
        }
    }
}

Write-Host ''
Write-ValLog "Passed: $($passed.Count)  Failed: $($failed.Count)  Skipped: $($skipped.Count)"
if ($passed.Count) { Write-ValLog ("  PASS: " + ($passed -join ', ')) }
if ($failed.Count) { Write-ValLog ("  FAIL: " + ($failed -join ', ')) 'FAIL' }
if ($skipped.Count) { Write-ValLog ("  SKIP: " + ($skipped -join ', ')) 'WARN' }

if ($failed.Count -gt 0) {
    exit 1
}
exit 0
