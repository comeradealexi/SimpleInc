# Windows path case: cache stores exact Tracker casing; lookup uses that string
param($Suite)

Clear-EnvFakeKnobs
$ctx = New-TestContext -WorkRoot $Suite.WorkRoot -Name 'path-case' `
    -SimpleIncExe $Suite.SimpleIncExe -FakeTrackerDir $Suite.FakeTrackerDir

$inFile = Join-Path $ctx.DataDir 'CaseInput.txt'
$outFile = Join-Path $ctx.DataDir 'CaseOutput.txt'
Write-Utf8NoBom $inFile 'case-v1'
$child = "`"$($Suite.TouchFileExe)`" `"$outFile`""

# Report a differently-cased path than the on-disk CreateFile path (same NTFS object).
$altCase = Join-Path $ctx.DataDir 'caseinput.txt'  # lower 'c'
$envMap = @{
    SIMPLEINC_FAKE_READS  = $altCase
    SIMPLEINC_FAKE_WRITES = $outFile
}

$null = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
$cacheDir = Get-SingleCacheDir $ctx.CacheRoot
$reads = Get-Content (Join-Path $cacheDir 'readfiles.txt') -Encoding UTF8
Assert-True ($reads -contains $altCase) 'cache should store the exact casing Tracker reported'

$before = Get-FakeRunCount $ctx.RunLog
$null = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
# On NTFS, CreateFileW with different case opens the same file → same mtime → skip
Assert-equal $before (Get-FakeRunCount $ctx.RunLog) `
    'case-differing path string should still open the same file and stay up to date on NTFS'

Write-ValLog 'Test-PathCase passed'
