# Shared helpers for SimpleInc validation suite.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-ValLog {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = (Get-Date).ToString('HH:mm:ss')
    $color = switch ($Level) {
        'PASS'  { 'Green' }
        'FAIL'  { 'Red' }
        'ERROR' { 'Red' }
        'WARN'  { 'Yellow' }
        default { 'Gray' }
    }
    Write-Host "[$ts][$Level] $Message" -ForegroundColor $color
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw "ASSERT FAILED: $Message"
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "ASSERT FAILED: $Message (expected='$Expected' actual='$Actual')"
    }
}

function Assert-ExitCode {
    param([int]$Expected, [int]$Actual, [string]$Message)
    # Normalize Windows DWORD wrap of -1 → compare as Int32
    $e = [int]$Expected
    $a = [int]$Actual
    if ($e -ne $a) {
        throw "ASSERT FAILED: $Message (expected exit $e actual $a)"
    }
}

function Get-FileTimeUInt64 {
    param([Parameter(Mandatory)][string]$Path)
    return [uint64]([System.IO.File]::GetLastWriteTimeUtc($Path).ToFileTimeUtc())
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function New-CacheListContent {
    param([hashtable]$PathToFileTime)
    $sb = New-Object System.Text.StringBuilder
    foreach ($key in $PathToFileTime.Keys) {
        [void]$sb.Append($key)
        [void]$sb.Append("`n")
        [void]$sb.Append([string]$PathToFileTime[$key])
        [void]$sb.Append("`n")
    }
    return $sb.ToString()
}

function Find-MSBuild {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
        $found = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' 2>$null
        if ($found) {
            if ($found -is [array]) { return $found[0] }
            return $found
        }
    }
    $candidates = @(
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Enterprise\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Community\MSBuild\Current\Bin\MSBuild.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

function Find-Csc {
    $frameworks = @(
        "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
        "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    )
    foreach ($c in $frameworks) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

function Find-RealTrackerDir {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
        $msbuildBin = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin' 2>$null
        if ($msbuildBin) {
            $dir = if ($msbuildBin -is [array]) { $msbuildBin[0] } else { $msbuildBin }
            if (Test-Path (Join-Path $dir 'Tracker.exe')) { return $dir }
        }
    }
    return $null
}

function Build-SimpleInc {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$OutDir,
        [switch]$SkipBuild,
        [switch]$AllowPrebuilt
    )

    $prebuilt = Join-Path $RepoRoot 'Bin\Release\SimpleInc.exe'
    $msbuild = Find-MSBuild

    # Checked-in Bin\Release is not rebuilt by this script. Using it without an
    # explicit opt-in validates a stale binary and reports PASS.
    if ($SkipBuild -or -not $msbuild) {
        if (-not $AllowPrebuilt) {
            if ($SkipBuild) {
                throw "Refusing prebuilt $prebuilt. -SkipBuild requires -AllowPrebuilt (that binary may not match source)."
            }
            throw "MSBuild not found. Refusing prebuilt $prebuilt. Install Visual Studio Build Tools, or pass -AllowPrebuilt to use the checked-in binary."
        }
        if (-not (Test-Path $prebuilt)) {
            throw "AllowPrebuilt requested but prebuilt binary missing: $prebuilt"
        }
        $why = if ($SkipBuild) { '-SkipBuild -AllowPrebuilt' } else { 'MSBuild not found and -AllowPrebuilt' }
        Write-ValLog "Using prebuilt $prebuilt ($why). It may not match current source." 'WARN'
        Copy-Item $prebuilt (Join-Path $OutDir 'SimpleInc.exe') -Force
        return (Join-Path $OutDir 'SimpleInc.exe')
    }

    Write-ValLog "Building SimpleInc with $msbuild"
    $sln = Join-Path $RepoRoot 'SimpleInc.sln'
    # Capture MSBuild stdout/stderr so it does not become part of this function's
    # return value (PowerShell would otherwise make SimpleIncExe an Object[]).
    $msbuildOutput = & $msbuild $sln /nologo /v:m /t:Rebuild /p:Configuration=Release /p:Platform=x64 `
        /p:OutDir="$OutDir\" /p:IntDir="$OutDir\obj\" 2>&1
    if ($LASTEXITCODE -ne 0) {
        $msbuildOutput | ForEach-Object { Write-ValLog "$_" 'ERROR' }
        throw "MSBuild failed with exit $LASTEXITCODE"
    }
    $built = Join-Path $OutDir 'SimpleInc.exe'
    if (-not (Test-Path $built)) {
        # Default vcxproj output when /p:OutDir is ignored. Not Bin\Release —
        # that tree is a checked-in binary and is only used with -AllowPrebuilt.
        $alts = @(
            (Join-Path $RepoRoot 'x64\Release\SimpleInc.exe'),
            (Join-Path $RepoRoot 'Release\SimpleInc.exe')
        )
        foreach ($alt in $alts) {
            if (Test-Path $alt) {
                Write-ValLog "Copying fresh build output from $alt"
                Copy-Item $alt $built -Force
                break
            }
        }
    }
    if (-not (Test-Path $built)) {
        throw "SimpleInc.exe was not produced at $built. Refusing Bin\Release\SimpleInc.exe without -AllowPrebuilt."
    }
    return [string]$built
}

function Build-HelperTools {
    param(
        [Parameter(Mandatory)][string]$ToolsSrcDir,
        [Parameter(Mandatory)][string]$OutDir
    )
    $csc = Find-Csc
    if (-not $csc) {
        throw 'csc.exe not found (need .NET Framework 4.x developer pack / runtime).'
    }

    $sources = @(
        @{ Name = 'FakeTracker'; Src = 'FakeTracker.cs' },
        @{ Name = 'EchoArgs'; Src = 'EchoArgs.cs' },
        @{ Name = 'TouchFile'; Src = 'TouchFile.cs' }
    )

    foreach ($s in $sources) {
        $src = Join-Path $ToolsSrcDir $s.Src
        $out = Join-Path $OutDir ($s.Name + '.exe')
        Write-ValLog "Compiling $($s.Name) -> $out"
        $cscOutput = & $csc /nologo /optimize+ /target:exe /out:$out $src 2>&1
        if ($LASTEXITCODE -ne 0) {
            $cscOutput | ForEach-Object { Write-ValLog "$_" 'ERROR' }
            throw "csc failed for $($s.Name) with exit $LASTEXITCODE"
        }
        Assert-True (Test-Path $out) "Missing $out"
    }
}

function New-TestContext {
    param(
        [Parameter(Mandatory)][string]$WorkRoot,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$SimpleIncExe,
        [Parameter(Mandatory)][string]$FakeTrackerDir
    )

    $sandbox = Join-Path $WorkRoot "cases\$Name"
    if (Test-Path $sandbox) {
        Remove-Item $sandbox -Recurse -Force
    }
    New-Item -ItemType Directory -Path $sandbox | Out-Null

    $cacheRoot = Join-Path $sandbox 'cache'
    $dataDir = Join-Path $sandbox 'data'
    New-Item -ItemType Directory -Path $cacheRoot, $dataDir | Out-Null

    $runLog = Join-Path $sandbox 'faketracker-runs.log'
    if (Test-Path $runLog) { Remove-Item $runLog -Force }

    return [pscustomobject]@{
        Name            = $Name
        Sandbox         = $sandbox
        CacheRoot       = $cacheRoot
        DataDir         = $dataDir
        SimpleInc       = $SimpleIncExe
        TrackerDir      = $FakeTrackerDir
        FakeTrackerExe  = Join-Path $FakeTrackerDir 'Tracker.exe'
        RunLog          = $runLog
    }
}

function Get-FakeRunCount {
    param([string]$RunLog)
    if (-not (Test-Path $RunLog)) { return 0 }
    return @(Get-Content $RunLog | Where-Object { $_.Trim() -ne '' }).Count
}

function Invoke-SimpleInc {
    param(
        [Parameter(Mandatory)]$Ctx,
        [Parameter(Mandatory)][string]$CommandLine,
        [hashtable]$EnvExtra = @{},
        [int[]]$AcceptExitCodes = @(0),
        [string]$WorkingDirectory = ''
    )

    $prev = @{}
    foreach ($k in $EnvExtra.Keys) {
        $prev[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')
        [Environment]::SetEnvironmentVariable($k, [string]$EnvExtra[$k], 'Process')
    }
    # Always point FakeTracker run log unless caller overrides
    if (-not $EnvExtra.ContainsKey('SIMPLEINC_FAKE_RUNLOG')) {
        $prev['SIMPLEINC_FAKE_RUNLOG'] = [Environment]::GetEnvironmentVariable('SIMPLEINC_FAKE_RUNLOG', 'Process')
        [Environment]::SetEnvironmentVariable('SIMPLEINC_FAKE_RUNLOG', $Ctx.RunLog, 'Process')
    }

    try {
        $argList = @($Ctx.TrackerDir, $Ctx.CacheRoot) + $CommandLine
        # Use Start-Process with ArgumentList carefully — for quote tests callers pass a single
        # pre-built command string as one element when needed.
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Ctx.SimpleInc
        $psi.Arguments = "`"$($Ctx.TrackerDir)`" `"$($Ctx.CacheRoot)`" $CommandLine"
        if ($WorkingDirectory) {
            $psi.WorkingDirectory = $WorkingDirectory
        }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $stdout = $p.StandardOutput.ReadToEnd()
        $stderr = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        $code = $p.ExitCode

        if ($AcceptExitCodes -notcontains $code) {
            throw ("SimpleInc exit $code not in accepted [$($AcceptExitCodes -join ',')].`n" +
                "Args: $($psi.Arguments)`nOUT: $stdout`nERR: $stderr")
        }
        return [pscustomobject]@{
            ExitCode = $code
            StdOut   = $stdout
            StdErr   = $stderr
            Arguments = $psi.Arguments
        }
    }
    finally {
        foreach ($k in $prev.Keys) {
            [Environment]::SetEnvironmentVariable($k, $prev[$k], 'Process')
        }
    }
}

function Invoke-SimpleIncConcurrent {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string]$Arguments,
        [Parameter(Mandatory)][hashtable]$EnvPairs,
        [Parameter(Mandatory)][int]$Count
    )

    $jobs = 1..$Count | ForEach-Object {
        Start-Job -ScriptBlock {
            param($JobExe, $JobArguments, $JobEnv)
            foreach ($k in $JobEnv.Keys) {
                [Environment]::SetEnvironmentVariable($k, [string]$JobEnv[$k], 'Process')
            }
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $JobExe
            $psi.Arguments = $JobArguments
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            $null = $p.StandardOutput.ReadToEnd()
            $null = $p.StandardError.ReadToEnd()
            $p.WaitForExit()
            return [int]$p.ExitCode
        } -ArgumentList $Exe, $Arguments, $EnvPairs
    }

    $codes = @($jobs | Wait-Job | Receive-Job)
    $jobs | Remove-Job -Force
    return $codes
}

