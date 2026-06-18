using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using BurrowWin.Models;
using BurrowWin.Services;

namespace BurrowWin.ViewModels;

public partial class UninstallViewModel : ViewModelBase
{
    private const string AppsTabUninstall = "uninstall";
    private const string AppsTabUpdates = "updates";
    private const string AppsTabStartup = "startup";

    private readonly IMoleEngineService _moleEngineService;
    private readonly IInstalledApplicationService _installedApplicationService;
    private readonly List<InstalledApplication> _allApplications = [];

    public UninstallViewModel(
        IMoleEngineService moleEngineService,
        IInstalledApplicationService installedApplicationService)
    {
        _moleEngineService = moleEngineService;
        _installedApplicationService = installedApplicationService;
    }

    public ObservableCollection<ApplicationRowViewModel> Applications { get; } = new();

    public ObservableCollection<LeftoverCandidate> Leftovers { get; } = new();

    public ObservableCollection<string> OutputLines { get; } = new();

    [ObservableProperty]
    private string summary = "Load installed applications to start";

    [ObservableProperty]
    private bool isBusy;

    [ObservableProperty]
    private string searchQuery = string.Empty;

    [ObservableProperty]
    private string sortKey = "size";

    [ObservableProperty]
    private bool sortDescending = true;

    [ObservableProperty]
    private InstalledApplication? selectedApplication;

    [ObservableProperty]
    private ApplicationRowViewModel? selectedApplicationRow;

    [ObservableProperty]
    private string leftoverSummary = "No application selected";

    [ObservableProperty]
    private string appsTab = AppsTabUninstall;

    public string OutputText => string.Join(Environment.NewLine, OutputLines);

    public bool CanPreviewLeftovers => SelectedApplication is not null && !IsBusy;

    public bool CanLaunchUninstaller =>
        SelectedApplication is not null &&
        !string.IsNullOrWhiteSpace(SelectedApplication.UninstallString) &&
        !IsBusy;

    public bool CanRemoveSelectedLeftovers => Leftovers.Any(leftover => leftover.IsSelected) && !IsBusy;

    public string SortSummary => $"sorted by {SortKey}{(SortDescending ? " desc" : " asc")}";

    public string AppsCountText => $"{Applications.Count} apps";

    public string LoadedCountText => _allApplications.Count == 0
        ? "Load installed applications"
        : $"Loaded {_allApplications.Count} installed applications";

    public bool IsUninstallTab => string.Equals(AppsTab, AppsTabUninstall, StringComparison.OrdinalIgnoreCase);

    public bool IsUpdatesTab => string.Equals(AppsTab, AppsTabUpdates, StringComparison.OrdinalIgnoreCase);

    public bool IsStartupTab => string.Equals(AppsTab, AppsTabStartup, StringComparison.OrdinalIgnoreCase);

    public bool HasSelectedApplication => SelectedApplication is not null;

    public bool HasLeftovers => Leftovers.Count > 0;

    public string LeftoverSelectionText => Leftovers.Count == 0
        ? "0/0 selected"
        : $"{Leftovers.Count(leftover => leftover.IsSelected)}/{Leftovers.Count} selected";

    public string UpdatesSummary =>
        "Mole Windows update sources are still being connected. App update checks will appear here when Mole exposes a non-interactive Windows source.";

    public string StartupSummary =>
        "Mole Windows startup inventory is still being connected. Startup entries will appear here when the Windows engine exposes them safely.";

    [RelayCommand]
    public async Task LoadAsync()
    {
        IsBusy = true;
        Summary = "Loading installed applications...";
        OutputLines.Clear();
        Leftovers.Clear();
        OnPropertyChanged(nameof(OutputText));

        try
        {
            var apps = await _installedApplicationService.GetInstalledApplicationsAsync();
            RunOnUiThread(() =>
            {
                _allApplications.Clear();
                _allApplications.AddRange(apps);
                ApplyFilter();
                Summary = $"Loaded {_allApplications.Count} installed applications";
                OnPropertyChanged(nameof(LoadedCountText));
            });
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Summary = ex.Message;
            AppendOutput(ex.Message);
        }
        finally
        {
            IsBusy = false;
            PreviewLeftoversCommand.NotifyCanExecuteChanged();
            LaunchUninstallerCommand.NotifyCanExecuteChanged();
            RemoveSelectedLeftoversCommand.NotifyCanExecuteChanged();
        }
    }

    [RelayCommand]
    public void Sort(string key)
    {
        if (string.IsNullOrWhiteSpace(key))
        {
            return;
        }

        if (string.Equals(SortKey, key, StringComparison.OrdinalIgnoreCase))
        {
            SortDescending = !SortDescending;
        }
        else
        {
            SortKey = key;
            SortDescending = !string.Equals(key, "name", StringComparison.OrdinalIgnoreCase);
        }

        ApplyFilter();
        OnPropertyChanged(nameof(SortSummary));
    }

