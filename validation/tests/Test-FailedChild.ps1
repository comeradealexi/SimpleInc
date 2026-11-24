# Failed child must not leave a false up-to-date stamp
param($Suite)

Clear-EnvFakeKnobs
$ctx = New-TestContext -WorkRoot $Suite.WorkRoot -Name 'failed-child' `
    -SimpleIncExe $Suite.SimpleIncExe -FakeTrackerDir $Suite.FakeTrackerDir

$inFile = Join-Path $ctx.DataDir 'input.txt'
$outFile = Join-Path $ctx.DataDir 'output.txt'
Write-Utf8NoBom $inFile 'x'

# Child fails via cmd exit
$failChild = 'cmd.exe /C exit /B 7'
$envMap = @{
    SIMPLEINC_FAKE_READS  = $inFile
    SIMPLEINC_FAKE_WRITES = $outFile
}

$r1 = Invoke-SimpleInc -Ctx $ctx -CommandLine $failChild -EnvExtra $envMap -AcceptExitCodes @(7)
Assert-ExitCode 7 $r1.ExitCode 'child failure exit should propagate'
Assert-equal 1 (Get-FakeRunCount $ctx.RunLog) 'FakeTracker ran for failed child'

$dirs = @(Get-CacheHashDirs $ctx.CacheRoot)
foreach ($d in $dirs) {
    Assert-True (-not (Test-Path (Join-Path $d 'complete.flag'))) `
        "failed run must not leave complete.flag in $d"
    Assert-True (-not (Test-Path (Join-Path $d 'readfiles.txt'))) `
        "failed run must not leave readfiles.txt in $d"
}

# Same command again must re-run (not skip)
$r2 = Invoke-SimpleInc -Ctx $ctx -CommandLine $failChild -EnvExtra $envMap -AcceptExitCodes @(7)
Assert-ExitCode 7 $r2.ExitCode 'second failed attempt still fails'
Assert-Equal 2 (Get-FakeRunCount $ctx.RunLog) 'must not treat failed cache as up-to-date'

# Successful run after failures should publish a good cache
$okChild = "`"$($Suite.TouchFileExe)`" `"$outFile`""
$r3 = Invoke-SimpleInc -Ctx $ctx -CommandLine $okChild -EnvExtra $envMap
Assert-ExitCode 0 $r3.ExitCode 'success after failures'
Assert-True (Test-CacheComplete (Get-SingleCacheDir $ctx.CacheRoot)) 'success publishes complete cache'

Write-ValLog 'Test-FailedChild passed'
