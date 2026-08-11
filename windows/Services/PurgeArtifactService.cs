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
        "CMakeLists.txt",
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
        new("*.log", ArtifactKind.File, "Logs")
    ];

    private readonly ISafeDeletionService _safeDeletionService;
    private readonly IWindowsPathSafetyPolicy _pathSafetyPolicy;
    private readonly IWindowsFileSystemInspector _fileSystem;
    private readonly string _userProfile;
    private readonly string _configFile;
    private readonly object _previewLock = new();
    private readonly HashSet<string> _approvedCandidateFingerprints = new(StringComparer.Ordinal);

    public PurgeArtifactService()
        : this(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".config",
                "mole",
                "purge_paths.txt"),
            new RecycleBinDeletionService(),
            new WindowsPathSafetyPolicy(),
            new WindowsFileSystemInspector())
    {
    }

    public PurgeArtifactService(ISafeDeletionService safeDeletionService)
        : this(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".config",
                "mole",
                "purge_paths.txt"),
            safeDeletionService,
            new WindowsPathSafetyPolicy(),
            new WindowsFileSystemInspector())
    {
    }

    public PurgeArtifactService(string userProfile, string configFile)
        : this(
            userProfile,
            configFile,
            new RecycleBinDeletionService(),
            new WindowsPathSafetyPolicy(),
            new WindowsFileSystemInspector())
    {
    }

    public PurgeArtifactService(
        string userProfile,
        string configFile,
        ISafeDeletionService safeDeletionService)
        : this(
            userProfile,
            configFile,
            safeDeletionService,
            new WindowsPathSafetyPolicy(),
            new WindowsFileSystemInspector())
    {
    }

    public PurgeArtifactService(
        ISafeDeletionService safeDeletionService,
        IWindowsPathSafetyPolicy pathSafetyPolicy,
        IWindowsFileSystemInspector fileSystem)
        : this(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".config",
                "mole",
                "purge_paths.txt"),
            safeDeletionService,
            pathSafetyPolicy,
            fileSystem)
    {
    }

    public PurgeArtifactService(
        string userProfile,
        string configFile,
        ISafeDeletionService safeDeletionService,
        IWindowsPathSafetyPolicy pathSafetyPolicy,
        IWindowsFileSystemInspector fileSystem)
    {
        _safeDeletionService = safeDeletionService;
        _pathSafetyPolicy = pathSafetyPolicy;
        _fileSystem = fileSystem;
        _userProfile = userProfile;
        _configFile = configFile;
    }

    public Task<IReadOnlyList<PurgeProjectCandidate>> PreviewAsync(
        IReadOnlyList<string>? searchRoots = null,
        CancellationToken cancellationToken = default)
    {
        ClearApprovedPreview();
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

                    var artifacts = FindArtifacts(directory, marker, cancellationToken);
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

            var ordered = projects.Values
                .OrderByDescending(project => project.TotalSizeBytes)
                .ThenBy(project => project.Name, StringComparer.OrdinalIgnoreCase)
                .ToList();

            lock (_previewLock)
            {
                foreach (var item in BuildWorkItems(ordered))
                {
                    _approvedCandidateFingerprints.Add(item.Descriptor.Fingerprint());
                }
            }

            return (IReadOnlyList<PurgeProjectCandidate>)ordered;
        }, cancellationToken);
    }

    public ConfirmedDeletionAuthorization ConfirmRemoval(IReadOnlyList<PurgeProjectCandidate> projects)
    {
        var workItems = BuildWorkItems(projects);
        return ConfirmedDeletionAuthorization.Confirm(
            DestructiveFlow.Purge,
            workItems.Select(item => item.Descriptor));
    }

    public Task<DeletionBatchResult> RemoveAsync(
        IReadOnlyList<PurgeProjectCandidate> projects,
        ConfirmedDeletionAuthorization authorization,
        IProgress<DeletionProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(projects);
        ArgumentNullException.ThrowIfNull(authorization);
        var workItems = BuildWorkItems(projects);
        var exactAuthorization = authorization.SourceFlow == DestructiveFlow.Purge &&
                                 authorization.IsExactMatch(workItems.Select(item => item.Descriptor));

        return Task.Run(() => DeletionBatchProcessor.RunAsync(
                workItems,
                authorization.OperationId,
                item => item.Descriptor.OriginalPath,
                item => RemoveArtifactAsync(item, authorization, exactAuthorization, cancellationToken),
                progress,
                cancellationToken));
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

        var safeRoots = new List<string>();
        foreach (var candidate in candidates.Where(path => !string.IsNullOrWhiteSpace(path)))
        {
            var expanded = Environment.ExpandEnvironmentVariables(candidate);
            var safety = _pathSafetyPolicy.ValidateScopeRoot(expanded);
            if (safety.IsSafe && safety.CanonicalScopeRoot is not null)
            {
                safeRoots.Add(safety.CanonicalScopeRoot);
            }
        }

        return safeRoots.Distinct(StringComparer.OrdinalIgnoreCase).ToList();
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
        if (IsReparsePoint(rootFullPath))
        {
            yield break;
        }

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
                children = Directory.EnumerateDirectories(current.Path).ToArray();
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException)
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

                if (IsReparsePoint(child))
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
        try
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
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
        }

        return null;
    }

    private IReadOnlyList<PurgeArtifactCandidate> FindArtifacts(
        string projectPath,
        string projectMarker,
        CancellationToken cancellationToken)
    {
        var artifacts = new List<PurgeArtifactCandidate>();
        foreach (var pattern in ArtifactPatterns)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!IsPatternAllowedForProject(pattern, projectPath, projectMarker))
            {
                continue;
            }

            IEnumerable<string> matches;
            try
            {
                matches = pattern.Kind == ArtifactKind.Directory
                    ? Directory.EnumerateDirectories(projectPath, pattern.Name).ToArray()
                    : Directory.EnumerateFiles(projectPath, pattern.Name).ToArray();
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException)
            {
                continue;
            }

            foreach (var match in matches)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var fullPath = Path.GetFullPath(match);
                var entry = _fileSystem.Inspect(fullPath);
                if (!entry.Exists || entry.IsReparsePoint ||
                    !_fileSystem.TryMeasureSize(fullPath, cancellationToken, out var sizeBytes))
                {
                    continue;
                }

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

    private static bool IsReparsePoint(string path)
    {
        try
        {
            return File.GetAttributes(path).HasFlag(FileAttributes.ReparsePoint);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            return true;
        }
    }

    private async Task<SafeDeletionResult> RemoveArtifactAsync(
        PurgeWorkItem item,
        ConfirmedDeletionAuthorization authorization,
        bool exactAuthorization,
        CancellationToken cancellationToken)
    {
        var descriptor = item.Descriptor;
        var safety = _pathSafetyPolicy.Validate(descriptor.OriginalPath, descriptor.ExpectedScopeRoot);
        bool approvedByPreview;
        lock (_previewLock)
        {
            approvedByPreview = _approvedCandidateFingerprints.Contains(descriptor.Fingerprint());
        }

        var validation = exactAuthorization && approvedByPreview
            ? ValidatePurgeCandidate(item, safety, cancellationToken)
            : FlowSafetyValidation.Reject(
                approvedByPreview ? "authorization_set_mismatch" : "not_previewed",
                approvedByPreview
                    ? "Explicit confirmation does not match the exact selected purge candidate set."
                    : "The target is not an approved candidate from the current purge preview.");

        return await _safeDeletionService.DeleteAsync(
            new SafeDeletionRequest(
                descriptor,
                safety.CanonicalPath ?? descriptor.OriginalPath,
                authorization.OperationId,
                authorization,
                validation),
            cancellationToken).ConfigureAwait(false);
    }

    private FlowSafetyValidation ValidatePurgeCandidate(
        PurgeWorkItem item,
        PathSafetyResult safety,
        CancellationToken cancellationToken)
    {
        if (!safety.IsSafe || safety.CanonicalPath is null || safety.CanonicalScopeRoot is null)
        {
            return FlowSafetyValidation.Reject(safety.ReasonCode, safety.Message);
        }

        var marker = FindProjectMarker(safety.CanonicalScopeRoot);
        if (marker is null || !string.Equals(marker, item.Project.Marker, StringComparison.OrdinalIgnoreCase))
        {
            return FlowSafetyValidation.Reject("project_marker_changed", "The previewed project marker is missing or changed.");
        }

        var parent = Path.GetDirectoryName(safety.CanonicalPath);
        if (!string.Equals(parent?.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                safety.CanonicalScopeRoot.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                StringComparison.OrdinalIgnoreCase) ||
            !IsAllowedArtifact(safety.CanonicalScopeRoot, safety.CanonicalPath, item.Artifact.Type))
        {
            return FlowSafetyValidation.Reject("artifact_rule_changed", "The target no longer matches the approved project artifact rule.");
        }

        var entry = safety.TargetInfo ?? _fileSystem.Inspect(safety.CanonicalPath);
        if (!entry.Exists)
        {
            return FlowSafetyValidation.Allow();
        }

        if (entry.ItemType != item.Descriptor.ItemType)
        {
            return FlowSafetyValidation.Reject("candidate_type_changed", "The artifact type changed after preview.");
        }

        try
        {
            if (!_fileSystem.TryMeasureSize(safety.CanonicalPath, cancellationToken, out var observedSize))
            {
                return FlowSafetyValidation.Reject("candidate_unverifiable", "The artifact size could not be verified safely.");
            }

            return observedSize == item.Artifact.SizeBytes
                ? FlowSafetyValidation.Allow(observedSize)
                : FlowSafetyValidation.Reject("candidate_changed", "The artifact contents changed after preview; rescan before removal.");
        }
        catch (OperationCanceledException)
        {
            return FlowSafetyValidation.Reject("cancelled", "Cancellation was requested while revalidating the artifact.");
        }
    }

    private static IReadOnlyList<PurgeWorkItem> BuildWorkItems(IReadOnlyList<PurgeProjectCandidate> projects)
    {
        ArgumentNullException.ThrowIfNull(projects);
        var items = new List<PurgeWorkItem>();
        foreach (var project in projects)
        {
            foreach (var artifact in project.Artifacts)
            {
                var itemType = string.Equals(artifact.Type, ArtifactKind.Directory.ToString(), StringComparison.OrdinalIgnoreCase)
                    ? DeletionItemType.Directory
                    : DeletionItemType.File;
                var descriptor = new DeletionCandidateDescriptor(
                    artifact.Path,
                    project.Path,
                    DestructiveFlow.Purge,
                    $"{artifact.Type}:{artifact.Language}",
                    itemType,
                    artifact.SizeBytes);
                items.Add(new PurgeWorkItem(project, artifact, descriptor));
            }
        }

        return items;
    }

    private void ClearApprovedPreview()
    {
        lock (_previewLock)
        {
            _approvedCandidateFingerprints.Clear();
        }
    }

    private static bool IsAllowedArtifact(string projectRoot, string path, string type)
    {
        var marker = FindProjectMarker(projectRoot);
        if (marker is null)
        {
            return false;
        }

        var name = Path.GetFileName(path);
        return ArtifactPatterns.Any(pattern =>
            string.Equals(pattern.Kind.ToString(), type, StringComparison.OrdinalIgnoreCase) &&
            IsPatternAllowedForProject(pattern, projectRoot, marker) &&
            (string.Equals(pattern.Name, name, StringComparison.OrdinalIgnoreCase) ||
             (pattern.Name == "*.log" && name.EndsWith(".log", StringComparison.OrdinalIgnoreCase))));
    }

    private static bool IsPatternAllowedForProject(
        ArtifactPattern pattern,
        string projectRoot,
        string projectMarker)
    {
        return pattern.Name switch
        {
            "node_modules" or ".next" or ".nuxt" or ".turbo" or ".parcel-cache" =>
                HasProjectFile(projectRoot, "package.json"),
            "vendor" => HasProjectFile(projectRoot, "composer.json") || HasProjectFile(projectRoot, "go.mod"),
            ".venv" or "venv" or "__pycache__" or ".pytest_cache" =>
                HasProjectFile(projectRoot, "pyproject.toml") || HasProjectFile(projectRoot, "requirements.txt"),
            "target" =>
                HasProjectFile(projectRoot, "Cargo.toml") ||
                HasProjectFile(projectRoot, "pom.xml") ||
                HasProjectFile(projectRoot, "build.gradle"),
            "bin" or "obj" => HasAnyFile(projectRoot, "*.csproj") || HasAnyFile(projectRoot, "*.sln"),
            "build" or "dist" =>
                (HasProjectFile(projectRoot, "package.json") && HasAnyPackageLock(projectRoot)) ||
                (HasProjectFile(projectRoot, "CMakeLists.txt") &&
                 Directory.Exists(Path.Combine(projectRoot, pattern.Name)) &&
                 File.Exists(Path.Combine(projectRoot, pattern.Name, "CMakeCache.txt"))),
            ".gradle" => HasProjectFile(projectRoot, "build.gradle"),
            "*.log" => projectMarker.Length > 0,
            _ => true
        };
    }

    private static bool HasAnyPackageLock(string projectRoot)
    {
        return HasProjectFile(projectRoot, "package-lock.json") ||
               HasProjectFile(projectRoot, "pnpm-lock.yaml") ||
               HasProjectFile(projectRoot, "yarn.lock") ||
               HasProjectFile(projectRoot, "bun.lockb");
    }

    private static bool HasProjectFile(string projectRoot, string fileName)
    {
        return File.Exists(Path.Combine(projectRoot, fileName));
    }

    private static bool HasAnyFile(string projectRoot, string pattern)
    {
        try
        {
            return Directory.EnumerateFiles(projectRoot, pattern, SearchOption.TopDirectoryOnly).Any();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            return false;
        }
    }

    private sealed record ArtifactPattern(string Name, ArtifactKind Kind, string Language);

    private sealed record PurgeWorkItem(
        PurgeProjectCandidate Project,
        PurgeArtifactCandidate Artifact,
        DeletionCandidateDescriptor Descriptor);

    private enum ArtifactKind
    {
        Directory,
        File
    }
}
