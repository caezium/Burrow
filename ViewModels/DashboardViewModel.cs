using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using BurrowWin.Models;
using BurrowWin.Services;

namespace BurrowWin.ViewModels;

public partial class DashboardViewModel : ViewModelBase
{
    private const int CpuBarCount = 34;
    private const int NetworkPointCount = 48;
    private const double ChartWidth = 100;
    private const double ChartHeight = 100;
    private const double ChartPadding = 8;
    private const double NetworkChartWidth = 520;
    private const double NetworkChartHeight = 80;
    private const double NetworkChartTopPadding = 10;
    private const double NetworkChartBottomPadding = 12;
    private readonly IMoleEngineService _moleEngineService;
    private readonly ISystemTelemetrySamplerService _telemetrySamplerService;
    private readonly ISystemTelemetryHistoryService _systemTelemetryHistoryService;
    private readonly IOperationHistoryService _operationHistoryService;

    public DashboardViewModel(
        IMoleEngineService moleEngineService,
        ISystemTelemetrySamplerService telemetrySamplerService,
        ISystemTelemetryHistoryService systemTelemetryHistoryService,
        IOperationHistoryService operationHistoryService)
    {
        _moleEngineService = moleEngineService;
        _telemetrySamplerService = telemetrySamplerService;
        _systemTelemetryHistoryService = systemTelemetryHistoryService;
        _operationHistoryService = operationHistoryService;
        TelemetryHistoryPath = _systemTelemetryHistoryService.HistoryFilePath;
    }

    public ObservableCollection<string> OutputLines { get; } = new();

    public ObservableCollection<DashboardBarSample> CpuBars { get; } = new();

    public ObservableCollection<ProcessTelemetry> TopProcesses { get; } = new();

    public ObservableCollection<OperationHistoryEntry> RecentActivity { get; } = new();

    [ObservableProperty]
    private string engineStatus = "Not checked";

    [ObservableProperty]
    private string enginePath = string.Empty;

    [ObservableProperty]
    private string engineKindText = "Mole";

    [ObservableProperty]
    private bool isBusy;

    [ObservableProperty]
    private bool isEngineAvailable;

    [ObservableProperty]
    private string statusContract = "Waiting for engine check";

    [ObservableProperty]
    private double cpuUsagePercent;

    [ObservableProperty]
    private double memoryUsagePercent;

    [ObservableProperty]
    private string memorySummary = "Not sampled";

    [ObservableProperty]
    private double diskUsagePercent;

    [ObservableProperty]
    private string diskSummary = "Not sampled";

    [ObservableProperty]
    private string networkSummary = "Not sampled";

    [ObservableProperty]
    private string gpuStatus = "Not sampled";

    [ObservableProperty]
    private string capturedAt = string.Empty;

    [ObservableProperty]
    private string telemetryHistorySummary = "No telemetry history recorded yet";

    [ObservableProperty]
    private string telemetryHistoryPath = string.Empty;

    [ObservableProperty]
    private string activitySummary = "No recent activity";

    [ObservableProperty]
    private string deviceSummary = "Windows";

    [ObservableProperty]
    private string healthFooter = "up 0d 0h";

    [ObservableProperty]
    private string cpuCoresBadge = $"{Environment.ProcessorCount} cores";

    [ObservableProperty]
    private string cpuFooter = "load 0.00";

    [ObservableProperty]
    private string memoryStateBadge = "normal";

    [ObservableProperty]
    private string diskTotalBadge = "-";

    [ObservableProperty]
    private string diskFreeAmountText = "-";

    [ObservableProperty]
    private string diskFreeUnitText = "free";

    [ObservableProperty]
    private string diskFooter = "Not sampled";

    [ObservableProperty]
    private string networkRateText = "-";

    [ObservableProperty]
    private string networkRateValueText = "-";

    [ObservableProperty]
    private string networkRateUnitText = "KB/s";

    [ObservableProperty]
    private string networkFooter = "Not sampled";

    [ObservableProperty]
    private string networkBadge = "HTTP";

    [ObservableProperty]
    private string networkAdapterText = "network - unavailable";

    [ObservableProperty]
    private string gpuMetricText = "-";

    [ObservableProperty]
    private string gpuFooter = "Windows GPU engine";

    [ObservableProperty]
    private string batteryMetricText = "-";

    [ObservableProperty]
    private string batteryStateText = "unavailable";

    [ObservableProperty]
    private string batteryFooter = "Desktop or unavailable";

    [ObservableProperty]
    private string batteryBadge = "Good";

