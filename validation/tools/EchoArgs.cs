// Writes argv and GetCommandLineW to files so quote-preservation tests can assert.
// Usage: EchoArgs.exe <outDir> [args...]
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

internal static class EchoArgs
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetCommandLineW();

    private static int Main(string[] args)
    {
        if (args.Length < 1)
        {
            Console.Error.WriteLine("EchoArgs: need output directory as argv[0]");
            return 2;
        }

        string outDir = args[0];
        Directory.CreateDirectory(outDir);

        var argvBuilder = new StringBuilder();
        for (int i = 0; i < args.Length; i++)
        {
            argvBuilder.Append(i).Append('=').Append(args[i]).Append('\n');
        }
        File.WriteAllText(Path.Combine(outDir, "argv.txt"), argvBuilder.ToString(), new UTF8Encoding(false));

        string commandLine = Marshal.PtrToStringUni(GetCommandLineW()) ?? "";
        File.WriteAllText(Path.Combine(outDir, "cmdline.txt"), commandLine, new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(outDir, "ran.txt"), "1", new UTF8Encoding(false));
        return 0;
    }
}
