using Microsoft.UI.Xaml.Controls;
using BurrowWin.Pages;

namespace BurrowWin.Services;

public sealed class NavigationService : INavigationService
{
    private readonly Dictionary<string, Type> _routes = new(StringComparer.OrdinalIgnoreCase)
    {
        ["status"] = typeof(DashboardPage),
        ["dashboard"] = typeof(DashboardPage),
        ["clean"] = typeof(CleanupPage),
        ["cleanup"] = typeof(CleanupPage),
        ["purge"] = typeof(PurgePage),
        ["installer"] = typeof(InstallerPage),
        ["optimize"] = typeof(OptimizePage),
        ["apps"] = typeof(UninstallPage),
        ["uninstall"] = typeof(UninstallPage),
        ["analyze"] = typeof(AnalyzePage),
        ["history"] = typeof(HistoryPage),
        ["activity"] = typeof(ActivityPage),
        ["settings"] = typeof(SettingsPage)
    };

    private Frame? _frame;

    public bool CanGoBack => _frame?.CanGoBack == true;

    public void Initialize(Frame frame)
    {
        _frame = frame;
    }

    public bool NavigateTo(string route)
    {
        if (_frame is null || !_routes.TryGetValue(route, out var pageType))
        {
            return false;
        }

        if (_frame.Content?.GetType() == pageType)
        {
            return true;
        }

        return _frame.Navigate(pageType);
    }

    public bool GoBack()
    {
        if (_frame?.CanGoBack != true)
        {
            return false;
        }

        _frame.GoBack();
        return true;
    }
}
