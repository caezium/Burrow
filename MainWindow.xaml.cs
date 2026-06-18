using Microsoft.UI.Windowing;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using BurrowWin.Views;

namespace BurrowWin;

public sealed partial class MainWindow : Window
{
    private static readonly Windows.UI.Color TitleBarColor = Windows.UI.Color.FromArgb(255, 13, 15, 15);

    public MainWindow(ShellPage shellPage)
    {
        InitializeComponent();

        ExtendsContentIntoTitleBar = true;
        SystemBackdrop = new MicaBackdrop();
        Content = shellPage;
        shellPage.InitializeForWindow(this);
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        AppWindow.TitleBar.BackgroundColor = TitleBarColor;
        AppWindow.TitleBar.InactiveBackgroundColor = TitleBarColor;
        AppWindow.TitleBar.ButtonBackgroundColor = TitleBarColor;
        AppWindow.TitleBar.ButtonInactiveBackgroundColor = TitleBarColor;
        AppWindow.TitleBar.ButtonHoverBackgroundColor = Windows.UI.Color.FromArgb(48, 255, 255, 255);
        AppWindow.TitleBar.ButtonPressedBackgroundColor = Windows.UI.Color.FromArgb(64, 255, 255, 255);
        AppWindow.TitleBar.ButtonForegroundColor = Colors.White;
        AppWindow.TitleBar.ButtonInactiveForegroundColor = Colors.Gray;
        AppWindow.SetIcon("Assets/AppIcon.ico");
    }
}
