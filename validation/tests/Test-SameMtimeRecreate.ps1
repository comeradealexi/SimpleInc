# Delete + recreate with identical FILETIME: mtime-only cache does NOT rebuild (documents pitfall)
param($Suite)

Clear-EnvFakeKnobs
$ctx = New-TestContext -WorkRoot $Suite.WorkRoot -Name 'same-mtime-recreate' `
    -SimpleIncExe $Suite.SimpleIncExe -FakeTrackerDir $Suite.FakeTrackerDir

$inFile = Join-Path $ctx.DataDir 'input.txt'
$outFile = Join-Path $ctx.DataDir 'output.txt'
Write-Utf8NoBom $inFile 'original-bytes'
$child = "`"$($Suite.TouchFileExe)`" `"$outFile`""
$envMap = @{
    SIMPLEINC_FAKE_READS  = $inFile
    SIMPLEINC_FAKE_WRITES = $outFile
}

$null = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
$ft = Get-FileTimeUInt64 $inFile
$before = Get-FakeRunCount $ctx.RunLog

# Replace content but restore the exact prior FILETIME via TouchFile helper
Remove-Item $inFile -Force
& $Suite.TouchFileExe $inFile ([string]$ft)
if ($LASTEXITCODE -ne 0) { throw "TouchFile failed with $LASTEXITCODE" }
Assert-Equal $ft (Get-FileTimeUInt64 $inFile) 'restored FILETIME must match cached stamp'

$null = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
Assert-equal $before (Get-FakeRunCount $ctx.RunLog) `
    'same FILETIME after recreate must NOT invalidate (mtime-only limitation)'

# Control: bump mtime → rebuild
Start-Sleep -Milliseconds 20
Write-Utf8NoBom $inFile 'new-bytes-new-mtime'
$null = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
Assert-equal ($before + 1) (Get-FakeRunCount $ctx.RunLog) 'real mtime change still rebuilds'

Write-ValLog 'Test-SameMtimeRecreate passed'
