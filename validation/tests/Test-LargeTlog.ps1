# At-scale: many tracked files + sharded tlogs → build cache, skip, then one mtime dirty
param($Suite)

Clear-EnvFakeKnobs
$ctx = New-TestContext -WorkRoot $Suite.WorkRoot -Name 'large-tlog' `
    -SimpleIncExe $Suite.SimpleIncExe -FakeTrackerDir $Suite.FakeTrackerDir

$readCount = 400
$writeCount = 100
$readsRoot = Join-Path $ctx.DataDir 'reads'
$writesRoot = Join-Path $ctx.DataDir 'writes'
$readPaths = New-ManyTouchFiles -Root $readsRoot -Count $readCount -Prefix 'in'
$writePaths = New-ManyTouchFiles -Root $writesRoot -Count $writeCount -Prefix 'out'

$readsFile = Join-Path $ctx.Sandbox 'reads.list'
$writesFile = Join-Path $ctx.Sandbox 'writes.list'
Write-PathListFile $readsFile $readPaths
Write-PathListFile $writesFile $writePaths

# Child just ensures success; FakeTracker supplies the large dependency lists.
$marker = Join-Path $ctx.DataDir 'done.txt'
$child = "`"$($Suite.TouchFileExe)`" `"$marker`""
$envMap = @{
    SIMPLEINC_FAKE_READS_FILE  = $readsFile
    SIMPLEINC_FAKE_WRITES_FILE = $writesFile
    SIMPLEINC_FAKE_TLOG_SHARDS = '4'
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$null = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
$sw.Stop()
Write-ValLog ("Large first run: {0} reads + {1} writes in {2}ms" -f $readCount, $writeCount, $sw.ElapsedMilliseconds)

Assert-equal 1 (Get-FakeRunCount $ctx.RunLog) 'large cold cache runs FakeTracker once'
$cacheDir = Get-SingleCacheDir $ctx.CacheRoot
Assert-True (Test-CacheComplete $cacheDir) 'large cache complete'

function Get-CachePathCount([string]$ListPath) {
    $lines = @(Get-Content $ListPath -Encoding UTF8 | Where-Object { $null -ne $_ })
    # Format is path\nmtime\n pairs
    return [int]([math]::Floor($lines.Count / 2))
}
Assert-Equal $readCount (Get-CachePathCount (Join-Path $cacheDir 'readfiles.txt')) "expected $readCount read paths in cache"
Assert-Equal $writeCount (Get-CachePathCount (Join-Path $cacheDir 'writefiles.txt')) "expected $writeCount write paths in cache"

# Up-to-date skip should stay cheap (no FakeTracker)
$before = Get-FakeRunCount $ctx.RunLog
$sw2 = [System.Diagnostics.Stopwatch]::StartNew()
$null = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
$sw2.Stop()
Assert-Equal $before (Get-FakeRunCount $ctx.RunLog) 'large up-to-date must skip FakeTracker'
Write-ValLog ("Large up-to-date skip in {0}ms" -f $sw2.ElapsedMilliseconds)

# Dirty one mid-list input → rebuild
Start-Sleep -Milliseconds 20
Write-Utf8NoBom $readPaths[($readCount / 2)] 'changed-mid-list'
$null = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
Assert-equal ($before + 1) (Get-FakeRunCount $ctx.RunLog) 'mtime change in large list must rebuild'

Write-ValLog 'Test-LargeTlog passed'
