# Many commands share one cache root; concurrent distinct commands must not clobber each other
param($Suite)

Clear-EnvFakeKnobs
$ctx = New-TestContext -WorkRoot $Suite.WorkRoot -Name 'shared-cache-root' `
    -SimpleIncExe $Suite.SimpleIncExe -FakeTrackerDir $Suite.FakeTrackerDir

$inFile = Join-Path $ctx.DataDir 'shared-in.txt'
Write-Utf8NoBom $inFile 'shared'

$jobs = @()
$commandCount = 8
1..$commandCount | ForEach-Object {
    $i = $_
    $out = Join-Path $ctx.DataDir ("out-$i.txt")
    $child = "`"$($Suite.TouchFileExe)`" `"$out`""
    $envPairs = @{
        SIMPLEINC_FAKE_READS  = $inFile
        SIMPLEINC_FAKE_WRITES = $out
        SIMPLEINC_FAKE_RUNLOG = $ctx.RunLog
    }
    $argString = "`"$($ctx.TrackerDir)`" `"$($ctx.CacheRoot)`" $child"
    $jobs += Start-Job -ScriptBlock {
        param($Exe, $Arguments, $EnvPairs)
        foreach ($k in $EnvPairs.Keys) {
            [Environment]::SetEnvironmentVariable($k, [string]$EnvPairs[$k], 'Process')
        }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Exe
        $psi.Arguments = $Arguments
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $null = $p.StandardOutput.ReadToEnd()
        $null = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        return $p.ExitCode
    } -ArgumentList $ctx.SimpleInc, $argString, $envPairs
}

$codes = $jobs | Wait-Job | Receive-Job
$jobs | Remove-Job -Force
foreach ($c in $codes) {
    Assert-equal 0 ([int]$c) "shared-root concurrent exit should be 0 (got $c)"
}

$dirs = @(Get-CacheHashDirs $ctx.CacheRoot)
Assert-equal $commandCount $dirs.Count "expected $commandCount distinct hash dirs under shared cache root"
foreach ($d in $dirs) {
    Assert-True (Test-CacheComplete $d) "each concurrent command should leave a complete cache: $d"
}

# Serial re-run of command 1 should skip (its hash dir intact)
$out1 = Join-Path $ctx.DataDir 'out-1.txt'
$child1 = "`"$($Suite.TouchFileExe)`" `"$out1`""
if (Test-Path $ctx.RunLog) { Remove-Item $ctx.RunLog -Force }
$null = Invoke-SimpleInc -Ctx $ctx -CommandLine $child1 -EnvExtra @{
    SIMPLEINC_FAKE_READS  = $inFile
    SIMPLEINC_FAKE_WRITES = $out1
}
Assert-equal 0 (Get-FakeRunCount $ctx.RunLog) 're-run of one shared-root command should skip after concurrent populate'

Write-ValLog 'Test-SharedCacheRoot passed'
