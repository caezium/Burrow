using BurrowWin.Models;

namespace BurrowWin.Services;

public sealed class PurgeArtifactService : IPurgeArtifactService
{
    private const int MaxSearchDepth = 4;

    private static readonly string[] DefaultSearchPaths =
    [
        @"Documents",
        @"Projects",
        @"Code",
        @"Development",
        @"workspace",
        @"github",
        @"repos",
        @"src"
    ];

    private static readonly string[] AbsoluteDefaultSearchPaths =
    [
        @"D:\Projects",
        @"D:\Code",
        @"D:\Development"
    ];

    private static readonly string[] ProjectMarkers =
    [
        "package.json",
        "composer.json",
        "Cargo.toml",
        "go.mod",
        "pom.xml",
        "build.gradle",
        "requirements.txt",
        "pyproject.toml",
        "*.csproj",
        "*.sln"
    ];

    private static readonly ArtifactPattern[] ArtifactPatterns =
    [
        new("node_modules", ArtifactKind.Directory, "JavaScript/Node.js"),
        new("vendor", ArtifactKind.Directory, "PHP/Go"),
        new(".venv", ArtifactKind.Directory, "Python"),
        new("venv", ArtifactKind.Directory, "Python"),
        new("__pycache__", ArtifactKind.Directory, "Python"),
        new(".pytest_cache", ArtifactKind.Directory, "Python"),
        new("target", ArtifactKind.Directory, "Rust/Java"),
        new("build", ArtifactKind.Directory, "General"),
        new("dist", ArtifactKind.Directory, "General"),
        new(".next", ArtifactKind.Directory, "Next.js"),
        new(".nuxt", ArtifactKind.Directory, "Nuxt.js"),
        new(".turbo", ArtifactKind.Directory, "Turborepo"),
        new(".parcel-cache", ArtifactKind.Directory, "Parcel"),
        new("bin", ArtifactKind.Directory, ".NET"),
        new("obj", ArtifactKind.Directory, ".NET"),
        new(".gradle", ArtifactKind.Directory, "Java/Gradle"),
        new(".idea", ArtifactKind.Directory, "JetBrains IDE"),
        new("*.log", ArtifactKind.File, "Logs")
    ];

    private readonly string _userProfile;
    private readonly string _configFile;

