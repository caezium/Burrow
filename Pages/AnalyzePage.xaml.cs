using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml;
using BurrowWin.Services;
using BurrowWin.ViewModels;

namespace BurrowWin.Pages;

public sealed partial class AnalyzePage : Page
{
    private const double ShellChromeHeight = 172;
    private const double AnalyzeHeaderHeight = 84;
    private bool _autoScanStarted;
    private readonly IStartupDiagnosticsService _diagnostics;

    public AnalyzePage()
    {
        InitializeComponent();
        ViewModel = App.GetService<AnalyzeViewModel>();
        _diagnostics = App.GetService<IStartupDiagnosticsService>();
        DataContext = ViewModel;
    }

    public AnalyzeViewModel ViewModel { get; }

    private async void AnalyzePage_Loaded(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        UpdateAnalyzeRootSize(ActualWidth, ActualHeight);

        if (_autoScanStarted)
        {
            return;
        }

        var autoScan = Environment.GetEnvironmentVariable("BURROWWIN_ANALYZE_AUTOSCAN");
        if (!string.Equals(autoScan, "1", StringComparison.OrdinalIgnoreCase) &&
            !string.Equals(autoScan, "true", StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        _autoScanStarted = true;
        _diagnostics.Record("analyze", "Starting analyze autoscan.");
        UpdateTreemapViewport();
        await ViewModel.ScanAsync();
        UpdateTreemapViewport();
        _diagnostics.Record("analyze", $"Analyze autoscan finished: {ViewModel.Summary}");
    }

    private void AnalyzePage_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        UpdateAnalyzeRootSize(e.NewSize.Width, e.NewSize.Height);
    }

    private void TreemapViewport_Loaded(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        UpdateTreemapViewport();
    }

    private void TreemapViewport_SizeChanged(object sender, Microsoft.UI.Xaml.SizeChangedEventArgs e)
    {
        UpdateTreemapViewport();
    }

    private void UpdateTreemapViewport()
    {
        var padding = TreemapViewport.Padding;
        var width = Math.Max(0, TreemapViewport.ActualWidth - padding.Left - padding.Right);
        var height = Math.Max(0, TreemapViewport.ActualHeight - padding.Top - padding.Bottom);
        ViewModel.UpdateTreemapViewport(width, height);
    }

    private void UpdateAnalyzeRootSize(double width, double height)
    {
        if (Parent is FrameworkElement parent)
        {
            width = Math.Max(width, parent.ActualWidth);
            height = Math.Max(height, parent.ActualHeight);
        }

        if (XamlRoot is not null)
        {
            width = Math.Max(width, XamlRoot.Size.Width);
            height = Math.Max(height, XamlRoot.Size.Height - ShellChromeHeight);
        }

        if (width > 0)
        {
            AnalyzeRoot.Width = width;
        }

        if (height > 0)
        {
            AnalyzeRoot.Height = height;
            TreemapViewport.Height = Math.Max(0, height - AnalyzeHeaderHeight);
        }

        UpdateTreemapViewport();
        DispatcherQueue.TryEnqueue(UpdateTreemapViewport);
    }
}
