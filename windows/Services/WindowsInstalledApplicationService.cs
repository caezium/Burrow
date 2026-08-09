using System.Diagnostics;
using Microsoft.Win32;
using BurrowWin.Models;

namespace BurrowWin.Services;

public sealed class WindowsInstalledApplicationService : IInstalledApplicationService
{
    private static readonly char[] DirectorySeparators = [Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar];

    private readonly ISafeDeletionService _safeDeletionService;
    private readonly IOperationHistoryService? _operationHistoryService;
    private readonly IWindowsPathSafetyPolicy _pathSafetyPolicy;
    private readonly IWindowsFileSystemInspector _fileSystem;
    private readonly object _previewLock = new();
    private readonly HashSet<string> _approvedLeftoverFingerprints = new(StringComparer.Ordinal);

    public WindowsInstalledApplicationService(IOperationHistoryService? operationHistoryService = null)
        : this(
            new RecycleBinDeletionService(),
            operationHistoryService,
            new WindowsPathSafetyPolicy(),
            new WindowsFileSystemInspector())
    {
    }

    public WindowsInstalledApplicationService(
        ISafeDeletionService safeDeletionService,
        IOperationHistoryService? operationHistoryService = null)
        : this(
            safeDeletionService,
            operationHistoryService,
            new WindowsPathSafetyPolicy(),
            new WindowsFileSystemInspector())
    {
    }

