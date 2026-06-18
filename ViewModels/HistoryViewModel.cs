using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using BurrowWin.Models;
using BurrowWin.Services;

namespace BurrowWin.ViewModels;

public partial class HistoryViewModel : ViewModelBase
{
    private const double ChartWidth = 100;
    private const double ChartHeight = 100;
    private const double ChartPadding = 8;
    private readonly ISystemTelemetryHistoryService _historyService;
    private readonly IApplicationSettingsService _settingsService;

    public HistoryViewModel(
        ISystemTelemetryHistoryService historyService,
        IApplicationSettingsService settingsService)
    {
        _historyService = historyService;
        _settingsService = settingsService;
        HistoryPath = _historyService.HistoryFilePath;
    }

    public ObservableCollection<SystemTelemetrySnapshot> Samples { get; } = new();

    public ObservableCollection<ProcessUsageSummary> CpuProcessLeaders { get; } = new();

    [ObservableProperty]
    private string summary = "No samples loaded";

    [ObservableProperty]
    private string historyPath = string.Empty;

    [ObservableProperty]
    private string selectedRangeKey = HistoryRangeCatalog.DefaultRangeKey;

    [ObservableProperty]
    private double averageCpu;

    [ObservableProperty]
    private double averageMemory;

    [ObservableProperty]
    private double averageDisk;

    [ObservableProperty]
    private HistoryChartSeries cpuUsageChart = HistoryChartSeries.Empty("0%", "avg 0%");

    [ObservableProperty]
    private HistoryChartSeries memoryChart = HistoryChartSeries.Empty("0%", "avg 0%");

    [ObservableProperty]
    private HistoryChartSeries diskChart = HistoryChartSeries.Empty("0%", "avg 0%");

    [ObservableProperty]
    private HistoryChartSeries networkChart = HistoryChartSeries.Empty("0 B/s", "avg 0 B/s");

    [RelayCommand]
    public async Task RefreshAsync()
    {
        var range = HistoryRangeCatalog.Resolve(SelectedRangeKey);
        var readLimit = HistoryRangeCatalog.EstimateReadLimit(range, _settingsService.Current.SamplingIntervalSeconds);
        var readSamples = await _historyService.ReadRecentAsync(readLimit);
        var rangeEnd = readSamples.Count == 0
            ? DateTimeOffset.Now
            : readSamples.Max(sample => sample.CapturedAt);
        var samples = HistoryRangeCatalog.Filter(readSamples, range, rangeEnd);

        RunOnUiThread(() =>
        {
            Samples.Clear();
            foreach (var sample in samples)
            {
                Samples.Add(sample);
            }

            if (samples.Count == 0)
            {
                Summary = $"No telemetry samples in {range.Label}";
                AverageCpu = 0;
                AverageMemory = 0;
                AverageDisk = 0;
                CpuUsageChart = HistoryChartSeries.Empty("0%", "avg 0%");
                MemoryChart = HistoryChartSeries.Empty("0%", "avg 0%");
                DiskChart = HistoryChartSeries.Empty("0%", "avg 0%");
                NetworkChart = HistoryChartSeries.Empty("0 B/s", "avg 0 B/s");
                CpuProcessLeaders.Clear();
                return;
            }

            AverageCpu = samples.Average(sample => sample.CpuUsagePercent);
            AverageMemory = samples.Average(sample => sample.MemoryUsagePercent);
            AverageDisk = samples.Average(sample => sample.DiskUsagePercent);
            CpuUsageChart = BuildChart(samples, sample => sample.CpuUsagePercent, 100, SystemTelemetryFormatter.Percent);
            MemoryChart = BuildChart(samples, sample => sample.MemoryUsagePercent, 100, SystemTelemetryFormatter.Percent);
            DiskChart = BuildChart(samples, sample => sample.DiskUsagePercent, 100, SystemTelemetryFormatter.Percent);
            NetworkChart = BuildChart(
                samples,
                sample => sample.NetworkReceivedBytesPerSecond + sample.NetworkSentBytesPerSecond,
                null,
                SystemTelemetryFormatter.Rate);

            CpuProcessLeaders.Clear();
            foreach (var process in ProcessUsageAggregator.Rank(samples, ProcessUsageAggregator.PeakCpuMetric, 8))
            {
                CpuProcessLeaders.Add(process);
            }

            Summary = $"{samples.Count} samples in {range.Label} | latest {samples[0].CapturedAt.ToLocalTime():HH:mm:ss}";
        });
    }

    public async Task SelectRangeAsync(string key)
    {
        SelectedRangeKey = HistoryRangeCatalog.Resolve(key).Key;
        await RefreshAsync();
    }

    private static HistoryChartSeries BuildChart(
        IReadOnlyList<SystemTelemetrySnapshot> samples,
        Func<SystemTelemetrySnapshot, double> selector,
        double? fixedMaximum,
        Func<double, string> formatter)
    {
        var orderedSamples = samples
            .OrderBy(sample => sample.CapturedAt)
            .ToArray();
        if (orderedSamples.Length == 0)
        {
            return HistoryChartSeries.Empty(formatter(0), $"avg {formatter(0)}");
        }

        var values = orderedSamples
            .Select(sample => Math.Max(0, selector(sample)))
            .ToArray();
        var maximum = fixedMaximum ?? Math.Max(1, values.Max() * 1.15);
        if (maximum <= 0)
        {
            maximum = 1;
        }

        var xStep = orderedSamples.Length == 1
            ? 0
            : ChartWidth / (orderedSamples.Length - 1);
        var usableHeight = ChartHeight - (ChartPadding * 2);
        var points = new PointCollection();
        for (var index = 0; index < values.Length; index++)
        {
            var value = Math.Clamp(values[index], 0, maximum);
            var x = orderedSamples.Length == 1 ? ChartWidth / 2 : index * xStep;
            var y = ChartHeight - ChartPadding - (value / maximum * usableHeight);
            points.Add(new Point(x, y));
        }

        return new HistoryChartSeries(
            formatter(values[^1]),
            $"avg {formatter(values.Average())}",
            points);
    }
}
