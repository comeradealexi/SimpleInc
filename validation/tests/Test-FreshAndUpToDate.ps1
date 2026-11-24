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

# Relative tlog paths must still match. Prefixing them with \\?\ makes CreateFileW
# fail and the command looks permanently dirty.
$relRoot = Join-Path $ctx.DataDir 'relcase'
New-Item -ItemType Directory -Path $relRoot -Force | Out-Null
Write-Utf8NoBom (Join-Path $relRoot 'input.txt') 'rel-input'
$relOut = Join-Path $relRoot 'output.txt'
$relChild = "`"$($Suite.TouchFileExe)`" `"$relOut`""
$relEnv = @{
    SIMPLEINC_FAKE_READS  = 'input.txt'
    SIMPLEINC_FAKE_WRITES = 'output.txt'
}
if (Test-Path $ctx.RunLog) { Remove-Item $ctx.RunLog -Force }
$rr1 = Invoke-SimpleInc -Ctx $ctx -CommandLine $relChild -EnvExtra $relEnv -WorkingDirectory $relRoot
Assert-ExitCode 0 $rr1.ExitCode 'relative-dep first run'
Assert-Equal 1 (Get-FakeRunCount $ctx.RunLog) 'relative-dep cold run invokes FakeTracker'
Assert-True (Test-Path $relOut) 'relative-dep child wrote the absolute output'
$rr2 = Invoke-SimpleInc -Ctx $ctx -CommandLine $relChild -EnvExtra $relEnv -WorkingDirectory $relRoot
Assert-ExitCode 0 $rr2.ExitCode 'relative-dep second run'
Assert-Equal 1 (Get-FakeRunCount $ctx.RunLog) 'relative dependency path must skip when unchanged'

Write-ValLog 'Test-FreshAndUpToDate passed'
