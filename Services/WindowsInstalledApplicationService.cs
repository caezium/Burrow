using System.Diagnostics;
using Microsoft.Win32;
using BurrowWin.Models;

namespace BurrowWin.Services;

public sealed class WindowsInstalledApplicationService : IInstalledApplicationService
{
    private readonly IOperationHistoryService? _operationHistoryService;

    public WindowsInstalledApplicationService(IOperationHistoryService? operationHistoryService = null)
    {
        _operationHistoryService = operationHistoryService;
    }

    private static readonly string[] ProtectedNamePrefixes =
    [
        "Microsoft Windows",
        "Windows Feature Experience Pack",
        "Windows Security",
        "Microsoft Edge",
        "Microsoft Edge WebView2",
        "Microsoft Visual C++",
        "Microsoft .NET",
        ".NET Desktop Runtime"
    ];

    public Task<IReadOnlyList<InstalledApplication>> GetInstalledApplicationsAsync(CancellationToken cancellationToken = default)
    {
        return Task.Run<IReadOnlyList<InstalledApplication>>(() =>
        {
            var apps = new List<InstalledApplication>();
            ReadRegistryHive(Registry.LocalMachine, @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall", "Registry", apps, cancellationToken);
            ReadRegistryHive(Registry.LocalMachine, @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall", "Registry32", apps, cancellationToken);
            ReadRegistryHive(Registry.CurrentUser, @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall", "UserRegistry", apps, cancellationToken);

            return apps
                .GroupBy(app => app.Id, StringComparer.OrdinalIgnoreCase)
                .Select(group => group.OrderByDescending(app => app.SizeBytes).First())
                .OrderByDescending(app => app.SizeBytes)
                .ThenBy(app => app.Name, StringComparer.OrdinalIgnoreCase)
                .ToArray();
        }, cancellationToken);
    }

    public Task<IReadOnlyList<LeftoverCandidate>> PreviewLeftoversAsync(
        InstalledApplication application,
        CancellationToken cancellationToken = default)
    {
        return Task.Run<IReadOnlyList<LeftoverCandidate>>(() =>
        {
            var candidates = BuildLeftoverPaths(application)
                .Where(candidate => Directory.Exists(candidate.Path))
                .Select(candidate => new LeftoverCandidate(
                    candidate.Category,
                    candidate.Path,
                    MeasureDirectory(candidate.Path, cancellationToken)))
                .Where(candidate => candidate.SizeBytes > 0)
                .OrderByDescending(candidate => candidate.SizeBytes)
                .ToArray();

            return candidates;
        }, cancellationToken);
    }

    public async Task<MoleCommandResult> LaunchUninstallerAsync(
        InstalledApplication application,
        CancellationToken cancellationToken = default)
    {
        var startedAt = Stopwatch.GetTimestamp();
        MoleCommandResult result;

        try
        {
            cancellationToken.ThrowIfCancellationRequested();

            if (string.IsNullOrWhiteSpace(application.UninstallString))
            {
                result = new MoleCommandResult(1, string.Empty, "No uninstall command is registered for this application.", false, TimeSpan.Zero);
            }
            else if (!TryBuildUninstallStartInfo(application.UninstallString, out var startInfo, out var error))
            {
                result = new MoleCommandResult(1, string.Empty, error, false, Stopwatch.GetElapsedTime(startedAt));
            }
            else
            {
                using var process = Process.Start(startInfo);
                result = process is null
                    ? new MoleCommandResult(1, string.Empty, "The uninstaller process could not be started.", false, Stopwatch.GetElapsedTime(startedAt))
                    : new MoleCommandResult(0, $"Started uninstaller process {process.Id}.", string.Empty, false, Stopwatch.GetElapsedTime(startedAt));
            }
        }
        catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception or OperationCanceledException)
        {
            result = new MoleCommandResult(1, string.Empty, ex.Message, ex is OperationCanceledException, Stopwatch.GetElapsedTime(startedAt));
        }

        await RecordHistoryAsync(
            "uninstall",
            application.Name,
            result,
            cancellationToken: CancellationToken.None).ConfigureAwait(false);
        return result;
    }

    public async Task<IReadOnlyList<LeftoverRemovalResult>> RemoveLeftoversAsync(
        IEnumerable<LeftoverCandidate> leftovers,
        CancellationToken cancellationToken = default)
    {
        var results = await Task.Run<IReadOnlyList<LeftoverRemovalResult>>(() =>
        {
            var results = new List<LeftoverRemovalResult>();
            foreach (var leftover in leftovers)
            {
                cancellationToken.ThrowIfCancellationRequested();
                results.Add(RemoveLeftover(leftover));
            }

            return results;
        }, cancellationToken).ConfigureAwait(false);

        var failedCount = results.Count(result => !result.Succeeded);
        var removedCount = results.Count(result => result.Succeeded);
        var output = $"Removed {removedCount} leftover targets. Failed {failedCount}.";
        await RecordHistoryAsync(
            "remove_leftovers",
            string.Join(Environment.NewLine, results.Select(result => result.Path)),
            new MoleCommandResult(failedCount == 0 ? 0 : 1, output, failedCount == 0 ? string.Empty : output, false, TimeSpan.Zero),
            CancellationToken.None).ConfigureAwait(false);

        return results;
    }

    public static InstalledApplication? CreateApplicationFromRegistryValues(
        string keyName,
        IReadOnlyDictionary<string, object?> values,
        string source)
    {
        var name = ReadString(values, "DisplayName");
        if (string.IsNullOrWhiteSpace(name) || IsProtectedApplication(name))
        {
            return null;
        }

        if (ReadInt(values, "SystemComponent") == 1)
        {
            return null;
        }

        var uninstallString = ReadString(values, "UninstallString");
        var installLocation = ReadString(values, "InstallLocation");
        var publisher = ReadString(values, "Publisher");
        var version = ReadString(values, "DisplayVersion");
        var estimatedSizeKb = ReadLong(values, "EstimatedSize");
        var sizeBytes = estimatedSizeKb > 0 ? estimatedSizeKb * 1024 : TryMeasureDirectory(installLocation);
        var id = string.Join("|", [name, publisher, version, installLocation, keyName]).ToLowerInvariant();

        return new InstalledApplication(
            id,
            name.Trim(),
            publisher,
            version,
            installLocation,
            uninstallString,
            source,
            sizeBytes);
    }

    public static IReadOnlyList<(string Category, string Path)> BuildLeftoverPaths(InstalledApplication application)
    {
        var names = CandidateNames(application).ToArray();
        var paths = new List<(string Category, string Path)>();

        AddKnownPath(paths, "Install location", application.InstallLocation);

        foreach (var name in names)
        {
            AddKnownPath(paths, "Local app data", Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), name));
            AddKnownPath(paths, "Roaming app data", Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), name));
            AddKnownPath(paths, "Program data", Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), name));
        }

        if (!string.IsNullOrWhiteSpace(application.Publisher))
        {
            foreach (var name in names)
            {
                var publisher = SafePathSegment(application.Publisher);
                AddKnownPath(paths, "Publisher local data", Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), publisher, name));
                AddKnownPath(paths, "Publisher roaming data", Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), publisher, name));
            }
        }

        return paths
            .Where(candidate => !string.IsNullOrWhiteSpace(candidate.Path))
            .DistinctBy(candidate => candidate.Path, StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    private static void ReadRegistryHive(
        RegistryKey hive,
        string subKeyPath,
        string source,
        ICollection<InstalledApplication> apps,
        CancellationToken cancellationToken)
    {
        using var uninstallKey = hive.OpenSubKey(subKeyPath);
        if (uninstallKey is null)
        {
            return;
        }

        foreach (var subKeyName in uninstallKey.GetSubKeyNames())
        {
            cancellationToken.ThrowIfCancellationRequested();
            using var appKey = uninstallKey.OpenSubKey(subKeyName);
            if (appKey is null)
            {
                continue;
            }

            var values = appKey.GetValueNames().ToDictionary(name => name, appKey.GetValue, StringComparer.OrdinalIgnoreCase);
            var app = CreateApplicationFromRegistryValues(subKeyName, values, source);
            if (app is not null)
            {
                apps.Add(app);
            }
        }
    }

    private static IEnumerable<string> CandidateNames(InstalledApplication application)
    {
        yield return SafePathSegment(application.Name);

        if (!string.IsNullOrWhiteSpace(application.Publisher))
        {
            yield return SafePathSegment($"{application.Publisher} {application.Name}");
        }
    }

    private static void AddKnownPath(List<(string Category, string Path)> paths, string category, string? path)
    {
        if (!string.IsNullOrWhiteSpace(path))
        {
            paths.Add((category, Environment.ExpandEnvironmentVariables(path.Trim())));
        }
    }

    private static string SafePathSegment(string value)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var cleaned = new string(value.Select(ch => invalid.Contains(ch) ? ' ' : ch).ToArray());
        return string.Join(" ", cleaned.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
    }

    private static bool IsProtectedApplication(string name)
    {
        return ProtectedNamePrefixes.Any(prefix => name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase));
    }

    private static string? ReadString(IReadOnlyDictionary<string, object?> values, string key)
    {
        return values.TryGetValue(key, out var value) ? value?.ToString() : null;
    }

    private static int ReadInt(IReadOnlyDictionary<string, object?> values, string key)
    {
        return int.TryParse(ReadString(values, key), out var value) ? value : 0;
    }

    private static long ReadLong(IReadOnlyDictionary<string, object?> values, string key)
    {
        return long.TryParse(ReadString(values, key), out var value) ? value : 0;
    }

    private static long TryMeasureDirectory(string? path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Directory.Exists(path))
        {
            return 0;
        }

        try
        {
            return MeasureDirectory(path, CancellationToken.None);
        }
        catch
        {
            return 0;
        }
    }

    private static long MeasureDirectory(string path, CancellationToken cancellationToken)
    {
        long total = 0;

        try
        {
            foreach (var file in Directory.EnumerateFiles(path))
            {
                cancellationToken.ThrowIfCancellationRequested();
                try
                {
                    total += new FileInfo(file).Length;
                }
                catch
                {
                    // Files may disappear or deny access during scanning.
                }
            }

            foreach (var directory in Directory.EnumerateDirectories(path))
            {
                cancellationToken.ThrowIfCancellationRequested();
                total += MeasureDirectory(directory, cancellationToken);
            }
        }
        catch
        {
            // Directories may deny access during scanning.
        }

        return total;
    }

    private static LeftoverRemovalResult RemoveLeftover(LeftoverCandidate leftover)
    {
        try
        {
            var fullPath = Path.GetFullPath(Environment.ExpandEnvironmentVariables(leftover.Path));
            if (!IsSafeDeletionTarget(fullPath))
            {
                return new LeftoverRemovalResult(leftover.Path, false, "Blocked unsafe deletion target.", leftover.SizeBytes);
            }

            if (Directory.Exists(fullPath))
            {
                Directory.Delete(fullPath, recursive: true);
                return new LeftoverRemovalResult(leftover.Path, true, "Directory removed.", leftover.SizeBytes);
            }

            if (File.Exists(fullPath))
            {
                File.Delete(fullPath);
                return new LeftoverRemovalResult(leftover.Path, true, "File removed.", leftover.SizeBytes);
            }

            return new LeftoverRemovalResult(leftover.Path, true, "Path was already absent.", leftover.SizeBytes);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            return new LeftoverRemovalResult(leftover.Path, false, ex.Message, leftover.SizeBytes);
        }
    }

    private static bool TryBuildUninstallStartInfo(
        string uninstallString,
        out ProcessStartInfo startInfo,
        out string error)
    {
        startInfo = new ProcessStartInfo();
        error = string.Empty;

        if (!TrySplitCommandLine(uninstallString, out var fileName, out var arguments))
        {
            error = "The uninstall command could not be parsed.";
            return false;
        }

        if (IsBlockedProcessHost(fileName))
        {
            error = "Shell-hosted uninstall commands are blocked for safety.";
            return false;
        }

        startInfo = new ProcessStartInfo
        {
            FileName = fileName,
            Arguments = arguments,
            UseShellExecute = false,
            CreateNoWindow = false,
            WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)
        };
        return true;
    }

    public static bool TrySplitCommandLine(string commandLine, out string fileName, out string arguments)
    {
        fileName = string.Empty;
        arguments = string.Empty;
        commandLine = commandLine.Trim();

        if (commandLine.Length == 0)
        {
            return false;
        }

        if (commandLine[0] == '"')
        {
            var closingQuote = commandLine.IndexOf('"', 1);
            if (closingQuote <= 1)
            {
                return false;
            }

            fileName = commandLine[1..closingQuote];
            arguments = commandLine[(closingQuote + 1)..].Trim();
            return !string.IsNullOrWhiteSpace(fileName);
        }

        var separator = commandLine.IndexOf(' ');
        if (separator < 0)
        {
            fileName = commandLine;
            return true;
        }

        fileName = commandLine[..separator];
        arguments = commandLine[(separator + 1)..].Trim();
        return !string.IsNullOrWhiteSpace(fileName);
    }

    public static bool IsSafeDeletionTarget(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return false;
        }

        var fullPath = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var root = Path.GetPathRoot(fullPath)?.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (string.Equals(fullPath, root, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var blockedRoots = new[]
        {
            Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
            Environment.GetFolderPath(Environment.SpecialFolder.CommonProgramFiles),
            Environment.GetFolderPath(Environment.SpecialFolder.CommonProgramFilesX86),
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData)
        };

        return blockedRoots
            .Where(blocked => !string.IsNullOrWhiteSpace(blocked))
            .Select(blocked => Path.GetFullPath(blocked).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar))
            .All(blocked => !string.Equals(fullPath, blocked, StringComparison.OrdinalIgnoreCase));
    }

    private static bool IsBlockedProcessHost(string fileName)
    {
        var executable = Path.GetFileNameWithoutExtension(fileName);
        return executable.Equals("cmd", StringComparison.OrdinalIgnoreCase) ||
               executable.Equals("powershell", StringComparison.OrdinalIgnoreCase) ||
               executable.Equals("pwsh", StringComparison.OrdinalIgnoreCase) ||
               executable.Equals("wscript", StringComparison.OrdinalIgnoreCase) ||
               executable.Equals("cscript", StringComparison.OrdinalIgnoreCase);
    }

    private async Task RecordHistoryAsync(
        string operation,
        string arguments,
        MoleCommandResult result,
        CancellationToken cancellationToken)
    {
        if (_operationHistoryService is null)
        {
            return;
        }

        var entry = new OperationHistoryEntry(
            DateTimeOffset.UtcNow,
            "windows_uninstaller",
            operation,
            arguments,
            result.ExitCode,
            result.Succeeded,
            (long)result.Duration.TotalMilliseconds,
            string.IsNullOrWhiteSpace(result.StandardError) ? result.StandardOutput : result.StandardError);

        try
        {
            await _operationHistoryService.RecordAsync(entry, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
    }
}
