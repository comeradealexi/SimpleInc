# SimpleInc

SimpleInc runs a command through Visual Studio's `Tracker.exe` and skips later runs when the files that command read and wrote still have the same last-write time.

# How it works

`Tracker.exe` ships with Visual Studio and the Build Tools. It watches a child process and writes `.tlog` files listing the paths that process read and wrote.

SimpleInc keeps those paths, plus each path's last-write `FILETIME`, under a cache directory named for the command and the working directory. The next launch reads that stamp. If every recorded path is still there and still has the same timestamp, SimpleInc exits 0 and does not start the command. If anything is missing, unreadable, or newer, it runs the command again and publishes a new stamp.

# How to use

```text
SimpleInc.exe <TrackerDirectory> <CacheDirectory> <command...>
```

| Argument | Meaning |
| --- | --- |
| `TrackerDirectory` | Folder that contains `Tracker.exe`, for example `$(MSBuildBinPath)` from a Visual Studio install. SimpleInc appends `\Tracker.exe`. This is a directory, not the path of the exe. |
| `CacheDirectory` | Root where stamps are stored. SimpleInc creates one subdirectory per command and working directory. |
| `command...` | The command to run, written the same way you would type it in `cmd`. |

Both the Tracker directory and the cache root are rejected if they contain a double-quote (`"`). SimpleInc places those two paths in quotes on the Tracker command line and does not escape an embedded quote, so it stops with a message on stderr instead of launching a broken command. Exit code is `-1`. Quotes inside the wrapped command are fine; that is how paths with spaces are passed.

A missing argument prints usage and exits `-1`.

## Absolute-command convention

SimpleInc does not rebuild your command from parsed `argv`. Parsed `argv` drops quotes. It takes the exact tail of its own command line, everything after the cache directory, and both hashes and launches that text unchanged.

Write that tail the same way you would type the command, including quotes around paths that contain spaces. That literal text is the command half of the cache key.

Use absolute paths for the tool and for the files it reads and writes. A relative tool name is stored as that relative text. `PATH` is outside the key, so which copy of a tool runs can change while the stamp still matches. The working directory is inside the key, so the same relative command from two folders does not share a stamp. An absolute command is how you name one specific tool and specific files.

## Example: wrap a compile or codegen step

From a Visual Studio developer prompt, with `cl.exe` on `PATH` and sources under the current directory:

```bat
SimpleInc.exe "%MSBuildBinPath%" "%CD%\simpleinc-cache" cl.exe /nologo /c /Fo"%CD%\out\foo.obj" "%CD%\src\foo.cpp"
```

A codegen tool:

```bat
SimpleInc.exe "%MSBuildBinPath%" "%CD%\simpleinc-cache" "%CD%\tools\codegen.exe" --in "%CD%\schema.idl" --out "%CD%\generated\schema.h"
```

The first launch runs the tool under Tracker and writes the stamp. A second launch with the same command text, the same working directory, and unchanged inputs and outputs exits 0 and does not run the tool. Editing `schema.idl` or replacing `schema.h` changes a `FILETIME`, so the next launch runs the tool again.

In an MSBuild `Exec`:

```xml
<Exec Command="SimpleInc.exe &quot;$(MSBuildBinPath)&quot; &quot;$(IntermediateOutputPath)simpleinc&quot; &quot;$(CodegenTool)&quot; &quot;$(InputPath)&quot; &quot;$(OutputPath)&quot;" />
```

The child inherits SimpleInc's working directory and environment. Tracker is started as `"<TrackerDirectory>\Tracker.exe" /i "<hash directory>" /c <command tail>`.

## Cache layout

```text
<CacheDirectory>\<decimal-fnv>\
  readfiles.txt     UTF-8. Each record is a path line, then a decimal FILETIME line.
  writefiles.txt    Same layout, for paths Tracker recorded as writes.
  complete.flag     Contains the text ok and a newline. Written last. Absent means the stamp is incomplete.
  cache.lock        Left in the directory. The lock is an exclusive open, not the file's presence.
```

