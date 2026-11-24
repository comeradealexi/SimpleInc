# SimpleInc validation suite

Windows-only automated checks for the incremental Tracker wrapper. The suite **builds** SimpleInc and small helper tools, **generates** all inputs under a temp work root, runs scenarios covering cache correctness / CLI / tlog edge cases, then **deletes** that work root.

> This cloud/Linux environment cannot execute `SimpleInc.exe`. Run the suite on a Windows machine with Visual Studio (or Build Tools) and .NET Framework 4.x (`csc.exe`).

## Quick start

From the repo root in **Windows PowerShell** (5.1+) or PowerShell 7 on Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\validation\Run-Validation.ps1
```

Optional switches:

| Switch | Meaning |
| --- | --- |
| `-SkipBuild` | Use `Bin\Release\SimpleInc.exe` instead of MSBuild (may lag source fixes) |
| `-KeepWorkRoot` | Leave `%TEMP%\simpleinc-validation-*` for debugging |
| `-Filter Dirty` | Run only `tests\Test-*Dirty*.ps1` |
| `-UseRealTracker` | Extra smoke against the real VS `Tracker.exe` if vswhere finds it |

Exit code `0` = all selected tests passed; `1` = failures; `2` = wrong OS / setup.

## Layout

```text
validation/
  Run-Validation.ps1     ← single entry point
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
| Fresh cache + up-to-date skip | `Test-FreshAndUpToDate.ps1` |
| Read/write mtime, missing/corrupt cache | `Test-DirtyInvalidation.ps1` |
| `complete.flag` / empty dir / partial publish | `Test-SentinelAndPartial.ps1` |
| Quotes + multi-space command lines | `Test-Quotes.ps1` |
| Unicode path UTF-8 cache round-trip | `Test-UnicodePaths.ps1` |
| `.tlog` CRLF/LF/no final NL, dedupe, empty, `.write.` in path | `Test-TlogParsing.ps1` |
| Failed child clears stamp | `Test-FailedChild.ps1` |
| Cache hash identity | `Test-CacheIdentity.ps1` |
| Interrupted publish + concurrent runs | `Test-InterruptedAndConcurrent.ps1` |
| Optional real Tracker | `-UseRealTracker` |

Helpers talk to SimpleInc the same way production does:  
`SimpleInc.exe <TrackerDir> <CacheDir> <command...>`, with FakeTracker answering as `<TrackerDir>\Tracker.exe`.

FakeTracker is controlled via process environment variables (`SIMPLEINC_FAKE_READS`, `SIMPLEINC_FAKE_WRITES`, `SIMPLEINC_FAKE_NEWLINE`, …) documented in `tools/FakeTracker.cs`.

## Requirements

- Windows x64
- Visual Studio 2019/2022 or Build Tools with MSBuild **and** C++ toolset for the SimpleInc project (unless `-SkipBuild` + prebuilt exe)
- .NET Framework 4.x `csc.exe` (usually `%\WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe`)
- For `-UseRealTracker`: MSBuild/`Tracker.exe` from a VS install

## Cleanup

`Run-Validation.ps1` always attempts to `Remove-Item -Recurse` its work root in a `finally` block unless `-KeepWorkRoot` is set. Tests do not write outside that work root (aside from compiling into it / reading the repo sources).
