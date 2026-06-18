using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using BurrowWin.Services;
using BurrowWin.ViewModels;

namespace BurrowWin.Pages;

public sealed partial class CleanupPage : Page
{
    private bool _autoScanStarted;
    private readonly IStartupDiagnosticsService _diagnostics;

    public CleanupPage()
    {
        InitializeComponent();
        ViewModel = App.GetService<CleanupViewModel>();
        _diagnostics = App.GetService<IStartupDiagnosticsService>();
        DataContext = ViewModel;
    }

    public CleanupViewModel ViewModel { get; }

    private async void CleanupPage_Loaded(object sender, RoutedEventArgs e)
    {
        if (_autoScanStarted)
        {
            return;
        }

        var autoScan = Environment.GetEnvironmentVariable("BURROWWIN_CLEAN_AUTOSCAN");
        if (!string.Equals(autoScan, "1", StringComparison.OrdinalIgnoreCase) &&
            !string.Equals(autoScan, "true", StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        _autoScanStarted = true;
        _diagnostics.Record("clean", "Starting clean autoscan.");
        await ViewModel.ScanAsync();
        _diagnostics.Record("clean", $"Clean autoscan finished: {ViewModel.Summary}");
    }

    private async void CleanButton_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = "Clean with Mole",
            Content = "This runs `mo clean` and may delete cache, temp, and log files reported by Mole.",
            PrimaryButtonText = "Clean",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close
        };

        var result = await dialog.ShowAsync();
        if (result == ContentDialogResult.Primary)
        {
            await ViewModel.CleanAsync();
        }
    }
}