function Get-CachedFileTime {
    param(
        [Parameter(Mandatory)][string]$CacheDir,
        [Parameter(Mandatory)][string]$ListName,
        [Parameter(Mandatory)][string]$Path
    )
    $lines = @(Get-Content (Join-Path $CacheDir $ListName) -Encoding UTF8)
    for ($i = 0; $i -lt ($lines.Count - 1); $i += 2) {
        if ($lines[$i] -eq $Path) {
            return [uint64]$lines[$i + 1]
        }
    }
    throw "Path not found in ${ListName}: $Path"
}

function Get-CacheHashDirs {
    param([string]$CacheRoot)
    # Emit zero-or-more path strings on the pipeline. Callers must wrap with @()
    # so a single directory is still an Object[] (StrictMode: [string] has no .Count).
    if (-not (Test-Path $CacheRoot)) {
        return
    }
    Get-ChildItem $CacheRoot -Directory | Select-Object -ExpandProperty FullName
}

function Get-SingleCacheDir {
    param([string]$CacheRoot)
    $dirs = @(Get-CacheHashDirs $CacheRoot)
    Assert-True ($dirs.Count -eq 1) "Expected exactly one cache hash dir under $CacheRoot (got $($dirs.Count))"
    return [string]$dirs[0]
}

function Get-CompleteCacheDirs {
    param([string]$CacheRoot)
    @(Get-CacheHashDirs $CacheRoot) | Where-Object { Test-CacheComplete $_ }
}

