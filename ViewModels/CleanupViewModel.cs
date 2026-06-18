using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using BurrowWin.Models;

namespace BurrowWin.ViewModels;

public partial class CleanupViewModel : ViewModelBase
{
    private const string PendingFeatureMessage = "Mole Windows is still being updated, stay tuned.";

    public CleanupViewModel()
    {
        Summary = PendingFeatureMessage;
    }

    public ObservableCollection<CleanupPreviewItem> PreviewItems { get; } = new();

    public ObservableCollection<string> OutputLines { get; } = new();

    [ObservableProperty]
    private string summary = PendingFeatureMessage;

    [ObservableProperty]
    private bool isBusy;

    [ObservableProperty]
    private bool canClean;

    [ObservableProperty]
    private bool canPreview;

    [ObservableProperty]
    private string pendingMessage = PendingFeatureMessage;

    public string OutputText => string.Join(Environment.NewLine, OutputLines);

    [RelayCommand]
    public async Task ScanAsync()
    {
        await ShowPendingAsync();
    }

    [RelayCommand]
    public async Task CleanAsync()
    {
        await ShowPendingAsync();
    }

    private Task ShowPendingAsync()
    {
        IsBusy = false;
        CanClean = false;
        CanPreview = false;
        PreviewItems.Clear();
        OutputLines.Clear();
        OutputLines.Add(PendingFeatureMessage);
        OutputLines.Add("The current Mole Windows preview does not expose a stable non-interactive cleanup preview for the GUI yet.");
        Summary = PendingFeatureMessage;
        OnPropertyChanged(nameof(OutputText));
        return Task.CompletedTask;
    }

}
