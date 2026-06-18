using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using BurrowWin.Ui;
using BurrowWin.ViewModels;

namespace BurrowWin.Pages;

public sealed partial class DashboardPage : Page
{
    private readonly DispatcherTimer _refreshTimer = new();

    public DashboardPage()
    {
        InitializeComponent();
        ViewModel = App.GetService<DashboardViewModel>();
        DataContext = ViewModel;
        _refreshTimer.Interval = TimeSpan.FromSeconds(15);
        _refreshTimer.Tick += RefreshTimer_Tick;
    }

    public DashboardViewModel ViewModel { get; }

    private async void DashboardPage_Loaded(object sender, RoutedEventArgs e)
    {
        ApplySecondaryNavSelection("status");
        BurrowButtonVisualState.FreezeTree(this);

        if (!ViewModel.IsBusy)
        {
            await ViewModel.RefreshAsync();
        }

        _refreshTimer.Start();
    }

    private void DashboardPage_Unloaded(object sender, RoutedEventArgs e)
    {
        _refreshTimer.Stop();
    }

    private async void RefreshTimer_Tick(object? sender, object e)
    {
        if (!ViewModel.IsBusy)
        {
            await ViewModel.RefreshAsync();
        }
    }

    private void StatusSecondaryNav_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string route } && !string.IsNullOrWhiteSpace(route))
        {
            ApplySecondaryNavSelection(route);
            App.GetService<ShellViewModel>().NavigateCommand.Execute(route);
        }
    }

    private void ApplySecondaryNavSelection(string route)
    {
        BurrowButtonVisualState.ApplyNavigationState(StatusOverviewButton, string.Equals(route, "status", StringComparison.OrdinalIgnoreCase));
        BurrowButtonVisualState.ApplyNavigationState(StatusHistoryButton, string.Equals(route, "history", StringComparison.OrdinalIgnoreCase));
        BurrowButtonVisualState.ApplyNavigationState(StatusActivityButton, string.Equals(route, "activity", StringComparison.OrdinalIgnoreCase));
    }
}