    [ObservableProperty]
    private string batteryHealthBadge = "Unavailable";

    [ObservableProperty]
    private string batteryPercentText = "-";

    [ObservableProperty]
    private string fanMetricText = "-";

    [ObservableProperty]
    private string fanBadge = "0 fans";

    [ObservableProperty]
    private string fanFooter = "Windows fan telemetry unavailable";

    [ObservableProperty]
    private HistoryChartSeries fanStatusChart = HistoryChartSeries.Empty("0 RPM", "avg 0 RPM");

    [ObservableProperty]
    private string topProcessesTitle = "NAME (0)";

    [ObservableProperty]
    private HistoryChartSeries memoryStatusChart = HistoryChartSeries.Empty("0%", "avg 0%");

    [ObservableProperty]
    private HistoryChartSeries networkStatusChart = HistoryChartSeries.Empty("0 B/s", "avg 0 B/s");

    [ObservableProperty]
    private HistoryChartSeries networkDownloadChart = HistoryChartSeries.Empty("0 B/s", "avg 0 B/s");

    [ObservableProperty]
    private HistoryChartSeries networkUploadChart = HistoryChartSeries.Empty("0 B/s", "avg 0 B/s");

    [ObservableProperty]
    private HistoryChartSeries gpuStatusChart = HistoryChartSeries.Empty("0%", "avg 0%");

    public string McpSurfaceSummary => $"HTTP 127.0.0.1:{LocalMcpServerService.DefaultPort} | STDIO Assets\\Mcp\\burrow-mcp-stdio.exe";

    public string CpuUsageText => SystemTelemetryFormatter.Percent(CpuUsagePercent);

    public string MemoryUsageText => SystemTelemetryFormatter.Percent(MemoryUsagePercent);

    public string DiskUsageText => SystemTelemetryFormatter.Percent(DiskUsagePercent);

    public string OutputText => string.Join(Environment.NewLine, OutputLines);

    public double HealthScoreValue => Math.Clamp(100 - Math.Round(Math.Max(DiskUsagePercent, Math.Max(MemoryUsagePercent, CpuUsagePercent)) / 2), 0, 100);

    public string HealthScore => HealthScoreValue.ToString("0");

    public string HealthStatusText => DiskUsagePercent > 90 || MemoryUsagePercent > 90 ? "Watch" : "Good";

    public string HealthReason => DiskUsagePercent > 90 ? "Disk Almost Full" : "System Ready";

    [RelayCommand]
    public async Task RefreshAsync()
    {
        IsBusy = true;
        OutputLines.Clear();
        OnPropertyChanged(nameof(OutputText));

        try
        {
            await RefreshTelemetryAsync();

            var availability = _moleEngineService.GetAvailability();
            IsEngineAvailable = availability.IsAvailable;
            EngineStatus = availability.Message;
            EnginePath = availability.Path ?? string.Empty;
            EngineKindText = availability.IsAvailable ? availability.Kind.ToString() : "Mole missing";

            if (!availability.IsAvailable)
            {
                StatusContract = "Mole is missing";
                AppendOutput(availability.Message);
                return;
            }

            var version = await _moleEngineService.ExecuteCommandAsync("--version", AppendOutput);
            if (version.Succeeded)
            {
                StatusContract = "Mole engine is available; Dashboard uses native polling until Mole Windows exposes non-interactive status data";
            }
            else
            {
                StatusContract = "Mole version check failed";
                AppendOutput(version.StandardError);
            }
        }
        finally
        {
            IsBusy = false;
        }
    }

    partial void OnCpuUsagePercentChanged(double value)
    {
        OnPropertyChanged(nameof(CpuUsageText));
        OnPropertyChanged(nameof(HealthScoreValue));
        OnPropertyChanged(nameof(HealthScore));
        OnPropertyChanged(nameof(HealthStatusText));
        OnPropertyChanged(nameof(HealthReason));
    }

    partial void OnMemoryUsagePercentChanged(double value)
    {
        OnPropertyChanged(nameof(MemoryUsageText));
        OnPropertyChanged(nameof(HealthScoreValue));
        OnPropertyChanged(nameof(HealthScore));
        OnPropertyChanged(nameof(HealthStatusText));
        OnPropertyChanged(nameof(HealthReason));
    }

    partial void OnDiskUsagePercentChanged(double value)
    {
        OnPropertyChanged(nameof(DiskUsageText));
        OnPropertyChanged(nameof(HealthScoreValue));
        OnPropertyChanged(nameof(HealthScore));
        OnPropertyChanged(nameof(HealthStatusText));
        OnPropertyChanged(nameof(HealthReason));
    }

