using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using BurrowWin.Models;
using BurrowWin.Services;

namespace BurrowWin.ViewModels;

public partial class InstallerViewModel : ViewModelBase
{
    private readonly IInstallerCleanupService _installerCleanupService;
    private readonly IMoleEngineService _moleEngineService;
    private readonly IOperationHistoryService _operationHistoryService;

    public InstallerViewModel(
        IInstallerCleanupService installerCleanupService,
        IMoleEngineService moleEngineService,
        IOperationHistoryService operationHistoryService)
    {
        _installerCleanupService = installerCleanupService;
        _moleEngineService = moleEngineService;
        _operationHistoryService = operationHistoryService;
    }

    public ObservableCollection<InstallerCleanupCandidate> Items { get; } = new();

    public ObservableCollection<string> OutputLines { get; } = new();

    [ObservableProperty]
    private bool isBusy;

    [ObservableProperty]
    private bool canRemove;

    [ObservableProperty]
    private string summary = "Ready to scan old installers";

    [ObservableProperty]
    private string selectedSummary = "0 files";

    [ObservableProperty]
    private string engineSummary = "Mole Windows has no dedicated installer command yet; this view mirrors Mole's old Downloads installer/archive rules.";

    public string OutputText => string.Join(Environment.NewLine, OutputLines);

    [RelayCommand]
    public async Task ScanAsync()
    {
        var startedAt = Stopwatch.GetTimestamp();
        var succeeded = false;
        var historySummary = "Installer preview did not finish";

        IsBusy = true;
        CanRemove = false;
        ClearItems();
        OutputLines.Clear();
        OnPropertyChanged(nameof(OutputText));
        Summary = "Scanning old installers...";

        try
        {
            var availability = _moleEngineService.GetAvailability();
            var items = await _installerCleanupService.PreviewAsync().ConfigureAwait(false);
            succeeded = true;
            historySummary = BuildPreviewSummary(items);

            RunOnUiThread(() =>
            {
                EngineSummary = availability.IsAvailable
                    ? $"Mole engine available at {availability.Path}; installer preview uses Mole-compatible Downloads rules."
                    : $"{availability.Message} Installer preview uses local Windows Downloads rules.";

                ClearItems();
                foreach (var item in items)
                {
                    item.PropertyChanged += Item_PropertyChanged;
                    Items.Add(item);
                }

                Summary = historySummary;
                UpdateSelectionState();
            });
        }
        finally
        {
            await RecordHistoryAsync(
                "installer-preview",
                "old Downloads installers",
                succeeded,
                Stopwatch.GetElapsedTime(startedAt),
                historySummary).ConfigureAwait(false);

            RunOnUiThread(() =>
            {
                IsBusy = false;
                UpdateSelectionState();
            });
        }
    }

    public async Task RemoveAsync()
    {
        var selected = Items.Where(item => item.IsSelected).ToList();
        if (selected.Count == 0)
        {
            return;
        }

        var startedAt = Stopwatch.GetTimestamp();
        var succeeded = false;
        var historySummary = "Installer removal did not finish";

        IsBusy = true;
        CanRemove = false;
        OutputLines.Clear();
        OnPropertyChanged(nameof(OutputText));
        Summary = "Removing selected installers...";

        try
        {
            var results = await _installerCleanupService.RemoveAsync(selected).ConfigureAwait(false);
            var removedBytes = results.Where(result => result.Succeeded).Sum(result => result.SizeBytes);
            var failedCount = results.Count(result => !result.Succeeded);
            succeeded = failedCount == 0;
            historySummary = failedCount == 0
                ? $"Removed {results.Count} files, freed {SystemTelemetryFormatter.Bytes(removedBytes)}"
                : $"Removed {results.Count - failedCount} files; {failedCount} failed";

            RunOnUiThread(() =>
            {
                foreach (var result in results)
                {
                    var prefix = result.Succeeded ? "removed" : "failed";
                    OutputLines.Add($"{prefix}: {result.Path} ({SystemTelemetryFormatter.Bytes(result.SizeBytes)}) {result.Message}");
                }

                Summary = historySummary;
                OnPropertyChanged(nameof(OutputText));
            });
        }
        finally
        {
            await RecordHistoryAsync(
                "installer-remove",
                $"{selected.Count} selected old Downloads installers",
                succeeded,
                Stopwatch.GetElapsedTime(startedAt),
                historySummary).ConfigureAwait(false);

            RunOnUiThread(() =>
            {
                IsBusy = false;
                UpdateSelectionState();
            });
        }
    }

    [RelayCommand]
    public void SelectAll()
    {
        foreach (var item in Items)
        {
            item.IsSelected = true;
        }

        UpdateSelectionState();
    }

    [RelayCommand]
    public void ClearSelection()
    {
        foreach (var item in Items)
        {
            item.IsSelected = false;
        }

        UpdateSelectionState();
    }

    private void Item_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(InstallerCleanupCandidate.IsSelected))
        {
            UpdateSelectionState();
        }
    }

    private void UpdateSelectionState()
    {
        var selected = Items.Where(item => item.IsSelected).ToList();
        var selectedBytes = selected.Sum(item => item.SizeBytes);
        SelectedSummary = $"{selected.Count} files - {SystemTelemetryFormatter.Bytes(selectedBytes)}";
        CanRemove = selected.Count > 0 && !IsBusy;
    }

    private void ClearItems()
    {
        foreach (var item in Items)
        {
            item.PropertyChanged -= Item_PropertyChanged;
        }

        Items.Clear();
        UpdateSelectionState();
    }

    private static string BuildPreviewSummary(IReadOnlyList<InstallerCleanupCandidate> items)
    {
        if (items.Count == 0)
        {
            return "No old installers found";
        }

        var totalBytes = items.Sum(item => item.SizeBytes);
        return $"{items.Count} files - {SystemTelemetryFormatter.Bytes(totalBytes)}";
    }

    private async Task RecordHistoryAsync(
        string operation,
        string arguments,
        bool succeeded,
        TimeSpan duration,
        string historySummary)
    {
        var entry = new OperationHistoryEntry(
            DateTimeOffset.UtcNow,
            "burrowwin",
            operation,
            arguments,
            succeeded ? 0 : 1,
            succeeded,
            (long)duration.TotalMilliseconds,
            historySummary);

        try
        {
            await _operationHistoryService.RecordAsync(entry).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
    }
}