function Test-CacheComplete {
    param([string]$CacheDir)
    return (Test-Path (Join-Path $CacheDir 'complete.flag')) -and
        (Test-Path (Join-Path $CacheDir 'readfiles.txt')) -and
        (Test-Path (Join-Path $CacheDir 'writefiles.txt'))
}

function Clear-EnvFakeKnobs {
    $names = @(
        'SIMPLEINC_FAKE_READS', 'SIMPLEINC_FAKE_WRITES',
        'SIMPLEINC_FAKE_READS_FILE', 'SIMPLEINC_FAKE_WRITES_FILE',
        'SIMPLEINC_FAKE_NEWLINE', 'SIMPLEINC_FAKE_DUP_PATHS', 'SIMPLEINC_FAKE_EMPTY_TLOG',
        'SIMPLEINC_FAKE_SKIP_TLOGS', 'SIMPLEINC_FAKE_BOM', 'SIMPLEINC_FAKE_PREFIX',
        'SIMPLEINC_FAKE_TLOG_SHARDS', 'SIMPLEINC_FAKE_FORCE_EXIT', 'SIMPLEINC_FAKE_RUNLOG',
        'SIMPLEINC_FAKE_CACHE_ROOT_MARKER', 'SIMPLEINC_FAKE_CHILD_DELAY_MS'
    )
    foreach ($n in $names) {
        [Environment]::SetEnvironmentVariable($n, $null, 'Process')
    }
}

function New-ManyTouchFiles {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][int]$Count,
        [string]$Prefix = 'f'
    )
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    $paths = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $Count; $i++) {
        $p = Join-Path $Root ("{0}-{1:D5}.txt" -f $Prefix, $i)
        Write-Utf8NoBom $p ("content-$i")
        [void]$paths.Add($p)
    }
    return ,@($paths.ToArray())
}

function Write-PathListFile {
    param([string]$Path, [string[]]$Paths)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($Path, $Paths, $enc)
}