    private async Task RefreshTelemetryAsync()
    {
        var snapshot = await _telemetrySamplerService.SampleNowAsync();
        var recentSnapshots = await _systemTelemetryHistoryService.ReadRecentAsync(Math.Max(CpuBarCount, NetworkPointCount));
        var recentActivity = await _operationHistoryService.ReadRecentAsync(5);

        RunOnUiThread(() =>
        {
            CpuUsagePercent = snapshot.CpuUsagePercent;
            MemoryUsagePercent = snapshot.MemoryUsagePercent;
            MemorySummary = SystemTelemetryFormatter.MemorySummary(snapshot);
            DiskUsagePercent = snapshot.DiskUsagePercent;
            DiskSummary = SystemTelemetryFormatter.DiskSummary(snapshot);
            DiskFooter = $"{DiskUsageText} used - {DiskSummary}";
            NetworkSummary =
                $"Down {SystemTelemetryFormatter.Rate(snapshot.NetworkReceivedBytesPerSecond)} | Up {SystemTelemetryFormatter.Rate(snapshot.NetworkSentBytesPerSecond)}";
            NetworkRateText = SystemTelemetryFormatter.Rate(snapshot.NetworkReceivedBytesPerSecond + snapshot.NetworkSentBytesPerSecond);
            (NetworkRateValueText, NetworkRateUnitText) = SplitRateText(NetworkRateText);
            NetworkAdapterText = BuildNetworkEndpointText(snapshot);
            NetworkFooter =
                $"↓ {SystemTelemetryFormatter.Rate(snapshot.NetworkReceivedBytesPerSecond)}  ↑ {SystemTelemetryFormatter.Rate(snapshot.NetworkSentBytesPerSecond)} · {NetworkAdapterText}";
            GpuStatus = snapshot.GpuStatus;
            GpuMetricText = string.Equals(snapshot.GpuStatus, "Unavailable", StringComparison.OrdinalIgnoreCase)
                ? "-"
                : snapshot.GpuStatus;
            CapturedAt = snapshot.CapturedAt.ToString("HH:mm:ss");
            CpuFooter = $"load {snapshot.CpuUsagePercent / 100 * Environment.ProcessorCount:0.00} - {snapshot.TopProcesses.Count} processes";
            CpuCoresBadge = $"{Environment.ProcessorCount} cores";
            DeviceSummary = $"Windows - {SystemTelemetryFormatter.Bytes(snapshot.MemoryTotalBytes)}";
            HealthFooter = BuildUptimeText(snapshot.CapturedAt);
            MemoryStateBadge = snapshot.MemoryUsagePercent >= 85 ? "high" : "normal";
            DiskTotalBadge = SystemTelemetryFormatter.Bytes(snapshot.DiskTotalBytes);
            SetDiskFreeText(snapshot);
            SetBatteryText(snapshot);
            FanMetricText = "-";
            FanBadge = "0 fans";
            FanFooter = "Windows fan telemetry unavailable";

            TopProcesses.Clear();
            foreach (var process in snapshot.TopProcesses.Take(8))
            {
                TopProcesses.Add(process);
            }
            TopProcessesTitle = $"NAME ({TopProcesses.Count})";

            var chartSamples = BuildStatusSamples(recentSnapshots, snapshot);
            RebuildCpuBars(chartSamples);
            MemoryStatusChart = BuildChart(chartSamples, sample => sample.MemoryUsagePercent, 100, SystemTelemetryFormatter.Percent);
            (NetworkDownloadChart, NetworkUploadChart) = BuildNetworkCharts(chartSamples);
            NetworkStatusChart = NetworkDownloadChart;
            GpuStatusChart = BuildChart(chartSamples, sample => ParseGpuPercent(sample.GpuStatus), 100, SystemTelemetryFormatter.Percent);
            FanStatusChart = HistoryChartSeries.Empty("0 RPM", "avg 0 RPM");

            TelemetryHistorySummary = BuildTelemetryHistorySummary(recentSnapshots);
            ActivitySummary = BuildActivitySummary(recentActivity);

            RecentActivity.Clear();
            foreach (var entry in recentActivity)
            {
                RecentActivity.Add(entry);
            }
        });
    }