    [RelayCommand]
    public void SelectAppsTab(string tab)
    {
        if (string.IsNullOrWhiteSpace(tab))
        {
            return;
        }

        var normalized = tab.Trim().ToLowerInvariant();
        if (normalized is not (AppsTabUninstall or AppsTabUpdates or AppsTabStartup))
        {
            return;
        }

        AppsTab = normalized;
    }

    [RelayCommand]
    public void SelectAllLeftovers()
    {
        foreach (var leftover in Leftovers)
        {
            leftover.IsSelected = true;
        }

        NotifyLeftoverSelectionState();
    }

    [RelayCommand(CanExecute = nameof(CanPreviewLeftovers))]
    public async Task PreviewLeftoversAsync()
    {
        if (SelectedApplication is null)
        {
            return;
        }

        IsBusy = true;
        Leftovers.Clear();
        NotifyLeftoverSelectionState();

        try
        {
            var leftovers = await _installedApplicationService.PreviewLeftoversAsync(SelectedApplication);
            RunOnUiThread(() =>
            {
                foreach (var leftover in leftovers)
                {
                    Leftovers.Add(leftover);
                    TrackLeftover(leftover);
                }

                var totalBytes = leftovers.Sum(leftover => leftover.SizeBytes);
                LeftoverSummary = leftovers.Count == 0
                    ? "No leftover candidates found"
                    : $"{leftovers.Count} leftover candidates | {SystemTelemetryFormatter.Bytes(totalBytes)}";
                NotifyLeftoverSelectionState();
            });
        }
        finally
        {
            IsBusy = false;
            PreviewLeftoversCommand.NotifyCanExecuteChanged();
            LaunchUninstallerCommand.NotifyCanExecuteChanged();
            RemoveSelectedLeftoversCommand.NotifyCanExecuteChanged();
        }
    }

    [RelayCommand(CanExecute = nameof(CanLaunchUninstaller))]
    public async Task LaunchUninstallerAsync()
    {
        if (SelectedApplication is null)
        {
            return;
        }

        IsBusy = true;
        OutputLines.Clear();
        OnPropertyChanged(nameof(OutputText));

        try
        {
            var result = await _installedApplicationService.LaunchUninstallerAsync(SelectedApplication);
            AppendOutput(result.Succeeded ? result.StandardOutput : result.StandardError);
            Summary = result.Succeeded
                ? $"Started uninstaller for {SelectedApplication.Name}"
                : $"Uninstaller launch failed for {SelectedApplication.Name}";
        }
        finally
        {
            IsBusy = false;
            LaunchUninstallerCommand.NotifyCanExecuteChanged();
            RemoveSelectedLeftoversCommand.NotifyCanExecuteChanged();
        }
    }

    [RelayCommand(CanExecute = nameof(CanRemoveSelectedLeftovers))]
    public async Task RemoveSelectedLeftoversAsync()
    {
        var selected = Leftovers.Where(leftover => leftover.IsSelected).ToArray();
        if (selected.Length == 0)
        {
            return;
        }

        IsBusy = true;
        OutputLines.Clear();
        OnPropertyChanged(nameof(OutputText));

        try
        {
            var results = await _installedApplicationService.RemoveLeftoversAsync(selected);
            RunOnUiThread(() =>
            {
                foreach (var result in results)
                {
                    OutputLines.Add($"{(result.Succeeded ? "OK" : "FAILED")} {result.Path} - {result.Message}");
                }

                foreach (var removed in results.Where(result => result.Succeeded).Select(result => result.Path).ToHashSet(StringComparer.OrdinalIgnoreCase))
                {
                    var item = Leftovers.FirstOrDefault(leftover => string.Equals(leftover.Path, removed, StringComparison.OrdinalIgnoreCase));
                    if (item is not null)
                    {
                        Leftovers.Remove(item);
                    }
                }

                var removedBytes = results.Where(result => result.Succeeded).Sum(result => result.SizeBytes);
                LeftoverSummary = $"Removed {results.Count(result => result.Succeeded)} of {results.Count} selected leftovers | {SystemTelemetryFormatter.Bytes(removedBytes)}";
                OnPropertyChanged(nameof(OutputText));
                NotifyLeftoverSelectionState();
            });
        }
        finally
        {
            IsBusy = false;
            RemoveSelectedLeftoversCommand.NotifyCanExecuteChanged();
        }
    }

    [RelayCommand]
    public async Task CheckMoleAsync()
    {
        IsBusy = true;
        OutputLines.Clear();
        OnPropertyChanged(nameof(OutputText));

        try
        {
            var result = await _moleEngineService.ExecuteCommandAsync("--version", AppendOutput);
            Summary = result.Succeeded
                ? "Mole engine is present; this page uses native inventory and safe leftover preview because Mole uninstall is an interactive TUI"
                : $"Mole engine check failed with exit code {result.ExitCode}; native inventory remains available";
        }
        finally
        {
            IsBusy = false;
        }
    }

    partial void OnSearchQueryChanged(string value)
    {
        ApplyFilter();
    }

    partial void OnSortKeyChanged(string value)
    {
        OnPropertyChanged(nameof(SortSummary));
    }

