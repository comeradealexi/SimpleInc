# Read/write mtime changes, missing write, corrupt/missing cache files → dirty
param($Suite)

Clear-EnvFakeKnobs
$ctx = New-TestContext -WorkRoot $Suite.WorkRoot -Name 'dirty-invalidation' `
    -SimpleIncExe $Suite.SimpleIncExe -FakeTrackerDir $Suite.FakeTrackerDir

$inFile = Join-Path $ctx.DataDir 'input.txt'
$outFile = Join-Path $ctx.DataDir 'output.txt'
Write-Utf8NoBom $inFile 'v1'
$child = "`"$($Suite.TouchFileExe)`" `"$outFile`""
$envMap = @{
    SIMPLEINC_FAKE_READS  = $inFile
    SIMPLEINC_FAKE_WRITES = $outFile
}

function Reset-Baseline {
    if (Test-Path $ctx.CacheRoot) { Remove-Item $ctx.CacheRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $ctx.CacheRoot | Out-Null
    if (Test-Path $ctx.RunLog) { Remove-Item $ctx.RunLog -Force }
    Write-Utf8NoBom $inFile 'v1'
    if (Test-Path $outFile) { Remove-Item $outFile -Force }
    $null = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
    Assert-Equal 1 (Get-FakeRunCount $ctx.RunLog) 'baseline FakeTracker run'
}

# --- read mtime change ---
Reset-Baseline
Start-Sleep -Milliseconds 20
Write-Utf8NoBom $inFile 'v2-changed'
$null = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
Assert-Equal 2 (Get-FakeRunCount $ctx.RunLog) 'read mtime change must rebuild'

# --- write mtime change (clobber output) ---
Reset-Baseline
Start-Sleep -Milliseconds 20
Write-Utf8NoBom $outFile 'clobbered-externally'
$null = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
Assert-Equal 2 (Get-FakeRunCount $ctx.RunLog) 'write mtime change must rebuild'

# --- missing write ---
Reset-Baseline
Remove-Item $outFile -Force
$null = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
Assert-Equal 2 (Get-FakeRunCount $ctx.RunLog) 'missing write must rebuild'

# --- missing readfiles.txt ---
Reset-Baseline
$cacheDir = Get-SingleCacheDir $ctx.CacheRoot
Remove-Item (Join-Path $cacheDir 'readfiles.txt') -Force
$null = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
Assert-equal 2 (Get-FakeRunCount $ctx.RunLog) 'missing readfiles.txt must rebuild'

# --- missing writefiles.txt ---
Reset-Baseline
$cacheDir = Get-SingleCacheDir $ctx.CacheRoot
Remove-Item (Join-Path $cacheDir 'writefiles.txt') -Force
$null = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
Assert-equal 2 (Get-FakeRunCount $ctx.RunLog) 'missing writefiles.txt must rebuild'

# --- corrupt mtime ---
Reset-Baseline
$cacheDir = Get-SingleCacheDir $ctx.CacheRoot
$corrupt = @(
    $inFile
    'not-a-number'
)
Write-Utf8NoBom (Join-Path $cacheDir 'readfiles.txt') (($corrupt -join "`n") + "`n")
# keep complete.flag + writefiles so only mtime parse fails
$null = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
Assert-equal 2 (Get-FakeRunCount $ctx.RunLog) 'corrupt mtime must rebuild'

# --- truncated pair (path without mtime line) ---
Reset-Baseline
$cacheDir = Get-SingleCacheDir $ctx.CacheRoot
Write-Utf8NoBom (Join-Path $cacheDir 'writefiles.txt') "$outFile`n"
$null = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
Assert-Equal 2 (Get-FakeRunCount $ctx.RunLog) 'truncated cache entry must rebuild'

Write-ValLog 'Test-DirtyInvalidation passed'
