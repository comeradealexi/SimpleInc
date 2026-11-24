# cache.lock must single-flight identical commands: a holder blocks the next
# rebuild, and overlapping cold/dirty runs publish exactly once.
param($Suite)

Clear-EnvFakeKnobs

if (-not ('SimpleIncCacheLockHold' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SimpleIncCacheLockHold {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr h);
    static IntPtr handle = new IntPtr(-1);
    public static void Hold(string path) {
        handle = CreateFileW(path, 0x80000000u | 0x40000000u, 0, IntPtr.Zero, 4, 0x80, IntPtr.Zero);
        if (handle == new IntPtr(-1)) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "CreateFileW cache.lock");
        }
    }
    public static void Release() {
        if (handle != new IntPtr(-1)) {
            CloseHandle(handle);
            handle = new IntPtr(-1);
        }
    }
}
'@
}

function Assert-OverlappingSingleFlight {
    param(
        [Parameter(Mandatory)]$FlightCtx,
        [Parameter(Mandatory)][string]$FlightChild,
        [Parameter(Mandatory)][hashtable]$FlightEnv,
        [Parameter(Mandatory)][string]$FlightOut,
        [Parameter(Mandatory)][string]$Label
    )
    $workers = 4
    $argString = "`"$($FlightCtx.TrackerDir)`" `"$($FlightCtx.CacheRoot)`" $FlightChild"
    $codes = @(Invoke-SimpleIncConcurrent -Exe $FlightCtx.SimpleInc -Arguments $argString -EnvPairs $FlightEnv -Count $workers)
    Assert-Equal $workers $codes.Count "$Label launched $workers processes (got $($codes.Count))"
    foreach ($c in $codes) {
        Assert-Equal 0 ([int]$c) "$Label exit should be 0 (got $c)"
    }
    $dirs = @(Get-CacheHashDirs $FlightCtx.CacheRoot)
    Assert-Equal 1 $dirs.Count "$Label leaves exactly one hash dir (got $($dirs.Count))"
    Assert-True (Test-CacheComplete $dirs[0]) "$Label cache is complete"
    Assert-Equal 1 (Get-FakeRunCount $FlightCtx.RunLog) "$Label invokes FakeTracker once"
    Assert-True (Test-Path $FlightOut) "$Label output exists"
}

$ctx = New-TestContext -WorkRoot $Suite.WorkRoot -Name 'stamp-race' `
    -SimpleIncExe $Suite.SimpleIncExe -FakeTrackerDir $Suite.FakeTrackerDir

$inFile = Join-Path $ctx.DataDir 'input.txt'
$outFile = Join-Path $ctx.DataDir 'output.txt'
Write-Utf8NoBom $inFile 'race'
$child = "`"$($Suite.TouchFileExe)`" `"$outFile`""
$envMap = @{
    SIMPLEINC_FAKE_READS  = $inFile
    SIMPLEINC_FAKE_WRITES = $outFile
    SIMPLEINC_FAKE_RUNLOG = $ctx.RunLog
}
$argString = "`"$($ctx.TrackerDir)`" `"$($ctx.CacheRoot)`" $child"

# Seed a hash dir so the test can hold cache.lock before the next rebuild.
$seed = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
Assert-ExitCode 0 $seed.ExitCode 'seed run'
$cacheDir = Get-SingleCacheDir $ctx.CacheRoot
Assert-True (Test-CacheComplete $cacheDir) 'seed cache complete'
$lockPath = Join-Path $cacheDir 'cache.lock'
Assert-True (Test-Path $lockPath) 'seed run creates cache.lock'

Write-Utf8NoBom $inFile 'race-while-locked'
if (Test-Path $ctx.RunLog) { Remove-Item $ctx.RunLog -Force }

$blocked = $null
$stillBlocked = $false
$runsWhileHeld = -1
[SimpleIncCacheLockHold]::Hold($lockPath)
try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ctx.SimpleInc
    $psi.Arguments = $argString
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($k in $envMap.Keys) {
        [Environment]::SetEnvironmentVariable($k, [string]$envMap[$k], 'Process')
    }
    $blocked = [System.Diagnostics.Process]::Start($psi)
    $null = $blocked.StandardOutput.ReadToEndAsync()
    $null = $blocked.StandardError.ReadToEndAsync()

    # TouchFile is milliseconds. If SimpleInc ignored the lock it would have
    # finished well inside this window.
    Start-Sleep -Milliseconds 800
    $stillBlocked = -not $blocked.HasExited
    $runsWhileHeld = Get-FakeRunCount $ctx.RunLog
}
finally {
    [SimpleIncCacheLockHold]::Release()
    foreach ($k in $envMap.Keys) {
        [Environment]::SetEnvironmentVariable($k, $null, 'Process')
    }
}