    public PurgeArtifactService()
        : this(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".config",
                "mole",
                "purge_paths.txt"))
    {
    }

    public PurgeArtifactService(string userProfile, string configFile)
    {
        _userProfile = userProfile;
        _configFile = configFile;
    }

    public Task<IReadOnlyList<PurgeProjectCandidate>> PreviewAsync(
        IReadOnlyList<string>? searchRoots = null,
        CancellationToken cancellationToken = default)
    {
        return Task.Run(() =>
        {
            var roots = ResolveSearchRoots(searchRoots);
            var projects = new Dictionary<string, PurgeProjectCandidate>(StringComparer.OrdinalIgnoreCase);

            foreach (var root in roots)
            {
                cancellationToken.ThrowIfCancellationRequested();
                foreach (var directory in EnumerateDirectories(root, MaxSearchDepth, cancellationToken))
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    if (projects.ContainsKey(directory))
                    {
                        continue;
                    }

                    var marker = FindProjectMarker(directory);
                    if (marker is null)
                    {
                        continue;
                    }

                    var artifacts = FindArtifacts(directory, cancellationToken);
                    if (artifacts.Count == 0)
                    {
                        continue;
                    }

                    var project = new PurgeProjectCandidate(
                        Path.GetFileName(directory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)),
                        directory,
                        marker,
                        artifacts);
                    projects[directory] = project;
                }
            }

            return (IReadOnlyList<PurgeProjectCandidate>)projects.Values
                .OrderByDescending(project => project.TotalSizeBytes)
                .ThenBy(project => project.Name, StringComparer.OrdinalIgnoreCase)
                .ToList();
        }, cancellationToken);
    }

    public Task<IReadOnlyList<LeftoverRemovalResult>> RemoveAsync(
        IReadOnlyList<PurgeProjectCandidate> projects,
        CancellationToken cancellationToken = default)
    {
        return Task.Run(() =>
        {
            var results = new List<LeftoverRemovalResult>();
            foreach (var project in projects)
            {
                var projectRoot = Path.GetFullPath(project.Path);
                foreach (var artifact in project.Artifacts)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    results.Add(RemoveArtifact(projectRoot, artifact));
                }
            }

            return (IReadOnlyList<LeftoverRemovalResult>)results;
        }, cancellationToken);
    }

    private IReadOnlyList<string> ResolveSearchRoots(IReadOnlyList<string>? searchRoots)
    {
        var candidates = searchRoots is { Count: > 0 }
            ? searchRoots
            : ReadConfiguredSearchRoots();

        if (candidates.Count == 0)
        {
            candidates = BuildDefaultSearchRoots();
        }

        return candidates
            .Where(path => !string.IsNullOrWhiteSpace(path))
            .Select(path => Environment.ExpandEnvironmentVariables(path))
            .Select(path => Path.GetFullPath(path))
            .Where(Directory.Exists)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private IReadOnlyList<string> ReadConfiguredSearchRoots()
    {
        if (!File.Exists(_configFile))
        {
            return Array.Empty<string>();
        }

        try
        {
            return File.ReadAllLines(_configFile)
                .Select(line => line.Trim())
                .Where(line => line.Length > 0 && !line.StartsWith('#'))
                .ToList();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return Array.Empty<string>();
        }
    }

    private IReadOnlyList<string> BuildDefaultSearchRoots()
    {
        var roots = DefaultSearchPaths
            .Select(path => Path.Combine(_userProfile, path))
            .Concat(AbsoluteDefaultSearchPaths)
            .ToList();
        return roots;
    }

    private static IEnumerable<string> EnumerateDirectories(
        string root,
        int maxDepth,
        CancellationToken cancellationToken)
    {
        var rootFullPath = Path.GetFullPath(root);
        yield return rootFullPath;

        var pending = new Queue<(string Path, int Depth)>();
        pending.Enqueue((rootFullPath, 0));

        while (pending.Count > 0)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var current = pending.Dequeue();
            if (current.Depth >= maxDepth)
            {
                continue;
            }

            IEnumerable<string> children;
            try
            {
                children = Directory.EnumerateDirectories(current.Path);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                continue;
            }

            foreach (var child in children)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var name = Path.GetFileName(child);
                if (ShouldSkipDirectory(name))
                {
                    continue;
                }

                yield return child;
                pending.Enqueue((child, current.Depth + 1));
            }
        }
    }

    private static bool ShouldSkipDirectory(string name)
    {
        return string.Equals(name, ".git", StringComparison.OrdinalIgnoreCase) ||
               string.Equals(name, "node_modules", StringComparison.OrdinalIgnoreCase) ||
               string.Equals(name, "vendor", StringComparison.OrdinalIgnoreCase);
    }

    private static string? FindProjectMarker(string directory)
    {
        foreach (var marker in ProjectMarkers)
        {
            if (marker.StartsWith('*'))
            {
                if (Directory.EnumerateFiles(directory, marker).Any())
                {
                    return marker;
                }

                continue;
            }

            if (File.Exists(Path.Combine(directory, marker)))
            {
                return marker;
            }
        }

        return null;
    }

    private static IReadOnlyList<PurgeArtifactCandidate> FindArtifacts(
        string projectPath,
        CancellationToken cancellationToken)
    {
        var artifacts = new List<PurgeArtifactCandidate>();
        foreach (var pattern in ArtifactPatterns)
        {
            cancellationToken.ThrowIfCancellationRequested();
            IEnumerable<string> matches;
            try
            {
                matches = pattern.Kind == ArtifactKind.Directory
                    ? Directory.EnumerateDirectories(projectPath, pattern.Name)
                    : Directory.EnumerateFiles(projectPath, pattern.Name);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                continue;
            }

            foreach (var match in matches)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var fullPath = Path.GetFullPath(match);
                var sizeBytes = pattern.Kind == ArtifactKind.Directory
                    ? GetDirectorySize(fullPath, cancellationToken)
                    : GetFileSize(fullPath);

                artifacts.Add(new PurgeArtifactCandidate(
                    Path.GetFileName(fullPath),
                    fullPath,
                    pattern.Kind.ToString(),
                    pattern.Language,
                    sizeBytes));
            }
        }

        return artifacts
            .OrderByDescending(artifact => artifact.SizeBytes)
            .ThenBy(artifact => artifact.Name, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private static long GetDirectorySize(string directory, CancellationToken cancellationToken)
    {
        long total = 0;
        try
        {
            foreach (var file in Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories))
            {
                cancellationToken.ThrowIfCancellationRequested();
                total += GetFileSize(file);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }

        return total;
    }

    private static long GetFileSize(string file)
    {
        try
        {
            return new FileInfo(file).Length;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return 0;
        }
    }

    private static LeftoverRemovalResult RemoveArtifact(string projectRoot, PurgeArtifactCandidate artifact)
    {
        var artifactPath = Path.GetFullPath(artifact.Path);
        if (!IsPathUnder(projectRoot, artifactPath) || !IsAllowedArtifact(artifactPath, artifact.Type))
        {
            return new LeftoverRemovalResult(artifact.Path, false, "Path is outside the purge preview scope.", artifact.SizeBytes);
        }

        try
        {
            if (string.Equals(artifact.Type, ArtifactKind.Directory.ToString(), StringComparison.OrdinalIgnoreCase))
            {
                if (Directory.Exists(artifactPath))
                {
                    Directory.Delete(artifactPath, recursive: true);
                }
            }
            else if (File.Exists(artifactPath))
            {
                File.Delete(artifactPath);
            }

            return new LeftoverRemovalResult(artifact.Path, true, "Removed", artifact.SizeBytes);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return new LeftoverRemovalResult(artifact.Path, false, ex.Message, artifact.SizeBytes);
        }
    }

    private static bool IsPathUnder(string root, string path)
    {
        var normalizedRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
        var normalizedPath = Path.GetFullPath(path);
        return normalizedPath.StartsWith(normalizedRoot, StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsAllowedArtifact(string path, string type)
    {
        var name = Path.GetFileName(path);
        return ArtifactPatterns.Any(pattern =>
            string.Equals(pattern.Kind.ToString(), type, StringComparison.OrdinalIgnoreCase) &&
            (string.Equals(pattern.Name, name, StringComparison.OrdinalIgnoreCase) ||
             (pattern.Name == "*.log" && name.EndsWith(".log", StringComparison.OrdinalIgnoreCase))));
    }

    private sealed record ArtifactPattern(string Name, ArtifactKind Kind, string Language);

    private enum ArtifactKind
    {
        Directory,
        File
    }
}
