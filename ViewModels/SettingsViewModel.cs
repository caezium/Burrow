using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using BurrowWin.Models;
using BurrowWin.Services;

namespace BurrowWin.ViewModels;

public partial class SettingsViewModel : ViewModelBase
{
    private readonly IMoleEngineService _moleEngineService;
    private readonly IOperationHistoryService _operationHistoryService;
    private readonly ISystemTelemetryHistoryService _telemetryHistoryService;
    private readonly IApplicationSettingsService _settingsService;

    public SettingsViewModel(
        IMoleEngineService moleEngineService,
        IOperationHistoryService operationHistoryService,
        ISystemTelemetryHistoryService telemetryHistoryService,
        IApplicationSettingsService settingsService)
    {
        _moleEngineService = moleEngineService;
        _operationHistoryService = operationHistoryService;
        _telemetryHistoryService = telemetryHistoryService;
        _settingsService = settingsService;
        Refresh();
    }

    public ObservableCollection<OperationHistoryEntry> HistoryEntries { get; } = new();

    [ObservableProperty]
    private string engineStatus = string.Empty;

    [ObservableProperty]
    private string enginePath = string.Empty;

    [ObservableProperty]
    private string engineKind = string.Empty;

    [ObservableProperty]
    private string mcpEndpoint = string.Empty;

    [ObservableProperty]
    private string mcpStdioCommand = "Assets\\Mcp\\burrow-mcp-stdio.exe";

    [ObservableProperty]
    private string engineInstallHint = "BurrowWin ships Assets\\Mole\\mo.exe. You can also override with Assets\\mo.exe, Assets\\Mole\\mole.ps1, Assets\\Mole\\mo.cmd, or a PATH `mo` install.";

    [ObservableProperty]
    private string settingsPath = string.Empty;

    [ObservableProperty]
    private string telemetryHistoryPath = string.Empty;

    [ObservableProperty]
    private string activityHistoryPath = string.Empty;

    [ObservableProperty]
    private string historySummary = "History has not been loaded";

    [ObservableProperty]
    private string settingsStatus = "Settings have not been saved in this session";

    [ObservableProperty]
    private string samplingIntervalSeconds = string.Empty;

    [ObservableProperty]
    private string historyRetentionDays = string.Empty;

    [ObservableProperty]
    private bool httpServerEnabled;

    [ObservableProperty]
    private string httpServerPort = string.Empty;

    [ObservableProperty]
    private bool trayIconEnabled;

    [ObservableProperty]
    private bool mcpDestructiveActionsEnabled;

    [RelayCommand]
    public void Refresh()
    {
        var availability = _moleEngineService.GetAvailability();
        EngineStatus = availability.Message;
        EnginePath = availability.Path ?? "Not resolved";
        EngineKind = availability.Kind.ToString();

        SettingsPath = _settingsService.SettingsFilePath;
        TelemetryHistoryPath = _telemetryHistoryService.HistoryFilePath;
        ActivityHistoryPath = _operationHistoryService.HistoryFilePath;
        ApplySettings(_settingsService.Reload());
    }

    [RelayCommand]
    public async Task SaveSettingsAsync()
    {
        var current = _settingsService.Current;
        var settings = BurrowSettings.Normalize(new BurrowSettings
        {
            SamplingIntervalSeconds = ParseInt(SamplingIntervalSeconds, current.SamplingIntervalSeconds),
            HistoryRetentionDays = ParseInt(HistoryRetentionDays, current.HistoryRetentionDays),
            HttpServerEnabled = HttpServerEnabled,
            HttpServerPort = ParseInt(HttpServerPort, current.HttpServerPort),
            TrayIconEnabled = TrayIconEnabled,
            McpDestructiveActionsEnabled = McpDestructiveActionsEnabled
        });

        var saved = await _settingsService.SaveAsync(settings).ConfigureAwait(false);
        RunOnUiThread(() =>
        {
            ApplySettings(saved);
            SettingsStatus = "Settings saved. Sampling, tray, HTTP, and MCP gates apply immediately.";
        });
    }

    [RelayCommand]
    public async Task LoadHistoryAsync()
    {
        var entries = await _operationHistoryService.ReadRecentAsync(25).ConfigureAwait(false);
        RunOnUiThread(() =>
        {
            HistoryEntries.Clear();
            foreach (var entry in entries)
            {
                HistoryEntries.Add(entry);
            }

            HistorySummary = entries.Count == 0 ? "No history entries found" : $"Loaded {entries.Count} recent entries";
        });
    }

    private void ApplySettings(BurrowSettings settings)
    {
        SamplingIntervalSeconds = settings.SamplingIntervalSeconds.ToString();
        HistoryRetentionDays = settings.HistoryRetentionDays.ToString();
        HttpServerEnabled = settings.HttpServerEnabled;
        HttpServerPort = settings.HttpServerPort.ToString();
        TrayIconEnabled = settings.TrayIconEnabled;
        McpDestructiveActionsEnabled = settings.McpDestructiveActionsEnabled;
        McpEndpoint = settings.HttpServerEnabled
            ? $"http://127.0.0.1:{settings.HttpServerPort}"
            : "Disabled";
    }

    private static int ParseInt(string value, int fallback)
    {
        return int.TryParse(value, out var parsed) ? parsed : fallback;
    }
}
