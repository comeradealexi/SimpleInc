# .tlog edge cases: newlines, classification by filename, empty, duplicates
param($Suite)

Clear-EnvFakeKnobs

function Run-TlogScenario {
    param(
        [string]$Name,
        [hashtable]$EnvExtra,
        [scriptblock]$AfterFirst,
        [string]$CacheRootName = 'cache'
    )

    $ctx = New-TestContext -WorkRoot $Suite.WorkRoot -Name $Name `
        -SimpleIncExe $Suite.SimpleIncExe -FakeTrackerDir $Suite.FakeTrackerDir

    # Optionally put ".write." in the cache *root path* to catch substring misclassification
    if ($CacheRootName -ne 'cache') {
        $ctx = [pscustomobject]@{
            Name           = $ctx.Name
            Sandbox        = $ctx.Sandbox
            CacheRoot      = (Join-Path $ctx.Sandbox $CacheRootName)
            DataDir        = $ctx.DataDir
            SimpleInc      = $ctx.SimpleInc
            TrackerDir     = $ctx.TrackerDir
            FakeTrackerExe = $ctx.FakeTrackerExe
            RunLog         = $ctx.RunLog
        }
        New-Item -ItemType Directory -Path $ctx.CacheRoot -Force | Out-Null
    }

    $inFile = Join-Path $ctx.DataDir 'in.txt'
    $outFile = Join-Path $ctx.DataDir 'out.txt'
    Write-Utf8NoBom $inFile 'tlog-in'
    $child = "`"$($Suite.TouchFileExe)`" `"$outFile`""

    $envMap = @{
        SIMPLEINC_FAKE_READS  = $inFile
        SIMPLEINC_FAKE_WRITES = $outFile
    }
    foreach ($k in $EnvExtra.Keys) { $envMap[$k] = $EnvExtra[$k] }

    $null = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra $envMap
    $cacheDir = Get-SingleCacheDir $ctx.CacheRoot
    Assert-True (Test-CacheComplete $cacheDir) "${Name}: cache complete"

    if ($AfterFirst) {
        & $AfterFirst $ctx $cacheDir $inFile $outFile
    }
}

# CRLF (default)
$null = Run-TlogScenario -Name 'tlog-crlf' -EnvExtra @{ SIMPLEINC_FAKE_NEWLINE = 'crlf' } -AfterFirst {
    param($ctx, $cacheDir, $inFile, $outFile)
    $reads = Get-Content (Join-Path $cacheDir 'readfiles.txt') -Encoding UTF8
    Assert-True ($reads -contains $inFile) 'CRLF tlog should produce read entry'
    $writes = Get-Content (Join-Path $cacheDir 'writefiles.txt') -Encoding UTF8
    Assert-True ($writes -contains $outFile) 'CRLF tlog should produce write entry'
}

# LF-only
$null = Run-TlogScenario -Name 'tlog-lf' -EnvExtra @{ SIMPLEINC_FAKE_NEWLINE = 'lf' } -AfterFirst {
    param($ctx, $cacheDir, $inFile, $outFile)
    $reads = Get-Content (Join-Path $cacheDir 'readfiles.txt') -Encoding UTF8
    Assert-True ($reads -contains $inFile) 'LF tlog should produce read entry'
}

# Final line without trailing newline
$null = Run-TlogScenario -Name 'tlog-nonewline' -EnvExtra @{ SIMPLEINC_FAKE_NEWLINE = 'none' } -AfterFirst {
    param($ctx, $cacheDir, $inFile, $outFile)
    $reads = Get-Content (Join-Path $cacheDir 'readfiles.txt') -Encoding UTF8
    Assert-True ($reads -contains $inFile) 'final line without newline must still be parsed'
    $writes = Get-Content (Join-Path $cacheDir 'writefiles.txt') -Encoding UTF8
    Assert-True ($writes -contains $outFile) 'final write line without newline must be parsed'
}

# Duplicate paths in tlog → single cache entry
$null = Run-TlogScenario -Name 'tlog-dup' -EnvExtra @{ SIMPLEINC_FAKE_DUP_PATHS = '1' } -AfterFirst {
    param($ctx, $cacheDir, $inFile, $outFile)
    $reads = @(Get-Content (Join-Path $cacheDir 'readfiles.txt') -Encoding UTF8 | Where-Object { $_ -eq $inFile })
    Assert-Equal 1 $reads.Count 'duplicate tlog paths should dedupe to one read entry'
    $writeLines = Get-Content (Join-Path $cacheDir 'writefiles.txt') -Encoding UTF8
    $pathHits = @($writeLines | Where-Object { $_ -eq $outFile })
    Assert-equal 1 $pathHits.Count 'duplicate write paths should dedupe'
}

# Empty / header-only tlogs → empty maps but still complete
$null = Run-TlogScenario -Name 'tlog-empty' -EnvExtra @{ SIMPLEINC_FAKE_EMPTY_TLOG = '1' } -AfterFirst {
    param($ctx, $cacheDir, $inFile, $outFile)
    $readText = Get-Content (Join-Path $cacheDir 'readfiles.txt') -Raw -ErrorAction SilentlyContinue
    $writeText = Get-Content (Join-Path $cacheDir 'writefiles.txt') -Raw -ErrorAction SilentlyContinue
    Assert-True ([string]::IsNullOrWhiteSpace($readText)) 'empty tlog → empty readfiles'
    Assert-True ([string]::IsNullOrWhiteSpace($writeText)) 'empty tlog → empty writefiles'
    # Second run should skip (no inputs/outputs to invalidate)
    $before = Get-FakeRunCount $ctx.RunLog
    $child = "`"$($Suite.TouchFileExe)`" `"$outFile`""
    $null = Invoke-SimpleInc -Ctx $ctx -CommandLine $child -EnvExtra @{
        SIMPLEINC_FAKE_READS = $inFile
        SIMPLEINC_FAKE_WRITES = $outFile
        SIMPLEINC_FAKE_EMPTY_TLOG = '1'
    }
    Assert-equal $before (Get-FakeRunCount $ctx.RunLog) 'empty-deps cache should be up to date'
}

# Classification by filename — cache root contains ".write." substring
$null = Run-TlogScenario -Name 'tlog-classify-path' -CacheRootName 'cache.write.root' -EnvExtra @{} -AfterFirst {
    param($ctx, $cacheDir, $inFile, $outFile)
    Assert-True ($ctx.CacheRoot -match '\.write\.') 'cache root should contain .write. for this scenario'
    $reads = Get-Content (Join-Path $cacheDir 'readfiles.txt') -Encoding UTF8
    $writes = Get-Content (Join-Path $cacheDir 'writefiles.txt') -Encoding UTF8
    Assert-True ($reads -contains $inFile) 'read tlog must not be misclassified because path contains .write.'
    Assert-True ($writes -contains $outFile) 'write tlog still classified as write'
    Assert-True ($reads -notcontains $outFile) 'output must not appear in readfiles'
    Assert-True ($writes -notcontains $inFile) 'input must not appear in writefiles'
}

Write-ValLog 'Test-TlogParsing passed'
