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
        IOperationHistoryService operationHistoryService,
        IApplicationSettingsService settingsService)
    {
        _moleEngineService = moleEngineService;
        _diskAnalyzerService = diskAnalyzerService;
        _telemetrySamplerService = telemetrySamplerService;
        _systemTelemetryHistoryService = systemTelemetryHistoryService;
        _installedApplicationService = installedApplicationService;
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
            if (action == HttpServerSettingsAction.Stop)
            {
                return;
            }

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
        if (!IsLoopback(context.Request.RemoteEndPoint?.Address) || !IsAllowedOrigin(context.Request.Headers["Origin"]))
        {
            context.Response.StatusCode = StatusCodes.Status403Forbidden;
            context.Response.Close();
            return;
        }

        var path = context.Request.Url?.AbsolutePath.TrimEnd('/').ToLowerInvariant() ?? string.Empty;
        var response = path switch
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
                Tool("burrow_uninstall", "List apps, preview leftovers, or launch a confirmed vendor uninstaller.")
            }
        };
    }

    private async Task<JsonObject> CallToolAsync(HttpListenerRequest request, CancellationToken cancellationToken)
    {
        using var reader = new StreamReader(request.InputStream, request.ContentEncoding);
        var body = await reader.ReadToEndAsync(cancellationToken).ConfigureAwait(false);
        var node = string.IsNullOrWhiteSpace(body) ? null : JsonNode.Parse(body);
        var name = node?["name"]?.GetValue<string>() ?? string.Empty;
        var arguments = node?["arguments"]?.AsObject() ?? new JsonObject();
        var startedAt = Stopwatch.GetTimestamp();

        var response = await ExecuteToolByNameAsync(name, arguments, cancellationToken).ConfigureAwait(false);

        await RecordToolHistoryAsync(name, arguments, response, startedAt).ConfigureAwait(false);
        return response;
    }

    private async Task<JsonObject> HandleMcpJsonRpcAsync(HttpListenerRequest request, CancellationToken cancellationToken)
    {
        using var reader = new StreamReader(request.InputStream, request.ContentEncoding);
        var body = await reader.ReadToEndAsync(cancellationToken).ConfigureAwait(false);
        var node = string.IsNullOrWhiteSpace(body) ? null : JsonNode.Parse(body)?.AsObject();
        var id = node?["id"]?.DeepClone();
        var method = node?["method"]?.GetValue<string>() ?? string.Empty;

        try
        {
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
        catch (Exception ex) when (ex is InvalidOperationException or JsonException)
        {
            return new JsonObject
            {
                ["jsonrpc"] = "2.0",
                ["id"] = id,
                ["error"] = new JsonObject
                {
                    ["code"] = -32601,
                    ["message"] = ex.Message
                }
            };
        }
    }

    private async Task<JsonObject> HandleMcpToolCallAsync(JsonObject parameters, CancellationToken cancellationToken)
    {
        var name = parameters["name"]?.GetValue<string>() ?? string.Empty;
        var arguments = parameters["arguments"]?.AsObject() ?? new JsonObject();
        var startedAt = Stopwatch.GetTimestamp();
        var response = await ExecuteToolByNameAsync(name, arguments, cancellationToken).ConfigureAwait(false);
        await RecordToolHistoryAsync(name, arguments, response, startedAt).ConfigureAwait(false);

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
            "burrow_uninstall" => await UninstallAsync(arguments, cancellationToken),
            _ => new JsonObject { ["error"] = $"unknown tool: {name}" }
        };
    }

    private async Task<JsonObject> RunActionToolAsync(string command, JsonObject arguments, CancellationToken cancellationToken)
    {
        var confirm = arguments["confirm"]?.GetValue<bool>() == true;
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
        var limit = Math.Clamp(arguments["limit"]?.GetValue<int>() ?? 24, 1, 500);
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
        var historyLimit = Math.Clamp(arguments["history_limit"]?.GetValue<int>() ?? 120, 1, 1000);
        var limit = Math.Clamp(arguments["limit"]?.GetValue<int>() ?? 10, 1, 100);
        var metric = ProcessUsageAggregator.NormalizeMetric(
            arguments["metric"]?.GetValue<string>() ?? ProcessUsageAggregator.PeakCpuMetric);
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
        var requestedMetric = arguments["metric"]?.GetValue<string>() ?? "peak_mem";
        var metric = ProcessUsageAggregator.NormalizeMetric(requestedMetric);
        var historyLimit = Math.Clamp(arguments["history_limit"]?.GetValue<int>() ?? 120, 1, 1000);
        var limit = Math.Clamp(arguments["limit"]?.GetValue<int>() ?? 10, 1, 100);
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
        var path = arguments["path"]?.GetValue<string>()
            ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var maxDepth = arguments["max_depth"]?.GetValue<int>() ?? 2;
        var maxChildren = arguments["max_children"]?.GetValue<int>() ?? 12;

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
            McpTool("burrow_uninstall", "List apps, preview leftovers, or launch a confirmed vendor uninstaller.", new JsonObject
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

    private async Task<JsonObject> UninstallAsync(JsonObject arguments, CancellationToken cancellationToken)
    {
        var action = arguments["action"]?.GetValue<string>() ?? "list";
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
        var search = arguments["search"]?.GetValue<string>() ?? string.Empty;
        var limit = Math.Clamp(arguments["limit"]?.GetValue<int>() ?? 50, 1, 200);
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
        var confirm = arguments["confirm"]?.GetValue<bool>() == true;
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
        var appId = arguments["app_id"]?.GetValue<string>();
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
