// Minimal Tracker.exe stand-in for SimpleInc validation.
// Usage mirrors MSBuild Tracker: FakeTracker.exe /i <cacheDir> /c <command...>
//
// Environment knobs (all optional):
//   SIMPLEINC_FAKE_READS       ;-separated absolute paths → *.read.*.tlog
//   SIMPLEINC_FAKE_WRITES      ;-separated absolute paths → *.write.*.tlog
//   SIMPLEINC_FAKE_NEWLINE     crlf | lf | none  (default crlf)
//   SIMPLEINC_FAKE_DUP_PATHS   1 → emit each path twice in the tlog
//   SIMPLEINC_FAKE_EMPTY_TLOG  1 → header-only tlogs (no paths)
//   SIMPLEINC_FAKE_SKIP_TLOGS  1 → do not write tlogs after the child
//   SIMPLEINC_FAKE_BOM         0 → omit UTF-16 BOM
//   SIMPLEINC_FAKE_PREFIX      tlog filename prefix (default "tool")
//   SIMPLEINC_FAKE_FORCE_EXIT  if set, exit with this code and skip child/tlogs
//   SIMPLEINC_FAKE_RUNLOG      path to append one line per FakeTracker invocation
//   SIMPLEINC_FAKE_CACHE_ROOT_MARKER  if set, write this relative name under /i before child

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;

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

        WriteTlog(Path.Combine(cacheDir, prefix + ".read.1.tlog"),
            ParseList(Environment.GetEnvironmentVariable("SIMPLEINC_FAKE_READS")));
        WriteTlog(Path.Combine(cacheDir, prefix + ".write.1.tlog"),
            ParseList(Environment.GetEnvironmentVariable("SIMPLEINC_FAKE_WRITES")));

        return 0;
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
                // Remainder of argv after /c is the child command line pieces; re-join with spaces.
                // SimpleInc already preserves quoting in the CreateProcess command string; when the
                // OS splits argv for FakeTracker, quotes may be stripped — EchoArgs tests cover the
                // SimpleInc → child path using GetCommandLine, while FakeTracker re-joins for /c.
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

    private static int RunCommand(string command)
    {
        var psi = new ProcessStartInfo
        {
            FileName = "cmd.exe",
            Arguments = "/C " + command,
            UseShellExecute = false,
        };
        using (var p = Process.Start(psi))
        {
            p.WaitForExit();
            return p.ExitCode;
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
                // Final path line has no trailing newline (still separate earlier lines with CRLF).
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
