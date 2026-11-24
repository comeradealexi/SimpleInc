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

# A double-quote inside the Tracker directory or cache root is rejected.
# Those paths are wrapped in quotes on the Tracker command line and are not escaped.
function Quote-WinArg {
    param([string]$Value)
    return '"' + ($Value -replace '"', '""') + '"'
}

function Invoke-SimpleIncCommandLine {
    param([string]$Exe, [string]$Arguments)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return [pscustomobject]@{ ExitCode = $p.ExitCode; StdOut = $out; StdErr = $err }
}

function Assert-QuoteRejected {
    param($Result, [string]$LabelFragment, [string]$What)
    Assert-ExitCode -1 $Result.ExitCode "$What must fail"
    $text = $Result.StdErr + $Result.StdOut
    Assert-True ($text -match 'must not contain a double-quote') `
        "$What should explain the double-quote rejection: OUT=$($Result.StdOut) ERR=$($Result.StdErr)"
    Assert-True ($Result.StdErr -match [regex]::Escape($LabelFragment)) `
        "$What should name '$LabelFragment': ERR=$($Result.StdErr)"
}

$dirsBeforeQuote = @(Get-CacheHashDirs $ctx.CacheRoot)
$badTrackerArgs = (Quote-WinArg 'C:\track"er') + ' ' + (Quote-WinArg $ctx.CacheRoot) + ' cmd.exe /c echo hi'
$badTracker = Invoke-SimpleIncCommandLine -Exe $ctx.SimpleInc -Arguments $badTrackerArgs
Assert-QuoteRejected -Result $badTracker -LabelFragment 'Tracker directory' -What 'tracker path with a quote'
Assert-Equal $dirsBeforeQuote.Count @(Get-CacheHashDirs $ctx.CacheRoot).Count `
    'quoted tracker path must not create a hash dir'

$badCacheArgs = (Quote-WinArg $ctx.TrackerDir) + ' ' + (Quote-WinArg 'C:\ca"che') + ' cmd.exe /c echo hi'
$badCache = Invoke-SimpleIncCommandLine -Exe $ctx.SimpleInc -Arguments $badCacheArgs
Assert-QuoteRejected -Result $badCache -LabelFragment 'Cache directory' -What 'cache root with a quote'

Write-ValLog 'Test-Quotes passed'
