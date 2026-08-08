using System.Reflection;
using System.Net;
using System.Text.Json.Nodes;
using BurrowWin.Models;
using BurrowWin.Services;
using Xunit;

namespace BurrowWin.Tests;

public sealed class LocalMcpServerServiceTests
{
    [Fact]
    public void RequestGate_RequiresCredentialAndRejectsHostOrBrowserRequests()
    {
        const string token = "test-query-token";
        Assert.Equal(LocalRequestDecision.Allowed, EvaluateRequest(token));
        Assert.Equal(LocalRequestDecision.Unauthorized, EvaluateRequest(token, includeCredential: false));
        Assert.Equal(LocalRequestDecision.Unauthorized, EvaluateRequest(token, authorization: "Bearer wrong"));
        Assert.Equal(LocalRequestDecision.Forbidden, EvaluateRequest(token, host: "attacker.example"));
        Assert.Equal(LocalRequestDecision.Forbidden, EvaluateRequest(token, host: null));
        Assert.Equal(LocalRequestDecision.Forbidden, EvaluateRequest(token, origin: "http://localhost:3000"));
        Assert.Equal(LocalRequestDecision.Forbidden, EvaluateRequest(token, origin: "https://example.com"));
        Assert.Equal(LocalRequestDecision.Forbidden, EvaluateRequest(token, secFetchSite: "cross-site"));
        Assert.Equal(LocalRequestDecision.Forbidden,
            EvaluateRequest(token, remoteAddress: IPAddress.Parse("192.168.1.10")));
    }

    [Fact]
    public void RequestGate_ConstrainsMethodsContentTypesAndPayloadSize()
    {
        const string token = "test-query-token";
        Assert.Equal(LocalRequestDecision.Allowed,
            EvaluateRequest(token, path: "/mcp", method: "POST",
                contentType: "application/json; charset=utf-8", contentLength: 512));
        Assert.Equal(LocalRequestDecision.MethodNotAllowed,
            EvaluateRequest(token, path: "/health", method: "POST",
                contentType: "application/json", contentLength: 2));
        Assert.Equal(LocalRequestDecision.UnsupportedMediaType,
            EvaluateRequest(token, path: "/mcp", method: "POST",
                contentType: "text/plain", contentLength: 2));
        Assert.Equal(LocalRequestDecision.PayloadTooLarge,
            EvaluateRequest(token, path: "/mcp", method: "POST",
                contentType: "application/json", contentLength: 64 * 1024 + 1));
        Assert.Equal(LocalRequestDecision.BadRequest,
            EvaluateRequest(token, path: "/health", method: "GET", contentLength: 1));
    }

    [Fact]
    public void RequestRateLimiter_RejectsBurstPastLimitAndRecovers()
    {
        var limiter = new LocalRequestRateLimiter(limit: 2, window: TimeSpan.FromSeconds(60));
        var start = DateTimeOffset.Parse("2026-08-08T00:00:00Z");
        Assert.True(limiter.Allow(start));
        Assert.True(limiter.Allow(start.AddSeconds(1)));
        Assert.False(limiter.Allow(start.AddSeconds(2)));
        Assert.True(limiter.Allow(start.AddSeconds(61)));
    }

    [Fact]
    public void ShouldBlockRestEndpoint_AllowsMcpWhenRestIsDisabled()
    {
        Assert.True(LocalMcpServerService.ShouldBlockRestEndpoint(false, "/health", "GET"));
        Assert.True(LocalMcpServerService.ShouldBlockRestEndpoint(false, "/mcp", "GET"));
        Assert.False(LocalMcpServerService.ShouldBlockRestEndpoint(false, "/mcp", "POST"));
        Assert.False(LocalMcpServerService.ShouldBlockRestEndpoint(true, "/health", "GET"));
    }

