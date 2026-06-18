using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using BurrowWin.Services;

namespace BurrowWin.ViewModels;

public partial class ShellViewModel : ViewModelBase
{
    private readonly INavigationService _navigationService;

    public ShellViewModel(INavigationService navigationService)
    {
        _navigationService = navigationService;
    }

    [ObservableProperty]
    private bool canGoBack;

    [ObservableProperty]
    private string selectedRoute = "dashboard";

    [RelayCommand]
    private void Navigate(string route)
    {
        var previousRoute = SelectedRoute;
        SelectedRoute = route;
        if (!_navigationService.NavigateTo(route))
        {
            SelectedRoute = previousRoute;
        }

        RefreshNavigationState();
    }

    [RelayCommand(CanExecute = nameof(CanGoBack))]
    private void GoBack()
    {
        _navigationService.GoBack();
        RefreshNavigationState();
    }

    public void RefreshNavigationState()
    {
        CanGoBack = _navigationService.CanGoBack;
        GoBackCommand.NotifyCanExecuteChanged();
    }
}
