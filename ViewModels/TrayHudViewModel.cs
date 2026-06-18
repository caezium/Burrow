using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using BurrowWin.Models;
using BurrowWin.Services;

namespace BurrowWin.ViewModels;

public partial class TrayHudViewModel : ViewModelBase
{
    private readonly ISystemTelemetrySamplerService _telemetrySamplerService;
    private readonly IOperationHistoryService _operationHistoryService;

    public TrayHudViewModel(
        ISystemTelemetrySamplerService telemetrySamplerService,
        IOperationHistoryService operationHistoryService)
    {
        _telemetrySamplerService = telemetrySamplerService;
        _operationHistoryService = operationHistoryService;
    }

    public ObservableCollection<ProcessTelemetry> TopProcesses { get; } = new();

    [ObservableProperty]
    private string sampleText = "No telemetry sample yet";

    [ObservableProperty]
    private string healthScore = "--";

    [ObservableProperty]
    private string healthLabel = "warming up";

    [ObservableProperty]
    private string cpuText = "--";

    [ObservableProperty]
    private string memoryText = "--";

    [ObservableProperty]
    private string diskText = "--";

    [ObservableProperty]
    private string networkText = "--";

    [ObservableProperty]
    private string activityTitle = "No activity";

    [ObservableProperty]
    private string activityDetail = "Burrow has not recorded an operation yet.";

    public async Task RefreshAsync()
    {
        var snapshot = _telemetrySamplerService.LatestSnapshot;
        var entries = await _operationHistoryService.ReadRecentAsync(1).ConfigureAwait(false);
        var status = TrayHudStatusFormatter.Build(snapshot, entries.FirstOrDefault());

        RunOnUiThread(() => ApplyStatus(status));
    }

    private void ApplyStatus(TrayHudStatus status)
    {
        SampleText = status.SampleText;
        HealthScore = status.HealthScore;
        HealthLabel = status.HealthLabel;
        CpuText = status.CpuText;
        MemoryText = status.MemoryText;
        DiskText = status.DiskText;
        NetworkText = status.NetworkText;
        ActivityTitle = status.ActivityTitle;
        ActivityDetail = status.ActivityDetail;

        TopProcesses.Clear();
        foreach (var process in status.TopProcesses)
        {
            TopProcesses.Add(process);
        }
    }
}
