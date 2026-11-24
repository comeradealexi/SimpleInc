# Read-only cache files: dirty must still attempt rebuild (no silent up-to-date skip)
param($Suite)

Clear-EnvFakeKnobs
$ctx = New-TestContext -WorkRoot $Suite.WorkRoot -Name 'readonly-cache' `
    -SimpleIncExe $Suite.SimpleIncExe -FakeTrackerDir $Suite.FakeTrackerDir

$inFile = Join-Path $ctx.DataDir 'input.txt'
$outFile = Join-Path $ctx.DataDir 'output.txt'
Write-Utf8NoBom $inFile 'v1'
$child = "`"$($Suite.TouchFileExe)`" `"$outFile`""
$envMap = @{
    SIMPLEINC_FAKE_READS  = $inFile
    SIMPLEINC_FAKE_WRITES = $outFile
}

$null = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
$cacheDir = Get-SingleCacheDir $ctx.CacheRoot
Assert-True (Test-CacheComplete $cacheDir) 'baseline complete'

Get-ChildItem $cacheDir -File | ForEach-Object { $_.IsReadOnly = $true }

Start-Sleep -Milliseconds 20
Write-Utf8NoBom $inFile 'v2-force-rebuild'
# ClearCacheDir / republish may fail on RO files on Windows; either successful rebuild
# or a failed rebuild is OK — silent skip is not.
$r = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap -AcceptExitCodes @(0, -1)
Assert-True ((Get-FakeRunCount $ctx.RunLog) -ge 2) 'dirty + RO cache must still invoke FakeTracker (not skip)'

if ($r.ExitCode -eq 0) {
    $cacheDir2 = Get-SingleCacheDir $ctx.CacheRoot
    Assert-True (Test-CacheComplete $cacheDir2) 'successful rebuild republishes complete cache'
}
else {
    Write-ValLog 'Rebuild exited non-zero with RO cache files (ClearCacheDir/publish limitation) — OK if not skipped' 'WARN'
    # Stale complete.flag + changed input must still look dirty next time
    if (Test-Path $ctx.RunLog) { Remove-Item $ctx.RunLog -Force }
    $r2 = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap -AcceptExitCodes @(0, -1)
    Assert-True ((Get-FakeRunCount $ctx.RunLog) -ge 1) 'must not silently skip while inputs disagree with cached mtimes'
}

Write-ValLog 'Test-ReadOnlyCache passed'
