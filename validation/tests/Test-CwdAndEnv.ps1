# Document cwd/env sensitivity: cache key is the command string only (not cwd/env)
param($Suite)

Clear-EnvFakeKnobs
$ctx = New-TestContext -WorkRoot $Suite.WorkRoot -Name 'cwd-env' `
    -SimpleIncExe $Suite.SimpleIncExe -FakeTrackerDir $Suite.FakeTrackerDir

$dirA = Join-Path $ctx.DataDir 'projA'
$dirB = Join-Path $ctx.DataDir 'projB'
New-Item -ItemType Directory -Path $dirA, $dirB -Force | Out-Null
Write-Utf8NoBom (Join-Path $dirA 'rel-in.txt') 'A'
Write-Utf8NoBom (Join-Path $dirB 'rel-in.txt') 'B'

# Relative child command text is identical; only cwd differs.
# SimpleInc hashes GetCommandLine remainder — cwd is NOT part of the key.
$relOut = 'rel-out.txt'
$child = "cmd.exe /C echo cwd-test> $relOut"

function Invoke-FromCwd {
    param([string]$Cwd, [string]$AbsRead, [string]$AbsWrite)
    $prev = Get-Location
    try {
        Set-Location $Cwd
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $ctx.SimpleInc
        $psi.Arguments = "`"$($ctx.TrackerDir)`" `"$($ctx.CacheRoot)`" $child"
        $psi.WorkingDirectory = $Cwd
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        # Absolute paths in FakeTracker lists so CheckIfOutOfDate is well-defined per project
        [Environment]::SetEnvironmentVariable('SIMPLEINC_FAKE_READS', $AbsRead, 'Process')
        [Environment]::SetEnvironmentVariable('SIMPLEINC_FAKE_WRITES', $AbsWrite, 'Process')
        [Environment]::SetEnvironmentVariable('SIMPLEINC_FAKE_RUNLOG', $ctx.RunLog, 'Process')
        $p = [System.Diagnostics.Process]::Start($psi)
        $null = $p.StandardOutput.ReadToEnd()
        $null = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        return $p.ExitCode
    }
    finally {
        Set-Location $prev
        Clear-EnvFakeKnobs
    }
}

$codeA = Invoke-FromCwd -Cwd $dirA -AbsRead (Join-Path $dirA 'rel-in.txt') -AbsWrite (Join-Path $dirA $relOut)
Assert-Equal 0 $codeA 'projA run'
Assert-True (Test-Path (Join-Path $dirA $relOut)) 'projA wrote relative output'
$dirsAfterA = @(Get-CacheHashDirs $ctx.CacheRoot)
Assert-Equal 1 $dirsAfterA.Count 'one hash after first cwd'

# Same command text from projB — SHARES the cache key. Document the false up-to-date:
# FakeTracker recorded A's absolute paths; B's inputs are different files but the command
# string matches, so SimpleInc skips and projB must NOT get a fresh relative output.
$runsAfterA = Get-FakeRunCount $ctx.RunLog
$codeB = Invoke-FromCwd -Cwd $dirB -AbsRead (Join-Path $dirB 'rel-in.txt') -AbsWrite (Join-Path $dirB $relOut)
Assert-Equal 0 $codeB 'projB run exits 0'
$dirsAfterB = @(Get-CacheHashDirs $ctx.CacheRoot)
Assert-Equal 1 $dirsAfterB.Count `
    'identical command strings share one hash dir regardless of cwd (documented limitation)'
Assert-Equal $runsAfterA (Get-FakeRunCount $ctx.RunLog) `
    'projB must share projA cache key and skip Tracker (documented cwd limitation)'
Assert-True (-not (Test-Path (Join-Path $dirB $relOut))) `
    'projB relative output must be absent when cwd is not part of the cache key'

# Env var change alone does not alter the cache key either
$env:SIMPLEINC_TEST_ENV_MARKER = 'one'
$null = Invoke-FromCwd -Cwd $dirA -AbsRead (Join-Path $dirA 'rel-in.txt') -AbsWrite (Join-Path $dirA $relOut)
$env:SIMPLEINC_TEST_ENV_MARKER = 'two'
$runsBefore = Get-FakeRunCount $ctx.RunLog
$null = Invoke-FromCwd -Cwd $dirA -AbsRead (Join-Path $dirA 'rel-in.txt') -AbsWrite (Join-Path $dirA $relOut)
Remove-Item Env:SIMPLEINC_TEST_ENV_MARKER -ErrorAction SilentlyContinue
Assert-Equal $runsBefore (Get-FakeRunCount $ctx.RunLog) `
    'changing an unrelated env var must not by itself bust the cache key'

Write-ValLog 'Test-CwdAndEnv passed (documents cwd/env not in cache key)'
