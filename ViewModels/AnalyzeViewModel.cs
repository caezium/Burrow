using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using BurrowWin.Models;
using BurrowWin.Services;

namespace BurrowWin.ViewModels;

public partial class AnalyzeViewModel : ViewModelBase
{
    private const double DefaultTreemapWidth = 980;
    private const double DefaultTreemapHeight = 620;
    private const double MinimumTreemapWidth = 320;
    private const double MinimumTreemapHeight = 220;
    private readonly IMoleEngineService _moleEngineService;
    private readonly IDiskAnalyzerService _diskAnalyzerService;
    private CancellationTokenSource? _scanCancellationTokenSource;
    private DiskUsageNode? _lastScanResult;

    public AnalyzeViewModel(IMoleEngineService moleEngineService, IDiskAnalyzerService diskAnalyzerService)
    {
        _moleEngineService = moleEngineService;
        _diskAnalyzerService = diskAnalyzerService;
        var startupRoot = Environment.GetEnvironmentVariable("BURROWWIN_ANALYZE_ROOT");
        RootPath = string.IsNullOrWhiteSpace(startupRoot)
            ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)
            : startupRoot;
    }

    public ObservableCollection<DiskUsageNode> Nodes { get; } = new();

    public ObservableCollection<AnalyzeSidebarItemViewModel> SidebarItems { get; } = new();

    public ObservableCollection<DiskTreemapTileViewModel> TreemapTiles { get; } = new();

    public ObservableCollection<string> OutputLines { get; } = new();

    [ObservableProperty]
    private string rootPath;

    [ObservableProperty]
    private string summary = "Ready to analyze a folder";

    [ObservableProperty]
    private string breadcrumbText = "Home";

    [ObservableProperty]
    private string scanStatusText = "Not scanned";

    [ObservableProperty]
    private string totalItemCountText = "0 items";

    [ObservableProperty]
    private string analyzeOverviewText = "0 items · Not scanned";

    [ObservableProperty]
    private bool hasScanResult;

    [ObservableProperty]
    private bool canShowTreemap;

    [ObservableProperty]
    private bool isBusy;

    [ObservableProperty]
    private string totalSize = "Not scanned";

    [ObservableProperty]
    private double treemapCanvasWidth = DefaultTreemapWidth;

    [ObservableProperty]
    private double treemapCanvasHeight = DefaultTreemapHeight;

    public bool CanCancel => IsBusy && _scanCancellationTokenSource is not null;

    public string OutputText => string.Join(Environment.NewLine, OutputLines);

    [RelayCommand]
    public async Task ScanAsync()
    {
        _scanCancellationTokenSource?.Cancel();
        _scanCancellationTokenSource?.Dispose();
        _scanCancellationTokenSource = new CancellationTokenSource();
        OnPropertyChanged(nameof(CanCancel));

        IsBusy = true;
        Nodes.Clear();
        SidebarItems.Clear();
        TreemapTiles.Clear();
        OutputLines.Clear();
        _lastScanResult = null;
        HasScanResult = false;
        CanShowTreemap = false;
        ScanStatusText = "Scanning";
        TotalSize = "Scanning";
        TotalItemCountText = "0 items";
        AnalyzeOverviewText = "0 items · Scanning";
        OnPropertyChanged(nameof(OutputText));

        try
        {
            var result = await _diskAnalyzerService.AnalyzeAsync(RootPath, new DiskAnalysisOptions(), _scanCancellationTokenSource.Token);
            RunOnUiThread(() =>
            {
                _lastScanResult = result;
                Nodes.Add(result);
                RebuildTreemapTiles();

                foreach (var item in result.Children
                             .OrderByDescending(child => child.SizeBytes)
                             .Select(child => new AnalyzeSidebarItemViewModel(child)))
                {
                    SidebarItems.Add(item);
                }

                var itemCount = CountNodes(result.Children);
                TotalSize = result.SizeText;
                TotalItemCountText = $"{itemCount} items";
                AnalyzeOverviewText = $"{itemCount} items · {result.SizeText}";
                ScanStatusText = $"{result.SizeText} in {itemCount} items";
                BreadcrumbText = BuildBreadcrumbText(result.Path);
                Summary = AnalyzeOverviewText;
                HasScanResult = true;
                CanShowTreemap = TreemapTiles.Count > 0;
            });
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or DirectoryNotFoundException or OperationCanceledException)
        {
            Summary = ex.Message;
            ScanStatusText = "Scan failed";
            TotalSize = "Not scanned";
            AnalyzeOverviewText = "0 items · Not scanned";
            HasScanResult = false;
            CanShowTreemap = false;
            AppendOutput(ex.Message);
        }
        finally
        {
            _scanCancellationTokenSource?.Dispose();
            _scanCancellationTokenSource = null;
            IsBusy = false;
            OnPropertyChanged(nameof(CanCancel));
        }
    }

    [RelayCommand]
    public void Cancel()
    {
        _scanCancellationTokenSource?.Cancel();
    }

    partial void OnIsBusyChanged(bool value)
    {
        OnPropertyChanged(nameof(CanCancel));
    }

    partial void OnRootPathChanged(string value)
    {
        BreadcrumbText = BuildBreadcrumbText(value);
    }

    public void UpdateTreemapViewport(double width, double height)
    {
        var nextWidth = Math.Max(MinimumTreemapWidth, width);
        var nextHeight = Math.Max(MinimumTreemapHeight, height);

        if (Math.Abs(nextWidth - TreemapCanvasWidth) < 1 &&
            Math.Abs(nextHeight - TreemapCanvasHeight) < 1)
        {
            return;
        }

        TreemapCanvasWidth = nextWidth;
        TreemapCanvasHeight = nextHeight;
        RebuildTreemapTiles();
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
                ? "Mole engine is present; this page uses a native non-interactive tree fallback because Mole analyze is an interactive TUI"
                : $"Mole engine check failed with exit code {result.ExitCode}; native tree fallback remains available";
        }
        finally
        {
            IsBusy = false;
        }
    }

    private void AppendOutput(string line)
    {
        RunOnUiThread(() =>
        {
            OutputLines.Add(line);
            OnPropertyChanged(nameof(OutputText));
        });
    }

    private void RebuildTreemapTiles()
    {
        TreemapTiles.Clear();
        if (_lastScanResult is null)
        {
            CanShowTreemap = false;
            return;
        }

        foreach (var tile in DiskTreemapLayout
                     .Build(_lastScanResult, TreemapCanvasWidth, TreemapCanvasHeight)
                     .Select(rect => new DiskTreemapTileViewModel(rect)))
        {
            TreemapTiles.Add(tile);
        }

        CanShowTreemap = TreemapTiles.Count > 0;
    }

    private static int CountNodes(IEnumerable<DiskUsageNode> nodes)
    {
        var count = 0;
        foreach (var node in nodes)
        {
            count++;
            count += CountNodes(node.Children);
        }

        return count;
    }

    private static string BuildBreadcrumbText(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return "Home";
        }

        try
        {
            var expandedPath = Environment.ExpandEnvironmentVariables(path.Trim());
            var profilePath = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            var fullPath = Path.GetFullPath(expandedPath).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            var fullProfilePath = Path.GetFullPath(profilePath).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            if (string.Equals(fullPath, fullProfilePath, StringComparison.OrdinalIgnoreCase))
            {
                return "Home";
            }

            var name = Path.GetFileName(fullPath);
            return string.IsNullOrWhiteSpace(name) ? fullPath : $"Home > {name}";
        }
        catch
        {
            return "Home";
        }
    }
}