The directory name is the decimal FNV-1a 64-bit digest of the cache key (see below). Names changed when the hash moved off `std::hash` and started including the working directory. Old stamps are left behind; the next run is cold. Delete the cache root if you want the old directories gone.

`readfiles.txt` and `writefiles.txt` are UTF-8. Each path is followed by the Win32 last-write `FILETIME` as a decimal `uint64` (100-nanosecond intervals since 1601). `.tlog` files are deleted after a successful publish. Publish writes a temp file and replaces the destination, and `complete.flag` is written only after both lists are in place.

## When a command runs again

SimpleInc runs the command when:

- There is no completed stamp for this command text and normalized working directory.
- `complete.flag` is missing, or either list is missing, unreadable, truncated, or has a bad timestamp.
- Any recorded read or write path is missing, unreadable, or its last-write `FILETIME` differs.
- The previous run exited non-zero. The stamp is deleted (the lock file stays) so the next launch tries again.

It skips, exits 0, and does not start Tracker when `complete.flag` is present and every recorded path still has the same `FILETIME`.

## Working directory

The process working directory is part of the cache key. The same relative command from two folders gets two stamps, and both run.

Before hashing, the directory is normalized:

- `GetFullPathNameW` makes it absolute and collapses `.` and `..`.
- Forward slashes become backslashes.
- A `\\?\UNC\` prefix becomes `\\`, and a `\\?\` prefix is removed, so the extended form matches the ordinary Win32 path.
- A trailing slash is removed, except a drive root such as `C:\`.

The key is not case-folded. `D:\Work` and `d:\work` are different stamps. Short 8.3 names are not expanded. If the working directory cannot be read or cannot be made absolute, SimpleInc exits `-1` and does not publish a stamp.

## Unicode

SimpleInc is a Unicode process (`wmain`, `GetCommandLineW`, `CreateProcessW`, and wide file APIs). The cache key is FNV-1a over the UTF-8 bytes of that command text and the UTF-8 bytes of the normalized working directory, with a single `0x00` byte between them so the two fields cannot run together. Non-ASCII paths are stored as UTF-8 in the lists and opened with wide Win32 APIs. Absolute dependency paths longer than `MAX_PATH` are opened with the `\\?\` prefix. Relative dependency paths are left relative and open against the working directory.

## cache.lock

Each hash directory has `cache.lock`. SimpleInc opens it with `CreateFileW` and share mode 0, and holds that handle across the up-to-date check, the clear, the child, and the publish. A second launch of the same command in the same working directory waits, then checks again, so it skips when the first launch published a fresh stamp. Different commands, and the same command from different working directories, use different directories and can run at the same time. If the process crashes, the OS closes the handle and the wait ends. The file is left on disk; clearing a stamp does not delete it.

## Cache key

FNV-1a 64-bit, offset basis `14695981039346656037`, prime `1099511628211`. The input is the UTF-8 command bytes, one `0x00`, then the UTF-8 normalized working directory. The hash directory name is that value in decimal. The function is fixed, so the name does not depend on the MSVC `std::hash` implementation.

# Building

Binaries are not in the repo. Open `SimpleInc.sln` in Visual Studio 2022 (v143 toolset) and build x64 Debug or Release, or:

```text
msbuild SimpleInc.sln /p:Configuration=Release /p:Platform=x64
```

The project default output is `x64\Release\SimpleInc.exe` (or `x64\Debug\`). `Bin\` is gitignored.

# Validation

On Windows, the suite builds SimpleInc and the helper tools, runs every scenario under a temp work root, then deletes that work root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\validation\Run-Validation.ps1
```

Optional: `-UseRealTracker`, `-KeepWorkRoot`, `-Filter <name>`, `-AllowPrebuilt` (required with `-SkipBuild`). Without `-AllowPrebuilt`, a missing MSBuild fails the suite. `Bin\Release\SimpleInc.exe` is not in the repo; `-AllowPrebuilt` only uses a binary you placed there yourself. Details are in `validation/README.md`.

