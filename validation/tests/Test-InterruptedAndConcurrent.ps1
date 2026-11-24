# Interrupted publish + best-effort concurrent identical commands
param($Suite)

Clear-EnvFakeKnobs
$ctx = New-TestContext -WorkRoot $Suite.WorkRoot -Name 'interrupted-concurrent' `
    -SimpleIncExe $Suite.SimpleIncExe -FakeTrackerDir $Suite.FakeTrackerDir

$inFile = Join-Path $ctx.DataDir 'input.txt'
$outFile = Join-Path $ctx.DataDir 'output.txt'
Write-Utf8NoBom $inFile 'x'
$child = "`"$($Suite.TouchFileExe)`" `"$outFile`""
$envMap = @{
    SIMPLEINC_FAKE_READS  = $inFile
    SIMPLEINC_FAKE_WRITES = $outFile
}

# --- Interrupted: Tracker succeeds but writes no tlogs; BuildCacheFile still publishes empty complete cache.
# Simulate a worse interrupt: manually create partial files without sentinel after a good run.
$null = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
$cacheDir = Get-SingleCacheDir $ctx.CacheRoot
Assert-True (Test-CacheComplete $cacheDir) 'baseline complete'

# Tear down to partial: writefiles missing mid-publish
Remove-Item (Join-Path $cacheDir 'complete.flag') -Force
Remove-Item (Join-Path $cacheDir 'writefiles.txt') -Force
Write-Utf8NoBom (Join-Path $cacheDir 'writefiles.txt.tmp') "partial`n0`n"

if (Test-Path $ctx.RunLog) { Remove-Item $ctx.RunLog -Force }
$null = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
Assert-equal 1 (Get-FakeRunCount $ctx.RunLog) 'partial cache must force rebuild'
Assert-True (Test-CacheComplete (Get-SingleCacheDir $ctx.CacheRoot)) 'rebuild completes publish'
Assert-True (-not (Test-Path (Join-Path (Get-SingleCacheDir $ctx.CacheRoot) 'writefiles.txt.tmp'))) `
    'temp publish leftovers cleared'

# --- Skip-tlogs success: FakeTracker exits 0 without tlogs → empty but complete cache; next call skips
$ctx2 = New-TestContext -WorkRoot $Suite.WorkRoot -Name 'skiptlogs' `
    -SimpleIncExe $Suite.SimpleIncExe -FakeTrackerDir $Suite.FakeTrackerDir
$out2 = Join-Path $ctx2.DataDir 'out2.txt'
$child2 = "`"$($Suite.TouchFileExe)`" `"$out2`""
$envSkip = @{
    SIMPLEINC_FAKE_READS      = $inFile
    SIMPLEINC_FAKE_WRITES     = $out2
    SIMPLEINC_FAKE_SKIP_TLOGS = '1'
}
$null = Invoke-SimpleInc -Ctx $ctx2 -CommandLine $child2 -EnvExtra $envSkip
Assert-True (Test-CacheComplete (Get-SingleCacheDir $ctx2.CacheRoot)) 'skip-tlogs still publishes sentinel'
$before = Get-FakeRunCount $ctx2.RunLog
$null = Invoke-SimpleInc -Ctx $ctx2 -CommandLine $child2 -EnvExtra $envSkip
Assert-equal $before (Get-FakeRunCount $ctx2.RunLog) 'empty complete cache is up to date'

# --- Concurrent identical commands (best-effort): both should exit 0; end state complete or dirty-but-safe
$ctx3 = New-TestContext -WorkRoot $Suite.WorkRoot -Name 'concurrent' `
    -SimpleIncExe $Suite.SimpleIncExe -FakeTrackerDir $Suite.FakeTrackerDir
$out3 = Join-Path $ctx3.DataDir 'out3.txt'
$child3 = "`"$($Suite.TouchFileExe)`" `"$out3`""
$env3 = @{
    SIMPLEINC_FAKE_READS  = $inFile
    SIMPLEINC_FAKE_WRITES = $out3
    SIMPLEINC_FAKE_RUNLOG = $ctx3.RunLog
}

$argString = "`"$($ctx3.TrackerDir)`" `"$($ctx3.CacheRoot)`" $child3"
$jobs = 1..2 | ForEach-Object {
    Start-Job -ScriptBlock {
        param($Exe, $Arguments, $EnvPairs)
        foreach ($k in $EnvPairs.Keys) {
            [Environment]::SetEnvironmentVariable($k, $EnvPairs[$k], 'Process')
        }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Exe
        $psi.Arguments = $Arguments
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $null = $p.StandardOutput.ReadToEnd()
        $null = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        return $p.ExitCode
    } -ArgumentList $ctx3.SimpleInc, $argString, $env3
}

$codes = $jobs | Wait-Job | Receive-Job
$jobs | Remove-Job -Force
foreach ($c in $codes) {
    Assert-Equal 0 ([int]$c) "concurrent run exit should be 0 (got $c)"
}

$dirs = @(Get-CacheHashDirs $ctx3.CacheRoot)
Assert-True ($dirs.Count -ge 1) 'concurrent runs leave at least one hash dir'
# Safe outcome: either complete cache, or incomplete (no false up-to-date without sentinel)
foreach ($d in $dirs) {
    $complete = Test-Path (Join-Path $d 'complete.flag')
    if ($complete) {
        Assert-True (Test-CacheComplete $d) 'if sentinel exists, lists must exist'
    }
}

Write-ValLog 'Test-InterruptedAndConcurrent passed'
