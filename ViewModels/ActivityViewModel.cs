using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using BurrowWin.Models;
using BurrowWin.Services;

namespace BurrowWin.ViewModels;

public partial class ActivityViewModel : ViewModelBase
{
    private readonly IOperationHistoryService _operationHistoryService;

    public ActivityViewModel(IOperationHistoryService operationHistoryService)
    {
        _operationHistoryService = operationHistoryService;
        HistoryPath = _operationHistoryService.HistoryFilePath;
    }

    public ObservableCollection<OperationHistoryEntry> Entries { get; } = new();

    [ObservableProperty]
    private string summary = "No activity loaded";

    [ObservableProperty]
    private string historyPath = string.Empty;

    [RelayCommand]
    public async Task RefreshAsync()
    {
        var entries = await _operationHistoryService.ReadRecentAsync(50);
        RunOnUiThread(() =>
        {
            Entries.Clear();
            foreach (var entry in entries)
            {
                Entries.Add(entry);
            }

            Summary = entries.Count == 0 ? "No Burrow activity yet" : $"{entries.Count} recent operations";
        });
    }
}
