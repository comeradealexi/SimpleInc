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

Optional: `-UseRealTracker`, `-KeepWorkRoot`, `-Filter <name>`, `-AllowPrebuilt` (required with `-SkipBuild`; otherwise a missing MSBuild fails the suite instead of using `Bin\Release\SimpleInc.exe`). Details in `validation/README.md`.

The runner prints a timed per-scenario table and a final pass/fail/skip rollup.

### Suite TLDR (what each scenario covers)

| Script | What it checks |
| --- | --- |
| `Test-ArgcUsage` | Too few args → usage text with newlines + non-zero exit (no crash). |
| `Test-FreshAndUpToDate` | Cold/missing cache runs once; identical second call skips. A relative tlog path still skips (not broken by `\\?\`). |
| `Test-DirtyInvalidation` | Rebuilds on read mtime change, write mtime/clobber, missing write, missing/corrupt/truncated cache lists. |
| `Test-SentinelAndPartial` | Empty hash dir, missing `complete.flag`, sentinel-only, or leftover `.tmp` → never treated as up-to-date. |
| `Test-Quotes` | Paths with spaces / nested quotes and multi-space argv survive into the child. |
| `Test-UnicodePaths` | Non-ASCII paths round-trip in UTF-8 cache via Unicode APIs; up-to-date + write-clobber still work (skips only if the FS can't create the paths). |
| `Test-TlogParsing` | `.tlog` CRLF vs LF vs no final newline; path dedupe; empty tlogs; read vs write from **filename**, even if cache root contains `.write.`. |
| `Test-FailedChild` | Non-zero child exit clears stamp; same command must re-run (no false up-to-date). |
| `Test-MissingTracker` | Missing `Tracker.exe` → non-zero exit and no `complete.flag`. |
| `Test-CacheIdentity` | Different commands get different hash dirs; same command reuses its dir and skips. |
| `Test-InterruptedAndConcurrent` | Partial publish forces rebuild; skip-tlogs still publishes sentinel; four overlapping identical runs exit 0, invoke Tracker once, and a later call skips. |
| `Test-LargeTlog` | Hundreds of read/write paths via list files + sharded `.tlog`s; up-to-date skip; mid-list mtime dirty. |
| `Test-DeepLongPaths` | Deep nested directories + long filenames survive cache round-trip and skip. |
| `Test-SameMtimeRecreate` | Delete/recreate with identical FILETIME does **not** invalidate (documents mtime-only pitfall); real mtime bump does. |
| `Test-PathCase` | Tracker casing preserved; NTFS case-insensitive open still up-to-date. |
| `Test-ReadOnlyCache` | Read-only cache files are cleared and republished when an input changes; the next call skips. |
| `Test-LongCommandLine` | Multi-KB command lines hash/skip correctly; tiny mutation gets a new hash dir. |
| `Test-SharedCacheRoot` | Many distinct commands concurrent under one cache root → one complete hash dir each. |
| `Test-CwdAndEnv` | Identical command strings share a cache key across cwd/env (documents limitation). |
| `Test-StampRace` | Holding `cache.lock` blocks a dirty rebuild (Tracker does not run until release). Four overlapping cold starts and four dirty rebuilds each invoke Tracker once, then a later call skips. |

`-UseRealTracker` (optional): one smoke against the real VS `Tracker.exe` if vswhere finds it.

# Limitations

- **Cache key** is the trailing command string only (not cwd or environment). Identical relative commands from different directories share one hash dir.
- **Mtime only** — delete/recreate with the same `FILETIME` does not invalidate.
- **Per-hash-dir lock** — `cache.lock` is opened exclusively (`CreateFileW`, share mode 0) for the out-of-date check, clear, run, and publish. Identical concurrent commands single-flight. Distinct commands use different hash dirs and still run in parallel. A crashed process releases the lock when the OS closes the handle.
- Requires Visual Studio / Build Tools **Tracker.exe**.
