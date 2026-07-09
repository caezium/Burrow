using System.Net;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using BurrowWin.Models;
using Microsoft.Extensions.Hosting;

namespace BurrowWin.Services;

public sealed class LocalMcpServerService : BackgroundService
{
    public const int DefaultPort = 9277;
    private const string ProtocolVersion = "2025-11-25";

    private readonly IMoleEngineService _moleEngineService;
    private readonly IDiskAnalyzerService _diskAnalyzerService;
    private readonly ISystemTelemetrySamplerService _telemetrySamplerService;
    private readonly ISystemTelemetryHistoryService _systemTelemetryHistoryService;
    private readonly IInstalledApplicationService _installedApplicationService;
    private readonly IPurgeArtifactService _purgeArtifactService;
    private readonly IInstallerCleanupService _installerCleanupService;
    private readonly IOperationHistoryService _operationHistoryService;
    private readonly IApplicationSettingsService _settingsService;
    private readonly SemaphoreSlim _listenerGate = new(1, 1);
    private HttpListener? _listener;
    private Task? _listenerTask;
    private int _activePort = DefaultPort;
    private bool _activeHttpEnabled;

    public LocalMcpServerService(
        IMoleEngineService moleEngineService,
        IDiskAnalyzerService diskAnalyzerService,
        ISystemTelemetrySamplerService telemetrySamplerService,
        ISystemTelemetryHistoryService systemTelemetryHistoryService,
        IInstalledApplicationService installedApplicationService,
        IPurgeArtifactService purgeArtifactService,
        IInstallerCleanupService installerCleanupService,
        IOperationHistoryService operationHistoryService,
        IApplicationSettingsService settingsService)
    {
        _moleEngineService = moleEngineService;
        _diskAnalyzerService = diskAnalyzerService;
        _telemetrySamplerService = telemetrySamplerService;
        _systemTelemetryHistoryService = systemTelemetryHistoryService;
        _installedApplicationService = installedApplicationService;
        _purgeArtifactService = purgeArtifactService;
        _installerCleanupService = installerCleanupService;
        _operationHistoryService = operationHistoryService;
        _settingsService = settingsService;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _settingsService.SettingsChanged += OnSettingsChanged;
        await ApplyHttpSettingsAsync(_settingsService.Current, stoppingToken).ConfigureAwait(false);

        try
        {
            await Task.Delay(Timeout.InfiniteTimeSpan, stoppingToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
        }
        finally
        {
            _settingsService.SettingsChanged -= OnSettingsChanged;
            await StopListenerAsync(CancellationToken.None).ConfigureAwait(false);
        }
    }

    public override async Task StopAsync(CancellationToken cancellationToken)
    {
        await StopListenerAsync(cancellationToken).ConfigureAwait(false);
        await base.StopAsync(cancellationToken).ConfigureAwait(false);
    }

    private void OnSettingsChanged(object? sender, BurrowSettings settings)
    {
        _ = Task.Run(async () =>
        {
            try
            {
                await ApplyHttpSettingsAsync(settings, CancellationToken.None).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is HttpListenerException or InvalidOperationException or ObjectDisposedException)
            {
            }
        });
    }

    private async Task ApplyHttpSettingsAsync(BurrowSettings settings, CancellationToken cancellationToken)
    {
        var normalized = BurrowSettings.Normalize(settings);
        await _listenerGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var action = HttpServerSettingsPlanner.Plan(_activeHttpEnabled, _activePort, normalized);
            if (action == HttpServerSettingsAction.None)
            {
                return;
            }

            await StopListenerLockedAsync().ConfigureAwait(false);
            _activePort = normalized.HttpServerPort;

            var listener = new HttpListener();
            listener.Prefixes.Add($"http://127.0.0.1:{_activePort}/");
            listener.Start();

            _listener = listener;
            _activeHttpEnabled = true;
            _listenerTask = Task.Run(() => ListenAsync(listener, cancellationToken), CancellationToken.None);
        }
        catch
        {
            _activeHttpEnabled = false;
        }
        finally
        {
            _listenerGate.Release();
        }
    }

