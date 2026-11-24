# Fresh cache → run; identical second call → skip
param($Suite)

Clear-EnvFakeKnobs
$ctx = New-TestContext -WorkRoot $Suite.WorkRoot -Name 'fresh-uptodate' `
    -SimpleIncExe $Suite.SimpleIncExe -FakeTrackerDir $Suite.FakeTrackerDir

$inFile = Join-Path $ctx.DataDir 'input.txt'
$outFile = Join-Path $ctx.DataDir 'output.txt'
Write-Utf8NoBom $inFile 'hello-input'

$child = "`"$($Suite.TouchFileExe)`" `"$outFile`""
$envMap = @{
    SIMPLEINC_FAKE_READS  = $inFile
    SIMPLEINC_FAKE_WRITES = $outFile
}

$r1 = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
Assert-ExitCode 0 $r1.ExitCode 'first run should succeed'
Assert-Equal 1 (Get-FakeRunCount $ctx.RunLog) 'FakeTracker should run once on cold cache'
Assert-True (Test-Path $outFile) 'child should create output'
$cacheDir = Get-SingleCacheDir $ctx.CacheRoot
Assert-True (Test-CacheComplete $cacheDir) 'complete cache after success'

$r2 = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
Assert-ExitCode 0 $r2.ExitCode 'second run should succeed (skip)'
Assert-Equal 1 (Get-FakeRunCount $ctx.RunLog) 'FakeTracker must NOT re-run when up to date'

Write-ValLog 'Test-FreshAndUpToDate passed'
