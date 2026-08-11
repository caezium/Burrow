using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using BurrowWin.Models;
using BurrowWin.Services;

namespace BurrowWin.ViewModels;

public partial class PurgeViewModel : ViewModelBase
{
    private readonly IMoleEngineService _moleEngineService;
    private readonly IPurgeArtifactService _purgeArtifactService;
    private readonly IOperationHistoryService _operationHistoryService;
    private CancellationTokenSource? _operationCancellation;

    public PurgeViewModel(
        IMoleEngineService moleEngineService,
        IPurgeArtifactService purgeArtifactService,
        IOperationHistoryService operationHistoryService)
    {
        _moleEngineService = moleEngineService;
        _purgeArtifactService = purgeArtifactService;
        _operationHistoryService = operationHistoryService;
    }

    public ObservableCollection<PurgeProjectCandidate> Projects { get; } = new();

    public ObservableCollection<string> OutputLines { get; } = new();

    [ObservableProperty]
    private bool isBusy;

    [ObservableProperty]
    private bool canRemove;

    [ObservableProperty]
    private string summary = "Ready to scan project artifacts";

    [ObservableProperty]
    private string selectedSummary = "0 projects";

    [ObservableProperty]
    private string engineSummary = "Mole Windows purge is interactive; BurrowWin previews project artifacts using the same Windows rules.";

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
    public async Task PreviewAsync()
    {
        if (IsBusy)
        {
            return;
        }

        var startedAt = Stopwatch.GetTimestamp();
        var succeeded = false;
        var historySummary = "Purge preview did not finish";

        IsBusy = true;
        CanRemove = false;
        ClearProjects();
        OutputLines.Clear();
        OnPropertyChanged(nameof(OutputText));
        Summary = "Scanning project artifacts...";
        CurrentTarget = "Scanning project roots";
        IsProgressIndeterminate = true;
        BeginOperation();

        try
        {
            var availability = _moleEngineService.GetAvailability();
            EngineSummary = availability.IsAvailable
                ? $"Mole engine available at {availability.Path}; purge preview uses non-interactive Windows rules."
                : $"{availability.Message} Purge preview still uses local Windows artifact rules.";

            var projects = await _purgeArtifactService.PreviewAsync(
                cancellationToken: _operationCancellation!.Token).ConfigureAwait(false);
            succeeded = true;
            historySummary = BuildPreviewSummary(projects);

            RunOnUiThread(() =>
            {
                ClearProjects();
                foreach (var project in projects)
                {
                    project.PropertyChanged += Project_PropertyChanged;
                    Projects.Add(project);
                }

                Summary = historySummary;
                UpdateSelectionState();
            });
        }
        catch (OperationCanceledException)
        {
            historySummary = "Purge preview cancelled before completion";
            RunOnUiThread(() => Summary = historySummary);
        }
        finally
        {
            await RecordHistoryAsync(
                "purge-preview",
                "project artifacts",
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
        return _purgeArtifactService.ConfirmRemoval(
            Projects.Where(project => project.IsSelected).ToList());
    }

    public async Task RemoveAsync(ConfirmedDeletionAuthorization authorization)
    {
        if (IsBusy)
        {
            return;
        }

        var selectedProjects = Projects.Where(project => project.IsSelected).ToList();
        if (selectedProjects.Count == 0)
        {
            return;
        }

        var startedAt = Stopwatch.GetTimestamp();
        var historySummary = "Purge removal did not finish";

        IsBusy = true;
        CanRemove = false;
        OutputLines.Clear();
        OnPropertyChanged(nameof(OutputText));
        Summary = "Removing selected project artifacts...";
        BeginOperation();
        IsProgressIndeterminate = false;
        ProgressMaximum = 100;
        ProgressValue = 0;
        CurrentTarget = "Waiting to process the first selected artifact";

        try
        {
            var progress = new Progress<DeletionProgress>(ApplyProgress);
            var batch = await _purgeArtifactService.RemoveAsync(
                selectedProjects,
                authorization,
                progress,
                _operationCancellation!.Token).ConfigureAwait(false);
            historySummary = BuildRemovalSummary(batch, "artifacts");

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
                "purge-remove",
                $"{selectedProjects.Count} selected projects",
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
        foreach (var project in Projects)
        {
            project.IsSelected = true;
        }

        UpdateSelectionState();
    }

    [RelayCommand]
    public void ClearSelection()
    {
        foreach (var project in Projects)
        {
            project.IsSelected = false;
        }

        UpdateSelectionState();
    }

    [RelayCommand]
    public async Task CheckMoleAsync()
    {
        IsBusy = true;
        try
        {
            var result = await _moleEngineService.ExecuteCommandAsync("purge --help", AppendOutput).ConfigureAwait(false);
            RunOnUiThread(() =>
            {
                EngineSummary = result.Succeeded
                    ? "Mole purge is present; its Windows command is interactive, so BurrowWin uses a safe preview list before deleting artifacts."
                    : $"Mole purge help failed with exit code {result.ExitCode}; local preview remains available.";
            });
        }
        finally
        {
            RunOnUiThread(() => IsBusy = false);
        }
    }

    private void Project_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(PurgeProjectCandidate.IsSelected))
        {
            UpdateSelectionState();
        }
    }

    private void UpdateSelectionState()
    {
        var selected = Projects.Where(project => project.IsSelected).ToList();
        var selectedBytes = selected.Sum(project => project.TotalSizeBytes);
        SelectedSummary = $"{selected.Count} projects - {SystemTelemetryFormatter.Bytes(selectedBytes)}";
        CanRemove = selected.Count > 0 && !IsBusy;
    }

    private void ClearProjects()
    {
        foreach (var project in Projects)
        {
            project.PropertyChanged -= Project_PropertyChanged;
        }

        Projects.Clear();
        UpdateSelectionState();
    }

    private static string BuildPreviewSummary(IReadOnlyList<PurgeProjectCandidate> projects)
    {
        if (projects.Count == 0)
        {
            return "No cleanable project artifacts found";
        }

        var totalBytes = projects.Sum(project => project.TotalSizeBytes);
        var totalArtifacts = projects.Sum(project => project.ArtifactCount);
        return $"{projects.Count} projects - {totalArtifacts} artifacts - {SystemTelemetryFormatter.Bytes(totalBytes)}";
    }

    private static string BuildRemovalSummary(DeletionBatchResult batch, string noun)
    {
        return $"{batch.Outcome}: recycled {batch.RecycledCount}/{batch.TotalSelectedItems} {noun}, " +
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

    private void AppendOutput(string line)
    {
        RunOnUiThread(() =>
        {
            OutputLines.Add(line);
            OnPropertyChanged(nameof(OutputText));
        });
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