    private async Task StopListenerAsync(CancellationToken cancellationToken)
    {
        await _listenerGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await StopListenerLockedAsync().ConfigureAwait(false);
        }
        finally
        {
            _listenerGate.Release();
        }
    }

    private async Task StopListenerLockedAsync()
    {
        var listener = _listener;
        var listenerTask = _listenerTask;
        _listener = null;
        _listenerTask = null;
        _activeHttpEnabled = false;

        if (listener is not null)
        {
            try
            {
                if (listener.IsListening)
                {
                    listener.Stop();
                }
            }
            catch
            {
            }
            finally
            {
                listener.Close();
            }
        }

        if (listenerTask is null)
        {
            return;
        }

        try
        {
            await listenerTask.WaitAsync(TimeSpan.FromSeconds(2)).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is OperationCanceledException or TimeoutException or HttpListenerException or ObjectDisposedException)
        {
        }
    }

    private async Task ListenAsync(HttpListener listener, CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            HttpListenerContext context;
            try
            {
                context = await listener.GetContextAsync().WaitAsync(stoppingToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception ex) when (ex is HttpListenerException or InvalidOperationException or ObjectDisposedException)
            {
                break;
            }
            catch
            {
                continue;
            }

            _ = Task.Run(() => HandleRequestAsync(context, stoppingToken), CancellationToken.None);
        }
    }

    private async Task HandleRequestAsync(HttpListenerContext context, CancellationToken cancellationToken)
    {
        if (!IsRequestAllowed(context.Request.RemoteEndPoint?.Address, context.Request.Headers["Origin"]))
        {
            context.Response.StatusCode = StatusCodes.Status403Forbidden;
            context.Response.Close();
            return;
        }

        var path = context.Request.Url?.AbsolutePath.TrimEnd('/').ToLowerInvariant() ?? string.Empty;
        var response = ShouldBlockRestEndpoint(_settingsService.Current.HttpServerEnabled, path, context.Request.HttpMethod)
            ? new JsonObject
            {
                ["error"] = "HTTP REST endpoints are disabled in BurrowWin Settings. Local stdio MCP remains available through /mcp."
            }
            : path switch
        {
            "" or "/health" => BuildHealth(),
            "/info" => await BuildInfoAsync(cancellationToken),
            "/snapshot" => await CaptureSnapshotAsync(cancellationToken),
            "/metrics" => await CaptureMetricsAsync(context.Request, cancellationToken),
            "/tools" => BuildTools(),
            "/mcp" when context.Request.HttpMethod == "POST" => await HandleMcpJsonRpcAsync(context.Request, cancellationToken),
            "/tools/call" when context.Request.HttpMethod == "POST" => await CallToolAsync(context.Request, cancellationToken),
            _ => new JsonObject { ["error"] = "unknown route" }
        };

        await WriteJsonAsync(context.Response, response, cancellationToken);
    }

    private JsonObject BuildHealth()
    {
        var availability = _moleEngineService.GetAvailability();
        return new JsonObject
        {
            ["ok"] = true,
            ["app"] = "BurrowWin",
            ["port"] = _activePort,
            ["http_enabled"] = _settingsService.Current.HttpServerEnabled,
            ["engine_available"] = availability.IsAvailable,
            ["engine_path"] = availability.Path,
            ["engine_kind"] = availability.Kind.ToString(),
            ["sampler_source"] = _telemetrySamplerService.Source,
            ["latest_sample_at"] = _telemetrySamplerService.LatestSnapshot?.CapturedAt.ToString("O")
        };
    }

    private async Task<JsonObject> BuildInfoAsync(CancellationToken cancellationToken)
    {
        var recent = await _systemTelemetryHistoryService.ReadRecentAsync(1, cancellationToken).ConfigureAwait(false);
        return new JsonObject
        {
            ["app"] = "BurrowWin",
            ["settings_path"] = _settingsService.SettingsFilePath,
            ["http_enabled"] = _settingsService.Current.HttpServerEnabled,
            ["http_port"] = _settingsService.Current.HttpServerPort,
            ["sampler_source"] = _telemetrySamplerService.Source,
            ["sampling_interval_seconds"] = _telemetrySamplerService.SamplingInterval.TotalSeconds,
            ["history_retention_days"] = _settingsService.Current.HistoryRetentionDays,
            ["history_path"] = _systemTelemetryHistoryService.HistoryFilePath,
            ["activity_path"] = _operationHistoryService.HistoryFilePath,
            ["mcp_destructive_actions_enabled"] = _settingsService.Current.McpDestructiveActionsEnabled,
            ["latest_sample_at"] = _telemetrySamplerService.LatestSnapshot?.CapturedAt.ToString("O")
                ?? recent.FirstOrDefault()?.CapturedAt.ToString("O"),
            ["mcp_stdio_command"] = "Assets\\Mcp\\burrow-mcp-stdio.exe"
        };
    }

    private static JsonObject BuildTools()
    {
        return new JsonObject
        {
            ["tools"] = new JsonArray
            {
                Tool("burrow_clean", "Preview or run Mole cleanup. Defaults to dry-run unless confirm is true."),
                Tool("burrow_optimize", "Preview or run Mole optimize. Defaults to dry-run unless confirm is true."),
                Tool("burrow_snapshot", "Return current Windows telemetry used by the Dashboard fallback."),
                Tool("burrow_history", "Return recent Windows telemetry snapshots recorded by BurrowWin."),
                Tool("burrow_top_processes", "Return process CPU or memory leaders from recent telemetry history."),
                Tool("burrow_process_usage", "Rank process usage over recent telemetry history by CPU or memory."),
                Tool("burrow_info", "Return what BurrowWin is recording and where local MCP/HTTP state is stored."),
                Tool("burrow_engine", "Return Mole engine availability for BurrowWin."),
                Tool("burrow_analyze", "Analyze a directory and return a size-ranked tree. Uses native Windows fallback until Mole Windows exposes analyze JSON."),
                Tool("burrow_list_apps", "Return installed Windows applications. Read-only."),
                Tool("burrow_purge", "Preview Windows project artifact purge candidates. Real removal must be run from the BurrowWin GUI."),
                Tool("burrow_installer", "Preview old installer/archive cleanup candidates. Real removal must be run from the BurrowWin GUI."),
                Tool("burrow_uninstall", "Windows compatibility tool: list apps, preview leftovers, or launch a confirmed vendor uninstaller.")
            }
        };
    }

    private async Task<JsonObject> CallToolAsync(HttpListenerRequest request, CancellationToken cancellationToken)
    {
        var startedAt = Stopwatch.GetTimestamp();
        var name = string.Empty;
        var arguments = new JsonObject();

        try
        {
            using var reader = new StreamReader(request.InputStream, request.ContentEncoding);
            var body = await reader.ReadToEndAsync(cancellationToken).ConfigureAwait(false);
            var node = string.IsNullOrWhiteSpace(body) ? new JsonObject() : JsonNode.Parse(body)?.AsObject();
            if (node is null)
            {
                return ToolError("Request body must be a JSON object.");
            }

            if (!TryReadOptionalString(node, "name", string.Empty, out name, out var nameError))
            {
                return ToolError(nameError);
            }

            if (!TryReadOptionalObject(node, "arguments", out arguments, out var argumentsError))
            {
                return ToolError(argumentsError);
            }

            var response = await ExecuteToolByNameAsync(name, arguments, cancellationToken).ConfigureAwait(false);
            await RecordToolHistoryAsync(name, arguments, response, startedAt).ConfigureAwait(false);
            return response;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            var response = ToolError(ex.Message);
            await RecordToolHistoryAsync(name, arguments, response, startedAt).ConfigureAwait(false);
            return response;
        }
    }

    private async Task<JsonObject> HandleMcpJsonRpcAsync(HttpListenerRequest request, CancellationToken cancellationToken)
    {
        JsonNode? id = null;
        try
        {
            using var reader = new StreamReader(request.InputStream, request.ContentEncoding);
            var body = await reader.ReadToEndAsync(cancellationToken).ConfigureAwait(false);
            var node = string.IsNullOrWhiteSpace(body) ? new JsonObject() : JsonNode.Parse(body)?.AsObject();
            if (node is null)
            {
                throw new InvalidOperationException("JSON-RPC request must be a JSON object.");
            }

            id = node["id"]?.DeepClone();
            if (!TryReadOptionalString(node, "method", string.Empty, out var method, out var methodError))
            {
                throw new InvalidOperationException(methodError);
            }

            var result = method switch
            {
                "initialize" => BuildMcpInitializeResult(),
                "tools/list" => new JsonObject { ["tools"] = BuildMcpToolArray() },
                "tools/call" => await HandleMcpToolCallAsync(node?["params"]?.AsObject() ?? new JsonObject(), cancellationToken).ConfigureAwait(false),
                _ => throw new InvalidOperationException($"Unsupported MCP method: {method}")
            };

            return new JsonObject
            {
                ["jsonrpc"] = "2.0",
                ["id"] = id,
                ["result"] = result
            };
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return new JsonObject
            {
                ["jsonrpc"] = "2.0",
                ["id"] = id,
                ["error"] = new JsonObject
                {
                    ["code"] = ex is InvalidOperationException or JsonException ? -32602 : -32603,
                    ["message"] = ex.Message
                }
            };
        }
    }

    private async Task<JsonObject> HandleMcpToolCallAsync(JsonObject parameters, CancellationToken cancellationToken)
    {
        if (!TryReadOptionalString(parameters, "name", string.Empty, out var name, out var nameError))
        {
            return BuildMcpToolResult(ToolError(nameError));
        }

        if (!TryReadOptionalObject(parameters, "arguments", out var arguments, out var argumentsError))
        {
            return BuildMcpToolResult(ToolError(argumentsError));
        }

        var startedAt = Stopwatch.GetTimestamp();
        var response = await ExecuteToolByNameAsync(name, arguments, cancellationToken).ConfigureAwait(false);
        await RecordToolHistoryAsync(name, arguments, response, startedAt).ConfigureAwait(false);

        return BuildMcpToolResult(response);
    }

    private static JsonObject BuildMcpToolResult(JsonObject response)
    {
        return new JsonObject
        {
            ["content"] = new JsonArray
            {
                new JsonObject
                {
                    ["type"] = "text",
                    ["text"] = response.ToJsonString(new JsonSerializerOptions { WriteIndented = false })
                }
            },
            ["isError"] = IsErrorToolResponse(response)
        };
    }

    private async Task<JsonObject> ExecuteToolByNameAsync(
        string name,
        JsonObject arguments,
        CancellationToken cancellationToken)
    {
        return name switch
        {
            "burrow_clean" => await RunActionToolAsync("clean", arguments, cancellationToken),
            "burrow_optimize" => await RunActionToolAsync("optimize", arguments, cancellationToken),
            "burrow_snapshot" => await CaptureSnapshotAsync(cancellationToken),
            "burrow_history" => await CaptureHistoryAsync(arguments, cancellationToken),
            "burrow_top_processes" => await CaptureTopProcessesAsync(arguments, cancellationToken),
            "burrow_process_usage" => await CaptureProcessUsageAsync(arguments, cancellationToken),
            "burrow_info" => await BuildInfoAsync(cancellationToken),
            "burrow_engine" => BuildHealth(),
            "burrow_analyze" => await AnalyzeAsync(arguments, cancellationToken),
            "burrow_list_apps" => await ListAppsAsync(arguments, cancellationToken),
            "burrow_purge" => await PreviewPurgeAsync(arguments, cancellationToken),
            "burrow_installer" => await PreviewInstallerAsync(arguments, cancellationToken),
            "burrow_uninstall" => await UninstallAsync(arguments, cancellationToken),
            _ => new JsonObject { ["error"] = $"unknown tool: {name}" }
        };
    }

    private async Task<JsonObject> RunActionToolAsync(string command, JsonObject arguments, CancellationToken cancellationToken)
    {
        if (!TryReadOptionalBoolean(arguments, "confirm", false, out var confirm, out var confirmError))
        {
            return ToolError(confirmError);
        }

        if (confirm && !_settingsService.Current.McpDestructiveActionsEnabled)
        {
            return new JsonObject
            {
                ["command"] = command,
                ["supported"] = false,
                ["reason"] = "Enable MCP destructive actions in BurrowWin Settings before running confirmed maintenance through MCP."
            };
        }

        var effectiveCommand = confirm ? command : $"{command} --dry-run";

        // Prefer the bundled conductor: `burrow <command> [--apply] --json` runs the bundled
        // engine with the stable envelope + classified errors. burrow defaults to dry-run, so a
        // confirmed (live) run adds --apply via BurrowConductorService.ActionArguments (the
        // mo→burrow inversion). Any conductor miss falls through to the direct engine below.
        var conductor = new BurrowConductorService();
        if (conductor.IsAvailable)
        {
            try
            {
                var envelope = await conductor.CaptureAsync(
                    command, BurrowConductorService.ActionArguments(confirm), cancellationToken);
                return new JsonObject
                {
                    ["command"] = effectiveCommand,
                    ["dry_run"] = !confirm,
                    ["exit_code"] = 0,
                    ["succeeded"] = true,
                    ["stdout"] = ExtractEngineText(envelope.Data),
                    ["stderr"] = string.Empty
                };
            }
            catch (BurrowConductorException ex)
            {
                return new JsonObject
                {
                    ["command"] = effectiveCommand,
                    ["dry_run"] = !confirm,
                    ["exit_code"] = 1,
                    ["succeeded"] = false,
                    ["stdout"] = string.Empty,
                    ["stderr"] = $"{ex.Message} [{ex.Kind}]"
                };
            }
            catch (InvalidOperationException)
            {
                // Conductor vanished between IsAvailable and the run — fall through to the engine.
            }
        }

        var result = await _moleEngineService.ExecuteCommandAsync(effectiveCommand, cancellationToken: cancellationToken);

        return new JsonObject
        {
            ["command"] = effectiveCommand,
            ["dry_run"] = !confirm,
            ["exit_code"] = result.ExitCode,
            ["succeeded"] = result.Succeeded,
            ["stdout"] = result.StandardOutput,
            ["stderr"] = result.StandardError
        };
    }

    // clean/optimize return their report as data.text; unwrap it so the MCP consumer sees the
    // engine's text (as with the direct path), else fall back to the raw payload.
    private static string ExtractEngineText(JsonElement data)
    {
        if (data.ValueKind == JsonValueKind.Object && data.TryGetProperty("text", out var text))
        {
            return text.GetString() ?? string.Empty;
        }

        return data.ValueKind == JsonValueKind.Undefined ? string.Empty : data.GetRawText();
    }

    private async Task<JsonObject> CaptureSnapshotAsync(CancellationToken cancellationToken)
    {
        var snapshot = _telemetrySamplerService.LatestSnapshot
            ?? await _telemetrySamplerService.SampleNowAsync(cancellationToken).ConfigureAwait(false);
        return SnapshotToJson(snapshot, _telemetrySamplerService.Source);
    }

    private async Task<JsonObject> CaptureMetricsAsync(HttpListenerRequest request, CancellationToken cancellationToken)
    {
        var limit = Math.Clamp(ParseIntQuery(request, "limit", 120), 1, 1000);
        var snapshots = await _systemTelemetryHistoryService.ReadRecentAsync(limit, cancellationToken).ConfigureAwait(false);
        return new JsonObject
        {
            ["source"] = "burrowwin_local_history",
            ["history_path"] = _systemTelemetryHistoryService.HistoryFilePath,
            ["count"] = snapshots.Count,
            ["snapshots"] = new JsonArray(snapshots.Select(snapshot => SnapshotToJson(snapshot, "history")).ToArray<JsonNode?>())
        };
    }

    private async Task<JsonObject> CaptureHistoryAsync(JsonObject arguments, CancellationToken cancellationToken)
    {
        if (!TryReadOptionalInt(arguments, "limit", 24, out var requestedLimit, out var limitError))
        {
            return ToolError(limitError);
        }

        var limit = Math.Clamp(requestedLimit, 1, 500);
        var snapshots = await _systemTelemetryHistoryService.ReadRecentAsync(limit, cancellationToken).ConfigureAwait(false);
        return new JsonObject
        {
            ["source"] = "burrowwin_local_history",
            ["history_path"] = _systemTelemetryHistoryService.HistoryFilePath,
            ["count"] = snapshots.Count,
            ["snapshots"] = new JsonArray(snapshots.Select(snapshot => SnapshotToJson(snapshot, "history")).ToArray<JsonNode?>())
        };
    }

    private async Task<JsonObject> CaptureTopProcessesAsync(JsonObject arguments, CancellationToken cancellationToken)
    {
        if (!TryReadOptionalInt(arguments, "history_limit", 120, out var requestedHistoryLimit, out var historyLimitError))
        {
            return ToolError(historyLimitError);
        }

        if (!TryReadOptionalInt(arguments, "limit", 10, out var requestedLimit, out var limitError))
        {
            return ToolError(limitError);
        }

        if (!TryReadOptionalString(arguments, "metric", ProcessUsageAggregator.PeakCpuMetric, out var requestedMetric, out var metricError))
        {
            return ToolError(metricError);
        }

        var historyLimit = Math.Clamp(requestedHistoryLimit, 1, 1000);
        var limit = Math.Clamp(requestedLimit, 1, 100);
        var metric = ProcessUsageAggregator.NormalizeMetric(
            requestedMetric);
        var snapshots = await _systemTelemetryHistoryService.ReadRecentAsync(historyLimit, cancellationToken).ConfigureAwait(false);
        var processes = ProcessUsageAggregator.Rank(snapshots, metric, limit);

        return new JsonObject
        {
            ["source"] = "burrowwin_local_history",
            ["metric"] = metric,
            ["history_samples"] = snapshots.Count,
            ["count"] = processes.Count,
            ["processes"] = new JsonArray(processes.Select(ProcessUsageToJson).ToArray<JsonNode?>())
        };
    }

    private async Task<JsonObject> CaptureProcessUsageAsync(JsonObject arguments, CancellationToken cancellationToken)
    {
        if (!TryReadOptionalString(arguments, "metric", "peak_mem", out var requestedMetric, out var metricError))
        {
            return ToolError(metricError);
        }

        if (!TryReadOptionalInt(arguments, "history_limit", 120, out var requestedHistoryLimit, out var historyLimitError))
        {
            return ToolError(historyLimitError);
        }

        if (!TryReadOptionalInt(arguments, "limit", 10, out var requestedLimit, out var limitError))
        {
            return ToolError(limitError);
        }

        var metric = ProcessUsageAggregator.NormalizeMetric(requestedMetric);
        var historyLimit = Math.Clamp(requestedHistoryLimit, 1, 1000);
        var limit = Math.Clamp(requestedLimit, 1, 100);
        var snapshots = await _systemTelemetryHistoryService.ReadRecentAsync(historyLimit, cancellationToken).ConfigureAwait(false);
        var processes = ProcessUsageAggregator.Rank(snapshots, metric, limit);

        return new JsonObject
        {
            ["source"] = "burrowwin_local_history",
            ["metric_requested"] = requestedMetric,
            ["metric_used"] = metric,
            ["history_samples"] = snapshots.Count,
            ["count"] = processes.Count,
            ["processes"] = new JsonArray(processes.Select(ProcessUsageToJson).ToArray<JsonNode?>())
        };
    }

    private static JsonObject ProcessUsageToJson(ProcessUsageSummary summary)
    {
        return new JsonObject
        {
            ["name"] = summary.Name,
            ["process_id"] = summary.ProcessId,
            ["sample_count"] = summary.SampleCount,
            ["peak_working_set_bytes"] = summary.PeakWorkingSetBytes,
            ["average_working_set_bytes"] = summary.AverageWorkingSetBytes,
            ["peak_cpu_usage_percent"] = summary.PeakCpuUsagePercent,
            ["average_cpu_usage_percent"] = summary.AverageCpuUsagePercent,
            ["total_processor_seconds"] = summary.TotalProcessorSeconds,
            ["peak_working_set_text"] = SystemTelemetryFormatter.Bytes(summary.PeakWorkingSetBytes),
            ["average_working_set_text"] = SystemTelemetryFormatter.Bytes((long)summary.AverageWorkingSetBytes),
            ["peak_cpu_usage_text"] = SystemTelemetryFormatter.Percent(summary.PeakCpuUsagePercent),
            ["average_cpu_usage_text"] = SystemTelemetryFormatter.Percent(summary.AverageCpuUsagePercent)
        };
    }

    private static JsonObject SnapshotToJson(SystemTelemetrySnapshot snapshot, string source)
    {
        return new JsonObject
        {
            ["source"] = source,
            ["captured_at"] = snapshot.CapturedAt.ToString("O"),
            ["cpu_usage_percent"] = snapshot.CpuUsagePercent,
            ["memory_usage_percent"] = snapshot.MemoryUsagePercent,
            ["memory_used_bytes"] = snapshot.MemoryUsedBytes,
            ["memory_total_bytes"] = snapshot.MemoryTotalBytes,
            ["disk_usage_percent"] = snapshot.DiskUsagePercent,
            ["disk_used_bytes"] = snapshot.DiskUsedBytes,
            ["disk_total_bytes"] = snapshot.DiskTotalBytes,
            ["network_received_bytes_per_second"] = snapshot.NetworkReceivedBytesPerSecond,
            ["network_sent_bytes_per_second"] = snapshot.NetworkSentBytesPerSecond,
            ["gpu_status"] = snapshot.GpuStatus,
            ["has_battery"] = snapshot.HasBattery,
            ["battery_charge_percent"] = snapshot.BatteryChargePercent,
            ["battery_status"] = snapshot.BatteryStatusText,
            ["battery_health"] = snapshot.BatteryHealthText,
            ["battery_estimated_seconds_remaining"] = snapshot.BatteryEstimatedSecondsRemaining,
            ["top_processes"] = new JsonArray(snapshot.TopProcesses.Select(process => new JsonObject
            {
                ["name"] = process.Name,
                ["process_id"] = process.ProcessId,
                ["working_set_bytes"] = process.WorkingSetBytes,
                ["cpu_usage_percent"] = process.CpuUsagePercent,
                ["total_processor_seconds"] = process.TotalProcessorSeconds
            }).ToArray<JsonNode?>())
        };
    }

    private async Task<JsonObject> AnalyzeAsync(JsonObject arguments, CancellationToken cancellationToken)
    {
        if (!TryReadOptionalString(
                arguments,
                "path",
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                out var path,
                out var pathError))
        {
            return ToolError(pathError);
        }

        if (!TryReadOptionalInt(arguments, "max_depth", 2, out var maxDepth, out var maxDepthError))
        {
            return ToolError(maxDepthError);
        }

        if (!TryReadOptionalInt(arguments, "max_children", 12, out var maxChildren, out var maxChildrenError))
        {
            return ToolError(maxChildrenError);
        }

        try
        {
            var node = await _diskAnalyzerService
                .AnalyzeAsync(path, new DiskAnalysisOptions(maxDepth, maxChildren), cancellationToken)
                .ConfigureAwait(false);

            return new JsonObject
            {
                ["source"] = "windows_native_fallback",
                ["tree"] = NodeToJson(node)
            };
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or DirectoryNotFoundException or OperationCanceledException)
        {
            return new JsonObject
            {
                ["error"] = ex.Message,
                ["path"] = path
            };
        }
    }

    private static JsonObject NodeToJson(Models.DiskUsageNode node)
    {
        return new JsonObject
        {
            ["name"] = node.Name,
            ["path"] = node.Path,
            ["size_bytes"] = node.SizeBytes,
            ["percent_of_parent"] = node.PercentOfParent,
            ["children"] = new JsonArray(node.Children.Select(child => NodeToJson(child)).ToArray<JsonNode?>())
        };
    }

    private static int ParseIntQuery(HttpListenerRequest request, string name, int fallback)
    {
        var value = request.QueryString[name];
        return int.TryParse(value, out var parsed) ? parsed : fallback;
    }

    private static bool TryReadOptionalBoolean(
        JsonObject arguments,
        string name,
        bool fallback,
        out bool value,
        out string error)
    {
        value = fallback;
        error = string.Empty;
        if (!arguments.TryGetPropertyValue(name, out var node) || node is null)
        {
            return true;
        }

        try
        {
            value = node.GetValue<bool>();
            return true;
        }
        catch (Exception ex) when (ex is InvalidOperationException or FormatException)
        {
            error = $"Argument `{name}` must be a JSON boolean.";
            return false;
        }
    }

    private static bool TryReadOptionalInt(
        JsonObject arguments,
        string name,
        int fallback,
        out int value,
        out string error)
    {
        value = fallback;
        error = string.Empty;
        if (!arguments.TryGetPropertyValue(name, out var node) || node is null)
        {
            return true;
        }

        try
        {
            value = node.GetValue<int>();
            return true;
        }
        catch (Exception ex) when (ex is InvalidOperationException or FormatException)
        {
            error = $"Argument `{name}` must be a JSON integer.";
            return false;
        }
    }

    private static bool TryReadOptionalString(
        JsonObject arguments,
        string name,
        string fallback,
        out string value,
        out string error)
    {
        value = fallback;
        error = string.Empty;
        if (!arguments.TryGetPropertyValue(name, out var node) || node is null)
        {
            return true;
        }

        try
        {
            value = node.GetValue<string>() ?? fallback;
            return true;
        }
        catch (Exception ex) when (ex is InvalidOperationException or FormatException)
        {
            error = $"Argument `{name}` must be a JSON string.";
            return false;
        }
    }

    private static bool TryReadOptionalObject(
        JsonObject arguments,
        string name,
        out JsonObject value,
        out string error)
    {
        value = new JsonObject();
        error = string.Empty;
        if (!arguments.TryGetPropertyValue(name, out var node) || node is null)
        {
            return true;
        }

        if (node is JsonObject objectValue)
        {
            value = objectValue;
            return true;
        }

        error = $"Argument `{name}` must be a JSON object.";
        return false;
    }

    private static JsonObject ToolError(string message)
    {
        return new JsonObject
        {
            ["error"] = string.IsNullOrWhiteSpace(message) ? "Tool failed." : message,
            ["succeeded"] = false
        };
    }

    private static JsonObject UnsupportedInteractiveTool(string command)
    {
        return new JsonObject
        {
            ["command"] = command,
            ["supported"] = false,
            ["reason"] = $"Mole Windows `{command}` is interactive in the current upstream branch and is not safe to run from the background API yet."
        };
    }

    private static JsonObject Tool(string name, string description)
    {
        return new JsonObject
        {
            ["name"] = name,
            ["description"] = description
        };
    }

    private static JsonObject BuildMcpInitializeResult()
    {
        return new JsonObject
        {
            ["protocolVersion"] = ProtocolVersion,
            ["capabilities"] = new JsonObject
            {
                ["tools"] = new JsonObject()
            },
            ["serverInfo"] = new JsonObject
            {
                ["name"] = "BurrowWin",
                ["version"] = "0.1.0"
            }
        };
    }

    private static JsonArray BuildMcpToolArray()
    {
        return new JsonArray
        {
            McpTool("burrow_clean", "Preview or run Mole cleanup. Defaults to dry-run unless confirm is true.", new JsonObject
            {
                ["confirm"] = JsonSchemaBoolean("Run the cleanup instead of dry-run preview.")
            }),
            McpTool("burrow_optimize", "Preview or run Mole optimize. Defaults to dry-run unless confirm is true.", new JsonObject
            {
                ["confirm"] = JsonSchemaBoolean("Run the optimization instead of dry-run preview.")
            }),
            McpTool("burrow_snapshot", "Return current Windows telemetry used by the Dashboard fallback.", new JsonObject()),
            McpTool("burrow_history", "Return recent Windows telemetry snapshots recorded by BurrowWin.", new JsonObject
            {
                ["limit"] = JsonSchemaInteger("Maximum snapshots to return.")
            }),
            McpTool("burrow_top_processes", "Return process CPU or memory leaders from recent telemetry history.", new JsonObject
            {
                ["metric"] = JsonSchemaString("Metric used for ranking: peak_cpu, avg_cpu, cpu_time, peak_mem, or avg_mem."),
                ["limit"] = JsonSchemaInteger("Maximum processes to return."),
                ["history_limit"] = JsonSchemaInteger("Maximum telemetry snapshots to scan.")
            }),
            McpTool("burrow_process_usage", "Rank process usage over recent telemetry history by CPU or memory.", new JsonObject
            {
                ["metric"] = JsonSchemaString("Requested metric, such as peak_mem, avg_mem, peak_cpu, avg_cpu, or cpu_time."),
                ["limit"] = JsonSchemaInteger("Maximum processes to return."),
                ["history_limit"] = JsonSchemaInteger("Maximum telemetry snapshots to scan.")
            }),
            McpTool("burrow_info", "Return what BurrowWin is recording and where local MCP/HTTP state is stored.", new JsonObject()),
            McpTool("burrow_engine", "Return Mole engine availability for BurrowWin.", new JsonObject()),
            McpTool("burrow_analyze", "Analyze a directory and return a size-ranked tree.", new JsonObject
            {
                ["path"] = JsonSchemaString("Directory path to analyze."),
                ["max_depth"] = JsonSchemaInteger("Maximum recursive depth."),
                ["max_children"] = JsonSchemaInteger("Maximum children per directory.")
            }),
            McpTool("burrow_list_apps", "Installed Windows applications and the IDs `burrow_uninstall` accepts. Read-only.", new JsonObject
            {
                ["search"] = JsonSchemaString("Optional search text."),
                ["limit"] = JsonSchemaInteger("Maximum applications to return.")
            }),
            McpTool("burrow_purge", "Find project build artifacts using the Windows fallback preview. PREVIEW over MCP: real removal must be run from the BurrowWin GUI.", new JsonObject
            {
                ["confirm"] = JsonSchemaBoolean("Reserved. Real purge removal is GUI-only over Windows MCP; any value still returns the preview.")
            }),
            McpTool("burrow_installer", "Find leftover installer/archive files using the Windows fallback preview. PREVIEW over MCP: real removal must be run from the BurrowWin GUI.", new JsonObject
            {
                ["confirm"] = JsonSchemaBoolean("Reserved. Real installer cleanup is GUI-only over Windows MCP; any value still returns the preview.")
            }),
            McpTool("burrow_uninstall", "Windows compatibility tool: list apps, preview leftovers, or launch a confirmed vendor uninstaller.", new JsonObject
            {
                ["action"] = JsonSchemaString("One of list, preview_leftovers, or launch_uninstaller."),
                ["app_id"] = JsonSchemaString("Installed application ID returned by the list action."),
                ["search"] = JsonSchemaString("Optional search text for the list action."),
                ["limit"] = JsonSchemaInteger("Maximum applications to return for the list action."),
                ["confirm"] = JsonSchemaBoolean("Required for launch_uninstaller.")
            })
        };
    }

    private static JsonObject McpTool(string name, string description, JsonObject properties)
    {
        return new JsonObject
        {
            ["name"] = name,
            ["description"] = description,
            ["inputSchema"] = new JsonObject
            {
                ["type"] = "object",
                ["properties"] = properties
            }
        };
    }

    private static JsonObject JsonSchemaBoolean(string description)
    {
        return new JsonObject
        {
            ["type"] = "boolean",
            ["description"] = description
        };
    }

    private static JsonObject JsonSchemaInteger(string description)
    {
        return new JsonObject
        {
            ["type"] = "integer",
            ["description"] = description
        };
    }

    private static JsonObject JsonSchemaString(string description)
    {
        return new JsonObject
        {
            ["type"] = "string",
            ["description"] = description
        };
    }

    private static bool IsErrorToolResponse(JsonObject response)
    {
        if (response.ContainsKey("error"))
        {
            return true;
        }

        if (response.TryGetPropertyValue("supported", out var supported) &&
            supported is not null &&
            supported.GetValue<bool>() == false)
        {
            return true;
        }

        return response.TryGetPropertyValue("succeeded", out var succeeded) &&
               succeeded is not null &&
               succeeded.GetValue<bool>() == false;
    }

    private async Task<JsonObject> ListAppsAsync(JsonObject arguments, CancellationToken cancellationToken)
    {
        var apps = await _installedApplicationService.GetInstalledApplicationsAsync(cancellationToken).ConfigureAwait(false);
        var response = BuildUninstallList(apps, arguments);
        response["tool"] = "burrow_list_apps";
        return response;
    }

    private async Task<JsonObject> PreviewPurgeAsync(JsonObject arguments, CancellationToken cancellationToken)
    {
        if (!TryReadOptionalBoolean(arguments, "confirm", false, out var confirm, out var confirmError))
        {
            return ToolError(confirmError);
        }

        var projects = await _purgeArtifactService.PreviewAsync(cancellationToken: cancellationToken).ConfigureAwait(false);
        return new JsonObject
        {
            ["tool"] = "burrow_purge",
            ["action"] = "preview",
            ["source"] = "windows_native_fallback",
            ["confirm_requested"] = confirm,
            ["mcp_removal_supported"] = false,
            ["note"] = "Windows MCP returns purge previews only. Run removal from the BurrowWin GUI so the user can review and confirm selections.",
            ["count"] = projects.Count,
            ["total_bytes"] = projects.Sum(project => project.TotalSizeBytes),
            ["projects"] = new JsonArray(projects.Select(PurgeProjectToJson).ToArray<JsonNode?>())
        };
    }

    private async Task<JsonObject> PreviewInstallerAsync(JsonObject arguments, CancellationToken cancellationToken)
    {
        if (!TryReadOptionalBoolean(arguments, "confirm", false, out var confirm, out var confirmError))
        {
            return ToolError(confirmError);
        }

        var candidates = await _installerCleanupService.PreviewAsync(cancellationToken).ConfigureAwait(false);
        return new JsonObject
        {
            ["tool"] = "burrow_installer",
            ["action"] = "preview",
            ["source"] = "windows_native_fallback",
            ["confirm_requested"] = confirm,
            ["mcp_removal_supported"] = false,
            ["note"] = "Windows MCP returns installer cleanup previews only. Run removal from the BurrowWin GUI so the user can review and confirm selections.",
            ["count"] = candidates.Count,
            ["total_bytes"] = candidates.Sum(candidate => candidate.SizeBytes),
            ["candidates"] = new JsonArray(candidates.Select(InstallerCandidateToJson).ToArray<JsonNode?>())
        };
    }

    private async Task<JsonObject> UninstallAsync(JsonObject arguments, CancellationToken cancellationToken)
    {
        if (!TryReadOptionalString(arguments, "action", "list", out var action, out var actionError))
        {
            return ToolError(actionError);
        }

        var apps = await _installedApplicationService.GetInstalledApplicationsAsync(cancellationToken).ConfigureAwait(false);

        return action switch
        {
            "list" => BuildUninstallList(apps, arguments),
            "preview_leftovers" => await PreviewUninstallLeftoversAsync(apps, arguments, cancellationToken).ConfigureAwait(false),
            "launch_uninstaller" => await LaunchUninstallerAsync(apps, arguments, cancellationToken).ConfigureAwait(false),
            _ => new JsonObject { ["error"] = $"unsupported uninstall action: {action}" }
        };
    }

    private static JsonObject BuildUninstallList(IReadOnlyList<InstalledApplication> apps, JsonObject arguments)
    {
        if (!TryReadOptionalString(arguments, "search", string.Empty, out var search, out var searchError))
        {
            return ToolError(searchError);
        }

        if (!TryReadOptionalInt(arguments, "limit", 50, out var requestedLimit, out var limitError))
        {
            return ToolError(limitError);
        }

        var limit = Math.Clamp(requestedLimit, 1, 200);
        var filtered = string.IsNullOrWhiteSpace(search)
            ? apps.ToArray()
            : apps
                .Where(app =>
                    app.Name.Contains(search, StringComparison.OrdinalIgnoreCase) ||
                    app.Publisher.Contains(search, StringComparison.OrdinalIgnoreCase))
                .ToArray();

        return new JsonObject
        {
            ["action"] = "list",
            ["count"] = filtered.Length,
            ["returned"] = Math.Min(filtered.Length, limit),
            ["applications"] = new JsonArray(filtered.Take(limit).Select(ApplicationToJson).ToArray<JsonNode?>())
        };
    }

    private async Task<JsonObject> PreviewUninstallLeftoversAsync(
        IReadOnlyList<InstalledApplication> apps,
        JsonObject arguments,
        CancellationToken cancellationToken)
    {
        var app = FindApplication(apps, arguments);
        if (app is null)
        {
            return new JsonObject { ["error"] = "application not found" };
        }

        var leftovers = await _installedApplicationService.PreviewLeftoversAsync(app, cancellationToken).ConfigureAwait(false);
        return new JsonObject
        {
            ["action"] = "preview_leftovers",
            ["application"] = ApplicationToJson(app),
            ["count"] = leftovers.Count,
            ["total_bytes"] = leftovers.Sum(leftover => leftover.SizeBytes),
            ["leftovers"] = new JsonArray(leftovers.Select(leftover => new JsonObject
            {
                ["category"] = leftover.Category,
                ["path"] = leftover.Path,
                ["size_bytes"] = leftover.SizeBytes,
                ["size_text"] = leftover.SizeText
            }).ToArray<JsonNode?>())
        };
    }

    private async Task<JsonObject> LaunchUninstallerAsync(
        IReadOnlyList<InstalledApplication> apps,
        JsonObject arguments,
        CancellationToken cancellationToken)
    {
        if (!TryReadOptionalBoolean(arguments, "confirm", false, out var confirm, out var confirmError))
        {
            return ToolError(confirmError);
        }

        if (!confirm)
        {
            return new JsonObject
            {
                ["action"] = "launch_uninstaller",
                ["supported"] = false,
                ["reason"] = "Set confirm to true to launch a vendor uninstaller."
            };
        }

        if (!_settingsService.Current.McpDestructiveActionsEnabled)
        {
            return new JsonObject
            {
                ["action"] = "launch_uninstaller",
                ["supported"] = false,
                ["reason"] = "Enable MCP destructive actions in BurrowWin Settings before launching uninstallers through MCP."
            };
        }

        var app = FindApplication(apps, arguments);
        if (app is null)
        {
            return new JsonObject { ["error"] = "application not found" };
        }

        var result = await _installedApplicationService.LaunchUninstallerAsync(app, cancellationToken).ConfigureAwait(false);
        return new JsonObject
        {
            ["action"] = "launch_uninstaller",
            ["application"] = ApplicationToJson(app),
            ["exit_code"] = result.ExitCode,
            ["succeeded"] = result.Succeeded,
            ["stdout"] = result.StandardOutput,
            ["stderr"] = result.StandardError
        };
    }

    private static InstalledApplication? FindApplication(IReadOnlyList<InstalledApplication> apps, JsonObject arguments)
    {
        if (!TryReadOptionalString(arguments, "app_id", string.Empty, out var appId, out _))
        {
            return null;
        }

        return string.IsNullOrWhiteSpace(appId)
            ? null
            : apps.FirstOrDefault(app => string.Equals(app.Id, appId, StringComparison.OrdinalIgnoreCase));
    }

    private static JsonObject ApplicationToJson(InstalledApplication app)
    {
        return new JsonObject
        {
            ["id"] = app.Id,
            ["name"] = app.Name,
            ["publisher"] = app.Publisher,
            ["version"] = app.Version,
            ["install_location"] = app.InstallLocation,
            ["source"] = app.Source,
            ["size_bytes"] = app.SizeBytes,
            ["size_text"] = app.SizeText,
            ["can_launch_uninstaller"] = !string.IsNullOrWhiteSpace(app.UninstallString)
        };
    }

    private static JsonObject PurgeProjectToJson(PurgeProjectCandidate project)
    {
        return new JsonObject
        {
            ["name"] = project.Name,
            ["path"] = project.Path,
            ["marker"] = project.Marker,
            ["total_size_bytes"] = project.TotalSizeBytes,
            ["total_size_text"] = project.TotalSizeText,
            ["artifact_count"] = project.ArtifactCount,
            ["artifacts"] = new JsonArray(project.Artifacts.Select(artifact => new JsonObject
            {
                ["name"] = artifact.Name,
                ["path"] = artifact.Path,
                ["type"] = artifact.Type,
                ["language"] = artifact.Language,
                ["size_bytes"] = artifact.SizeBytes,
                ["size_text"] = artifact.SizeText
            }).ToArray<JsonNode?>())
        };
    }

    private static JsonObject InstallerCandidateToJson(InstallerCleanupCandidate candidate)
    {
        return new JsonObject
        {
            ["name"] = candidate.Name,
            ["path"] = candidate.Path,
            ["kind"] = candidate.Kind,
            ["size_bytes"] = candidate.SizeBytes,
            ["size_text"] = candidate.SizeText,
            ["last_write_time"] = candidate.LastWriteTime.ToString("O")
        };
    }

    private async Task RecordToolHistoryAsync(
        string name,
        JsonObject arguments,
        JsonObject response,
        long startedAt)
    {
        var hasError = response.ContainsKey("error");
        var supported = response["supported"]?.GetValue<bool?>() ?? true;
        var succeeded = !hasError && supported && (response["succeeded"]?.GetValue<bool?>() ?? true);
        var exitCode = response["exit_code"]?.GetValue<int?>() ?? (succeeded ? 0 : 1);
        var summary = hasError
            ? response["error"]?.GetValue<string>() ?? "Tool failed"
            : response["reason"]?.GetValue<string>() ?? "Tool completed";

        var entry = new OperationHistoryEntry(
            DateTimeOffset.UtcNow,
            "mcp_http",
            string.IsNullOrWhiteSpace(name) ? "unknown" : name,
            arguments.ToJsonString(new JsonSerializerOptions { WriteIndented = false }),
            exitCode,
            succeeded,
            (long)Stopwatch.GetElapsedTime(startedAt).TotalMilliseconds,
            summary);

        try
        {
            await _operationHistoryService.RecordAsync(entry).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
    }

    private static async Task WriteJsonAsync(HttpListenerResponse response, JsonNode payload, CancellationToken cancellationToken)
    {
        var json = payload.ToJsonString(new JsonSerializerOptions { WriteIndented = false });
        var bytes = Encoding.UTF8.GetBytes(json);
        response.StatusCode = StatusCodes.Status200OK;
        response.ContentType = "application/json; charset=utf-8";
        response.ContentLength64 = bytes.Length;
        response.Headers["Cache-Control"] = "no-store";
        await response.OutputStream.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
        response.Close();
    }

    internal static bool IsRequestAllowed(IPAddress? remoteAddress, string? origin)
    {
        return IsLoopback(remoteAddress) && IsAllowedOrigin(origin);
    }

    internal static bool ShouldBlockRestEndpoint(bool httpRestEnabled, string path, string method)
    {
        return !httpRestEnabled && !IsMcpRoute(path, method);
    }

    private static bool IsMcpRoute(string path, string method)
    {
        return path == "/mcp" && method.Equals("POST", StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsLoopback(IPAddress? address)
    {
        return address is not null && IPAddress.IsLoopback(address);
    }

    private static bool IsAllowedOrigin(string? origin)
    {
        if (string.IsNullOrWhiteSpace(origin))
        {
            return true;
        }

        if (!Uri.TryCreate(origin, UriKind.Absolute, out var uri))
        {
            return false;
        }

        return uri.IsLoopback &&
               (uri.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase) ||
                uri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase));
    }

    private static class StatusCodes
    {
        public const int Status200OK = 200;
        public const int Status403Forbidden = 403;
    }
}
