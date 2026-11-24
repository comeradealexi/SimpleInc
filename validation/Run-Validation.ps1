<#
.SYNOPSIS
  Single entry point for the SimpleInc validation suite (Windows).

.DESCRIPTION
  Builds SimpleInc (MSBuild) and helper tools (csc), generates all test inputs
  under a temporary work root, runs every scenario script, then deletes the
  work root. Prints a timed per-scenario table and a final rollup.

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

function Write-Banner {
    param([string]$Title)
    $bar = '=' * 72
    Write-Host ''
    Write-Host $bar -ForegroundColor DarkCyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host $bar -ForegroundColor DarkCyan
}

function Format-DurationMs {
    param([double]$Ms)
    if ($Ms -ge 1000) {
        return ('{0:N2}s' -f ($Ms / 1000.0))
    }
    return ('{0:N0}ms' -f $Ms)
}

function Write-ResultTable {
    param([System.Collections.IEnumerable]$Rows)
    $nameWidth = 36
    Write-Host ''
    Write-Host ("  {0,-$nameWidth}  {1,-6}  {2,10}" -f 'Scenario', 'Result', 'Duration') -ForegroundColor White
    Write-Host ("  {0,-$nameWidth}  {1,-6}  {2,10}" -f ('-' * $nameWidth), '------', '----------') -ForegroundColor DarkGray
    foreach ($row in $Rows) {
        $color = switch ($row.Status) {
            'PASS' { 'Green' }
            'FAIL' { 'Red' }
            'SKIP' { 'Yellow' }
            default { 'Gray' }
        }
        $name = $row.Name
        if ($name.Length -gt $nameWidth) { $name = $name.Substring(0, $nameWidth - 1) + '...' }
        Write-Host ("  {0,-$nameWidth}  " -f $name) -NoNewline
        Write-Host ("{0,-6}" -f $row.Status) -ForegroundColor $color -NoNewline
        Write-Host ("  {0,10}" -f (Format-DurationMs $row.Ms))
        if ($row.Status -eq 'FAIL' -and $row.Detail) {
            Write-Host ("           -> {0}" -f $row.Detail) -ForegroundColor Red
        }
    }
}

Write-Banner 'SimpleInc validation suite'
Write-ValLog "RepoRoot=$RepoRoot"

if ($env:OS -ne 'Windows_NT') {
    Write-ValLog 'This suite must run on Windows (SimpleInc.exe / Tracker are Win32).' 'ERROR'
    Write-ValLog 'This cloud/Linux agent cannot execute PE binaries.' 'ERROR'
    Write-ValLog 'On a Windows host with VS + .NET Framework csc:' 'INFO'
    Write-ValLog '  powershell -NoProfile -ExecutionPolicy Bypass -File .\validation\Run-Validation.ps1' 'INFO'
    Write-ValLog 'See validation/README.md for options.' 'INFO'
    exit 2
}

$suiteSw = [System.Diagnostics.Stopwatch]::StartNew()
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$WorkRoot = Join-Path $env:TEMP "simpleinc-validation-$stamp-$PID"
$BuildOut = Join-Path $WorkRoot 'build'
$ToolsOut = Join-Path $WorkRoot 'tools'
New-Item -ItemType Directory -Path $WorkRoot, $BuildOut, $ToolsOut -Force | Out-Null
Write-ValLog "WorkRoot=$WorkRoot"

$results = New-Object System.Collections.Generic.List[object]

