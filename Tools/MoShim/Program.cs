using System.Diagnostics;
using System.Text;

namespace BurrowWin.MoShim;

internal static class Program
{
    private static async Task<int> Main(string[] args)
    {
        var shimDirectory = AppContext.BaseDirectory;
        var scriptPath = Path.Combine(shimDirectory, "mole.ps1");
        if (!File.Exists(scriptPath))
        {
            Console.Error.WriteLine($"Mole script not found: {scriptPath}");
            return 127;
        }

        var powerShellHost = ResolvePowerShellHost();
        var startInfo = new ProcessStartInfo
        {
            FileName = powerShellHost,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };

        startInfo.ArgumentList.Add("-ExecutionPolicy");
        startInfo.ArgumentList.Add("Bypass");
        startInfo.ArgumentList.Add("-NoLogo");
        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-File");
        startInfo.ArgumentList.Add(scriptPath);
        foreach (var arg in args)
        {
            startInfo.ArgumentList.Add(arg);
        }

        using var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        try
        {
            if (!process.Start())
            {
                Console.Error.WriteLine("Mole process could not be started.");
                return 127;
            }
        }
        catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            Console.Error.WriteLine(ex.Message);
            return 127;
        }

        var outputTask = ForwardOutputAsync(process);
        await outputTask.ConfigureAwait(false);
        await process.WaitForExitAsync().ConfigureAwait(false);
        return process.ExitCode;
    }

    private static async Task ForwardOutputAsync(Process process)
    {
        var stdout = Task.Run(async () =>
        {
            while (!process.HasExited || !process.StandardOutput.EndOfStream)
            {
                var line = await process.StandardOutput.ReadLineAsync().ConfigureAwait(false);
                if (line is not null)
                {
                    Console.Out.WriteLine(line);
                }
            }
        });

        var stderr = Task.Run(async () =>
        {
            while (!process.HasExited || !process.StandardError.EndOfStream)
            {
                var line = await process.StandardError.ReadLineAsync().ConfigureAwait(false);
                if (line is not null)
                {
                    Console.Error.WriteLine(line);
                }
            }
        });

        await Task.WhenAll(stdout, stderr).ConfigureAwait(false);
    }

    private static string ResolvePowerShellHost()
    {
        return FindOnPath("pwsh.exe") ?? FindOnPath("powershell.exe") ?? "powershell.exe";
    }

    private static string? FindOnPath(string command)
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo
            {
                FileName = "where.exe",
                ArgumentList = { command },
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            });

            if (process is null)
            {
                return null;
            }

            var output = process.StandardOutput.ReadToEnd();
            process.WaitForExit(2000);
            return output
                .Split(Environment.NewLine, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .FirstOrDefault(File.Exists);
        }
        catch
        {
            return null;
        }
    }
}
