using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using BurrowWin.Services;
using BurrowWin.ViewModels;

namespace BurrowWin.Pages;

public sealed partial class InstallerPage : Page
{
    private bool _autoScanStarted;
    private readonly IStartupDiagnosticsService _diagnostics;

    public InstallerPage()
    {
        InitializeComponent();
        ViewModel = App.GetService<InstallerViewModel>();
        _diagnostics = App.GetService<IStartupDiagnosticsService>();
        DataContext = ViewModel;
    }

    public InstallerViewModel ViewModel { get; }

    private async void InstallerPage_Loaded(object sender, RoutedEventArgs e)
    {
        if (_autoScanStarted)
        {
            return;
        }

        var autoScan = Environment.GetEnvironmentVariable("BURROWWIN_INSTALLER_AUTOSCAN");
        if (!string.Equals(autoScan, "1", StringComparison.OrdinalIgnoreCase) &&
            !string.Equals(autoScan, "true", StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        _autoScanStarted = true;
        _diagnostics.Record("installer", "Starting installer autoscan.");
        await ViewModel.ScanAsync();
        _diagnostics.Record("installer", $"Installer autoscan finished: {ViewModel.Summary}");
    }

    private async void RemoveButton_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog
        {
            Title = "Remove old installers?",
            Content = "BurrowWin will remove the selected files from the installer preview list.",
            PrimaryButtonText = "Remove",
            CloseButtonText = "Cancel",
            XamlRoot = XamlRoot
        };

        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            await ViewModel.RemoveAsync();
        }
    }
}