    public WindowsInstalledApplicationService(
        ISafeDeletionService safeDeletionService,
        IOperationHistoryService? operationHistoryService,
        IWindowsPathSafetyPolicy pathSafetyPolicy,
        IWindowsFileSystemInspector fileSystem)
    {
        _safeDeletionService = safeDeletionService;
        _operationHistoryService = operationHistoryService;
        _pathSafetyPolicy = pathSafetyPolicy;
        _fileSystem = fileSystem;
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
        lock (_previewLock)
        {
            _approvedLeftoverFingerprints.Clear();
        }

        return Task.Run<IReadOnlyList<LeftoverCandidate>>(() =>
        {
            var candidates = new List<LeftoverCandidate>();
            foreach (var discovered in BuildLeftoverPaths(application))
            {
                cancellationToken.ThrowIfCancellationRequested();
                var scopeRoot = ResolveLeftoverScope(discovered.Category, discovered.Path);
                if (string.IsNullOrWhiteSpace(scopeRoot))
                {
                    continue;
                }

                var safety = _pathSafetyPolicy.Validate(discovered.Path, scopeRoot);
                if (!safety.IsSafe || safety.TargetInfo is not { Exists: true, ItemType: DeletionItemType.Directory })
                {
                    continue;
                }

                var candidate = new LeftoverCandidate(discovered.Category, discovered.Path, 0, scopeRoot);
                if (!IsSafeLeftoverCandidate(candidate) ||
                    !_fileSystem.TryMeasureSize(safety.CanonicalPath!, cancellationToken, out var sizeBytes) ||
                    sizeBytes <= 0)
                {
                    continue;
                }

                candidates.Add(new LeftoverCandidate(discovered.Category, safety.CanonicalPath!, sizeBytes, safety.CanonicalScopeRoot));
            }

            var ordered = candidates
                .OrderByDescending(candidate => candidate.SizeBytes)
                .ToArray();

            lock (_previewLock)
            {
                foreach (var candidate in ordered)
                {
                    _approvedLeftoverFingerprints.Add(BuildDescriptor(candidate).Fingerprint());
                }
            }

            return ordered;
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

    public ConfirmedDeletionAuthorization ConfirmLeftoverRemoval(IReadOnlyList<LeftoverCandidate> leftovers)
    {
        return ConfirmedDeletionAuthorization.Confirm(
            DestructiveFlow.UninstallLeftovers,
            leftovers.Select(BuildDescriptor));
    }

    public async Task<DeletionBatchResult> RemoveLeftoversAsync(
        IReadOnlyList<LeftoverCandidate> leftovers,
        ConfirmedDeletionAuthorization authorization,
        IProgress<DeletionProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(leftovers);
        ArgumentNullException.ThrowIfNull(authorization);
        var workItems = leftovers
            .Select(candidate => new LeftoverWorkItem(candidate, BuildDescriptor(candidate)))
            .ToArray();
        var exactAuthorization = authorization.SourceFlow == DestructiveFlow.UninstallLeftovers &&
                                 authorization.IsExactMatch(workItems.Select(item => item.Descriptor));

        var batch = await Task.Run(() => DeletionBatchProcessor.RunAsync(
                workItems,
                authorization.OperationId,
                item => item.Descriptor.OriginalPath,
                item => RemoveLeftoverAsync(item, authorization, exactAuthorization, cancellationToken),
                progress,
                cancellationToken))
            .ConfigureAwait(false);

        var output = BuildBatchSummary(batch, "leftover targets");
        await RecordHistoryAsync(
            "remove_leftovers",
            $"operation={batch.OperationId}{Environment.NewLine}{string.Join(Environment.NewLine, batch.ItemResults.Select(result => result.Path))}",
            new MoleCommandResult(
                batch.ExitCode,
                output,
                batch.Succeeded ? string.Empty : output,
                batch.Cancelled,
                TimeSpan.Zero),
            CancellationToken.None,
            batch).ConfigureAwait(false);

        return batch;
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

    private async Task<SafeDeletionResult> RemoveLeftoverAsync(
        LeftoverWorkItem item,
        ConfirmedDeletionAuthorization authorization,
        bool exactAuthorization,
        CancellationToken cancellationToken)
    {
        var safety = _pathSafetyPolicy.Validate(
            item.Descriptor.OriginalPath,
            item.Descriptor.ExpectedScopeRoot);
        var approvedByPreview = false;
        lock (_previewLock)
        {
            approvedByPreview = _approvedLeftoverFingerprints.Contains(item.Descriptor.Fingerprint());
        }

        var validation = exactAuthorization && approvedByPreview
            ? ValidateLeftoverCandidate(item, safety, cancellationToken)
            : FlowSafetyValidation.Reject(
                approvedByPreview ? "authorization_set_mismatch" : "not_previewed",
                approvedByPreview
                    ? "Explicit confirmation does not match the exact selected leftover set."
                    : "The target is not an approved candidate from the current leftover preview.");

        return await _safeDeletionService.DeleteAsync(
            new SafeDeletionRequest(
                item.Descriptor,
                safety.CanonicalPath ?? item.Descriptor.OriginalPath,
                authorization.OperationId,
                authorization,
                validation),
            cancellationToken).ConfigureAwait(false);
    }

    private FlowSafetyValidation ValidateLeftoverCandidate(
        LeftoverWorkItem item,
        PathSafetyResult safety,
        CancellationToken cancellationToken)
    {
        if (!safety.IsSafe || safety.CanonicalPath is null)
        {
            return FlowSafetyValidation.Reject(safety.ReasonCode, safety.Message);
        }

        if (!IsSafeLeftoverCandidate(item.Candidate))
        {
            return FlowSafetyValidation.Reject(
                "leftover_scope_changed",
                "The target no longer matches an approved uninstall-leftover location.");
        }

        var entry = safety.TargetInfo ?? _fileSystem.Inspect(safety.CanonicalPath);
        if (!entry.Exists)
        {
            return FlowSafetyValidation.Allow();
        }

        if (entry.ItemType != DeletionItemType.Directory)
        {
            return FlowSafetyValidation.Reject("candidate_type_changed", "The leftover target is no longer a directory.");
        }

        try
        {
            if (!_fileSystem.TryMeasureSize(safety.CanonicalPath, cancellationToken, out var observedSize))
            {
                return FlowSafetyValidation.Reject("candidate_unverifiable", "The leftover size could not be verified safely.");
            }

            return observedSize == item.Candidate.SizeBytes
                ? FlowSafetyValidation.Allow(observedSize)
                : FlowSafetyValidation.Reject(
                    "candidate_changed",
                    "The leftover contents changed after preview; rescan before removal.");
        }
        catch (OperationCanceledException)
        {
            return FlowSafetyValidation.Reject("cancelled", "Cancellation was requested while revalidating the leftover.");
        }
    }

    private static string ResolveLeftoverScope(string category, string path)
    {
        return category switch
        {
            "Local app data" or "Publisher local data" =>
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Roaming app data" or "Publisher roaming data" =>
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "Program data" => Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            _ => Path.GetDirectoryName(path) ?? string.Empty
        };
    }

    private static DeletionCandidateDescriptor BuildDescriptor(LeftoverCandidate candidate) =>
        new(
            candidate.Path,
            candidate.ApprovedScopeRoot,
            DestructiveFlow.UninstallLeftovers,
            candidate.Category,
            DeletionItemType.Directory,
            candidate.SizeBytes);

    private static string BuildBatchSummary(DeletionBatchResult batch, string noun)
    {
        return $"{batch.Outcome}: recycled {batch.RecycledCount} {noun}, " +
               $"already absent {batch.AlreadyAbsentCount}, rejected {batch.RejectedCount}, " +
               $"failed {batch.FailedCount}, bytes recycled {batch.RecycledBytes}, " +
               $"processed {batch.ProcessedCount}/{batch.TotalSelectedItems}, operation {batch.OperationId}.";
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

    public static bool IsSafeLeftoverCandidate(LeftoverCandidate leftover)
    {
        if (!TryNormalizePath(leftover.Path, out var fullPath) || !IsSafeDeletionTarget(fullPath))
        {
            return false;
        }

        return leftover.Category switch
        {
            "Install location" => !IsUnderUserProfile(fullPath),
            "Local app data" or "Roaming app data" or "Publisher local data" or "Publisher roaming data" =>
                IsAllowedApplicationDataTarget(fullPath),
            "Program data" => false,
            _ => true
        };
    }

    public static bool IsSafeDeletionTarget(string path)
    {
        if (!TryNormalizePath(path, out var fullPath))
        {
            return false;
        }

        var scopeRoot = Path.GetDirectoryName(fullPath);
        if (string.IsNullOrWhiteSpace(scopeRoot))
        {
            return false;
        }

        return new WindowsPathSafetyPolicy().Validate(fullPath, scopeRoot).IsSafe;
    }

    private static bool TryNormalizePath(string path, out string fullPath)
    {
        fullPath = string.Empty;
        if (string.IsNullOrWhiteSpace(path))
        {
            return false;
        }

        var expanded = Environment.ExpandEnvironmentVariables(path.Trim());
        if (string.IsNullOrWhiteSpace(expanded) || expanded.Contains('%', StringComparison.Ordinal))
        {
            return false;
        }

        try
        {
            fullPath = Path.GetFullPath(expanded).TrimEnd(DirectorySeparators);
            return fullPath.Length > 0;
        }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return false;
        }
    }

    private static bool IsAllowedApplicationDataTarget(string fullPath)
    {
        var roots = new[]
        {
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData)
        };

        foreach (var root in roots.Where(root => !string.IsNullOrWhiteSpace(root)).Select(NormalizeRoot))
        {
            if (!IsPathUnderRoot(fullPath, root))
            {
                continue;
            }

            var relative = Path.GetRelativePath(root, fullPath);
            var firstSegment = relative
                .Split(DirectorySeparators, StringSplitOptions.RemoveEmptyEntries)
                .FirstOrDefault();
            if (string.IsNullOrWhiteSpace(firstSegment))
            {
                return false;
            }

            var blockedFirstSegments = new[] { "Microsoft", "Windows", "Packages", "Programs", "Temp" };
            return !blockedFirstSegments.Contains(firstSegment, StringComparer.OrdinalIgnoreCase);
        }

        return false;
    }

    private static bool IsUnderUserProfile(string fullPath)
    {
        var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return !string.IsNullOrWhiteSpace(userProfile) && IsPathUnderRoot(fullPath, NormalizeRoot(userProfile));
    }

    private static bool IsPathUnderRoot(string path, string root)
    {
        return path.StartsWith(
            root.TrimEnd(DirectorySeparators) + Path.DirectorySeparatorChar,
            StringComparison.OrdinalIgnoreCase);
    }

    private static string NormalizeRoot(string path)
    {
        return Path.GetFullPath(Environment.ExpandEnvironmentVariables(path)).TrimEnd(DirectorySeparators);
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
        CancellationToken cancellationToken,
        DeletionBatchResult? batch = null)
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
            string.IsNullOrWhiteSpace(result.StandardError) ? result.StandardOutput : result.StandardError,
            batch?.Outcome,
            batch?.OperationId,
            batch?.RecycledCount ?? 0,
            batch?.AlreadyAbsentCount ?? 0,
            batch?.RejectedCount ?? 0,
            batch?.FailedCount ?? 0,
            batch?.ProcessedCount ?? 0,
            batch?.TotalSelectedItems ?? 0,
            batch?.RecycledBytes ?? 0,
            batch?.Cancelled ?? false);

        try
        {
            await _operationHistoryService.RecordAsync(entry, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
    }

    private sealed record LeftoverWorkItem(
        LeftoverCandidate Candidate,
        DeletionCandidateDescriptor Descriptor);
}
