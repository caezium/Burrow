using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using BurrowWin.Ui;
using BurrowWin.ViewModels;

namespace BurrowWin.Pages;

public sealed partial class HistoryPage : Page
{
    public HistoryPage()
    {
        InitializeComponent();
        ViewModel = App.GetService<HistoryViewModel>();
        DataContext = ViewModel;
    }

    public HistoryViewModel ViewModel { get; }

    private async void HistoryPage_Loaded(object sender, RoutedEventArgs e)
    {
        await ViewModel.RefreshAsync();
        UpdateRangeButtons();
        BurrowButtonVisualState.FreezeTree(this);
    }

    private async void RangeButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string rangeKey } && !string.IsNullOrWhiteSpace(rangeKey))
        {
            await ViewModel.SelectRangeAsync(rangeKey);
            UpdateRangeButtons();
        }
    }

    private void UpdateRangeButtons()
    {
        foreach (var button in GetRangeButtons())
        {
            var buttonRange = button.Tag as string;
            var isSelected = string.Equals(buttonRange, ViewModel.SelectedRangeKey, StringComparison.OrdinalIgnoreCase);
            button.Style = (Style)Application.Current.Resources[isSelected ? "BurrowTopNavButtonSelectedStyle" : "BurrowTopNavButtonStyle"];
            BurrowButtonVisualState.ApplyNavigationState(button, isSelected);
        }
    }

    private IEnumerable<Button> GetRangeButtons()
    {
        yield return Range5mButton;
        yield return Range1hButton;
        yield return Range6hButton;
        yield return Range24hButton;
        yield return Range7dButton;
        yield return Range30dButton;
        yield return Range90dButton;
    }
}
