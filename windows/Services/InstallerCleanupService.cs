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

    private readonly ISafeDeletionService _safeDeletionService;
    private readonly IWindowsPathSafetyPolicy _pathSafetyPolicy;
    private readonly IWindowsFileSystemInspector _fileSystem;
    private readonly string _downloadsPath;
    private readonly int _daysOld;
    private readonly object _previewLock = new();
    private readonly HashSet<string> _approvedCandidateFingerprints = new(StringComparer.Ordinal);

    public InstallerCleanupService()
        : this(
            ResolveDefaultDownloadsPath(),
            DefaultDaysOld,
            new RecycleBinDeletionService(),
            new WindowsPathSafetyPolicy(),
            new WindowsFileSystemInspector())
    {
    }

    public InstallerCleanupService(ISafeDeletionService safeDeletionService)
        : this(
            ResolveDefaultDownloadsPath(),
            DefaultDaysOld,
            safeDeletionService,
            new WindowsPathSafetyPolicy(),
            new WindowsFileSystemInspector())
    {
    }

    public InstallerCleanupService(string downloadsPath, int daysOld = DefaultDaysOld)
        : this(
            downloadsPath,
            daysOld,
            new RecycleBinDeletionService(),
            new WindowsPathSafetyPolicy(),
            new WindowsFileSystemInspector())
    {
    }

    public InstallerCleanupService(
        string downloadsPath,
        int daysOld,
        ISafeDeletionService safeDeletionService)
        : this(
            downloadsPath,
            daysOld,
            safeDeletionService,
            new WindowsPathSafetyPolicy(),
            new WindowsFileSystemInspector())
    {
    }

    public InstallerCleanupService(
        ISafeDeletionService safeDeletionService,
        IWindowsPathSafetyPolicy pathSafetyPolicy,
        IWindowsFileSystemInspector fileSystem)
        : this(
            ResolveDefaultDownloadsPath(),
            DefaultDaysOld,
            safeDeletionService,
            pathSafetyPolicy,
            fileSystem)
    {
    }

    public InstallerCleanupService(
        string downloadsPath,
        int daysOld,
        ISafeDeletionService safeDeletionService,
        IWindowsPathSafetyPolicy pathSafetyPolicy,
        IWindowsFileSystemInspector fileSystem)
    {
        _safeDeletionService = safeDeletionService;
        _pathSafetyPolicy = pathSafetyPolicy;
        _fileSystem = fileSystem;
        _downloadsPath = downloadsPath?.Trim() ?? string.Empty;
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
        ClearApprovedPreview();
        return Task.Run(() =>
        {
            if (!_pathSafetyPolicy.ValidateScopeRoot(_downloadsPath).IsSafe || !Directory.Exists(_downloadsPath))
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
                    files = Directory.EnumerateFiles(_downloadsPath, pattern, SearchOption.TopDirectoryOnly).ToArray();
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException)
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

            var ordered = candidates.Values
                .OrderByDescending(candidate => candidate.SizeBytes)
                .ThenBy(candidate => candidate.Name, StringComparer.OrdinalIgnoreCase)
                .ToList();

            lock (_previewLock)
            {
                foreach (var candidate in ordered)
                {
                    _approvedCandidateFingerprints.Add(BuildDescriptor(candidate).Fingerprint());
                }
            }

            return (IReadOnlyList<InstallerCleanupCandidate>)ordered;
        }, cancellationToken);
    }

    public ConfirmedDeletionAuthorization ConfirmRemoval(IReadOnlyList<InstallerCleanupCandidate> candidates)
    {
        return ConfirmedDeletionAuthorization.Confirm(
            DestructiveFlow.Installer,
            candidates.Select(BuildDescriptor));
    }

    public Task<DeletionBatchResult> RemoveAsync(
        IReadOnlyList<InstallerCleanupCandidate> candidates,
        ConfirmedDeletionAuthorization authorization,
        IProgress<DeletionProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(candidates);
        ArgumentNullException.ThrowIfNull(authorization);
        var workItems = candidates
            .Select(candidate => new InstallerWorkItem(candidate, BuildDescriptor(candidate)))
            .ToArray();
        var exactAuthorization = authorization.SourceFlow == DestructiveFlow.Installer &&
                                 authorization.IsExactMatch(workItems.Select(item => item.Descriptor));

        return Task.Run(() => DeletionBatchProcessor.RunAsync(
                workItems,
                authorization.OperationId,
                item => item.Descriptor.OriginalPath,
                item => RemoveCandidateAsync(item, authorization, exactAuthorization, cancellationToken),
                progress,
                cancellationToken));
    }

    private InstallerCleanupCandidate? BuildCandidate(string file, DateTimeOffset cutoffUtc)
    {
        try
        {
            var safety = _pathSafetyPolicy.Validate(file, _downloadsPath);
            if (!safety.IsSafe || safety.CanonicalPath is null ||
                safety.TargetInfo is not { Exists: true, ItemType: DeletionItemType.File } ||
                !IsPathDirectlyInDownloads(safety.CanonicalPath) ||
                !IsInstallerPattern(safety.CanonicalPath))
            {
                return null;
            }

            var info = new FileInfo(safety.CanonicalPath);
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
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException or ArgumentException or NotSupportedException)
        {
            return null;
        }
    }

    private async Task<SafeDeletionResult> RemoveCandidateAsync(
        InstallerWorkItem item,
        ConfirmedDeletionAuthorization authorization,
        bool exactAuthorization,
        CancellationToken cancellationToken)
    {
        var safety = _pathSafetyPolicy.Validate(item.Descriptor.OriginalPath, item.Descriptor.ExpectedScopeRoot);
        bool approvedByPreview;
        lock (_previewLock)
        {
            approvedByPreview = _approvedCandidateFingerprints.Contains(item.Descriptor.Fingerprint());
        }

        var validation = exactAuthorization && approvedByPreview
            ? ValidateInstallerCandidate(item, safety)
            : FlowSafetyValidation.Reject(
                approvedByPreview ? "authorization_set_mismatch" : "not_previewed",
                approvedByPreview
                    ? "Explicit confirmation does not match the exact selected installer candidate set."
                    : "The target is not an approved candidate from the current installer preview.");

        return await _safeDeletionService.DeleteAsync(
            new SafeDeletionRequest(
                item.Descriptor,
                safety.CanonicalPath ?? item.Descriptor.OriginalPath,
                authorization.OperationId,
                authorization,
                validation),
            cancellationToken).ConfigureAwait(false);
    }

    private FlowSafetyValidation ValidateInstallerCandidate(InstallerWorkItem item, PathSafetyResult safety)
    {
        if (!safety.IsSafe || safety.CanonicalPath is null)
        {
            return FlowSafetyValidation.Reject(safety.ReasonCode, safety.Message);
        }

        if (!IsPathDirectlyInDownloads(safety.CanonicalPath) || !IsInstallerPattern(safety.CanonicalPath))
        {
            return FlowSafetyValidation.Reject(
                "installer_scope_changed",
                "The target is no longer a direct Downloads child with an approved installer/archive extension.");
        }

        var entry = safety.TargetInfo ?? _fileSystem.Inspect(safety.CanonicalPath);
        if (!entry.Exists)
        {
            return FlowSafetyValidation.Allow();
        }

        if (entry.ItemType != DeletionItemType.File ||
            entry.SizeBytes != item.Candidate.SizeBytes ||
            !SameTimestamp(entry.LastWriteTimeUtc, item.Candidate.LastWriteTime))
        {
            return FlowSafetyValidation.Reject(
                "candidate_changed",
                "The installer/archive changed after preview; rescan before removal.");
        }

        return FlowSafetyValidation.Allow(entry.SizeBytes);
    }

    private DeletionCandidateDescriptor BuildDescriptor(InstallerCleanupCandidate candidate) =>
        new(
            candidate.Path,
            _downloadsPath,
            DestructiveFlow.Installer,
            candidate.Kind,
            DeletionItemType.File,
            candidate.SizeBytes,
            candidate.LastWriteTime.ToUniversalTime());

    private static bool SameTimestamp(DateTimeOffset? observed, DateTimeOffset previewed) =>
        observed.HasValue && observed.Value.UtcDateTime == previewed.UtcDateTime;

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

    private void ClearApprovedPreview()
    {
        lock (_previewLock)
        {
            _approvedCandidateFingerprints.Clear();
        }
    }

    private sealed record InstallerWorkItem(
        InstallerCleanupCandidate Candidate,
        DeletionCandidateDescriptor Descriptor);
}
