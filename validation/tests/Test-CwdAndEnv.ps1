# Cache key includes the normalized cwd. The environment is still outside the key.
param($Suite)

Clear-EnvFakeKnobs
$ctx = New-TestContext -WorkRoot $Suite.WorkRoot -Name 'cwd-env' `
    -SimpleIncExe $Suite.SimpleIncExe -FakeTrackerDir $Suite.FakeTrackerDir

$dirA = Join-Path $ctx.DataDir 'projA'
$dirB = Join-Path $ctx.DataDir 'projB'
New-Item -ItemType Directory -Path $dirA, $dirB -Force | Out-Null
Write-Utf8NoBom (Join-Path $dirA 'rel-in.txt') 'A'
Write-Utf8NoBom (Join-Path $dirB 'rel-in.txt') 'B'

# Same relative command text. Only the process working directory differs.
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
Assert-Equal 1 (Get-FakeRunCount $ctx.RunLog) 'projA invokes Tracker once'
Assert-True (Test-CacheComplete $dirsAfterA[0]) 'projA stamp is complete'

# Same relative command from projB must not reuse projA's stamp.
$codeB = Invoke-FromCwd -Cwd $dirB -AbsRead (Join-Path $dirB 'rel-in.txt') -AbsWrite (Join-Path $dirB $relOut)
Assert-Equal 0 $codeB 'projB run exits 0'
Assert-True (Test-Path (Join-Path $dirB $relOut)) 'projB wrote its own relative output'
$dirsAfterB = @(Get-CacheHashDirs $ctx.CacheRoot)
Assert-Equal 2 $dirsAfterB.Count 'same relative command from two cwds uses two cache dirs'
Assert-True ($dirsAfterB -contains $dirsAfterA[0]) 'projA hash dir is kept'
$newDirs = @($dirsAfterB | Where-Object { $_ -ne $dirsAfterA[0] })
Assert-Equal 1 $newDirs.Count 'projB has a distinct hash dir'
Assert-True (Test-CacheComplete $newDirs[0]) 'projB stamp is complete'
Assert-Equal 2 (Get-FakeRunCount $ctx.RunLog) 'projB runs Tracker instead of skipping'

# projA's stamp is still a hit. B did not clobber it.
$runsAfterBoth = Get-FakeRunCount $ctx.RunLog
$codeA2 = Invoke-FromCwd -Cwd $dirA -AbsRead (Join-Path $dirA 'rel-in.txt') -AbsWrite (Join-Path $dirA $relOut)
Assert-Equal 0 $codeA2 'projA second run'
Assert-Equal $runsAfterBoth (Get-FakeRunCount $ctx.RunLog) 'projA second run skips'

# Env var change alone does not alter the cache key.
$env:SIMPLEINC_TEST_ENV_MARKER = 'one'
$null = Invoke-FromCwd -Cwd $dirA -AbsRead (Join-Path $dirA 'rel-in.txt') -AbsWrite (Join-Path $dirA $relOut)
$env:SIMPLEINC_TEST_ENV_MARKER = 'two'
$runsBefore = Get-FakeRunCount $ctx.RunLog
$null = Invoke-FromCwd -Cwd $dirA -AbsRead (Join-Path $dirA 'rel-in.txt') -AbsWrite (Join-Path $dirA $relOut)
Remove-Item Env:SIMPLEINC_TEST_ENV_MARKER -ErrorAction SilentlyContinue
Assert-Equal $runsBefore (Get-FakeRunCount $ctx.RunLog) `
    'changing an unrelated env var must not by itself bust the cache key'

Write-ValLog 'Test-CwdAndEnv passed (cwd is in the cache key; env is not)'