    partial void OnSortDescendingChanged(bool value)
    {
        OnPropertyChanged(nameof(SortSummary));
    }

    partial void OnSelectedApplicationChanged(InstalledApplication? value)
    {
        Leftovers.Clear();
        LeftoverSummary = value is null ? "No application selected" : $"Selected {value.Name}";
        SyncExpandedRows();
        NotifySelectedApplicationState();
        NotifyLeftoverSelectionState();
    }

    partial void OnSelectedApplicationRowChanged(ApplicationRowViewModel? value)
    {
        SelectedApplication = value?.Application;
    }

    partial void OnAppsTabChanged(string value)
    {
        OnPropertyChanged(nameof(IsUninstallTab));
        OnPropertyChanged(nameof(IsUpdatesTab));
        OnPropertyChanged(nameof(IsStartupTab));
    }

    private void NotifySelectedApplicationState()
    {
        OnPropertyChanged(nameof(HasSelectedApplication));
        OnPropertyChanged(nameof(CanPreviewLeftovers));
        OnPropertyChanged(nameof(CanLaunchUninstaller));
        OnPropertyChanged(nameof(CanRemoveSelectedLeftovers));
        PreviewLeftoversCommand.NotifyCanExecuteChanged();
        LaunchUninstallerCommand.NotifyCanExecuteChanged();
        RemoveSelectedLeftoversCommand.NotifyCanExecuteChanged();
    }

    partial void OnIsBusyChanged(bool value)
    {
        NotifySelectedApplicationState();
        NotifyLeftoverSelectionState();
        PreviewLeftoversCommand.NotifyCanExecuteChanged();
        LaunchUninstallerCommand.NotifyCanExecuteChanged();
        RemoveSelectedLeftoversCommand.NotifyCanExecuteChanged();
    }

    private void ApplyFilter()
    {
        var query = SearchQuery.Trim();
        IEnumerable<InstalledApplication> filtered = string.IsNullOrWhiteSpace(query)
            ? _allApplications
            : _allApplications
                .Where(app =>
                    app.Name.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                    app.Publisher.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                    app.Source.Contains(query, StringComparison.OrdinalIgnoreCase));

        filtered = SortApplications(filtered);

        var selectedId = SelectedApplication?.Id;
        ApplicationRowViewModel? selectedRow = null;

        Applications.Clear();
        foreach (var app in filtered.Take(500))
        {
            var row = new ApplicationRowViewModel(app)
            {
                IsExpanded = !string.IsNullOrWhiteSpace(selectedId) && string.Equals(app.Id, selectedId, StringComparison.OrdinalIgnoreCase)
            };
            Applications.Add(row);
            if (row.IsExpanded)
            {
                selectedRow = row;
            }
        }

        SelectedApplicationRow = selectedRow;
        OnPropertyChanged(nameof(AppsCountText));
        OnPropertyChanged(nameof(LoadedCountText));
    }

    private IEnumerable<InstalledApplication> SortApplications(IEnumerable<InstalledApplication> apps)
    {
        return SortKey.ToLowerInvariant() switch
        {
            "name" => SortDescending
                ? apps.OrderByDescending(app => app.Name, StringComparer.OrdinalIgnoreCase)
                : apps.OrderBy(app => app.Name, StringComparer.OrdinalIgnoreCase),
            "source" => SortDescending
                ? apps.OrderByDescending(app => app.Source, StringComparer.OrdinalIgnoreCase).ThenBy(app => app.Name, StringComparer.OrdinalIgnoreCase)
                : apps.OrderBy(app => app.Source, StringComparer.OrdinalIgnoreCase).ThenBy(app => app.Name, StringComparer.OrdinalIgnoreCase),
            _ => SortDescending
                ? apps.OrderByDescending(app => app.SizeBytes).ThenBy(app => app.Name, StringComparer.OrdinalIgnoreCase)
                : apps.OrderBy(app => app.SizeBytes).ThenBy(app => app.Name, StringComparer.OrdinalIgnoreCase)
        };
    }

    private void AppendOutput(string line)
    {
        RunOnUiThread(() =>
        {
            OutputLines.Add(line);
            OnPropertyChanged(nameof(OutputText));
        });
    }

    private void TrackLeftover(LeftoverCandidate leftover)
    {
        leftover.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(LeftoverCandidate.IsSelected))
            {
                NotifyLeftoverSelectionState();
                RemoveSelectedLeftoversCommand.NotifyCanExecuteChanged();
            }
        };
    }

    private void SyncExpandedRows()
    {
        foreach (var row in Applications)
        {
            row.IsExpanded = SelectedApplication is not null &&
                string.Equals(row.Application.Id, SelectedApplication.Id, StringComparison.OrdinalIgnoreCase);
        }
    }

    private void NotifyLeftoverSelectionState()
    {
        OnPropertyChanged(nameof(HasLeftovers));
        OnPropertyChanged(nameof(LeftoverSelectionText));
        OnPropertyChanged(nameof(CanRemoveSelectedLeftovers));
        RemoveSelectedLeftoversCommand.NotifyCanExecuteChanged();
    }
}
