# Overlapping rebuilds of the same command (stamp race): end state must not be false up-to-date
param($Suite)

Clear-EnvFakeKnobs
$ctx = New-TestContext -WorkRoot $Suite.WorkRoot -Name 'stamp-race' `
    -SimpleIncExe $Suite.SimpleIncExe -FakeTrackerDir $Suite.FakeTrackerDir

$inFile = Join-Path $ctx.DataDir 'input.txt'
$outFile = Join-Path $ctx.DataDir 'output.txt'
Write-Utf8NoBom $inFile 'race'
$child = "`"$($Suite.TouchFileExe)`" `"$outFile`""
$envMap = @{
    SIMPLEINC_FAKE_READS         = $inFile
    SIMPLEINC_FAKE_WRITES        = $outFile
    SIMPLEINC_FAKE_CHILD_DELAY_MS = '200'
    SIMPLEINC_FAKE_RUNLOG        = $ctx.RunLog
}

$argString = "`"$($ctx.TrackerDir)`" `"$($ctx.CacheRoot)`" $child"
$jobBlock = {
    param($Exe, $Arguments, $EnvPairs)
    foreach ($k in $EnvPairs.Keys) {
        [Environment]::SetEnvironmentVariable($k, [string]$EnvPairs[$k], 'Process')
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
}

# Two cold overlapping runs with a child delay to widen the race window
$j1 = Start-Job -ScriptBlock $jobBlock -ArgumentList $ctx.SimpleInc, $argString, $envMap
Start-Sleep -Milliseconds 50
$j2 = Start-Job -ScriptBlock $jobBlock -ArgumentList $ctx.SimpleInc, $argString, $envMap
$codes = @($j1, $j2) | Wait-Job | Receive-Job
@($j1, $j2) | Remove-Job -Force
foreach ($c in $codes) {
    Assert-equal 0 ([int]$c) "stamp-race exit should be 0 (got $c)"
}

$dirs = @(Get-CacheHashDirs $ctx.CacheRoot)
Assert-True ($dirs.Count -ge 1) 'stamp-race leaves a hash dir'
foreach ($d in $dirs) {
    $complete = Test-Path (Join-Path $d 'complete.flag')
    if ($complete) {
        Assert-True (Test-CacheComplete $d) 'sentinel implies full publish'
    }
}

# If we have a complete stamp, a follow-up skip is OK; if not, follow-up must rebuild (not silent skip)
if (Test-Path $ctx.RunLog) { Remove-Item $ctx.RunLog -Force }
$followEnv = @{
    SIMPLEINC_FAKE_READS  = $inFile
    SIMPLEINC_FAKE_WRITES = $outFile
}
$null = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $followEnv
$anyComplete = $false
foreach ($d in @(Get-CacheHashDirs $ctx.CacheRoot)) {
    if (Test-CacheComplete $d) { $anyComplete = $true }
}
if ($anyComplete) {
    # May skip (0 FakeTracker) or rebuild; either is OK as long as we did not skip without a stamp earlier.
    Assert-True $true 'complete cache present after race'
}
else {
    Assert-True ((Get-FakeRunCount $ctx.RunLog) -ge 1) 'incomplete after race must not look up-to-date'
}

Write-ValLog 'Test-StampRace passed'
