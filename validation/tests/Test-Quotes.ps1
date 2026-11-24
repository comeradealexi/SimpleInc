# Quote-preserving command lines with spaces / nested quotes
param($Suite)

Clear-EnvFakeKnobs
$ctx = New-TestContext -WorkRoot $Suite.WorkRoot -Name 'quotes' `
    -SimpleIncExe $Suite.SimpleIncExe -FakeTrackerDir $Suite.FakeTrackerDir

$echoOut = Join-Path $ctx.DataDir 'echo-out'
$spaced = Join-Path $ctx.DataDir 'file with spaces.txt'
Write-Utf8NoBom $spaced 'payload'

# Child: EchoArgs <outDir> "file with spaces.txt" nested:"inner value"
# SimpleInc must keep quotes so EchoArgs receives distinct argv entries.
$child = "`"$($Suite.EchoArgsExe)`" `"$echoOut`" `"$spaced`" `"nested:inner value`""

# FakeTracker needs something to record; point reads at the spaced file.
$envMap = @{
    SIMPLEINC_FAKE_READS  = $spaced
    SIMPLEINC_FAKE_WRITES = (Join-Path $echoOut 'ran.txt')
}

$r = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
Assert-ExitCode 0 $r.ExitCode 'quoted command should succeed'
Assert-True (Test-Path (Join-Path $echoOut 'argv.txt')) 'EchoArgs should write argv.txt'

$argvText = Get-Content (Join-Path $echoOut 'argv.txt') -Raw
Assert-True ($argvText -match [regex]::Escape($spaced)) 'spaced path should appear as a single argv entry'
Assert-True ($argvText -match 'nested:inner value') 'nested quoted value should survive'

# Multiple spaces between args should still parse (GetCommandToRun skips extra spaces)
$echoOut2 = Join-Path $ctx.DataDir 'echo-out-2'
$childMultiSpace = "`"$($Suite.EchoArgsExe)`"   `"$echoOut2`"   `"only-one`""
# Different command → different cache hash
$envMap2 = @{
    SIMPLEINC_FAKE_READS  = $spaced
    SIMPLEINC_FAKE_WRITES = (Join-Path $echoOut2 'ran.txt')
}
$r2 = Invoke-SimpleInc -Ctx $ctx -CommandLine $childMultiSpace -EnvExtra $envMap2
Assert-ExitCode 0 $r2.ExitCode 'multi-space command should succeed'
Assert-True (Test-Path (Join-Path $echoOut2 'ran.txt')) 'EchoArgs ran with multi-space cmdline'

Write-ValLog 'Test-Quotes passed'
