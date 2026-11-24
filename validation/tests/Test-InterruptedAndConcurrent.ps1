# Interrupted publish + locked concurrent identical commands
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

# --- Interrupted: partial publish (missing sentinel / leftover .tmp) must rebuild.
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

# --- Skip-tlogs: Tracker exits 0 with no paths → incomplete. No complete.flag, non-zero, next run retries.
$ctx2 = New-TestContext -WorkRoot $Suite.WorkRoot -Name 'skiptlogs' `
    -SimpleIncExe $Suite.SimpleIncExe -FakeTrackerDir $Suite.FakeTrackerDir
$out2 = Join-Path $ctx2.DataDir 'out2.txt'
$child2 = "`"$($Suite.TouchFileExe)`" `"$out2`""
$envSkip = @{
    SIMPLEINC_FAKE_READS      = $inFile
    SIMPLEINC_FAKE_WRITES     = $out2
    SIMPLEINC_FAKE_SKIP_TLOGS = '1'
}
$skip1 = Invoke-SimpleInc -Ctx $ctx2 -CommandLine $child2 -EnvExtra $envSkip -AcceptExitCodes @(-1)
Assert-ExitCode -1 $skip1.ExitCode 'zero-path Tracker result must exit non-zero'
$skipDir = Get-SingleCacheDir $ctx2.CacheRoot
Assert-True (-not (Test-Path (Join-Path $skipDir 'complete.flag'))) 'zero-path run must not publish complete.flag'
Assert-True (-not (Test-Path (Join-Path $skipDir 'readfiles.txt'))) 'zero-path run must clear readfiles.txt'
Assert-True (-not (Test-Path (Join-Path $skipDir 'writefiles.txt'))) 'zero-path run must clear writefiles.txt'
Assert-True (Test-Path (Join-Path $skipDir 'cache.lock')) 'cache.lock stays when the stamp is cleared'
$skip2 = Invoke-SimpleInc -Ctx $ctx2 -CommandLine $child2 -EnvExtra $envSkip -AcceptExitCodes @(-1)
Assert-ExitCode -1 $skip2.ExitCode 'second zero-path run must retry'
Assert-Equal 2 (Get-FakeRunCount $ctx2.RunLog) 'empty stamp must not look up to date'

# --- Concurrent identical commands: cache.lock single-flights clear→run→publish.
$ctx3 = New-TestContext -WorkRoot $Suite.WorkRoot -Name 'concurrent' `
    -SimpleIncExe $Suite.SimpleIncExe -FakeTrackerDir $Suite.FakeTrackerDir
$out3 = Join-Path $ctx3.DataDir 'out3.txt'
$child3 = "`"$($Suite.TouchFileExe)`" `"$out3`""
$env3 = @{
    SIMPLEINC_FAKE_READS          = $inFile
    SIMPLEINC_FAKE_WRITES         = $out3
    SIMPLEINC_FAKE_RUNLOG         = $ctx3.RunLog
    SIMPLEINC_FAKE_CHILD_DELAY_MS = '1000'
}

$argString = "`"$($ctx3.TrackerDir)`" `"$($ctx3.CacheRoot)`" $child3"
$codes = @(Invoke-SimpleIncConcurrent -Exe $ctx3.SimpleInc -Arguments $argString -EnvPairs $env3 -Count 4)
Assert-Equal 4 $codes.Count 'concurrent launch count'
foreach ($c in $codes) {
    Assert-Equal 0 ([int]$c) "concurrent run exit should be 0 (got $c)"
}

$dirs = @(Get-CacheHashDirs $ctx3.CacheRoot)
Assert-Equal 1 $dirs.Count 'concurrent identical commands share one hash dir'
Assert-True (Test-CacheComplete $dirs[0]) 'concurrent publish is complete (lists + sentinel)'
Assert-Equal 1 (Get-FakeRunCount $ctx3.RunLog) 'concurrent identical commands invoke FakeTracker once'

if (Test-Path $ctx3.RunLog) { Remove-Item $ctx3.RunLog -Force }
$null = Invoke-SimpleInc -Ctx $ctx3 -CommandLine $child3 -EnvExtra $env3
Assert-Equal 0 (Get-FakeRunCount $ctx3.RunLog) 'serial call after concurrent publish must skip'

Write-ValLog 'Test-InterruptedAndConcurrent passed'
