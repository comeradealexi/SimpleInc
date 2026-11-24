# SimpleInc validation suite

Windows-only automated checks for the incremental Tracker wrapper. The suite **builds** SimpleInc and small helper tools, **generates** all inputs under a temp work root, runs scenarios covering cache correctness / CLI / tlog edge cases / at-scale stress, then **deletes** that work root.

Output includes colored logs, a **per-scenario PASS/FAIL/SKIP + duration table**, and a final rollup (counts + wall clock).

> This cloud/Linux environment cannot execute `SimpleInc.exe`. Run the suite on a Windows machine with Visual Studio (or Build Tools) and .NET Framework 4.x (`csc.exe`).

## Quick start

From the repo root in **Windows PowerShell** (5.1+) or PowerShell 7 on Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\validation\Run-Validation.ps1
```

Optional switches:

| Switch | Meaning |
| --- | --- |
| `-SkipBuild` | Do not run MSBuild. Requires `-AllowPrebuilt` |
| `-AllowPrebuilt` | Permit a local `Bin\Release\SimpleInc.exe` when `-SkipBuild` is set or MSBuild is missing. That file is not in the repo. Omitted, the suite fails instead of using it |
| `-KeepWorkRoot` | Leave `%TEMP%\simpleinc-validation-*` for debugging |
| `-Filter Dirty` | Run only `tests\Test-*Dirty*.ps1` |
| `-UseRealTracker` | Extra smoke against the real VS `Tracker.exe` if vswhere finds it |

Exit code `0` = all selected tests passed; `1` = failures; `2` = wrong OS / setup.

## Layout

```text
validation/
  Run-Validation.ps1     ← single entry point (summary table + timing)
  README.md
  lib/Common.ps1         ← asserts, build helpers, Invoke-SimpleInc
  tools/
    FakeTracker.cs       ← Tracker.exe stand-in (staged as Tracker.exe)
    EchoArgs.cs          ← records argv / GetCommandLineW
    TouchFile.cs         ← create/update files (optionally set FILETIME)
  tests/Test-*.ps1       ← one script per scenario group
  fixtures/              ← reserved for checked-in binary fixtures if needed
```

## What is covered

| Area | Script |
| --- | --- |
| `argc` / usage newlines | `Test-ArgcUsage.ps1` |
| Fresh cache + up-to-date skip, including a relative tlog path | `Test-FreshAndUpToDate.ps1` |
| Read/write mtime, missing/corrupt cache | `Test-DirtyInvalidation.ps1` |
| `complete.flag` / empty dir / partial publish | `Test-SentinelAndPartial.ps1` |
| Quotes + multi-space command lines; `"` in the Tracker directory or cache root is rejected | `Test-Quotes.ps1` |
| Unicode path UTF-8 cache round-trip | `Test-UnicodePaths.ps1` |
| `.tlog` CRLF/LF/no final NL, dedupe, header-only tlogs refused, `.write.` in path | `Test-TlogParsing.ps1` |
| Failed child / missing Tracker | `Test-FailedChild.ps1`, `Test-MissingTracker.ps1` |
| Cache hash identity | `Test-CacheIdentity.ps1` |
| Interrupted publish, zero-path Tracker miss (no `complete.flag`, non-zero), four locked concurrent runs | `Test-InterruptedAndConcurrent.ps1` |
| Large tlogs (hundreds of paths, sharded) | `Test-LargeTlog.ps1` |
| Deep / long paths | `Test-DeepLongPaths.ps1` |
| Same-mtime recreate pitfall | `Test-SameMtimeRecreate.ps1` |
| Path casing (NTFS) | `Test-PathCase.ps1` |
| Read-only cache files are replaced on a dirty rebuild; the next call skips | `Test-ReadOnlyCache.ps1` |
| Very long command lines | `Test-LongCommandLine.ps1` |
| Shared cache root, many commands | `Test-SharedCacheRoot.ps1` |
| Cwd is in the cache key (two folders, same relative command, both run); env is not | `Test-CwdAndEnv.ps1` |
| Stamp race: external `cache.lock` blocks a rebuild; overlapping cold and dirty runs single-flight | `Test-StampRace.ps1` |
| Optional real Tracker | `-UseRealTracker` |

Helpers talk to SimpleInc the same way production does:  
`SimpleInc.exe <TrackerDir> <CacheDir> <command...>`, with FakeTracker answering as `<TrackerDir>\Tracker.exe`.

FakeTracker knobs (`SIMPLEINC_FAKE_READS`, `SIMPLEINC_FAKE_READS_FILE`, `SIMPLEINC_FAKE_TLOG_SHARDS`, …) are documented in `tools/FakeTracker.cs`.

## Requirements

- Windows x64
- Visual Studio 2019/2022 or Build Tools with MSBuild **and** the C++ toolset (unless `-SkipBuild -AllowPrebuilt`, which needs a `Bin\Release\SimpleInc.exe` you built yourself; that file is not in the repo)
- .NET Framework 4.x `csc.exe` (usually `%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe`)
- For `-UseRealTracker`: MSBuild/`Tracker.exe` from a VS install

## Cleanup

`Run-Validation.ps1` always attempts to `Remove-Item -Recurse` its work root in a `finally` block unless `-KeepWorkRoot` is set. Tests do not write outside that work root (aside from compiling into it / reading the repo sources).
