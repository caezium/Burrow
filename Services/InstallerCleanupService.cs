using BurrowWin.Models;

namespace BurrowWin.Services;

public sealed class InstallerCleanupService : IInstallerCleanupService
{
    private const int DefaultDaysOld = 30;

    private static readonly string[] InstallerPatterns =
    [
        "*.exe",
        "*.msi",
        "*.zip",
        "*.7z",
        "*.rar",
        "*.tar.gz",
        "*.iso"
    ];

    private readonly string _downloadsPath;
    private readonly int _daysOld;

    public InstallerCleanupService()
        : this(ResolveDefaultDownloadsPath(), DefaultDaysOld)
    {
    }

    public InstallerCleanupService(string downloadsPath, int daysOld = DefaultDaysOld)
    {
        _downloadsPath = Path.GetFullPath(downloadsPath);
        _daysOld = Math.Max(1, daysOld);
    }

    private static string ResolveDefaultDownloadsPath()
    {
        var diagnosticRoot = Environment.GetEnvironmentVariable("BURROWWIN_INSTALLER_ROOT");
        if (!string.IsNullOrWhiteSpace(diagnosticRoot))
        {
            return diagnosticRoot;
        }

        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
    }

    public Task<IReadOnlyList<InstallerCleanupCandidate>> PreviewAsync(CancellationToken cancellationToken = default)
    {
        return Task.Run(() =>
        {
            if (!Directory.Exists(_downloadsPath))
            {
                return (IReadOnlyList<InstallerCleanupCandidate>)Array.Empty<InstallerCleanupCandidate>();
            }

            var cutoffUtc = DateTimeOffset.UtcNow.AddDays(-_daysOld);
            var candidates = new Dictionary<string, InstallerCleanupCandidate>(StringComparer.OrdinalIgnoreCase);

            foreach (var pattern in InstallerPatterns)
            {
                cancellationToken.ThrowIfCancellationRequested();
                IEnumerable<string> files;
                try
                {
                    files = Directory.EnumerateFiles(_downloadsPath, pattern, SearchOption.TopDirectoryOnly);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    continue;
                }

                foreach (var file in files)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    var candidate = BuildCandidate(file, cutoffUtc);
                    if (candidate is not null)
                    {
                        candidates[candidate.Path] = candidate;
                    }
                }
            }

            return (IReadOnlyList<InstallerCleanupCandidate>)candidates.Values
                .OrderByDescending(candidate => candidate.SizeBytes)
                .ThenBy(candidate => candidate.Name, StringComparer.OrdinalIgnoreCase)
                .ToList();
        }, cancellationToken);
    }

    public Task<IReadOnlyList<LeftoverRemovalResult>> RemoveAsync(
        IReadOnlyList<InstallerCleanupCandidate> candidates,
        CancellationToken cancellationToken = default)
    {
        return Task.Run(() =>
        {
            var results = new List<LeftoverRemovalResult>();
            foreach (var candidate in candidates)
            {
                cancellationToken.ThrowIfCancellationRequested();
                results.Add(RemoveCandidate(candidate));
            }

            return (IReadOnlyList<LeftoverRemovalResult>)results;
        }, cancellationToken);
    }

    private InstallerCleanupCandidate? BuildCandidate(string file, DateTimeOffset cutoffUtc)
    {
        try
        {
            var fullPath = Path.GetFullPath(file);
            if (!IsPathDirectlyInDownloads(fullPath) || !IsInstallerPattern(fullPath))
            {
                return null;
            }

            var info = new FileInfo(fullPath);
            var lastWriteTime = new DateTimeOffset(info.LastWriteTimeUtc, TimeSpan.Zero);
            if (lastWriteTime >= cutoffUtc)
            {
                return null;
            }

            return new InstallerCleanupCandidate(
                info.Name,
                info.FullName,
                GetKind(info.Name),
                info.Length,
                lastWriteTime);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private LeftoverRemovalResult RemoveCandidate(InstallerCleanupCandidate candidate)
    {
        var candidatePath = Path.GetFullPath(candidate.Path);
        if (!IsPathDirectlyInDownloads(candidatePath) || !IsInstallerPattern(candidatePath))
        {
            return new LeftoverRemovalResult(candidate.Path, false, "Path is outside the installer preview scope.", candidate.SizeBytes);
        }

        try
        {
            if (File.Exists(candidatePath))
            {
                File.Delete(candidatePath);
            }

            return new LeftoverRemovalResult(candidate.Path, true, "Removed", candidate.SizeBytes);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return new LeftoverRemovalResult(candidate.Path, false, ex.Message, candidate.SizeBytes);
        }
    }

    private bool IsPathDirectlyInDownloads(string fullPath)
    {
        var parent = Path.GetDirectoryName(fullPath);
        return string.Equals(
            Path.GetFullPath(parent ?? string.Empty).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
            _downloadsPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
            StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsInstallerPattern(string path)
    {
        var name = Path.GetFileName(path);
        return name.EndsWith(".tar.gz", StringComparison.OrdinalIgnoreCase) ||
               name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ||
               name.EndsWith(".msi", StringComparison.OrdinalIgnoreCase) ||
               name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase) ||
               name.EndsWith(".7z", StringComparison.OrdinalIgnoreCase) ||
               name.EndsWith(".rar", StringComparison.OrdinalIgnoreCase) ||
               name.EndsWith(".iso", StringComparison.OrdinalIgnoreCase);
    }

    private static string GetKind(string name)
    {
        if (name.EndsWith(".msi", StringComparison.OrdinalIgnoreCase))
        {
            return "MSI installer";
        }

        if (name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
        {
            return "Windows installer";
        }

        if (name.EndsWith(".iso", StringComparison.OrdinalIgnoreCase))
        {
            return "Disk image";
        }

        return "Archive";
    }
}