    [Fact]
    public void BuildMcpToolArray_IncludesCanonicalCrossPlatformToolNames()
    {
        var tools = BuildMcpTools();
        var names = tools
            .Select(tool => tool?["name"]?.GetValue<string>())
            .Where(name => name is not null)
            .ToArray();

        Assert.Contains("burrow_list_apps", names);
        Assert.Contains("burrow_purge", names);
        Assert.Contains("burrow_installer", names);
        Assert.Contains("burrow_uninstall", names);
    }

    [Fact]
    public async Task ExecuteToolByNameAsync_RejectsStringConfirm()
    {
        var engine = new FakeMoleEngineService();
        var service = BuildService(engine);
        var arguments = new JsonObject
        {
            ["confirm"] = "true"
        };

        var response = await ExecuteToolAsync(service, "burrow_clean", arguments);

        Assert.True(response.ContainsKey("error"));
        Assert.Contains("confirm", response["error"]!.GetValue<string>(), StringComparison.OrdinalIgnoreCase);
        Assert.Equal(0, engine.ExecuteCount);
    }

    [Fact]
    public async Task ExecuteToolByNameAsync_RejectsStringHistoryLimit()
    {
        var service = BuildService(new FakeMoleEngineService());
        var arguments = new JsonObject
        {
            ["limit"] = "24"
        };

        var response = await ExecuteToolAsync(service, "burrow_history", arguments);

        Assert.True(response.ContainsKey("error"));
        Assert.Contains("limit", response["error"]!.GetValue<string>(), StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task ExecuteToolByNameAsync_ListAppsUsesCanonicalToolName()
    {
        var appService = new FakeInstalledApplicationService();
        appService.Apps.Add(new InstalledApplication(
            "test-app",
            "Test App",
            "Example Publisher",
            "1.0",
            @"C:\Users\me\AppData\Local\Test App",
            "uninstall.exe",
            "Registry",
            2048));
        var service = BuildService(new FakeMoleEngineService(), appService: appService);

        var response = await ExecuteToolAsync(service, "burrow_list_apps", new JsonObject());

        Assert.Equal("burrow_list_apps", response["tool"]!.GetValue<string>());
        Assert.Equal(1, response["count"]!.GetValue<int>());
        Assert.Equal(1, response["returned"]!.GetValue<int>());
    }

    [Fact]
    public async Task ExecuteToolByNameAsync_PurgeIsPreviewOnly()
    {
        var service = BuildService(
            new FakeMoleEngineService(),
            purgeService: new FakePurgeArtifactService());
        var arguments = new JsonObject
        {
            ["confirm"] = true
        };

        var response = await ExecuteToolAsync(service, "burrow_purge", arguments);

        Assert.Equal("preview", response["action"]!.GetValue<string>());
        Assert.True(response["confirm_requested"]!.GetValue<bool>());
        Assert.False(response["mcp_removal_supported"]!.GetValue<bool>());
        Assert.Equal(1, response["count"]!.GetValue<int>());
    }

    [Fact]
    public async Task ExecuteToolByNameAsync_InstallerIsPreviewOnly()
    {
        var service = BuildService(
            new FakeMoleEngineService(),
            installerService: new FakeInstallerCleanupService());
        var arguments = new JsonObject
        {
            ["confirm"] = true
        };

        var response = await ExecuteToolAsync(service, "burrow_installer", arguments);

        Assert.Equal("preview", response["action"]!.GetValue<string>());
        Assert.True(response["confirm_requested"]!.GetValue<bool>());
        Assert.False(response["mcp_removal_supported"]!.GetValue<bool>());
        Assert.Equal(1, response["count"]!.GetValue<int>());
    }

    private static LocalMcpServerService BuildService(
        FakeMoleEngineService engine,
        FakeInstalledApplicationService? appService = null,
        FakePurgeArtifactService? purgeService = null,
        FakeInstallerCleanupService? installerService = null,
        FakeApplicationSettingsService? settingsService = null)
    {
        return new LocalMcpServerService(
            engine,
            new FakeDiskAnalyzerService(),
            new FakeTelemetrySamplerService(),
            new FakeTelemetryHistoryService(),
            appService ?? new FakeInstalledApplicationService(),
            purgeService ?? new FakePurgeArtifactService([]),
            installerService ?? new FakeInstallerCleanupService([]),
            new FakeOperationHistoryService(),
            settingsService ?? new FakeApplicationSettingsService());
    }

    private static LocalRequestDecision EvaluateRequest(
        string expectedToken,
        IPAddress? remoteAddress = null,
        string? host = "127.0.0.1:9277",
        string? origin = null,
        string? secFetchSite = null,
        bool includeCredential = true,
        string? authorization = null,
        string path = "/health",
        string method = "GET",
        string? contentType = null,
        long contentLength = 0)
    {
        if (includeCredential && authorization is null)
        {
            authorization = $"Bearer {expectedToken}";
        }
        return LocalMcpServerService.EvaluateRequest(
            remoteAddress ?? IPAddress.Loopback,
            host,
            origin,
            secFetchSite,
            authorization,
            expectedToken,
            LocalMcpServerService.DefaultPort,
            path,
            method,
            contentType,
            contentLength);
    }

    private static async Task<JsonObject> ExecuteToolAsync(
        LocalMcpServerService service,
        string name,
        JsonObject arguments)
    {
        var method = typeof(LocalMcpServerService).GetMethod(
            "ExecuteToolByNameAsync",
            BindingFlags.Instance | BindingFlags.NonPublic);
        Assert.NotNull(method);

        var task = (Task<JsonObject>)method.Invoke(
            service,
            [name, arguments, CancellationToken.None])!;
        return await task.ConfigureAwait(false);
    }

    private static JsonArray BuildMcpTools()
    {
        var method = typeof(LocalMcpServerService).GetMethod(
            "BuildMcpToolArray",
            BindingFlags.Static | BindingFlags.NonPublic);
        Assert.NotNull(method);

        return (JsonArray)method.Invoke(null, [])!;
    }

    private sealed class FakeMoleEngineService : IMoleEngineService
    {
        public int ExecuteCount { get; private set; }

        public MoleEngineAvailability GetAvailability()
        {
            return new MoleEngineAvailability(true, "mole.ps1", MoleEngineKind.PowerShellScript, "available");
        }

        public Task<MoleCommandResult> ExecuteCommandAsync(
            string arguments,
            Action<string>? onProgress = null,
            CancellationToken cancellationToken = default)
        {
            ExecuteCount++;
            return Task.FromResult(new MoleCommandResult(0, "ok", string.Empty, false, TimeSpan.Zero));
        }

        public Task<MoleCommandResult> ExecuteAsync(
            IReadOnlyList<string> arguments,
            Action<string>? onProgress = null,
            CancellationToken cancellationToken = default)
        {
            ExecuteCount++;
            return Task.FromResult(new MoleCommandResult(0, "ok", string.Empty, false, TimeSpan.Zero));
        }
    }

    private sealed class FakeDiskAnalyzerService : IDiskAnalyzerService
    {
        public Task<DiskUsageNode> AnalyzeAsync(
            string rootPath,
            DiskAnalysisOptions options,
            CancellationToken cancellationToken = default)
        {
            return Task.FromResult(new DiskUsageNode("root", rootPath, 0, 100, []));
        }
    }

    private sealed class FakeTelemetrySamplerService : ISystemTelemetrySamplerService
    {
        public TimeSpan SamplingInterval => TimeSpan.FromSeconds(60);

        public string Source => "test";

        public SystemTelemetrySnapshot? LatestSnapshot => null;

        public Task<SystemTelemetrySnapshot> SampleNowAsync(CancellationToken cancellationToken = default)
        {
            return Task.FromResult(Snapshot());
        }
    }

    private sealed class FakeTelemetryHistoryService : ISystemTelemetryHistoryService
    {
        public string HistoryFilePath => "history.jsonl";

        public Task RecordAsync(SystemTelemetrySnapshot snapshot, CancellationToken cancellationToken = default)
        {
            return Task.CompletedTask;
        }

        public Task<IReadOnlyList<SystemTelemetrySnapshot>> ReadRecentAsync(int limit, CancellationToken cancellationToken = default)
        {
            return Task.FromResult<IReadOnlyList<SystemTelemetrySnapshot>>([]);
        }
    }

    private sealed class FakeInstalledApplicationService : IInstalledApplicationService
    {
        public List<InstalledApplication> Apps { get; } = [];

        public Task<IReadOnlyList<InstalledApplication>> GetInstalledApplicationsAsync(CancellationToken cancellationToken = default)
        {
            return Task.FromResult<IReadOnlyList<InstalledApplication>>(Apps);
        }

        public Task<IReadOnlyList<LeftoverCandidate>> PreviewLeftoversAsync(
            InstalledApplication application,
            CancellationToken cancellationToken = default)
        {
            return Task.FromResult<IReadOnlyList<LeftoverCandidate>>([]);
        }

        public Task<MoleCommandResult> LaunchUninstallerAsync(
            InstalledApplication application,
            CancellationToken cancellationToken = default)
        {
            return Task.FromResult(new MoleCommandResult(0, "ok", string.Empty, false, TimeSpan.Zero));
        }

        public ConfirmedDeletionAuthorization ConfirmLeftoverRemoval(IReadOnlyList<LeftoverCandidate> leftovers)
        {
            return ConfirmedDeletionAuthorization.Confirm(
                DestructiveFlow.UninstallLeftovers,
                leftovers.Select(item => new DeletionCandidateDescriptor(
                    item.Path,
                    item.ApprovedScopeRoot,
                    DestructiveFlow.UninstallLeftovers,
                    item.Category,
                    DeletionItemType.Directory,
                    item.SizeBytes)));
        }

        public Task<DeletionBatchResult> RemoveLeftoversAsync(
            IReadOnlyList<LeftoverCandidate> leftovers,
            ConfirmedDeletionAuthorization authorization,
            IProgress<DeletionProgress>? progress = null,
            CancellationToken cancellationToken = default)
        {
            return Task.FromResult(EmptyBatch(leftovers.Count, authorization.OperationId));
        }
    }

    private sealed class FakePurgeArtifactService : IPurgeArtifactService
    {
        private readonly IReadOnlyList<PurgeProjectCandidate> _projects;

        public FakePurgeArtifactService()
            : this([
                new PurgeProjectCandidate(
                    "sample",
                    @"C:\Users\me\sample",
                    "package.json",
                    [
                        new PurgeArtifactCandidate(
                            "node_modules",
                            @"C:\Users\me\sample\node_modules",
                            "dependency cache",
                            "node",
                            4096)
                    ])
            ])
        {
        }

        public FakePurgeArtifactService(IReadOnlyList<PurgeProjectCandidate> projects)
        {
            _projects = projects;
        }

        public Task<IReadOnlyList<PurgeProjectCandidate>> PreviewAsync(
            IReadOnlyList<string>? searchRoots = null,
            CancellationToken cancellationToken = default)
        {
            return Task.FromResult(_projects);
        }

        public ConfirmedDeletionAuthorization ConfirmRemoval(IReadOnlyList<PurgeProjectCandidate> projects)
        {
            return ConfirmedDeletionAuthorization.Confirm(
                DestructiveFlow.Purge,
                projects.SelectMany(project => project.Artifacts.Select(artifact =>
                    new DeletionCandidateDescriptor(
                        artifact.Path,
                        project.Path,
                        DestructiveFlow.Purge,
                        artifact.Type,
                        DeletionItemType.Directory,
                        artifact.SizeBytes))));
        }

        public Task<DeletionBatchResult> RemoveAsync(
            IReadOnlyList<PurgeProjectCandidate> projects,
            ConfirmedDeletionAuthorization authorization,
            IProgress<DeletionProgress>? progress = null,
            CancellationToken cancellationToken = default)
        {
            return Task.FromResult(EmptyBatch(projects.Sum(project => project.ArtifactCount), authorization.OperationId));
        }
    }

    private sealed class FakeInstallerCleanupService : IInstallerCleanupService
    {
        private readonly IReadOnlyList<InstallerCleanupCandidate> _candidates;

        public FakeInstallerCleanupService()
            : this([
                new InstallerCleanupCandidate(
                    "setup.exe",
                    @"C:\Users\me\Downloads\setup.exe",
                    "Installer",
                    8192,
                    DateTimeOffset.UtcNow.AddDays(-40))
            ])
        {
        }

        public FakeInstallerCleanupService(IReadOnlyList<InstallerCleanupCandidate> candidates)
        {
            _candidates = candidates;
        }

        public Task<IReadOnlyList<InstallerCleanupCandidate>> PreviewAsync(CancellationToken cancellationToken = default)
        {
            return Task.FromResult(_candidates);
        }

        public ConfirmedDeletionAuthorization ConfirmRemoval(IReadOnlyList<InstallerCleanupCandidate> candidates)
        {
            return ConfirmedDeletionAuthorization.Confirm(
                DestructiveFlow.Installer,
                candidates.Select(candidate => new DeletionCandidateDescriptor(
                    candidate.Path,
                    Path.GetDirectoryName(candidate.Path)!,
                    DestructiveFlow.Installer,
                    candidate.Kind,
                    DeletionItemType.File,
                    candidate.SizeBytes,
                    candidate.LastWriteTime)));
        }

        public Task<DeletionBatchResult> RemoveAsync(
            IReadOnlyList<InstallerCleanupCandidate> candidates,
            ConfirmedDeletionAuthorization authorization,
            IProgress<DeletionProgress>? progress = null,
            CancellationToken cancellationToken = default)
        {
            return Task.FromResult(EmptyBatch(candidates.Count, authorization.OperationId));
        }
    }

    private static DeletionBatchResult EmptyBatch(int total, string operationId) =>
        new(
            [],
            total,
            0,
            0,
            0,
            0,
            total,
            false,
            0,
            0,
            null,
            null,
            DeletionBatchOutcome.Failed,
            0,
            operationId);

    private sealed class FakeOperationHistoryService : IOperationHistoryService
    {
        public string HistoryFilePath => "activity.jsonl";

        public Task RecordAsync(OperationHistoryEntry entry, CancellationToken cancellationToken = default)
        {
            return Task.CompletedTask;
        }

        public Task<IReadOnlyList<OperationHistoryEntry>> ReadRecentAsync(int limit, CancellationToken cancellationToken = default)
        {
            return Task.FromResult<IReadOnlyList<OperationHistoryEntry>>([]);
        }
    }

    private sealed class FakeApplicationSettingsService : IApplicationSettingsService
    {
        public string SettingsFilePath => "settings.json";

        public BurrowSettings Current { get; } = new()
        {
            HttpServerEnabled = false,
            McpDestructiveActionsEnabled = true
        };

        public event EventHandler<BurrowSettings>? SettingsChanged;

        public Task<BurrowSettings> SaveAsync(BurrowSettings settings, CancellationToken cancellationToken = default)
        {
            SettingsChanged?.Invoke(this, settings);
            return Task.FromResult(settings);
        }

        public BurrowSettings Reload()
        {
            return Current;
        }
    }

    private static SystemTelemetrySnapshot Snapshot()
    {
        return new SystemTelemetrySnapshot(
            DateTimeOffset.UtcNow,
            1,
            2,
            3,
            4,
            5,
            6,
            7,
            8,
            9,
            "GPU 0%",
            []);
    }
}
