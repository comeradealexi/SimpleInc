# Very long trailing command line (stress GetCommandLine / hash / CreateProcess path)
param($Suite)

Clear-EnvFakeKnobs
$ctx = New-TestContext -WorkRoot $Suite.WorkRoot -Name 'long-cmdline' `
    -SimpleIncExe $Suite.SimpleIncExe -FakeTrackerDir $Suite.FakeTrackerDir

$outFile = Join-Path $ctx.DataDir 'out.txt'
$inFile = Join-Path $ctx.DataDir 'in.txt'
Write-Utf8NoBom $inFile 'x'

# ~8KiB of payload args — well under CreateProcess 32K limit but larger than typical tools use
$chunks = 1..80 | ForEach-Object { 'PAD' + ('x' * 100) + $_ }
$payload = ($chunks | ForEach-Object { "`"$_`"" }) -join ' '
$child = "`"$($Suite.EchoArgsExe)`" `"$($ctx.DataDir)\echo`" $payload"
Assert-True ($child.Length -gt 7000) "expected long command fragment, got $($child.Length)"

$envMap = @{
    SIMPLEINC_FAKE_READS  = $inFile
    SIMPLEINC_FAKE_WRITES = (Join-Path $ctx.DataDir 'echo\ran.txt')
}

$r1 = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
Assert-ExitCode 0 $r1.ExitCode 'long cmdline first run'
Assert-True (Test-Path (Join-Path $ctx.DataDir 'echo\ran.txt')) 'EchoArgs ran'
Assert-True (Test-CacheComplete (Get-SingleCacheDir $ctx.CacheRoot)) 'long cmdline cache complete'

$before = Get-FakeRunCount $ctx.RunLog
$null = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
Assert-equal $before (Get-FakeRunCount $ctx.RunLog) 'identical long cmdline should skip'

# Tiny change at the end → different hash → new cache dir + re-run
$child2 = $child + ' "TAILDIFF"'
$null = Invoke-SimpleInc -Ctx $ctx -CommandLine $child2 -EnvExtra $envMap
Assert-True ((Get-FakeRunCount $ctx.RunLog) -gt $before) 'mutated long cmdline must not share cache'
Assert-True ((@(Get-CacheHashDirs $ctx.CacheRoot).Count) -ge 2) 'long cmdline mutation creates another hash dir'

Write-ValLog 'Test-LongCommandLine passed'
