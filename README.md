# SimpleInc
Simple Incremental build tool. Run any command via SimpleInc and it will track all inputs and outputs and only run your command when needed.

# How it works
SimpleInc relies on a program called Tracker.exe which is included as part of your Visual Studio install. Tracker.exe is a special tool which tracks all file access when running your command line and writes out this information.

We expand on this by also writing out the last modified timestamp of the files accessed so we know when a given command line needs to be run based on whether any of the input files have changed.


# How to use


# Building

Open `SimpleInc.sln` in Visual Studio 2022 (v143) and build x64 Debug/Release, or:

```text
msbuild SimpleInc.sln /p:Configuration=Release /p:Platform=x64
```

# Validation

On Windows, the suite builds SimpleInc + helpers, runs every scenario under a temp work root, then deletes that work root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\validation\Run-Validation.ps1
```

Optional: `-UseRealTracker`, `-KeepWorkRoot`, `-Filter <name>`, `-SkipBuild`. Details in `validation/README.md`.

The runner prints a timed per-scenario table and a final pass/fail/skip rollup.

### Suite TLDR (what each scenario covers)

| Script | What it checks |
| --- | --- |
| `Test-ArgcUsage` | Too few args → usage text with newlines + non-zero exit (no crash). |
| `Test-FreshAndUpToDate` | Cold/missing cache runs once; identical second call skips (FakeTracker not re-invoked). |
| `Test-DirtyInvalidation` | Rebuilds on read mtime change, write mtime/clobber, missing write, missing/corrupt/truncated cache lists. |
| `Test-SentinelAndPartial` | Empty hash dir, missing `complete.flag`, sentinel-only, or leftover `.tmp` → never treated as up-to-date. |
| `Test-Quotes` | Paths with spaces / nested quotes and multi-space argv survive into the child. |
| `Test-UnicodePaths` | Non-ASCII paths round-trip in UTF-8 cache via Unicode APIs; up-to-date + write-clobber still work (skips only if the FS can't create the paths). |
| `Test-TlogParsing` | `.tlog` CRLF vs LF vs no final newline; path dedupe; empty tlogs; read vs write from **filename**, even if cache root contains `.write.`. |
| `Test-FailedChild` | Non-zero child exit clears stamp; same command must re-run (no false up-to-date). |
| `Test-MissingTracker` | Missing `Tracker.exe` → non-zero exit and no `complete.flag`. |
| `Test-CacheIdentity` | Different commands get different hash dirs; same command reuses its dir and skips. |
| `Test-InterruptedAndConcurrent` | Partial publish forces rebuild; skip-tlogs still publishes sentinel; concurrent identical runs exit 0 without a false-complete stamp. |
| `Test-LargeTlog` | Hundreds of read/write paths via list files + sharded `.tlog`s; up-to-date skip; mid-list mtime dirty. |
| `Test-DeepLongPaths` | Deep nested directories + long filenames survive cache round-trip and skip. |
| `Test-SameMtimeRecreate` | Delete/recreate with identical FILETIME does **not** invalidate (documents mtime-only pitfall); real mtime bump does. |
| `Test-PathCase` | Tracker casing preserved; NTFS case-insensitive open still up-to-date. |
| `Test-ReadOnlyCache` | Read-only cache files must not cause a silent up-to-date skip when inputs change. |
| `Test-LongCommandLine` | Multi-KB command lines hash/skip correctly; tiny mutation gets a new hash dir. |
| `Test-SharedCacheRoot` | Many distinct commands concurrent under one cache root → one complete hash dir each. |
| `Test-CwdAndEnv` | Identical command strings share a cache key across cwd/env (documents limitation). |
| `Test-StampRace` | Overlapping same-command rebuilds must not leave a false up-to-date stamp. |

`-UseRealTracker` (optional): one smoke against the real VS `Tracker.exe` if vswhere finds it.

# Limitations
