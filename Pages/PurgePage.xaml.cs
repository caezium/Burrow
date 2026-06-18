using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using BurrowWin.ViewModels;

namespace BurrowWin.Pages;

public sealed partial class PurgePage : Page
{
    public PurgePage()
    {
        InitializeComponent();
        ViewModel = App.GetService<PurgeViewModel>();
        DataContext = ViewModel;
    }

    public PurgeViewModel ViewModel { get; }

    private async void RemoveButton_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog
        {
            Title = "Remove project artifacts?",
            Content = "BurrowWin will remove the selected build artifacts from the preview list.",
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
