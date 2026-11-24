# complete.flag / partial publish must never look up-to-date
param($Suite)

Clear-EnvFakeKnobs
$ctx = New-TestContext -WorkRoot $Suite.WorkRoot -Name 'sentinel-partial' `
    -SimpleIncExe $Suite.SimpleIncExe -FakeTrackerDir $Suite.FakeTrackerDir

$inFile = Join-Path $ctx.DataDir 'input.txt'
$outFile = Join-Path $ctx.DataDir 'output.txt'
Write-Utf8NoBom $inFile 'seed'
$child = "`"$($Suite.TouchFileExe)`" `"$outFile`""
$envMap = @{
    SIMPLEINC_FAKE_READS  = $inFile
    SIMPLEINC_FAKE_WRITES = $outFile
}

function Invoke-AndCount {
    param([int]$ExpectedRuns)
    if (Test-Path $ctx.RunLog) { Remove-Item $ctx.RunLog -Force }
    $null = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
    Assert-Equal $ExpectedRuns (Get-FakeRunCount $ctx.RunLog) "expected $ExpectedRuns FakeTracker runs"
}

# Empty cache directory (no sentinel) → dirty
$decoy = Join-Path $ctx.CacheRoot '12345'
New-Item -ItemType Directory -Path $decoy -Force | Out-Null
Invoke-AndCount 1
# Real command hashes to a different dir than the decoy; drop the decoy so later
# Get-SingleCacheDir assertions stay unambiguous.
Assert-True (-not (Test-CacheComplete $decoy)) 'decoy empty dir must not look complete'
Remove-Item $decoy -Recurse -Force
$cacheDir = Get-SingleCacheDir $ctx.CacheRoot
Assert-True (Test-CacheComplete $cacheDir) 'publish should create sentinel'

# Remove only complete.flag; leave read/write lists → dirty
Remove-Item (Join-Path $cacheDir 'complete.flag') -Force
Invoke-AndCount 1
$cacheDir = Get-SingleCacheDir $ctx.CacheRoot
Assert-True (Test-Path (Join-Path $cacheDir 'complete.flag')) 'sentinel restored after rebuild'

# Lists present but sentinel missing + leftover .tmp (interrupted publish simulation)
$cacheDir = Get-SingleCacheDir $ctx.CacheRoot
Copy-Item (Join-Path $cacheDir 'readfiles.txt') (Join-Path $cacheDir 'readfiles.txt.tmp') -Force
Remove-Item (Join-Path $cacheDir 'complete.flag') -Force
Invoke-AndCount 1
Assert-True (-not (Test-Path (Join-Path (Get-SingleCacheDir $ctx.CacheRoot) 'readfiles.txt.tmp'))) `
    'ClearCacheDir should remove leftover temp publish files before rebuild'

# Sentinel alone without lists → dirty
$cacheDir = Get-SingleCacheDir $ctx.CacheRoot
Remove-Item (Join-Path $cacheDir 'readfiles.txt') -Force
Remove-Item (Join-Path $cacheDir 'writefiles.txt') -Force
# leave complete.flag
Invoke-AndCount 1

# After ClearCacheDir-style empty hash dir (files gone, dir remains): still dirty
$cacheDir = Get-SingleCacheDir $ctx.CacheRoot
Get-ChildItem $cacheDir | Remove-Item -Force -Recurse
Assert-True (Test-Path $cacheDir) 'hash dir still exists but empty'
Invoke-AndCount 1
Assert-True (Test-CacheComplete (Get-SingleCacheDir $ctx.CacheRoot)) 'rebuild after empty dir'

Write-ValLog 'Test-SentinelAndPartial passed'
