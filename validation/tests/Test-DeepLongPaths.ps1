# Deep directories + long filenames (stay under classic MAX_PATH when possible)
param($Suite)

Clear-EnvFakeKnobs
$ctx = New-TestContext -WorkRoot $Suite.WorkRoot -Name 'deep-long-paths' `
    -SimpleIncExe $Suite.SimpleIncExe -FakeTrackerDir $Suite.FakeTrackerDir

# ~12 nested segments × short names + one long leaf (~80 chars) — typically < 260 with TEMP root
$deep = $ctx.DataDir
1..12 | ForEach-Object { $deep = Join-Path $deep ("seg{0:D2}" -f $_) }
New-Item -ItemType Directory -Path $deep -Force | Out-Null

$longLeaf = ('L' * 80) + '.txt'
$inFile = Join-Path $deep $longLeaf
$outFile = Join-Path $deep (('O' * 60) + '-out.txt')

try {
    Write-Utf8NoBom $inFile 'deep-input'
}
catch {
    throw "SKIP: deep/long path create ($($_.Exception.Message))"
}

Assert-True ($inFile.Length -gt 120) "expected a long path, got length $($inFile.Length)"
Write-ValLog ("Deep path length={0}" -f $inFile.Length)

$child = "`"$($Suite.TouchFileExe)`" `"$outFile`""
$envMap = @{
    SIMPLEINC_FAKE_READS  = $inFile
    SIMPLEINC_FAKE_WRITES = $outFile
}

$null = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
Assert-True (Test-Path $outFile) 'deep/long output created'
$cacheDir = Get-SingleCacheDir $ctx.CacheRoot
Assert-True (Test-CacheComplete $cacheDir) 'deep/long cache complete'

$reads = Get-Content (Join-Path $cacheDir 'readfiles.txt') -Encoding UTF8
Assert-True ($reads -contains $inFile) 'long path must appear verbatim in readfiles'

$before = Get-FakeRunCount $ctx.RunLog
$null = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
Assert-Equal $before (Get-FakeRunCount $ctx.RunLog) 'deep/long up-to-date skip'

Write-ValLog 'Test-DeepLongPaths passed'
