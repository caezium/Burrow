using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using BurrowWin.Services;
using BurrowWin.Ui;
using BurrowWin.ViewModels;

namespace BurrowWin.Views;

public sealed partial class ShellPage : Page
{
    private readonly INavigationService _navigationService;

    public ShellPage(ShellViewModel viewModel, INavigationService navigationService)
    {
        InitializeComponent();
        ViewModel = viewModel;
        _navigationService = navigationService;
        DataContext = ViewModel;
    }

    public ShellViewModel ViewModel { get; }

    public void InitializeForWindow(Window window)
    {
        window.ExtendsContentIntoTitleBar = true;
        window.SetTitleBar(AppTitleBar);
    }

    private void ShellPage_Loaded(object sender, RoutedEventArgs e)
    {
        _navigationService.Initialize(ContentFrame);
        if (ContentFrame.Content is null)
        {
            ViewModel.NavigateCommand.Execute("status");
            UpdateSelectedRoute("status");
        }

        BurrowButtonVisualState.FreezeTree(this);
    }

    private void TopNav_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string route } && !string.IsNullOrWhiteSpace(route))
        {
            UpdateSelectedRoute(route);
            ViewModel.NavigateCommand.Execute(route);
            UpdateSelectedRoute(ViewModel.SelectedRoute);
        }
    }

    private void ContentFrame_Navigated(object sender, NavigationEventArgs e)
    {
        ViewModel.RefreshNavigationState();
        UpdateSelectedRoute(ViewModel.SelectedRoute);
        if (e.Content is DependencyObject content)
        {
            BurrowButtonVisualState.FreezeTree(content);
        }
    }

    private void UpdateSelectedRoute(string route)
    {
        BurrowButtonVisualState.ApplyNavigationState(BrandButton, true);

        foreach (var button in GetRouteButtons())
        {
            var buttonRoute = button.Tag as string;
            var isSelected = string.Equals(buttonRoute, route, StringComparison.OrdinalIgnoreCase);
            button.Style = (Style)Application.Current.Resources[isSelected ? "BurrowTopNavButtonSelectedStyle" : "BurrowTopNavButtonStyle"];
            BurrowButtonVisualState.ApplyNavigationState(button, isSelected);
        }

        foreach (var button in GetUtilityButtons())
        {
            var buttonRoute = button.Tag as string;
            var isSelected = string.Equals(buttonRoute, route, StringComparison.OrdinalIgnoreCase);
            button.Style = (Style)Application.Current.Resources[isSelected ? "BurrowIconButtonSelectedStyle" : "BurrowIconButtonStyle"];
            BurrowButtonVisualState.ApplyNavigationState(button, isSelected);
        }
    }

    private IEnumerable<Button> GetRouteButtons()
    {
        yield return CleanNavButton;
        yield return OptimizeNavButton;
        yield return AppsNavButton;
        yield return AnalyzeNavButton;
    }

    private IEnumerable<Button> GetUtilityButtons()
    {
        yield return SettingsButton;
    }
}
