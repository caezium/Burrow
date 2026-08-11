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
    private CancellationTokenSource? _operationCancellation;

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

    [ObservableProperty]
    private string currentTarget = "No active target";

    [ObservableProperty]
    private int progressValue;

    [ObservableProperty]
    private int progressMaximum = 100;

    [ObservableProperty]
    private bool isProgressIndeterminate;

    public string OutputText => string.Join(Environment.NewLine, OutputLines);

    public bool CanStartOperation => !IsBusy;

    public bool CanCancel => IsBusy && _operationCancellation is not null;

    [RelayCommand]
    public async Task ScanAsync()
    {
        if (IsBusy)
        {
            return;
        }

        var startedAt = Stopwatch.GetTimestamp();
        var succeeded = false;
        var historySummary = "Installer preview did not finish";

        IsBusy = true;
        CanRemove = false;
        ClearItems();
        OutputLines.Clear();
        OnPropertyChanged(nameof(OutputText));
        Summary = "Scanning old installers...";
        CurrentTarget = "Scanning the configured Downloads directory";
        IsProgressIndeterminate = true;
        BeginOperation();

        try
        {
            var availability = _moleEngineService.GetAvailability();
            var items = await _installerCleanupService.PreviewAsync(_operationCancellation!.Token).ConfigureAwait(false);
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
        catch (OperationCanceledException)
        {
            historySummary = "Installer preview cancelled before completion";
            RunOnUiThread(() => Summary = historySummary);
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
                IsProgressIndeterminate = false;
                CurrentTarget = "No active target";
                UpdateSelectionState();
                EndOperation();
            });
        }
    }

    public ConfirmedDeletionAuthorization ConfirmSelectedRemoval()
    {
        return _installerCleanupService.ConfirmRemoval(
            Items.Where(item => item.IsSelected).ToList());
    }

    public async Task RemoveAsync(ConfirmedDeletionAuthorization authorization)
    {
        if (IsBusy)
        {
            return;
        }

        var selected = Items.Where(item => item.IsSelected).ToList();
        if (selected.Count == 0)
        {
            return;
        }

        var startedAt = Stopwatch.GetTimestamp();
        var historySummary = "Installer removal did not finish";

        IsBusy = true;
        CanRemove = false;
        OutputLines.Clear();
        OnPropertyChanged(nameof(OutputText));
        Summary = "Removing selected installers...";
        BeginOperation();
        IsProgressIndeterminate = false;
        ProgressMaximum = 100;
        ProgressValue = 0;
        CurrentTarget = "Waiting to process the first selected file";

        try
        {
            var progress = new Progress<DeletionProgress>(ApplyProgress);
            var batch = await _installerCleanupService.RemoveAsync(
                selected,
                authorization,
                progress,
                _operationCancellation!.Token).ConfigureAwait(false);
            historySummary = BuildRemovalSummary(batch);

            RunOnUiThread(() =>
            {
                foreach (var result in batch.ItemResults)
                {
                    OutputLines.Add($"{result.Status}: {result.Path} {result.Message}");
                }

                Summary = historySummary;
                OnPropertyChanged(nameof(OutputText));
            });

            await RecordBatchHistoryAsync(
                "installer-remove",
                $"{selected.Count} selected old Downloads installers",
                batch,
                Stopwatch.GetElapsedTime(startedAt),
                historySummary).ConfigureAwait(false);
        }
        finally
        {
            RunOnUiThread(() =>
            {
                IsBusy = false;
                IsProgressIndeterminate = false;
                CurrentTarget = "No active target";
                UpdateSelectionState();
                EndOperation();
            });
        }
    }

    [RelayCommand]
    public void Cancel()
    {
        _operationCancellation?.Cancel();
        Summary = "Cancellation requested; waiting for the active item to finish...";
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

    private static string BuildRemovalSummary(DeletionBatchResult batch)
    {
        return $"{batch.Outcome}: recycled {batch.RecycledCount}/{batch.TotalSelectedItems} files, " +
               $"absent {batch.AlreadyAbsentCount}, rejected {batch.RejectedCount}, failed {batch.FailedCount}, " +
               $"recycled {SystemTelemetryFormatter.Bytes(batch.RecycledBytes)} (operation {batch.OperationId})";
    }

    private void ApplyProgress(DeletionProgress progress)
    {
        RunOnUiThread(() =>
        {
            ProgressMaximum = 100;
            ProgressValue = Math.Clamp(progress.CompletionPercent, 0, 100);
            CurrentTarget = progress.CurrentPath ?? "Waiting for next target";
        });
    }

    private void BeginOperation()
    {
        _operationCancellation?.Dispose();
        _operationCancellation = new CancellationTokenSource();
        OnPropertyChanged(nameof(CanCancel));
        CancelCommand.NotifyCanExecuteChanged();
    }

    private void EndOperation()
    {
        _operationCancellation?.Dispose();
        _operationCancellation = null;
        OnPropertyChanged(nameof(CanCancel));
        CancelCommand.NotifyCanExecuteChanged();
    }

    partial void OnIsBusyChanged(bool value)
    {
        OnPropertyChanged(nameof(CanStartOperation));
        OnPropertyChanged(nameof(CanCancel));
        CancelCommand.NotifyCanExecuteChanged();
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

    private async Task RecordBatchHistoryAsync(
        string operation,
        string arguments,
        DeletionBatchResult batch,
        TimeSpan duration,
        string historySummary)
    {
        var entry = new OperationHistoryEntry(
            DateTimeOffset.UtcNow,
            "burrowwin",
            operation,
            arguments,
            batch.ExitCode,
            batch.Succeeded,
            (long)duration.TotalMilliseconds,
            historySummary,
            batch.Outcome,
            batch.OperationId,
            batch.RecycledCount,
            batch.AlreadyAbsentCount,
            batch.RejectedCount,
            batch.FailedCount,
            batch.ProcessedCount,
            batch.TotalSelectedItems,
            batch.RecycledBytes,
            batch.Cancelled);

        try
        {
            await _operationHistoryService.RecordAsync(entry).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
    }
}