The runner prints a timed per-scenario table and a final pass/fail/skip rollup.

### Suite TLDR (what each scenario covers)

| Script | What it checks |
| --- | --- |
| `Test-ArgcUsage` | Too few args → usage text with newlines + non-zero exit (no crash). |
| `Test-FreshAndUpToDate` | Cold/missing cache runs once; identical second call skips. A relative tlog path still skips (not broken by `\\?\`). |
| `Test-DirtyInvalidation` | Rebuilds on read mtime change, write mtime/clobber, missing write, missing/corrupt/truncated cache lists. |
| `Test-SentinelAndPartial` | Empty hash dir, missing `complete.flag`, sentinel-only, or leftover `.tmp` → never treated as up-to-date. |
| `Test-Quotes` | Paths with spaces / nested quotes and multi-space argv survive into the child. A `"` in the Tracker directory or cache root fails with an explanation and does not publish. |
| `Test-UnicodePaths` | Non-ASCII paths round-trip in UTF-8 cache via Unicode APIs; up-to-date + write-clobber still work (skips only if the FS can't create the paths). |
| `Test-TlogParsing` | `.tlog` CRLF vs LF vs no final newline; path dedupe; empty tlogs; read vs write from **filename**, even if cache root contains `.write.`. |
| `Test-FailedChild` | Non-zero child exit clears stamp; same command must re-run (no false up-to-date). |
| `Test-MissingTracker` | Missing `Tracker.exe` → non-zero exit and no `complete.flag`. |
| `Test-CacheIdentity` | Different commands get different hash dirs; same command reuses its dir and skips. |
| `Test-InterruptedAndConcurrent` | Partial publish forces rebuild; skip-tlogs still publishes sentinel; four overlapping identical runs exit 0, invoke Tracker once, and a later call skips. |
| `Test-LargeTlog` | Hundreds of read/write paths via list files + sharded `.tlog`s; up-to-date skip; mid-list mtime dirty. |
| `Test-DeepLongPaths` | Deep nested directories + long filenames survive cache round-trip and skip. |
| `Test-SameMtimeRecreate` | Delete/recreate with identical FILETIME does **not** invalidate (mtime-only); a real mtime bump does. |
| `Test-PathCase` | Tracker casing preserved; NTFS case-insensitive open still up-to-date. |
| `Test-ReadOnlyCache` | Read-only cache files are cleared and republished when an input changes; the next call skips. |
| `Test-LongCommandLine` | Multi-KB command lines hash/skip correctly; tiny mutation gets a new hash dir. |
| `Test-SharedCacheRoot` | Many distinct commands concurrent under one cache root → one complete hash dir each. |
| `Test-CwdAndEnv` | The same relative command from two working directories uses two cache dirs and both run. An environment-variable change does not bust the key. |
| `Test-StampRace` | Holding `cache.lock` blocks a dirty rebuild (Tracker does not run until release). Four overlapping cold starts and four dirty rebuilds each invoke Tracker once, then a later call skips. |

`-UseRealTracker` (optional): one smoke against the real VS `Tracker.exe` if vswhere finds it.

# Limitations

- **Environment is outside the cache key.** `PATH`, `INCLUDE`, `CL`, and any other variable can change which work a command does while the stamp still matches. Put flags that must invalidate the run on the command line.
- **A zero-path stamp is treated as up to date.** If Tracker exits 0 and records no reads and no writes, SimpleInc still publishes `complete.flag` with empty lists, and the next launch skips. That is right for a command that truly touches nothing. It is wrong when Tracker failed to record real file access.
- **Windows only.** The program uses the Win32 process and file APIs and a Visual Studio / Build Tools `Tracker.exe` next to the directory you pass. There is no Linux or macOS build.
- **Mtime only.** Deleting a file and recreating it with the same `FILETIME` does not invalidate the stamp.
- **The working-directory key is not case-folded**, and 8.3 short names are not expanded to their long form.
- **This is not a build graph.** SimpleInc does not order steps, sandbox the child, or track anything Tracker does not report.
