# Read-only cache files must not stick the tool: a dirty rebuild clears the
# attribute, republishes, and the following call skips.
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
Assert-Equal 1 (Get-FakeRunCount $ctx.RunLog) 'baseline runs once'

Get-ChildItem $cacheDir -File | ForEach-Object { $_.IsReadOnly = $true }

Start-Sleep -Milliseconds 20
Write-Utf8NoBom $inFile 'v2-force-rebuild'
$r = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
Assert-ExitCode 0 $r.ExitCode 'dirty read-only cache must rebuild and publish'
Assert-Equal 2 (Get-FakeRunCount $ctx.RunLog) 'dirty + RO cache must invoke FakeTracker (not skip)'

$cacheDir = Get-SingleCacheDir $ctx.CacheRoot
Assert-True (Test-CacheComplete $cacheDir) 'rebuild republishes a complete cache'
$cached = Get-CachedFileTime -CacheDir $cacheDir -ListName 'readfiles.txt' -Path $inFile
Assert-Equal (Get-FileTimeUInt64 $inFile) $cached 'republished read stamp matches the new input'
foreach ($name in @('readfiles.txt', 'writefiles.txt', 'complete.flag')) {
    $item = Get-Item (Join-Path $cacheDir $name)
    Assert-True (-not $item.IsReadOnly) "republished $name must not stay read-only"
}

# Recovery: with the cache writable again, the new stamp is up to date.
if (Test-Path $ctx.RunLog) { Remove-Item $ctx.RunLog -Force }
$recovered = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
Assert-ExitCode 0 $recovered.ExitCode 'call after read-only recovery must succeed'
Assert-Equal 0 (Get-FakeRunCount $ctx.RunLog) 'recovered cache must skip on the next call'
Assert-True (Test-CacheComplete (Get-SingleCacheDir $ctx.CacheRoot)) 'recovered cache stays complete'

Write-ValLog 'Test-ReadOnlyCache passed'