Assert-True ($null -ne $blocked) 'blocked SimpleInc process was not started'
Assert-True $stillBlocked 'SimpleInc must wait while cache.lock is held'
Assert-Equal 0 $runsWhileHeld 'FakeTracker must not run while cache.lock is held'

$deadline = [Diagnostics.Stopwatch]::StartNew()
while (-not $blocked.HasExited -and $deadline.ElapsedMilliseconds -lt 15000) {
    Start-Sleep -Milliseconds 50
}
if (-not $blocked.HasExited) {
    try { $blocked.Kill() } catch { }
    throw 'SimpleInc did not finish within 15s after cache.lock was released'
}
$blocked.WaitForExit()
Assert-Equal 0 ([int]$blocked.ExitCode) 'rebuild after the lock is released exits 0'
Assert-Equal 1 (Get-FakeRunCount $ctx.RunLog) 'exactly one FakeTracker run after the lock is released'
$cacheDir = Get-SingleCacheDir $ctx.CacheRoot
Assert-True (Test-CacheComplete $cacheDir) 'released rebuild publishes a complete cache'
$cached = Get-CachedFileTime -CacheDir $cacheDir -ListName 'readfiles.txt' -Path $inFile
Assert-Equal (Get-FileTimeUInt64 $inFile) $cached 'released rebuild records the new input mtime'

if (Test-Path $ctx.RunLog) { Remove-Item $ctx.RunLog -Force }
$null = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
Assert-Equal 0 (Get-FakeRunCount $ctx.RunLog) 'serial call after the locked rebuild must skip'

# Cold overlap uses its own cache root so the seeded hash dir cannot inflate the count.
$coldCtx = New-TestContext -WorkRoot $Suite.WorkRoot -Name 'stamp-race-cold' `
    -SimpleIncExe $Suite.SimpleIncExe -FakeTrackerDir $Suite.FakeTrackerDir
$coldIn = Join-Path $coldCtx.DataDir 'input.txt'
$coldOut = Join-Path $coldCtx.DataDir 'output.txt'
Write-Utf8NoBom $coldIn 'cold'
$coldChild = "`"$($Suite.TouchFileExe)`" `"$coldOut`""
$coldEnv = @{
    SIMPLEINC_FAKE_READS          = $coldIn
    SIMPLEINC_FAKE_WRITES         = $coldOut
    SIMPLEINC_FAKE_CHILD_DELAY_MS = '1000'
    SIMPLEINC_FAKE_RUNLOG         = $coldCtx.RunLog
}
Assert-OverlappingSingleFlight -FlightCtx $coldCtx -FlightChild $coldChild -FlightEnv $coldEnv `
    -FlightOut $coldOut -Label 'cold overlap'

$dirtyCtx = New-TestContext -WorkRoot $Suite.WorkRoot -Name 'stamp-race-dirty' `
    -SimpleIncExe $Suite.SimpleIncExe -FakeTrackerDir $Suite.FakeTrackerDir
$dirtyIn = Join-Path $dirtyCtx.DataDir 'input.txt'
$dirtyOut = Join-Path $dirtyCtx.DataDir 'output.txt'
Write-Utf8NoBom $dirtyIn 'dirty-seed'
$dirtyChild = "`"$($Suite.TouchFileExe)`" `"$dirtyOut`""
$dirtyEnv = @{
    SIMPLEINC_FAKE_READS          = $dirtyIn
    SIMPLEINC_FAKE_WRITES         = $dirtyOut
    SIMPLEINC_FAKE_CHILD_DELAY_MS = '1000'
    SIMPLEINC_FAKE_RUNLOG         = $dirtyCtx.RunLog
}
$null = Invoke-SimpleInc -Ctx $dirtyCtx -CommandLine $dirtyChild -EnvExtra $dirtyEnv
Write-Utf8NoBom $dirtyIn 'dirty-bump'
if (Test-Path $dirtyCtx.RunLog) { Remove-Item $dirtyCtx.RunLog -Force }
Assert-OverlappingSingleFlight -FlightCtx $dirtyCtx -FlightChild $dirtyChild -FlightEnv $dirtyEnv `
    -FlightOut $dirtyOut -Label 'dirty overlap'
$cachedDirty = Get-CachedFileTime -CacheDir (Get-SingleCacheDir $dirtyCtx.CacheRoot) -ListName 'readfiles.txt' -Path $dirtyIn
Assert-Equal (Get-FileTimeUInt64 $dirtyIn) $cachedDirty 'dirty overlap publishes the new input mtime'

if (Test-Path $dirtyCtx.RunLog) { Remove-Item $dirtyCtx.RunLog -Force }
$null = Invoke-SimpleInc -Ctx $dirtyCtx -CommandLine $dirtyChild -EnvExtra $dirtyEnv
Assert-Equal 0 (Get-FakeRunCount $dirtyCtx.RunLog) 'serial call after dirty overlap must skip'

Write-ValLog 'Test-StampRace passed'
