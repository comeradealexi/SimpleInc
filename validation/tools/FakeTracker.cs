// Minimal Tracker.exe stand-in for SimpleInc validation.
// Usage mirrors MSBuild Tracker: FakeTracker.exe /i <cacheDir> /c <command...>
//
// Environment knobs (all optional):
//   SIMPLEINC_FAKE_READS       ;-separated absolute paths → *.read.*.tlog
//   SIMPLEINC_FAKE_WRITES      ;-separated absolute paths → *.write.*.tlog
//   SIMPLEINC_FAKE_READS_FILE  text file, one absolute path per line (for large lists)
//   SIMPLEINC_FAKE_WRITES_FILE same for writes
//   SIMPLEINC_FAKE_NEWLINE     crlf | lf | none  (default crlf)
//   SIMPLEINC_FAKE_DUP_PATHS   1 → emit each path twice in the tlog
//   SIMPLEINC_FAKE_EMPTY_TLOG  1 → header-only tlogs (no paths)
//   SIMPLEINC_FAKE_SKIP_TLOGS  1 → do not write tlogs after the child
//   SIMPLEINC_FAKE_BOM         0 → omit UTF-16 BOM
//   SIMPLEINC_FAKE_PREFIX      tlog filename prefix (default "tool")
//   SIMPLEINC_FAKE_TLOG_SHARDS N → split paths across N read and N write tlog files
//   SIMPLEINC_FAKE_FORCE_EXIT  if set, exit with this code and skip child/tlogs
//   SIMPLEINC_FAKE_RUNLOG      path to append one line per FakeTracker invocation
//   SIMPLEINC_FAKE_CACHE_ROOT_MARKER  if set, write this relative name under /i before child
//   SIMPLEINC_FAKE_CHILD_DELAY_MS     sleep this many ms before running the child

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

internal static class FakeTracker
{
    private static int Main(string[] args)
    {
        string runLog = Environment.GetEnvironmentVariable("SIMPLEINC_FAKE_RUNLOG");
        if (!string.IsNullOrEmpty(runLog))
        {
            File.AppendAllText(runLog, DateTime.UtcNow.ToString("o") + "\n", Encoding.UTF8);
        }

        string forceExit = Environment.GetEnvironmentVariable("SIMPLEINC_FAKE_FORCE_EXIT");
        if (!string.IsNullOrEmpty(forceExit))
        {
            return int.Parse(forceExit);
        }

        string cacheDir;
        string command;
        if (!TryParseArgs(args, out cacheDir, out command))
        {
            Console.Error.WriteLine("FakeTracker: expected /i <dir> /c <command...>");
            return 2;
        }

        Directory.CreateDirectory(cacheDir);

        string marker = Environment.GetEnvironmentVariable("SIMPLEINC_FAKE_CACHE_ROOT_MARKER");
        if (!string.IsNullOrEmpty(marker))
        {
            File.WriteAllText(Path.Combine(cacheDir, marker), "1", Encoding.UTF8);
        }

        string delayRaw = Environment.GetEnvironmentVariable("SIMPLEINC_FAKE_CHILD_DELAY_MS");
        if (!string.IsNullOrEmpty(delayRaw))
        {
            int ms;
            if (int.TryParse(delayRaw, out ms) && ms > 0)
            {
                Thread.Sleep(ms);
            }
        }

        int childExit = RunCommand(command);
        if (childExit != 0)
        {
            return childExit;
        }

        if (IsTruthy(Environment.GetEnvironmentVariable("SIMPLEINC_FAKE_SKIP_TLOGS")))
        {
            return 0;
        }

        string prefix = Environment.GetEnvironmentVariable("SIMPLEINC_FAKE_PREFIX");
        if (string.IsNullOrEmpty(prefix))
        {
            prefix = "tool";
        }

        List<string> reads = CollectPaths(
            Environment.GetEnvironmentVariable("SIMPLEINC_FAKE_READS"),
            Environment.GetEnvironmentVariable("SIMPLEINC_FAKE_READS_FILE"));
        List<string> writes = CollectPaths(
            Environment.GetEnvironmentVariable("SIMPLEINC_FAKE_WRITES"),
            Environment.GetEnvironmentVariable("SIMPLEINC_FAKE_WRITES_FILE"));

        int shards = 1;
        string shardRaw = Environment.GetEnvironmentVariable("SIMPLEINC_FAKE_TLOG_SHARDS");
        if (!string.IsNullOrEmpty(shardRaw))
        {
            int.TryParse(shardRaw, out shards);
            if (shards < 1) shards = 1;
        }

        WriteShardedTlogs(cacheDir, prefix, "read", reads, shards);
        WriteShardedTlogs(cacheDir, prefix, "write", writes, shards);

        return 0;
    }

    private static void WriteShardedTlogs(string cacheDir, string prefix, string kind, List<string> paths, int shards)
    {
        if (shards <= 1)
        {
            WriteTlog(Path.Combine(cacheDir, prefix + "." + kind + ".1.tlog"), paths);
            return;
        }

        var buckets = new List<string>[shards];
        for (int i = 0; i < shards; i++)
        {
            buckets[i] = new List<string>();
        }
        for (int i = 0; i < paths.Count; i++)
        {
            buckets[i % shards].Add(paths[i]);
        }
        for (int i = 0; i < shards; i++)
        {
            WriteTlog(Path.Combine(cacheDir, prefix + "." + kind + "." + (i + 1) + ".tlog"), buckets[i]);
        }
    }

