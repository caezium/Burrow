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
            Content = "BurrowWin will revalidate the exact selected artifacts and move safe targets to the Windows Recycle Bin. Failed or changed targets will remain untouched.",
            PrimaryButtonText = "Remove",
            CloseButtonText = "Cancel",
            XamlRoot = XamlRoot
        };

        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            var authorization = ViewModel.ConfirmSelectedRemoval();
            await ViewModel.RemoveAsync(authorization);
        }
    }
}
