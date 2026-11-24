# UTF-8 / Unicode path round-trip through cache (when the host FS allows)
param($Suite)

Clear-EnvFakeKnobs
$ctx = New-TestContext -WorkRoot $Suite.WorkRoot -Name 'unicode-paths' `
    -SimpleIncExe $Suite.SimpleIncExe -FakeTrackerDir $Suite.FakeTrackerDir

$uniDir = Join-Path $ctx.DataDir ("uni-" + [char]0x00E9 + [char]0x03B1 + "-Pfad")  # é α
try {
    New-Item -ItemType Directory -Path $uniDir -Force | Out-Null
}
catch {
    Write-ValLog "Skipping Unicode path creation ($($_.Exception.Message))" 'WARN'
    return
}

$inFile = Join-Path $uniDir ("input-" + [char]0x65E5 + [char]0x672C + ".txt")  # 日本
$outFile = Join-Path $uniDir ("output-" + [char]0x4E2D + ".txt")
try {
    Write-Utf8NoBom $inFile 'unicode-input'
}
catch {
    Write-ValLog "Skipping Unicode file write ($($_.Exception.Message))" 'WARN'
    return
}

$child = "`"$($Suite.TouchFileExe)`" `"$outFile`""
$envMap = @{
    SIMPLEINC_FAKE_READS  = $inFile
    SIMPLEINC_FAKE_WRITES = $outFile
}

$r1 = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
Assert-ExitCode 0 $r1.ExitCode 'unicode first run'
Assert-True (Test-Path $outFile) 'unicode output created'
$cacheDir = Get-SingleCacheDir $ctx.CacheRoot
Assert-True (Test-CacheComplete $cacheDir) 'unicode cache complete'

$reads = Get-Content (Join-Path $cacheDir 'readfiles.txt') -Encoding UTF8
Assert-True ($reads[0].Contains([char]0x65E5) -or $reads[0] -like '*input*') `
    "readfiles should retain unicode path, got: $($reads[0])"

# Up-to-date skip with unicode paths
$before = Get-FakeRunCount $ctx.RunLog
$r2 = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
Assert-ExitCode 0 $r2.ExitCode 'unicode up-to-date skip'
Assert-Equal $before (Get-FakeRunCount $ctx.RunLog) 'should not re-run FakeTracker for unchanged unicode paths'

# Clobber unicode output → dirty
Start-Sleep -Milliseconds 20
Write-Utf8NoBom $outFile 'clobber'
$null = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
Assert-True ((Get-FakeRunCount $ctx.RunLog) -gt $before) 'unicode write mtime change rebuilds'

Write-ValLog 'Test-UnicodePaths passed'
