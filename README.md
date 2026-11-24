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

On Windows, run the automated suite (builds helpers, exercises cache/CLI/tlog edge cases, cleans temp files):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\validation\Run-Validation.ps1
```

See `validation/README.md` for options (`-UseRealTracker`, `-KeepWorkRoot`, …).

# Limitations
