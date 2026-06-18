using BurrowWin.Models;

namespace BurrowWin.Services;

public sealed class DiskAnalyzerService : IDiskAnalyzerService
{
    public Task<DiskUsageNode> AnalyzeAsync(
        string rootPath,
        DiskAnalysisOptions options,
        CancellationToken cancellationToken = default)
    {
        return Task.Run(() =>
        {
            var fullPath = ResolveRootPath(rootPath);
            return ScanDirectory(fullPath, options, 0, 100, cancellationToken);
        }, cancellationToken);
    }

    private static string ResolveRootPath(string rootPath)
    {
        var path = string.IsNullOrWhiteSpace(rootPath)
            ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)
            : Environment.ExpandEnvironmentVariables(rootPath.Trim());

        var fullPath = Path.GetFullPath(path);
        if (!Directory.Exists(fullPath))
        {
            throw new DirectoryNotFoundException($"Analysis root was not found: {fullPath}");
        }

        return fullPath;
    }

    private static DiskUsageNode ScanDirectory(
        string path,
        DiskAnalysisOptions options,
        int depth,
        double percentOfParent,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        var childInfos = new List<ChildUsage>();
        long ownFileBytes = 0;

        foreach (var file in SafeEnumerateFiles(path))
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                ownFileBytes += file.Length;
            }
            catch
            {
                // File size can fail if the file disappears or access is denied.
            }
        }

        foreach (var directory in SafeEnumerateDirectories(path))
        {
            cancellationToken.ThrowIfCancellationRequested();
            var size = MeasureDirectory(directory.FullName, cancellationToken);
            childInfos.Add(new ChildUsage(directory.Name, directory.FullName, size));
        }

        var totalBytes = ownFileBytes + childInfos.Sum(child => child.SizeBytes);
        var children = Array.Empty<DiskUsageNode>();

        if (depth < options.SafeMaxDepth && childInfos.Count > 0)
        {
            children = childInfos
                .OrderByDescending(child => child.SizeBytes)
                .Take(options.SafeMaxChildrenPerNode)
                .Select(child => ScanDirectory(
                    child.Path,
                    options,
                    depth + 1,
                    totalBytes <= 0 ? 0 : (double)child.SizeBytes / totalBytes * 100,
                    cancellationToken))
                .ToArray();
        }

        var name = depth == 0 ? path : Path.GetFileName(path);
        return new DiskUsageNode(name, path, totalBytes, percentOfParent, children);
    }

    private static long MeasureDirectory(string path, CancellationToken cancellationToken)
    {
        long total = 0;

        foreach (var file in SafeEnumerateFiles(path))
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                total += file.Length;
            }
            catch
            {
                // File size can fail if the file disappears or access is denied.
            }
        }

        foreach (var directory in SafeEnumerateDirectories(path))
        {
            cancellationToken.ThrowIfCancellationRequested();
            total += MeasureDirectory(directory.FullName, cancellationToken);
        }

        return total;
    }

    private static IEnumerable<FileInfo> SafeEnumerateFiles(string path)
    {
        try
        {
            return new DirectoryInfo(path).EnumerateFiles();
        }
        catch
        {
            return [];
        }
    }

    private static IEnumerable<DirectoryInfo> SafeEnumerateDirectories(string path)
    {
        try
        {
            return new DirectoryInfo(path).EnumerateDirectories();
        }
        catch
        {
            return [];
        }
    }

    private sealed record ChildUsage(string Name, string Path, long SizeBytes);
}
