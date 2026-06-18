using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace BurrowWin.Ui;

public static class BurrowButtonVisualState
{
    private static readonly Windows.UI.Color Transparent = Windows.UI.Color.FromArgb(0, 0, 0, 0);
    private static readonly Windows.UI.Color WhitePill = Windows.UI.Color.FromArgb(255, 255, 253, 248);
    private static readonly Windows.UI.Color BlackText = Windows.UI.Color.FromArgb(255, 0, 0, 0);
    private static readonly Windows.UI.Color MutedText = Windows.UI.Color.FromArgb(255, 167, 162, 156);
    private static readonly Windows.UI.Color DimText = Windows.UI.Color.FromArgb(255, 119, 116, 111);
    private static readonly Windows.UI.Color DisabledOnLight = Windows.UI.Color.FromArgb(255, 84, 80, 73);

    private static readonly string[] BurrowButtonStyleKeys =
    [
        "BurrowPillButtonStyle",
        "BurrowSecondaryPillButtonStyle",
        "BurrowTopNavButtonStyle",
        "BurrowTopNavButtonSelectedStyle",
        "BurrowIconButtonStyle",
        "BurrowIconButtonSelectedStyle"
    ];

    public static void ApplyNavigationState(Button button, bool isSelected)
    {
        var background = isSelected ? WhitePill : Transparent;
        var foreground = isSelected ? BlackText : MutedText;

        button.Background = new SolidColorBrush(background);
        button.Foreground = new SolidColorBrush(foreground);
        button.BorderBrush = new SolidColorBrush(background);
        Freeze(button);
    }

    public static void Freeze(Button button)
    {
        var background = CloneBrush(button.Background) ?? new SolidColorBrush(Transparent);
        var foreground = CloneBrush(button.Foreground) ?? new SolidColorBrush(MutedText);
        var border = CloneBrush(button.BorderBrush) ?? CloneBrush(background) ?? new SolidColorBrush(Transparent);

        button.Resources["ButtonBackgroundPointerOver"] = CloneBrush(background);
        button.Resources["ButtonForegroundPointerOver"] = CloneBrush(foreground);
        button.Resources["ButtonBorderBrushPointerOver"] = CloneBrush(border);
        button.Resources["ButtonBackgroundPressed"] = CloneBrush(background);
        button.Resources["ButtonForegroundPressed"] = CloneBrush(foreground);
        button.Resources["ButtonBorderBrushPressed"] = CloneBrush(border);

        button.Resources["ButtonBackgroundDisabled"] = CloneBrush(background);
        button.Resources["ButtonForegroundDisabled"] = new SolidColorBrush(DisabledForegroundFor(background));
        button.Resources["ButtonBorderBrushDisabled"] = CloneBrush(border);
    }

    public static void FreezeTree(DependencyObject root)
    {
        if (root is Button button && IsBurrowButton(button))
        {
            Freeze(button);
        }

        var childCount = VisualTreeHelper.GetChildrenCount(root);
        for (var index = 0; index < childCount; index++)
        {
            FreezeTree(VisualTreeHelper.GetChild(root, index));
        }
    }

    private static bool IsBurrowButton(Button button)
    {
        return IsBurrowStyle(button.Style);
    }

    private static bool IsBurrowStyle(Style? style)
    {
        while (style is not null)
        {
            foreach (var key in BurrowButtonStyleKeys)
            {
                if (Application.Current.Resources.TryGetValue(key, out var resource) && ReferenceEquals(style, resource))
                {
                    return true;
                }
            }

            style = style.BasedOn;
        }

        return false;
    }

    private static Brush? CloneBrush(Brush? brush)
    {
        if (brush is SolidColorBrush solid)
        {
            return new SolidColorBrush(solid.Color)
            {
                Opacity = solid.Opacity
            };
        }

        return brush;
    }

    private static Windows.UI.Color DisabledForegroundFor(Brush background)
    {
        if (background is SolidColorBrush solid && IsLightVisibleBackground(solid.Color))
        {
            return DisabledOnLight;
        }

        return DimText;
    }

    private static bool IsLightVisibleBackground(Windows.UI.Color color)
    {
        if (color.A < 96)
        {
            return false;
        }

        var brightness = (0.299 * color.R) + (0.587 * color.G) + (0.114 * color.B);
        return brightness >= 170;
    }
}
