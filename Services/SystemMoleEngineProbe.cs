using System.Diagnostics;

namespace BurrowWin.Services;

public sealed class SystemMoleEngineProbe : IMoleEngineProbe
{
    public IEnumerable<string> GetCandidatePaths()
    {
        return BuildCandidatePaths(GetBaseDirectories());
    }

    internal static IReadOnlyList<string> BuildCandidatePaths(IEnumerable<string> baseDirectories)
    {
        return baseDirectories
            .Where(baseDirectory => !string.IsNullOrWhiteSpace(baseDirectory))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .SelectMany(BuildCandidatePathsForBaseDirectory)
            .ToArray();
    }

    private static IEnumerable<string> GetBaseDirectories()
    {
        var processPath = Environment.ProcessPath;
        if (!string.IsNullOrWhiteSpace(processPath))
        {
            var processDirectory = Path.GetDirectoryName(processPath);
            if (!string.IsNullOrWhiteSpace(processDirectory))
            {
                yield return processDirectory;
            }
        }

        yield return AppContext.BaseDirectory;
    }

    private static IEnumerable<string> BuildCandidatePathsForBaseDirectory(string baseDirectory)
    {
        return
        [
            Path.Combine(baseDirectory, "Assets", "mo.exe"),
            Path.Combine(baseDirectory, "Assets", "Mole", "mo.exe"),
            Path.Combine(baseDirectory, "Assets", "Mole", "mole.exe"),
            Path.Combine(baseDirectory, "Assets", "mo.cmd"),
            Path.Combine(baseDirectory, "Assets", "Mole", "mo.cmd"),
            Path.Combine(baseDirectory, "Assets", "mole.ps1"),
            Path.Combine(baseDirectory, "Assets", "Mole", "mole.ps1")
        ];
    }

    public string? FindOnPath(string command)
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

    public string ResolvePowerShellHost()
    {
        return FindOnPath("pwsh.exe") ?? FindOnPath("powershell.exe") ?? "powershell.exe";
    }
}
