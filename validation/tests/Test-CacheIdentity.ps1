# Different commands → different hash dirs; same command → same dir
param($Suite)

Clear-EnvFakeKnobs
$ctx = New-TestContext -WorkRoot $Suite.WorkRoot -Name 'cache-identity' `
    -SimpleIncExe $Suite.SimpleIncExe -FakeTrackerDir $Suite.FakeTrackerDir

$inFile = Join-Path $ctx.DataDir 'input.txt'
$outA = Join-Path $ctx.DataDir 'outA.txt'
$outB = Join-Path $ctx.DataDir 'outB.txt'
Write-Utf8NoBom $inFile 'id'

$childA = "`"$($Suite.TouchFileExe)`" `"$outA`""
$childB = "`"$($Suite.TouchFileExe)`" `"$outB`""

$envA = @{ SIMPLEINC_FAKE_READS = $inFile; SIMPLEINC_FAKE_WRITES = $outA }
$envB = @{ SIMPLEINC_FAKE_READS = $inFile; SIMPLEINC_FAKE_WRITES = $outB }

$null = Invoke-SimpleInc -Ctx $ctx -CommandLine $childA -EnvExtra $envA
$dirAfterA = @(Get-CacheHashDirs $ctx.CacheRoot)
Assert-equal 1 $dirAfterA.Count 'one hash dir after command A'

$null = Invoke-SimpleInc -Ctx $ctx -CommandLine $childB -EnvExtra $envB
$dirAfterB = @(Get-CacheHashDirs $ctx.CacheRoot)
Assert-equal 2 $dirAfterB.Count 'different commands must not share a cache dir'

# Re-run A → still two dirs, FakeTracker not invoked for A
$runsBefore = Get-FakeRunCount $ctx.RunLog
$null = Invoke-SimpleInc -Ctx $ctx -CommandLine $childA -EnvExtra $envA
Assert-equal $runsBefore (Get-FakeRunCount $ctx.RunLog) 'same command A should hit its existing cache'
Assert-equal 2 (@(Get-CacheHashDirs $ctx.CacheRoot).Count) 'still two hash dirs'

Write-ValLog 'Test-CacheIdentity passed'