    private void SetDiskFreeText(SystemTelemetrySnapshot snapshot)
    {
        var freeBytes = Math.Max(0, snapshot.DiskTotalBytes - snapshot.DiskUsedBytes);
        var formatted = SystemTelemetryFormatter.Bytes(freeBytes).Split(' ', 2, StringSplitOptions.RemoveEmptyEntries);
        DiskFreeAmountText = formatted.Length > 0 ? formatted[0] : "-";
        DiskFreeUnitText = formatted.Length > 1 ? $"{formatted[1]} free" : "free";
    }

    private void SetBatteryText(SystemTelemetrySnapshot snapshot)
    {
        if (!snapshot.HasBattery || !snapshot.BatteryChargePercent.HasValue)
        {
            BatteryMetricText = "-";
            BatteryStateText = "unavailable";
            BatteryFooter = "Desktop or unavailable";
            BatteryBadge = "Good";
            BatteryHealthBadge = "Unavailable";
            BatteryPercentText = "-";
            return;
        }

        var percent = Math.Clamp(snapshot.BatteryChargePercent.Value, 0, 100);
        BatteryMetricText = percent.ToString("0");
        BatteryStateText = snapshot.BatteryStatusText;
        BatteryFooter = BuildBatteryFooter(snapshot);
        BatteryBadge = snapshot.BatteryHealthText;
        BatteryHealthBadge = snapshot.BatteryHealthText;
        BatteryPercentText = $"{percent:0}%";
    }

    private static string BuildBatteryFooter(SystemTelemetrySnapshot snapshot)
    {
        var parts = new List<string>();
        if (snapshot.BatteryEstimatedSecondsRemaining is > 0)
        {
            parts.Add($"{FormatBatteryDuration(snapshot.BatteryEstimatedSecondsRemaining.Value)} left");
        }

        parts.Add($"{Math.Clamp(snapshot.BatteryChargePercent ?? 0, 0, 100):0}% charge");
        parts.Add(snapshot.BatteryStatusText);
        return string.Join(" - ", parts);
    }

    private static string FormatBatteryDuration(int seconds)
    {
        var duration = TimeSpan.FromSeconds(seconds);
        if (duration.TotalHours >= 1)
        {
            return $"{(int)duration.TotalHours}:{duration.Minutes:00}";
        }

        return $"{duration.Minutes:0}m";
    }

    private void RebuildCpuBars(IReadOnlyList<SystemTelemetrySnapshot> samples)
    {
        var values = BuildPaddedValues(samples, sample => sample.CpuUsagePercent, CpuBarCount);
        CpuBars.Clear();
        foreach (var value in values)
        {
            CpuBars.Add(new DashboardBarSample(10 + (Math.Clamp(value, 0, 100) / 100 * 48)));
        }
    }

    private static IReadOnlyList<SystemTelemetrySnapshot> BuildStatusSamples(
        IReadOnlyList<SystemTelemetrySnapshot> recentSnapshots,
        SystemTelemetrySnapshot latestSnapshot)
    {
        return recentSnapshots
            .Append(latestSnapshot)
            .GroupBy(sample => sample.CapturedAt)
            .Select(group => group.First())
            .OrderBy(sample => sample.CapturedAt)
            .TakeLast(Math.Max(CpuBarCount, NetworkPointCount))
            .ToArray();
    }

    private static HistoryChartSeries BuildChart(
        IReadOnlyList<SystemTelemetrySnapshot> samples,
        Func<SystemTelemetrySnapshot, double> selector,
        double? fixedMaximum,
        Func<double, string> formatter,
        int pointCount = 12)
    {
        var values = BuildPaddedValues(samples, selector, pointCount);
        var maximum = fixedMaximum ?? Math.Max(1, values.Max() * 1.15);
        return BuildChartFromValues(values, maximum, formatter);
    }

    private static (HistoryChartSeries Download, HistoryChartSeries Upload) BuildNetworkCharts(IReadOnlyList<SystemTelemetrySnapshot> samples)
    {
        var downloadValues = BuildPaddedValues(
            samples,
            sample => sample.NetworkReceivedBytesPerSecond,
            NetworkPointCount);
        var uploadValues = BuildPaddedValues(
            samples,
            sample => sample.NetworkSentBytesPerSecond,
            NetworkPointCount);
        var maximum = Math.Max(downloadValues.Max(), uploadValues.Max());
        maximum = Math.Max(1, maximum * 1.85);

        return (
            BuildChartFromValues(
                downloadValues,
                maximum,
                SystemTelemetryFormatter.Rate,
                NetworkChartWidth,
                NetworkChartHeight,
                NetworkChartTopPadding,
                NetworkChartBottomPadding),
            BuildChartFromValues(
                uploadValues,
                maximum,
                SystemTelemetryFormatter.Rate,
                NetworkChartWidth,
                NetworkChartHeight,
                NetworkChartTopPadding,
                NetworkChartBottomPadding));
    }

