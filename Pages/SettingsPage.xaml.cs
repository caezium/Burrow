using Microsoft.UI.Xaml.Controls;
using BurrowWin.ViewModels;

namespace BurrowWin.Pages;

public sealed partial class SettingsPage : Page
{
    public SettingsPage()
    {
        InitializeComponent();
        ViewModel = App.GetService<SettingsViewModel>();
        DataContext = ViewModel;
    }

    public SettingsViewModel ViewModel { get; }
}