    private static List<string> CollectPaths(string semicolonList, string listFile)
    {
        var list = ParseList(semicolonList);
        if (!string.IsNullOrEmpty(listFile) && File.Exists(listFile))
        {
            foreach (string line in File.ReadAllLines(listFile, Encoding.UTF8))
            {
                string trimmed = line.Trim();
                if (trimmed.Length == 0 || trimmed.StartsWith("#"))
                {
                    continue;
                }
                list.Add(trimmed);
            }
        }
        return list;
    }

    private static bool TryParseArgs(string[] args, out string cacheDir, out string command)
    {
        cacheDir = null;
        command = null;
        for (int i = 0; i < args.Length; i++)
        {
            if (string.Equals(args[i], "/i", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
            {
                cacheDir = args[++i];
            }
            else if (string.Equals(args[i], "/c", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
            {
                var sb = new StringBuilder();
                for (int j = i + 1; j < args.Length; j++)
                {
                    if (sb.Length > 0) sb.Append(' ');
                    sb.Append(QuoteIfNeeded(args[j]));
                }
                command = sb.ToString();
                break;
            }
        }
        return !string.IsNullOrEmpty(cacheDir) && !string.IsNullOrEmpty(command);
    }

    private static string QuoteIfNeeded(string value)
    {
        if (value.IndexOfAny(new[] { ' ', '\t', '"' }) < 0)
        {
            return value;
        }
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcessW(
        string lpApplicationName,
        StringBuilder lpCommandLine,
        IntPtr lpProcessAttributes,
        IntPtr lpThreadAttributes,
        bool bInheritHandles,
        uint dwCreationFlags,
        IntPtr lpEnvironment,
        string lpCurrentDirectory,
        ref STARTUPINFO lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }

    // Run the child via CreateProcessW — not cmd.exe — so long command lines
    // (CreateProcess allows ~32K) are not truncated by cmd's 8191-char limit.
    private static int RunCommand(string command)
    {
        var si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        PROCESS_INFORMATION pi;
        // CreateProcessW requires a mutable buffer for lpCommandLine.
        var buffer = new StringBuilder(command);
        if (!CreateProcessW(
            null,
            buffer,
            IntPtr.Zero,
            IntPtr.Zero,
            false,
            0,
            IntPtr.Zero,
            null,
            ref si,
            out pi))
        {
            int err = Marshal.GetLastWin32Error();
            Console.Error.WriteLine("FakeTracker: CreateProcessW failed ({0}).", err);
            return err == 0 ? 1 : err;
        }
        try
        {
            WaitForSingleObject(pi.hProcess, 0xFFFFFFFF);
            uint exitCode;
            if (!GetExitCodeProcess(pi.hProcess, out exitCode))
            {
                return 1;
            }
            return unchecked((int)exitCode);
        }
        finally
        {
            if (pi.hThread != IntPtr.Zero) CloseHandle(pi.hThread);
            if (pi.hProcess != IntPtr.Zero) CloseHandle(pi.hProcess);
        }
    }

    private static List<string> ParseList(string raw)
    {
        var list = new List<string>();
        if (string.IsNullOrEmpty(raw))
        {
            return list;
        }
        foreach (string part in raw.Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries))
        {
            list.Add(part.Trim());
        }
        return list;
    }

    private static void WriteTlog(string path, List<string> paths)
    {
        string newlineMode = (Environment.GetEnvironmentVariable("SIMPLEINC_FAKE_NEWLINE") ?? "crlf").ToLowerInvariant();
        bool dup = IsTruthy(Environment.GetEnvironmentVariable("SIMPLEINC_FAKE_DUP_PATHS"));
        bool empty = IsTruthy(Environment.GetEnvironmentVariable("SIMPLEINC_FAKE_EMPTY_TLOG"));
        bool bom = !string.Equals(Environment.GetEnvironmentVariable("SIMPLEINC_FAKE_BOM"), "0", StringComparison.Ordinal);

        var lines = new List<string>();
        lines.Add("#FakeTracker tlog");
        if (!empty)
        {
            foreach (string p in paths)
            {
                lines.Add(p);
                if (dup)
                {
                    lines.Add(p);
                }
            }
        }

        string joined;
        switch (newlineMode)
        {
            case "lf":
                joined = string.Join("\n", lines) + "\n";
                break;
            case "none":
                joined = string.Join("\r\n", lines);
                break;
            default:
                joined = string.Join("\r\n", lines) + "\r\n";
                break;
        }

        using (var fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None))
        {
            if (bom)
            {
                fs.WriteByte(0xFF);
                fs.WriteByte(0xFE);
            }
            byte[] payload = Encoding.Unicode.GetBytes(joined);
            fs.Write(payload, 0, payload.Length);
        }
    }

    private static bool IsTruthy(string value)
    {
        if (string.IsNullOrEmpty(value)) return false;
        return value == "1"
            || value.Equals("true", StringComparison.OrdinalIgnoreCase)
            || value.Equals("yes", StringComparison.OrdinalIgnoreCase);
    }
}
