using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml;
using BurrowWin.Ui;
using BurrowWin.ViewModels;
using System.ComponentModel;

namespace BurrowWin.Pages;

public sealed partial class UninstallPage : Page
{
    private bool _loadStarted;

    public UninstallPage()
    {
        InitializeComponent();
        ViewModel = App.GetService<UninstallViewModel>();
        DataContext = ViewModel;
        ViewModel.PropertyChanged += ViewModel_PropertyChanged;
    }

    public UninstallViewModel ViewModel { get; }

    private async void UninstallPage_Loaded(object sender, RoutedEventArgs e)
    {
        if (_loadStarted)
        {
            return;
        }

        _loadStarted = true;
        await ViewModel.LoadAsync();
        UpdateAppsSurface();
        BurrowButtonVisualState.FreezeTree(this);
    }

    private void ViewModel_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(UninstallViewModel.AppsTab))
        {
            UpdateAppsSurface();
        }

        if (e.PropertyName is nameof(UninstallViewModel.SortKey))
        {
            UpdateSortVisuals();
        }
    }

    private void AppsTabButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button button || button.Tag is not string tab)
        {
            return;
        }

        ViewModel.SelectAppsTabCommand.Execute(tab);
        UpdateAppsSurface();
    }

    private async void UninstallButton_Click(object sender, RoutedEventArgs e)
    {
        var appName = ViewModel.SelectedApplication?.Name ?? "the selected application";
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = "Start uninstaller",
            Content = $"This launches the registered Windows uninstaller for {appName}. Follow the vendor uninstaller prompts before removing leftovers.",
            PrimaryButtonText = "Start",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close
        };

        var result = await dialog.ShowAsync();
        if (result == ContentDialogResult.Primary)
        {
            await ViewModel.LaunchUninstallerAsync();
        }
    }

    private async void RemoveLeftoversButton_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = "Remove selected leftovers",
            Content = "This permanently deletes the checked leftover paths. Protected roots are blocked, but the selected files cannot be restored from BurrowWin.",
            PrimaryButtonText = "Remove",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close
        };

        var result = await dialog.ShowAsync();
        if (result == ContentDialogResult.Primary)
        {
            await ViewModel.RemoveSelectedLeftoversAsync();
        }
    }

    private async void UnsupportedAppsFeatureButton_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = "Mole Windows is still being updated",
            Content = "Non-interactive Windows app update sources are not available yet. Burrow will show updates here when Mole exposes safe update metadata.",
            CloseButtonText = "OK",
            DefaultButton = ContentDialogButton.Close
        };

        await dialog.ShowAsync();
    }

    private void UpdateAppsSurface()
    {
        SetSegmentButton(UninstallTabButton, ViewModel.IsUninstallTab);
        SetSegmentButton(UpdatesTabButton, ViewModel.IsUpdatesTab);
        SetSegmentButton(StartupTabButton, ViewModel.IsStartupTab);

        UninstallContent.Visibility = ViewModel.IsUninstallTab ? Visibility.Visible : Visibility.Collapsed;
        UpdatesContent.Visibility = ViewModel.IsUpdatesTab ? Visibility.Visible : Visibility.Collapsed;
        StartupContent.Visibility = ViewModel.IsStartupTab ? Visibility.Visible : Visibility.Collapsed;

        UpdateSortVisuals();
    }

    private void UpdateSortVisuals()
    {
        SetSortButton(NameSortButton, "name");
        SetSortButton(SizeSortButton, "size");
        SetSortButton(SourceSortButton, "source");
    }

    private void SetSortButton(Button button, string key)
    {
        var isSelected = string.Equals(ViewModel.SortKey, key, StringComparison.OrdinalIgnoreCase);
        SetSegmentButton(button, isSelected);
    }

    private static void SetSegmentButton(Button button, bool isSelected)
    {
        button.Style = (Style)Application.Current.Resources[
            isSelected ? "BurrowTopNavButtonSelectedStyle" : "BurrowTopNavButtonStyle"];
        BurrowButtonVisualState.ApplyNavigationState(button, isSelected);
    }
}
