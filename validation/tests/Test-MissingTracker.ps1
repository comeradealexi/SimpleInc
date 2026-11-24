# CreateProcess failure when Tracker.exe is missing → non-zero, no complete stamp
param($Suite)

Clear-EnvFakeKnobs
$ctx = New-TestContext -WorkRoot $Suite.WorkRoot -Name 'missing-tracker' `
    -SimpleIncExe $Suite.SimpleIncExe -FakeTrackerDir $Suite.FakeTrackerDir

# Point at an empty directory so Tracker.exe cannot be found
$emptyTracker = Join-Path $ctx.Sandbox 'no-tracker'
New-Item -ItemType Directory -Path $emptyTracker -Force | Out-Null
$ctx = [pscustomobject]@{
    Name           = $ctx.Name
    Sandbox        = $ctx.Sandbox
    CacheRoot      = $ctx.CacheRoot
    DataDir        = $ctx.DataDir
    SimpleInc      = $ctx.SimpleInc
    TrackerDir     = $emptyTracker
    FakeTrackerExe = Join-Path $emptyTracker 'Tracker.exe'
    RunLog         = $ctx.RunLog
}

$outFile = Join-Path $ctx.DataDir 'out.txt'
$child = "`"$($Suite.TouchFileExe)`" `"$outFile`""
$r = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra @{} -AcceptExitCodes @(-1, 4294967295)
# main returns -1 from CreateProcess failure path (DWORD -1)
Assert-True ($r.ExitCode -ne 0) 'missing Tracker must not exit 0'

$dirs = @(Get-CacheHashDirs $ctx.CacheRoot)
foreach ($d in $dirs) {
    Assert-True (-not (Test-Path (Join-Path $d 'complete.flag'))) `
        'missing Tracker must not publish complete.flag'
}

Write-ValLog 'Test-MissingTracker passed'
