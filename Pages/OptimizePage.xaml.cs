using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using BurrowWin.Services;
using BurrowWin.ViewModels;

namespace BurrowWin.Pages;

public sealed partial class OptimizePage : Page
{
    private bool _autoPreviewStarted;
    private readonly IStartupDiagnosticsService _diagnostics;

    public OptimizePage()
    {
        InitializeComponent();
        ViewModel = App.GetService<OptimizeViewModel>();
        _diagnostics = App.GetService<IStartupDiagnosticsService>();
        DataContext = ViewModel;
    }

    public OptimizeViewModel ViewModel { get; }

    private async void OptimizePage_Loaded(object sender, RoutedEventArgs e)
    {
        if (_autoPreviewStarted)
        {
            return;
        }

        var autoPreview = Environment.GetEnvironmentVariable("BURROWWIN_OPTIMIZE_AUTOSCAN");
        if (!string.Equals(autoPreview, "1", StringComparison.OrdinalIgnoreCase) &&
            !string.Equals(autoPreview, "true", StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        _autoPreviewStarted = true;
        _diagnostics.Record("optimize", "Starting optimize auto-preview.");
        await ViewModel.PreviewAsync();
        _diagnostics.Record("optimize", $"Optimize auto-preview finished: {ViewModel.Summary}");
    }

    private async void OptimizeButton_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = "Optimize with Mole",
            Content = "This runs `mo optimize` and may restart Windows services or refresh system caches.",
            PrimaryButtonText = "Optimize",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close
        };

        var result = await dialog.ShowAsync();
        if (result == ContentDialogResult.Primary)
        {
            await ViewModel.OptimizeAsync();
        }
    }
}