    private static HistoryChartSeries BuildChartFromValues(
        IReadOnlyList<double> values,
        double maximum,
        Func<double, string> formatter,
        double chartWidth = ChartWidth,
        double chartHeight = ChartHeight,
        double chartTopPadding = ChartPadding,
        double chartBottomPadding = ChartPadding)
    {
        if (values.Count == 0)
        {
            return HistoryChartSeries.Empty(formatter(0), $"avg {formatter(0)}");
        }

        if (maximum <= 0)
        {
            maximum = 1;
        }

        var xStep = values.Count == 1 ? 0 : chartWidth / (values.Count - 1);
        var usableHeight = Math.Max(1, chartHeight - chartTopPadding - chartBottomPadding);
        var points = new PointCollection();
        for (var index = 0; index < values.Count; index++)
        {
            var value = Math.Clamp(values[index], 0, maximum);
            var x = values.Count == 1 ? chartWidth / 2 : index * xStep;
            var y = chartHeight - chartBottomPadding - (value / maximum * usableHeight);
            points.Add(new Point(x, y));
        }

        return new HistoryChartSeries(formatter(values[^1]), $"avg {formatter(values.Average())}", points);
    }

    private static string BuildNetworkEndpointText(SystemTelemetrySnapshot snapshot)
    {
        var interfaceName = string.IsNullOrWhiteSpace(snapshot.NetworkInterfaceName)
            ? "network"
            : snapshot.NetworkInterfaceName.Trim();
        var address = string.IsNullOrWhiteSpace(snapshot.NetworkIPv4Address)
            ? "unavailable"
            : snapshot.NetworkIPv4Address.Trim();

        return $"{interfaceName} · {address}";
    }

    private static (string Value, string Unit) SplitRateText(string rateText)
    {
        var parts = rateText.Split(' ', 2, StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0)
        {
            return ("-", "KB/s");
        }

        return parts.Length == 1 ? (parts[0], string.Empty) : (parts[0], parts[1]);
    }

    private static IReadOnlyList<double> BuildPaddedValues(
        IReadOnlyList<SystemTelemetrySnapshot> samples,
        Func<SystemTelemetrySnapshot, double> selector,
        int count)
    {
        var values = samples
            .OrderBy(sample => sample.CapturedAt)
            .TakeLast(count)
            .Select(sample => Math.Max(0, selector(sample)))
            .ToList();

        if (values.Count == 0)
        {
            return Enumerable.Repeat(0d, count).ToArray();
        }

        while (values.Count < count)
        {
            values.Insert(0, values[0]);
        }

        return values;
    }

    private static double ParseGpuPercent(string gpuStatus)
    {
        var numeric = new string(gpuStatus.Where(character => char.IsDigit(character) || character == '.').ToArray());
        return double.TryParse(numeric, out var value) ? value : 0;
    }

    private static string BuildUptimeText(DateTimeOffset capturedAt)
    {
        var uptime = TimeSpan.FromMilliseconds(Environment.TickCount64);
        var since = capturedAt - uptime;
        return $"up {(int)uptime.TotalDays}d {uptime.Hours}h - since {since:MMM dd}";
    }

    private static string BuildTelemetryHistorySummary(IReadOnlyList<SystemTelemetrySnapshot> snapshots)
    {
        if (snapshots.Count == 0)
        {
            return "No telemetry history recorded yet";
        }

        var averageCpu = snapshots.Average(snapshot => snapshot.CpuUsagePercent);
        var averageMemory = snapshots.Average(snapshot => snapshot.MemoryUsagePercent);
        return $"{snapshots.Count} recent samples | avg CPU {averageCpu:0.0}% | avg memory {averageMemory:0.0}%";
    }

    private static string BuildActivitySummary(IReadOnlyList<OperationHistoryEntry> entries)
    {
        if (entries.Count == 0)
        {
            return "No recent activity";
        }

        var succeeded = entries.Count(entry => entry.Succeeded);
        return $"{entries.Count} recent operations | {succeeded} succeeded";
    }

    private void AppendOutput(string line)
    {
        RunOnUiThread(() =>
        {
            OutputLines.Add(line);
            OnPropertyChanged(nameof(OutputText));
        });
    }
}