try {
    Clear-EnvFakeKnobs

    $setupSw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host ''
    Write-ValLog 'Setup: build SimpleInc + helpers'
    $simpleInc = Build-SimpleInc -RepoRoot $RepoRoot -OutDir $BuildOut -SkipBuild:$SkipBuild
    Build-HelperTools -ToolsSrcDir (Join-Path $ValidationRoot 'tools') -OutDir $ToolsOut

    $fakeTrackerDir = Join-Path $WorkRoot 'faketracker-bin'
    New-Item -ItemType Directory -Path $fakeTrackerDir -Force | Out-Null
    Copy-Item (Join-Path $ToolsOut 'FakeTracker.exe') (Join-Path $fakeTrackerDir 'Tracker.exe') -Force
    $setupSw.Stop()
    Write-ValLog ("Setup done in {0}" -f (Format-DurationMs $setupSw.Elapsed.TotalMilliseconds))

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

    Write-Banner ("Running {0} scenario(s)" -f $testScripts.Count)
    $index = 0
    foreach ($script in $testScripts) {
        $index++
        Clear-EnvFakeKnobs
        $label = $script.BaseName
        Write-Host ''
        Write-Host ("-- [{0}/{1}] {2}" -f $index, $testScripts.Count, $label) -ForegroundColor DarkCyan
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            & $script.FullName -Suite $suite
            $sw.Stop()
            $results.Add([pscustomobject]@{
                Name = $label; Status = 'PASS'; Ms = $sw.Elapsed.TotalMilliseconds; Detail = $null
            })
            Write-ValLog ("PASS {0} ({1})" -f $label, (Format-DurationMs $sw.Elapsed.TotalMilliseconds)) 'PASS'
        }
        catch {
            $sw.Stop()
            $detail = $_.Exception.Message
            if ($detail.Length -gt 160) { $detail = $detail.Substring(0, 157) + '...' }
            $results.Add([pscustomobject]@{
                Name = $label; Status = 'FAIL'; Ms = $sw.Elapsed.TotalMilliseconds; Detail = $detail
            })
            Write-ValLog ("FAIL {0}: {1}" -f $label, $_.Exception.Message) 'FAIL'
            if ($_.ScriptStackTrace) {
                Write-ValLog ($_.ScriptStackTrace) 'FAIL'
            }
        }
    }

    if ($UseRealTracker) {
        Write-Host ''
        Write-Host '-- Optional: RealTrackerSmoke' -ForegroundColor DarkCyan
        $trackerDir = Find-RealTrackerDir
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        if (-not $trackerDir) {
            $sw.Stop()
            $results.Add([pscustomobject]@{
                Name = 'RealTrackerSmoke'; Status = 'SKIP'; Ms = $sw.Elapsed.TotalMilliseconds
                Detail = 'Tracker.exe not found via vswhere'
            })
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
                Assert-True (Test-Path (Join-Path $dirs[0].FullName 'complete.flag')) 'real Tracker should publish complete.flag'
                $p2 = [System.Diagnostics.Process]::Start($psi)
                $p2.WaitForExit()
                Assert-ExitCode 0 $p2.ExitCode 'real Tracker smoke up-to-date'
                $sw.Stop()
                $results.Add([pscustomobject]@{
                    Name = 'RealTrackerSmoke'; Status = 'PASS'; Ms = $sw.Elapsed.TotalMilliseconds; Detail = $null
                })
                Write-ValLog ("PASS RealTrackerSmoke ({0})" -f (Format-DurationMs $sw.Elapsed.TotalMilliseconds)) 'PASS'
            }
            catch {
                $sw.Stop()
                $results.Add([pscustomobject]@{
                    Name = 'RealTrackerSmoke'; Status = 'FAIL'; Ms = $sw.Elapsed.TotalMilliseconds
                    Detail = $_.Exception.Message
                })
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

$suiteSw.Stop()
$passed = @($results | Where-Object { $_.Status -eq 'PASS' })
$failed = @($results | Where-Object { $_.Status -eq 'FAIL' })
$skipped = @($results | Where-Object { $_.Status -eq 'SKIP' })

Write-Banner 'Summary'
Write-ResultTable $results
Write-Host ''
$totalMs = ($results | Measure-Object -Property Ms -Sum).Sum
if ($null -eq $totalMs) { $totalMs = 0 }
Write-Host ("  Totals:  {0} passed  *  {1} failed  *  {2} skipped" -f $passed.Count, $failed.Count, $skipped.Count) -ForegroundColor White
Write-Host ("  Scenario time: {0}   Wall clock: {1}" -f (Format-DurationMs $totalMs), (Format-DurationMs $suiteSw.Elapsed.TotalMilliseconds)) -ForegroundColor DarkGray
Write-Host ''

if ($failed.Count -gt 0) {
    Write-Host '  RESULT: FAILED' -ForegroundColor Red
    exit 1
}
Write-Host '  RESULT: PASSED' -ForegroundColor Green
exit 0
