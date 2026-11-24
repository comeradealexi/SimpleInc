// Creates or updates a file and optionally sets LastWriteTimeUtc from a FILETIME uint64.
// Usage:
//   TouchFile.exe <path>                  → create/update with now
//   TouchFile.exe <path> <filetimeUInt64> → create/update then set mtime
using System;
using System.IO;

internal static class TouchFile
{
    private static int Main(string[] args)
    {
        if (args.Length < 1)
        {
            Console.Error.WriteLine("TouchFile: <path> [filetimeUInt64]");
            return 2;
        }

        string path = args[0];
        string dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir))
        {
            Directory.CreateDirectory(dir);
        }

        File.WriteAllText(path, "touch-" + Guid.NewGuid().ToString("N"));

        if (args.Length >= 2)
        {
            long ft = long.Parse(args[1]);
            DateTime dt = DateTime.FromFileTimeUtc(ft);
            File.SetLastWriteTimeUtc(path, dt);
        }
        return 0;
    }
}
