using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace BurrowWin.ViewModels;

public partial class OptimizeViewModel : ViewModelBase
{
    private const string PendingFeatureMessage = "Mole Windows is still being updated, stay tuned";

    public OptimizeViewModel()
    {
        Summary = PendingFeatureMessage;
    }

    public ObservableCollection<string> OutputLines { get; } = new();

    [ObservableProperty]
    private string summary = PendingFeatureMessage;

    [ObservableProperty]
    private bool isBusy;

    [ObservableProperty]
    private bool canOptimize;

    [ObservableProperty]
    private bool canPreview;

    [ObservableProperty]
    private string pendingMessage = PendingFeatureMessage;

    public string OutputText => string.Join(Environment.NewLine, OutputLines);

    [RelayCommand]
    public async Task PreviewAsync()
    {
        await ShowPendingAsync();
    }

    [RelayCommand]
    public async Task OptimizeAsync()
    {
        await ShowPendingAsync();
    }

    private Task ShowPendingAsync()
    {
        IsBusy = false;
        CanOptimize = false;
        CanPreview = false;
        OutputLines.Clear();
        OutputLines.Add(PendingFeatureMessage);
        OutputLines.Add("The current Mole Windows preview only exposes a dry-run optimize path; GUI execution remains disabled until the engine is non-interactive and safe.");
        Summary = PendingFeatureMessage;
        OnPropertyChanged(nameof(OutputText));
        return Task.CompletedTask;
    }

}
